import SwiftUI
import PhotosUI
import PocketKit
import PocketUI

struct PendingAttachment: Identifiable, Sendable {
    let id: UUID
    let image: UIImage
    let fileURL: URL
}

/// UI-09: Chat screen (S-CHAT), `02` §7.2. Covers streaming, stop, retry,
/// title rename, long-press actions, an error card, and the Pulse strip.
/// Not implemented: model switch per chat (no model picker sheet yet,
/// UI-13 scope; ponytail: remote-model-use gate — wire when the remote model picker lands),
/// branch-from-here, state restoration after an app kill
/// mid-reply (needs a real engine + background task, not exercisable
/// here), and jump-to-latest (always auto-scrolls to bottom instead).
struct ChatView: View {
    let conversationId: String
    var initialMessage: String?
    @Environment(AppModel.self) private var model
    @AppStorage("app.getpocketai.autoSpeakReplies") private var autoSpeakReplies = false

    @State private var title: String?
    @State private var messages: [Message] = []
    @State private var composerText = ""
    @State private var isGenerating = false
    @State private var streamTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var renamingTitle = false
    @State private var newTitle = ""
    @State private var voiceDictation = VoiceDictation()
    @State private var speechPlayback = SpeechPlayback()

    @State private var pendingAttachment: PendingAttachment?
    @State private var isPhotosPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var cameraUnavailableAlert = false
    @State private var showImageGenSheet = false
    @State private var imageGenPrompt = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PocketSpacing.s16) {
                        ForEach(messages, id: \.id) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if let errorText {
                            errorCard(errorText)
                        }
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                    .padding(.top, PocketSpacing.s16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            PulseStrip(
                state: isGenerating ? .generating(modelName: "On this iPhone", location: "On this iPhone", tokPerSec: 0) : .idle,
                onTap: {}
            )
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s8)

            if speechPlayback.isSpeaking {
                speakingAffordance
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                    .padding(.bottom, PocketSpacing.s8)
            }

            if voiceDictation.isRecording || voiceDictation.isTranscribing {
                recordingComposerBar
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                    .padding(.bottom, PocketSpacing.s8)
            } else {
                pendingAttachmentChip

                Composer(
                    text: $composerText,
                    modelChipLabel: nil, // ponytail: remote-model-use gate — wire when the remote model picker lands
                    isFocused: false,
                    isGenerating: isGenerating,
                    hasAttachment: pendingAttachment != nil,
                    onAttach: { kind in
                        switch kind {
                        case .photo:
                            isPhotosPickerPresented = true
                        case .camera:
                            if CameraCaptureView.isCameraAvailable {
                                isCameraPresented = true
                            } else {
                                cameraUnavailableAlert = true
                            }
                        case .image:
                            imageGenPrompt = ""
                            showImageGenSheet = true
                        case .file, .projectDocument:
                            break
                        }
                    },
                    onMic: { startDictation(handsFree: false) },
                    onMicLongPress: { startDictation(handsFree: true) },
                    onSend: { send() },
                    onStop: { stop() }
                )
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.bottom, PocketSpacing.s8)
            }
        }
        .background(PocketColor.bgCanvas)
        .navigationTitle(title ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: PocketSpacing.s12) {
                    if speechPlayback.isSpeaking {
                        Button {
                            speechPlayback.stop()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(PocketColor.accent)
                        }
                        .accessibilityLabel("Stop speaking")
                        .accessibilityHint("Stops speaking reply aloud")
                    } else {
                        Button {
                            autoSpeakReplies.toggle()
                        } label: {
                            Image(systemName: autoSpeakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                                .foregroundStyle(autoSpeakReplies ? PocketColor.accent : PocketColor.textTertiary)
                        }
                        .accessibilityLabel(autoSpeakReplies ? "Auto-speak replies enabled" : "Auto-speak replies disabled")
                        .accessibilityHint("Toggles automatic speech for assistant replies")
                    }

                    Menu {
                        Toggle("Speak replies", isOn: $autoSpeakReplies)
                        Divider()
                        Button("Generate image", systemImage: "sparkles") {
                            imageGenPrompt = ""
                            showImageGenSheet = true
                        }
                        Divider()
                        Button("Rename") { newTitle = title ?? ""; renamingTitle = true }
                        Button("Export as Markdown") {}
                        Button("Delete", role: .destructive) {
                            try? model.core.deleteConversation(id: conversationId)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename chat", isPresented: $renamingTitle) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                try? model.core.renameConversation(id: conversationId, title: newTitle)
                title = newTitle
            }
        }
        .alert("Voice Input Permission Required", isPresented: Binding(
            get: {
                if case .denied = voiceDictation.state { return true }
                return false
            },
            set: { if !$0 { voiceDictation.dismissError() } }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                voiceDictation.dismissError()
            }
            Button("Cancel", role: .cancel) {
                voiceDictation.dismissError()
            }
        } message: {
            if case .denied(let message) = voiceDictation.state {
                Text(message)
            }
        }
        .alert("Voice Input Error", isPresented: Binding(
            get: {
                if case .error = voiceDictation.state { return true }
                return false
            },
            set: { if !$0 { voiceDictation.dismissError() } }
        )) {
            Button("OK", role: .cancel) {
                voiceDictation.dismissError()
            }
        } message: {
            if case .error(let message) = voiceDictation.state {
                Text(message)
            }
        }
        .photosPicker(isPresented: $isPhotosPickerPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handlePickedImage(image)
                }
                selectedPhotoItem = nil
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraCaptureView { image in
                handlePickedImage(image)
            }
        }
        .sheet(isPresented: $showImageGenSheet) {
            ImageGenerationSheet(
                prompt: imageGenPrompt,
                core: model.core,
                onAttachToChat: { image, fileURL in
                    removePendingAttachment()
                    self.pendingAttachment = PendingAttachment(id: UUID(), image: image, fileURL: fileURL)
                }
            )
        }
        .alert("Camera Unavailable", isPresented: $cameraUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Camera is not available on this device or simulator.")
        }
        .onDisappear {
            voiceDictation.cancel()
            speechPlayback.stop()
            removePendingAttachment()
        }
        .task {
            reload()
            if let initialMessage, messages.isEmpty {
                composerText = initialMessage
                send()
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        let text = textForMessage(message)
        let thumbnails = imagesForMessage(message)

        if message.role == "user" {
            UserBubble(text: text, attachmentThumbnails: thumbnails)
                .contextMenu {
                    if !text.isEmpty {
                        Button("Copy") { UIPasteboard.general.string = text }
                    }
                }
        } else {
            let isCurrentSpeaking = speechPlayback.isSpeaking && speechPlayback.currentText == text
            MessageView(
                text: text,
                reasoning: message.reasoning,
                statsText: message.stats.map { "\($0.completionTokens) tokens · \(Int($0.decodeTps)) tok/s" },
                onCopy: { UIPasteboard.general.string = text },
                onRetry: { retry(after: message) },
                onSpeak: {
                    if isCurrentSpeaking {
                        speechPlayback.stop()
                    } else {
                        speechPlayback.speak(text)
                    }
                }
            )
            .contextMenu {
                Button("Copy") { UIPasteboard.general.string = text }
                if isCurrentSpeaking {
                    Button("Stop Speaking", systemImage: "stop.fill") {
                        speechPlayback.stop()
                    }
                    .accessibilityLabel("Stop speaking")
                } else {
                    Button("Speak", systemImage: "speaker.wave.2") {
                        speechPlayback.speak(text)
                    }
                    .accessibilityLabel("Speak reply aloud")
                }
                Button("Retry") { retry(after: message) }
            }
        }
    }

    private func errorCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            Text(text).font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
            Button("Retry") {
                errorText = nil
                if let last = messages.last(where: { $0.role == "user" }) {
                    retry(after: last)
                }
            }
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgSunken)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func reload() {
        messages = model.core.messages(conversationId: conversationId)
        let summary = model.core.conversations(query: ConversationQuery(search: nil, archived: nil, limit: 0, offset: 0))
            .first { $0.id == conversationId }
        title = summary?.title
    }

    private func send(handsFree: Bool = false) {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/image") {
            let prompt = trimmed.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = ""
            imageGenPrompt = prompt
            showImageGenSheet = true
            return
        }

        guard !composerText.isEmpty || pendingAttachment != nil else { return }
        speechPlayback.stop()
        let text = composerText
        composerText = ""
        let attachment = pendingAttachment
        pendingAttachment = nil
        errorText = nil
        isGenerating = true
        let shouldAutoSpeak = handsFree || autoSpeakReplies

        streamTask = Task {
            // ponytail: vision inference needs the MLX VLM engine registered (APL-14 follow-up)
            var parts: [ContentPart] = []
            if let attachment {
                parts.append(.imageRef(path: attachment.fileURL.path))
            }
            if !text.isEmpty {
                parts.append(.text(text: text))
            }
            let input = UserInput(parts: parts)
            var partialText = ""
            do {
                for try await event in model.core.sendMessage(conversationId: conversationId, input: input) {
                    switch event {
                    case .delta(let delta):
                        partialText += delta.text
                        upsertStreamingPlaceholder(text: partialText)
                    case .done(let finalMessage):
                        reload()
                        if title == nil { reload() }
                        if shouldAutoSpeak {
                            let textToSpeak = textForMessage(finalMessage)
                            let toSpeak = textToSpeak.isEmpty ? partialText : textToSpeak
                            let trimmed = toSpeak.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                speechPlayback.speak(trimmed)
                            }
                        }
                    }
                }
            } catch {
                errorText = "Something went wrong: \(error.localizedDescription)"
            }
            isGenerating = false
            reload()
        }
    }

    /// Shows the in-flight reply growing in place rather than waiting for
    /// `sendMessage`'s final `.done` event - `messages(conversationId:)`
    /// only reflects the persisted row, so this overlays a synthetic one.
    private func upsertStreamingPlaceholder(text: String) {
        let placeholderId = "streaming-placeholder"
        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages[index] = streamingMessage(id: placeholderId, text: text)
        } else {
            messages.append(streamingMessage(id: placeholderId, text: text))
        }
    }

    private func streamingMessage(id: String, text: String) -> Message {
        Message(
            id: id, conversationId: conversationId, role: "assistant",
            parts: [.text(text: text)], reasoning: nil, stats: nil, modelId: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000), status: .streaming
        )
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        speechPlayback.stop()
    }

    private func retry(after message: Message) {
        let text = textForMessage(message)
        composerText = text
        send()
    }

    private var speakingAffordance: some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PocketColor.accent)
            Text("Speaking reply…")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            Spacer()
            Button(action: {
                speechPlayback.stop()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Stop")
                        .font(.pocket(.footnote))
                }
                .foregroundStyle(PocketColor.accentOnAccent)
                .padding(.horizontal, PocketSpacing.s8)
                .padding(.vertical, 4)
                .background(PocketColor.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop speaking")
            .accessibilityHint("Stops audio playback of the reply")
        }
        .padding(.horizontal, PocketSpacing.s12)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    private var recordingComposerBar: some View {
        HStack(spacing: PocketSpacing.s12) {
            Button(action: {
                voiceDictation.cancel()
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PocketColor.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(voiceDictation.isTranscribing)
            .accessibilityLabel("Cancel voice recording")
            .accessibilityHint("Discards the recorded audio")

            Spacer()

            if voiceDictation.isTranscribing {
                HStack(spacing: PocketSpacing.s8) {
                    ProgressView()
                        .tint(PocketColor.accent)
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.pocket(.body))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcribing voice input")
            } else {
                HStack(spacing: PocketSpacing.s8) {
                    if voiceDictation.isHandsFree {
                        Text("Hands-free")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accent)
                            .padding(.horizontal, PocketSpacing.s8)
                            .padding(.vertical, 2)
                            .background(PocketColor.accentSoft, in: Capsule())
                    }
                    WaveformView(levels: voiceDictation.audioLevels)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(voiceDictation.isHandsFree ? "Recording hands-free voice input" : "Recording voice input")
                .accessibilityValue("Listening")
            }

            Spacer()

            Button(action: { finishRecording() }) {
                Image(systemName: voiceDictation.isHandsFree ? "arrow.up" : "checkmark")
                    .foregroundStyle(PocketColor.accentOnAccent)
                    .frame(width: 28, height: 28)
                    .background(PocketColor.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(voiceDictation.isTranscribing)
            .accessibilityLabel(voiceDictation.isHandsFree ? "Send voice message" : "Insert voice text")
            .accessibilityHint(voiceDictation.isHandsFree ? "Transcribes audio and sends the message" : "Transcribes audio and places text in the composer")
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s12)
        .background(.regularMaterial, in: Capsule())
    }

    private func startDictation(handsFree: Bool) {
        speechPlayback.stop()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            await voiceDictation.start(handsFree: handsFree)
        }
    }

    private func finishRecording() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let wasHandsFree = voiceDictation.isHandsFree
        Task {
            if let text = await voiceDictation.stop() {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if wasHandsFree {
                    if composerText.isEmpty {
                        composerText = trimmed
                    } else {
                        composerText += " " + trimmed
                    }
                    send(handsFree: true)
                } else {
                    if composerText.isEmpty {
                        composerText = trimmed
                    } else {
                        composerText += " " + trimmed
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pendingAttachmentChip: some View {
        if let pending = pendingAttachment {
            HStack(spacing: PocketSpacing.s8) {
                Image(uiImage: pending.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: PocketSpacing.s8))
                    .overlay(
                        RoundedRectangle(cornerRadius: PocketSpacing.s8)
                            .stroke(PocketColor.lineHairline, lineWidth: 1)
                    )
                    .accessibilityLabel("Pending image attachment")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Image attached")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text(pending.fileURL.lastPathComponent)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: { removePendingAttachment() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove attached image")
            }
            .padding(PocketSpacing.s8)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s8)
        }
    }

    private func handlePickedImage(_ image: UIImage) {
        removePendingAttachment()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("attach-\(UUID().uuidString).jpg")
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: fileURL)
            pendingAttachment = PendingAttachment(id: UUID(), image: image, fileURL: fileURL)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func removePendingAttachment() {
        if let fileURL = pendingAttachment?.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        pendingAttachment = nil
    }

    private func imagesForMessage(_ message: Message) -> [Image] {
        message.parts.compactMap { part -> Image? in
            if case .imageRef(let path) = part {
                if let uiImage = UIImage(contentsOfFile: path) {
                    return Image(uiImage: uiImage)
                }
            }
            return nil
        }
    }

    private func textForMessage(_ message: Message) -> String {
        message.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()
    }
}
