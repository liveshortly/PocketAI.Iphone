import AVFoundation
import Foundation
import Observation
import PocketKit
import Speech
import UIKit
import os

/// State of voice dictation and transcription.
public enum VoiceDictationState: Equatable, Sendable {
    case idle
    case recording(isHandsFree: Bool)
    case transcribing
    case denied(String)
    case error(String)
}

/// Token sink for collecting transcription output from `SpeechToTextEngine`.
/// Conforms to `Sendable` via `OSAllocatedUnfairLock` without `@unchecked Sendable`.
final class VoiceTokenSink: TokenSink, Sendable {
    private struct State: Sendable {
        var text: String = ""
        var error: PocketError?
        var isDone: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func onDelta(delta: GenerateDelta) {
        state.withLock { $0.text += delta.text }
    }

    func onDone(stats: GenerateStats) {
        state.withLock { $0.isDone = true }
    }

    func onError(err: PocketError) {
        state.withLock { $0.error = err }
    }

    var resultText: String {
        state.withLock { $0.text }
    }

    var resultError: PocketError? {
        state.withLock { $0.error }
    }
}

/// Controller managing microphone recording, level metering, and on-device transcription.
@Observable
@MainActor
public final class VoiceDictation {
    public private(set) var state: VoiceDictationState = .idle
    public private(set) var audioLevel: Float = 0.0
    public private(set) var audioLevels: [Float] = Array(repeating: 0.1, count: 12)

    private var recorder: AVAudioRecorder?
    private var tempAudioURL: URL?
    private var meteringTask: Task<Void, Never>?

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public var isTranscribing: Bool {
        if case .transcribing = state { return true }
        return false
    }

    public var isHandsFree: Bool {
        if case .recording(let handsFree) = state { return handsFree }
        return false
    }

    public init() {}

    private var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Check and request microphone and speech recognition permissions.
    private func checkAndRequestPermissions() async -> Bool {
        // Speech recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .denied, .restricted:
            state = .denied("Speech recognition is off for PocketAI. Turn it on in Settings to dictate.")
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if !granted {
                state = .denied("Speech recognition permission is required for voice input.")
                return false
            }
        case .authorized:
            break
        @unknown default:
            break
        }

        // Microphone
        let micGranted: Bool
        if #available(iOS 17.0, *) {
            let status = AVAudioApplication.shared.recordPermission
            switch status {
            case .denied:
                state = .denied("Microphone access is off for PocketAI. Turn it on in Settings to dictate.")
                return false
            case .undetermined:
                micGranted = await AVAudioApplication.requestRecordPermission()
            case .granted:
                micGranted = true
            @unknown default:
                micGranted = false
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .denied:
                state = .denied("Microphone access is off for PocketAI. Turn it on in Settings to dictate.")
                return false
            case .undetermined:
                micGranted = await withCheckedContinuation { continuation in
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            case .granted:
                micGranted = true
            @unknown default:
                micGranted = false
            }
        }

        if !micGranted {
            state = .denied("Microphone permission is required for voice input.")
            return false
        }

        return true
    }

    /// Start voice recording session.
    public func start(handsFree: Bool) async {
        guard state == .idle else { return }

        guard await checkAndRequestPermissions() else { return }

        do {
            if !isRunningInPreview {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }

            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("dictation_\(UUID().uuidString).m4a")
            self.tempAudioURL = fileURL

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .error("Failed to start recording audio.")
                return
            }

            self.recorder = recorder
            self.state = .recording(isHandsFree: handsFree)
            self.audioLevels = Array(repeating: 0.1, count: 12)
            self.audioLevel = 0.0

            startMetering()
            AccessibilityNotification.Announcement(handsFree ? "Hands-free voice recording started" : "Voice recording started").post()
        } catch {
            state = .error(String(localized: "Failed to initialize recording: \(error.localizedDescription)"))
        }
    }

    /// Stop recording and transcribe the recorded audio.
    public func stop() async -> String? {
        guard case .recording(let handsFree) = state else { return nil }
        stopMetering()
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()

        state = .transcribing
        AccessibilityNotification.Announcement("Transcribing voice input").post()

        guard let tempAudioURL else {
            state = .idle
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: tempAudioURL)
            self.tempAudioURL = nil
        }

        do {
            let path = tempAudioURL.path
            let text = try await Task.detached { () -> String in
                let sink = VoiceTokenSink()
                let engine = AppleSpeechToTextEngine()
                try engine.transcribe(audioPath: path, lang: nil, sink: sink)
                if let error = sink.resultError {
                    throw error
                }
                return sink.resultText
            }.value

            state = .idle
            AccessibilityNotification.Announcement(handsFree ? "Voice message ready to send" : "Voice transcribed").post()
            return text
        } catch {
            let errorMessage: String
            if case .Internal(let msg) = error as? PocketError {
                errorMessage = msg
            } else {
                errorMessage = error.localizedDescription
            }
            state = .error(String(localized: "Transcription failed: \(errorMessage)"))
            AccessibilityNotification.Announcement("Transcription failed").post()
            return nil
        }
    }

    /// Cancel active recording session and discard audio.
    public func cancel() {
        stopMetering()
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        if let tempAudioURL {
            try? FileManager.default.removeItem(at: tempAudioURL)
            self.tempAudioURL = nil
        }
        audioLevels = Array(repeating: 0.1, count: 12)
        audioLevel = 0.0
        state = .idle
        AccessibilityNotification.Announcement("Recording cancelled").post()
    }

    /// Dismiss denied or error state.
    public func dismissError() {
        state = .idle
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let recorder = self.recorder, recorder.isRecording else { break }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                let minDb: Float = -50.0
                let normalized = max(0.08, min(1.0, (power - minDb) / (-minDb)))
                self.audioLevel = normalized
                self.audioLevels.removeFirst()
                self.audioLevels.append(normalized)
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
    }

    private func deactivateAudioSession() {
        if !isRunningInPreview {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
