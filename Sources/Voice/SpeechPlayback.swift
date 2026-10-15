import AVFoundation
import Foundation
import Observation
import PocketKit
import UIKit

/// Controller managing text-to-speech synthesis and audio playback.
@Observable
@MainActor
public final class SpeechPlayback: NSObject {
    public private(set) var isSpeaking: Bool = false
    public private(set) var currentText: String?

    private var player: AVAudioPlayer?
    private var tempAudioURL: URL?
    private var synthTask: Task<Void, Never>?

    private var isRunningInPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    public override init() {
        super.init()
    }

    /// Synthesize and play the specified text aloud.
    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Stop any current playback or synthesis
        stopPlaybackOnly()

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("speech_\(UUID().uuidString).wav")
        self.tempAudioURL = fileURL
        self.currentText = trimmed
        self.isSpeaking = true

        AccessibilityNotification.Announcement("Speaking reply").post()

        let filePath = fileURL.path
        synthTask = Task { [weak self] in
            do {
                try await Task.detached {
                    let engine = AppleTextToSpeechEngine()
                    try engine.synthesize(text: trimmed, voice: "", outPath: filePath)
                }.value

                guard !Task.isCancelled else {
                    Self.deleteFile(at: fileURL)
                    return
                }

                guard let self else {
                    Self.deleteFile(at: fileURL)
                    return
                }

                self.startPlaying(url: fileURL)
            } catch {
                guard let self else {
                    Self.deleteFile(at: fileURL)
                    return
                }
                self.resetState()
            }
        }
    }

    /// Stop playback and cancel any ongoing synthesis.
    public func stop() {
        let wasSpeaking = isSpeaking
        stopPlaybackOnly()
        resetState()
        if wasSpeaking {
            AccessibilityNotification.Announcement("Speech stopped").post()
        }
    }

    private func stopPlaybackOnly() {
        synthTask?.cancel()
        synthTask = nil
        player?.stop()
        player = nil
    }

    private func startPlaying(url: URL) {
        do {
            if !isRunningInPreview {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
            }

            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            guard audioPlayer.play() else {
                resetState()
                return
            }
            self.player = audioPlayer
        } catch {
            resetState()
        }
    }

    private func resetState() {
        let wasSpeaking = isSpeaking
        isSpeaking = false
        currentText = nil
        if !isRunningInPreview && wasSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let url = tempAudioURL {
            Self.deleteFile(at: url)
            tempAudioURL = nil
        }
    }

    private static func deleteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

extension SpeechPlayback: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.resetState()
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.resetState()
        }
    }
}
