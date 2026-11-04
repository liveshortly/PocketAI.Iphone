import SwiftUI
import AVFoundation
import Speech
import PocketKit
import PocketUI

/// Destination screens for the Settings rows (completes the previously inert
/// chevron rows in `SettingsView`). Each is reached via a `NavigationLink`.
/// The default-model picker is the shared `ModelPickerView` (§5.3/§11.1).

// MARK: - Storage used

/// Lists installed models with their real on-disk size and a delete action.
/// Size is actual download/disk bytes, never a runtime-RAM estimate (F20).
struct StorageUsedView: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [CatalogEntry] = []
    @State private var pendingDelete: CatalogEntry?
    /// A delete that throws used to leave the row in place with no explanation.
    @State private var deleteError: String?

    private func diskBytes(_ entry: CatalogEntry) -> UInt64 {
        entry.fit.diskBytes != 0 ? entry.fit.diskBytes : entry.manifest.estRuntimeBytes
    }

    private var total: UInt64 {
        installed.reduce(0) { $0 + diskBytes($1) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total on this iPhone")
                        .font(.pocket(.body))
                        .foregroundStyle(PocketColor.textPrimary)
                    Spacer()
                    Text(installed.isEmpty ? "None" : formatBytes(total))
                        .font(.pocket(.body).weight(.semibold))
                        .foregroundStyle(PocketColor.textPrimary)
                }
                .accessibilityElement(children: .combine)
            }

            if installed.isEmpty {
                Section {
                    Text("No models are stored on this iPhone. Download one from the Models tab.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }
            } else {
                Section("Models") {
                    ForEach(installed, id: \.manifest.id) { entry in
                        HStack(spacing: PocketSpacing.s12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ModelNaming.short(entry.manifest.displayName))
                                    .font(.pocket(.body))
                                    .foregroundStyle(PocketColor.textPrimary)
                                Text(formatBytes(diskBytes(entry)))
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                pendingDelete = entry
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(PocketColor.statusBad)
                                    // UI-111: the bare glyph was a ~20 pt target.
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(entry.manifest.displayName)")
                        }
                        .accessibilityIdentifier("storage_row_\(entry.manifest.id)")
                        // UI-111: the iOS convention for removing a list item.
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Storage used")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .confirmationDialog(
            "Delete \(pendingDelete?.manifest.displayName ?? "model")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    do {
                        try model.core.deleteModel(modelId: entry.manifest.id)
                        if model.selectedModelId == entry.manifest.id { model.selectedModelId = nil }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } catch {
                        deleteError = "Couldn't delete \(entry.manifest.displayName): \(error.localizedDescription)"
                    }
                    reload()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let entry = pendingDelete {
                // UI-111: say so when this is the model new chats use.
                Text(model.selectedModelId == entry.manifest.id
                     ? "Frees \(formatBytes(diskBytes(entry))). It's your default chat model, so you'll choose another next time you chat."
                     : "Frees \(formatBytes(diskBytes(entry))). You can download it again later.")
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func reload() {
        // UI-111: largest first, like iPhone Storage — the reason to be here.
        installed = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
            .sorted { diskBytes($0) > diskBytes($1) }
    }
}

// MARK: - Engines

/// Informational screen listing the inference engines and their availability.
struct EnginesView: View {
    var body: some View {
        List {
            Section {
                engineRow(
                    icon: "bolt.fill",
                    tint: PocketColor.statusWarn,
                    name: "MLX",
                    detail: "Runs MLX models on Apple silicon. The default on-device engine.",
                    status: "Bundled"
                )
                engineRow(
                    icon: "cpu",
                    tint: PocketColor.textSecondary,
                    name: "llama.cpp",
                    detail: "Runs GGUF models on-device via Metal. Built into the core.",
                    status: "Bundled"
                )
                engineRow(
                    icon: "apple.logo",
                    tint: PocketColor.textPrimary,
                    name: "Apple Intelligence",
                    detail: "Apple's on-device foundation model (iOS 26+ on supported devices).",
                    status: AppleFoundationModelsEngine.isAvailable ? "Available" : "Unavailable"
                )
            } footer: {
                Text("PocketAI picks the right engine for each model automatically.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Engines")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func engineRow(icon: String, tint: Color, name: String, detail: String, status: String) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s12) {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PocketColor.accentOnAccent)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.pocket(.body))
                    .foregroundStyle(PocketColor.textPrimary)
                Text(detail)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            Spacer(minLength: PocketSpacing.s8)
            Text(status)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
        }
        .padding(.vertical, PocketSpacing.s4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status)
    }
}

// MARK: - Speech-to-text

/// Shows on-device Apple speech recognition availability for voice input.
struct SpeechToTextView: View {
    @State private var authStatus = SFSpeechRecognizer.authorizationStatus()

    private var recognizer: SFSpeechRecognizer? { SFSpeechRecognizer() }

    var body: some View {
        let rec = recognizer
        let langId = rec?.locale.identifier ?? Locale.current.identifier
        return List {
            Section("Apple Speech Recognition") {
                LabeledContent("Language", value: Locale.current.localizedString(forIdentifier: langId) ?? langId)
                LabeledContent("Available", value: (rec?.isAvailable ?? false) ? "Yes" : "No")
                // UI-112: says where audio goes, not "Server-based".
                LabeledContent("Processed", value: (rec?.supportsOnDeviceRecognition ?? false) ? "On this iPhone" : "By Apple")
                LabeledContent("Permission", value: authLabel)
            }

            if authStatus == .notDetermined {
                Section {
                    Button("Allow speech recognition") {
                        SFSpeechRecognizer.requestAuthorization { status in
                            Task { @MainActor in authStatus = status }
                        }
                    }
                    .frame(minHeight: 44)
                } footer: {
                    Text("PocketAI asks once. You can change it later in iOS Settings.")
                }
            } else if authStatus == .denied || authStatus == .restricted {
                Section {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } footer: {
                    Text("Speech recognition is off for PocketAI. Turn it on in iOS Settings to dictate messages.")
                }
            }

            Section {
                Text("Voice input is transcribed with Apple's Speech framework. When on-device recognition is supported, your audio stays on this iPhone.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Speech-to-text")
        .navigationBarTitleDisplayMode(.inline)
        .task { authStatus = SFSpeechRecognizer.authorizationStatus() }
    }

    private var authLabel: String {
        switch authStatus {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Text-to-speech voice

/// Picks and previews an on-device TTS voice for the current locale. The
/// selection is persisted so the reply-speaking path can read it.
struct TextToSpeechVoiceView: View {
    /// Shared with the playback path (empty = system default voice).
    @AppStorage("app.getpocketai.ttsVoiceId") private var ttsVoiceId = ""
    @State private var preview = AVSpeechSynthesizer()

    private var voices: [AVSpeechSynthesisVoice] {
        let lang = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let prefix = String(lang.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section {
                Button {
                    ttsVoiceId = ""
                } label: {
                    HStack {
                        Text("System default")
                            .font(.pocket(.body))
                            .foregroundStyle(PocketColor.textPrimary)
                        Spacer()
                        if ttsVoiceId.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(PocketColor.accent)
                        }
                    }
                }
                .accessibilityAddTraits(ttsVoiceId.isEmpty ? .isSelected : [])
            }

            if voices.isEmpty {
                Section {
                    Text("No voices for your language are installed. Add them in the Settings app › Accessibility › Spoken Content › Voices.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                }
            } else {
                // UI-112: "English voices", not the raw "en_IN voices".
                Section("\(languageName) voices") {
                    ForEach(voices, id: \.identifier) { voice in
                        Button {
                            ttsVoiceId = voice.identifier
                            speak(voice)
                        } label: {
                            HStack(spacing: PocketSpacing.s12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name)
                                        .font(.pocket(.body))
                                        .foregroundStyle(PocketColor.textPrimary)
                                    Text(voiceDetail(voice))
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textSecondary)
                                }
                                Spacer()
                                if ttsVoiceId == voice.identifier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(PocketColor.accent)
                                }
                            }
                        }
                        .accessibilityAddTraits(ttsVoiceId == voice.identifier ? .isSelected : [])
                        .accessibilityHint("Plays a sample and uses this voice for spoken replies")
                        .accessibilityIdentifier("tts_voice_row_\(voice.identifier)")
                    }
                }
            }

            Section {
                Text("Tap a voice to hear a sample. Your choice is saved as the preferred voice for spoken replies.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Text-to-speech voice")
        .navigationBarTitleDisplayMode(.inline)
        // The sample kept talking after you left the screen, and the only
        // control that could stop it was back here.
        .onDisappear { preview.stopSpeaking(at: .immediate) }
    }

    private var languageName: String {
        Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "")
            ?? Locale.current.identifier
    }

    /// Region plus quality, so two "Samantha"s can be told apart and the
    /// better-sounding downloads are visible.
    private func voiceDetail(_ voice: AVSpeechSynthesisVoice) -> String {
        let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        switch voice.quality {
        case .premium: return "\(region) · Premium"
        case .enhanced: return "\(region) · Enhanced"
        default: return region
        }
    }

    private func speak(_ voice: AVSpeechSynthesisVoice) {
        preview.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "The quick brown fox jumps over the lazy dog.")
        utterance.voice = voice
        preview.speak(utterance)
    }
}

// MARK: - Pair a Mac

/// Entry point for pairing; the camera/QR flow itself lives in the Mac tab.
struct PairMacView: View {
    @Environment(AppModel.self) private var model
    @State private var peers: [Peer] = []

    var body: some View {
        List {
            if peers.isEmpty {
                Section {
                    stepCard(number: "1", title: "Open PocketAI on your Mac", subtitle: "Go to Devices › Pair a device… to show a pairing code.")
                    stepCard(number: "2", title: "Scan the code from the Mac tab", subtitle: "The Mac tab opens the camera to scan your Mac's pairing code.")
                    // UI-113: go there instead of describing where it is.
                    Button {
                        model.nav.select(tab: .devices)
                    } label: {
                        Label("Open the Mac tab", systemImage: "qrcode.viewfinder")
                    }
                    .tint(PocketColor.accent)
                    .accessibilityIdentifier("settings_pair_open_mac_tab")
                } header: {
                    Text("Pair over local Wi-Fi")
                } footer: {
                    Text("Pairing uses the camera, so it runs from the Mac tab. Everything stays on your devices.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            } else {
                Section {
                    ForEach(peers, id: \.id) { peer in
                        SettingsRow(
                            icon: "laptopcomputer",
                            tint: PocketColor.statusOk,
                            title: peer.name,
                            // UI-113: a raw IP read as jargon, and "Connected"
                            // claimed a live link nobody had checked.
                            accessory: .value("Paired")
                        )
                    }
                    Button {
                        model.nav.select(tab: .devices)
                    } label: {
                        Label("Manage in the Mac tab", systemImage: "laptopcomputer")
                    }
                    .tint(PocketColor.accent)
                } header: {
                    Text("Paired")
                } footer: {
                    Text("Connection, custom address, chat sync and Forget live in the Mac tab.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pair a Mac")
        .navigationBarTitleDisplayMode(.inline)
        .task { peers = model.core.peers() }
    }

    private func stepCard(number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s12) {
            // UI-114: the number scales with Dynamic Type; the circle grows
            // around it instead of clipping a fixed 13 pt glyph.
            Text(number)
                .font(.pocket(.footnote).weight(.bold))
                .foregroundStyle(PocketColor.accent)
                .frame(minWidth: 28, minHeight: 28)
                .background(Circle().fill(PocketColor.accentSoft))
                .accessibilityLabel("Step \(number)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                Text(subtitle)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, PocketSpacing.s4)
        // UI-114: "Step 1, Open PocketAI…" as one element.
        .accessibilityElement(children: .combine)
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
