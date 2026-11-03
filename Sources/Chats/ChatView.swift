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
/// Consecutive same-role messages are grouped (role affordance only on the
/// first bubble of a run), and a jump-to-latest control appears when the user
/// scrolls up while new tokens stream. Not implemented: model switch per chat
/// (no model picker sheet yet, UI-13 scope; ponytail: remote-model-use gate —
/// wire when the remote model picker lands), branch-from-here, and state
/// restoration after an app kill mid-reply (needs a real engine + background
/// task, not exercisable here).
struct ChatView: View {
    let conversationId: String
    var projectId: String? = nil
    var initialMessage: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("app.getpocketai.autoSpeakReplies") private var autoSpeakReplies = false

    @State private var title: String?
    @State private var messages: [Message] = []
    @State private var composerText = ""
    @State private var isGenerating = false
    @State private var streamTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var renamingTitle = false
    @State private var showDeleteConfirm = false
    @State private var newTitle = ""
    @State private var voiceDictation = VoiceDictation()
    @State private var speechPlayback = SpeechPlayback()
    @State private var showVoicePrimer = false
    @State private var pendingHandsFree = false

    @State private var pendingAttachment: PendingAttachment?
    @State private var isPhotosPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var cameraUnavailableAlert = false
    @State private var showVisionRequiredAlert = false
    /// This conversation's bound model (F03/§9.1), loaded by ID in reload().
    @State private var conversationModelId: String?
    /// Per-chat thinking toggle (UI-27); default on. Persisted in
    /// UserDefaults keyed by conversation id — only "off" is stored.
    @State private var thinkingEnabled = true
    /// Catalog snapshot refreshed in reload() — header/composer lookups must
    /// never call core.catalog() per render (it re-parses the bundled JSON).
    @State private var cachedCatalog: [CatalogEntry] = []
    /// Identifies the stream whose cleanup may run; a Stop + immediate Retry
    /// must not let the old stream's teardown clobber the new one.
    @State private var activeStreamId = UUID()
    @State private var showModelPicker = false
    @State private var showSwitchWhileGeneratingAlert = false
    @State private var showImageGenSheet = false
    @State private var imageGenPrompt = ""
    @State private var activeSourceTurn: ActiveSourceTurn?
    @State private var showPulseDetailSheet = false
    @State private var showJumpToLatest = false
    @State private var isAtBottom = true
    /// True only after a real user drag; programmatic scrolls never unpin.
    @State private var userScrolledUp = false
    /// UI-36: Think chip + model pill fade out while the user reads history.
    @State private var accessoryCollapsed = false
    @State private var scrollInteracting = false
    @State private var didReconnectRetry = false
    /// UI-31: the notice the last Mac re-check posted, so a later good check
    /// clears only that and never an unrelated error.
    @State private var lastRemoteCheckError: String?
    /// The error the last reply stream posted. Only that one offers Retry —
    /// a failed rename/attach/delete used to show Retry, which regenerated
    /// the last reply instead of retrying the thing that failed.
    @State private var lastStreamError: String?
    @State private var cursorBlink = false
    // Honest instruments: a live decode rate derived from the real stream,
    // not a hardcoded constant. Updated as deltas arrive; the final
    // `message.stats.decodeTps` remains the authoritative post-hoc number.
    @State private var genStartTime: Date?
    @State private var genCharCount: Int = 0
    @State private var liveTokPerSec: Double = 0
    @FocusState private var isComposerFocused: Bool
    // Chrome that sits next to text has to grow with it, or it shrinks into
    // nothing at accessibility sizes while the labels beside it double.
    @ScaledMetric(relativeTo: .body) private var attachThumbSize: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var recordGlyphSize: CGFloat = 28
    @ScaledMetric(relativeTo: .caption) private var streamCursorSize: CGFloat = 8

    #if DEBUG
    @State private var perfDiagnostics = PerfDiagnostics.shared
    @State private var latestPerfRecord: PerfDiagnostics.GenerationPerfRecord?
    #endif

    /// Next-turn model for this conversation (F03/§5.1): the conversation's own
    /// bound choice, never inferred from the last assistant message. Falls back
    /// to the global default only while the chat is unbound.
    private var currentModelId: String? {
        if let bound = conversationModelId, !bound.isEmpty { return bound }
        return model.selectedModelId
    }

    /// UI-27: the thinking toggle only exists for reasoning-capable models —
    /// never a dead toggle on models that ignore it.
    private var currentModelSupportsReasoning: Bool {
        currentModelId.map { cachedCatalog.supportsReasoning(modelID: $0) } ?? false
    }

    // ponytail: per-chat UserDefaults key; orphaned on chat delete — move into
    // the conversation record when the FFI grows a reasoning field.
    private var thinkingOffKey: String { "app.getpocketai.thinkingOff.\(conversationId)" }

    private var thinkingBinding: Binding<Bool> {
        Binding(
            get: { thinkingEnabled },
            set: { on in
                thinkingEnabled = on
                if on {
                    UserDefaults.standard.removeObject(forKey: thinkingOffKey)
                } else {
                    UserDefaults.standard.set(true, forKey: thinkingOffKey)
                }
            }
        )
    }

    /// Is this model actually runnable right now (installed locally, or a remote
    /// Mac route)? Used to self-heal a conversation bound to a deleted model.
    private func isModelUsable(_ id: String) -> Bool {
        if id.hasPrefix("mac:") { return true }
        if id == AppleFoundationModelsEngine.modelId { return AppleFoundationModelsEngine.isAvailable }
        return cachedCatalog.contains { $0.manifest.id == id && $0.state == .installed }
    }

    /// Whether the model that will serve this chat can see images. Remote
    /// (`mac:`) models are allowed through (the Mac decides and reports back);
    /// a local model is checked against its catalog `modalities`.
    private var currentModelSupportsVision: Bool {
        guard let id = currentModelId else { return false }
        if id.hasPrefix("mac:") { return true }
        return cachedCatalog.first { $0.manifest.id == id }?
            .manifest.modalities.contains(.vision) ?? false
    }

    /// Name of an installed vision model to point the user at, if any.
    private var installedVisionModelName: String? {
        cachedCatalog
            .first { $0.state == .installed && $0.manifest.modalities.contains(.vision) }?
            .manifest.displayName
    }

    /// Real resident local model for the Pulse sheet. Empty when nothing local
    /// is loaded (remote `mac:` routing resides on the Mac, not here) — honest
    /// instruments, no fabricated "Qwen3 4B" placeholder.
    private var pulseLoadedModels: [LoadedModelSummary] {
        guard let id = currentModelId, !id.hasPrefix("mac:") else { return [] }
        let catalogName = cachedCatalog.first { $0.manifest.id == id }?.manifest.displayName
        let name = Self.humanLabel(catalogName) ?? friendlyModelName(from: id)
        return [
            LoadedModelSummary(
                id: id,
                name: name,
                residentBytes: Self.appUsedMemoryBytes(),
                onEject: {
                    try? model.core.unloadModel(id: id)
                    showPulseDetailSheet = false
                }
            )
        ]
    }

    private var remoteModelChipLabel: String? {
        guard let id = currentModelId, id.hasPrefix("mac:") else { return nil }
        let localId = RemoteEngine.localModelId(from: id)
        let catalogName = cachedCatalog
            .first { $0.manifest.id == localId || localId.hasPrefix($0.manifest.id) }?
            .manifest.displayName
        let displayName = Self.humanLabel(catalogName) ?? friendlyModelName(from: localId)
        // The Mac's *name*, never an id or an address.
        let macName = Self.humanLabel(peerName(for: id)) ?? "Mac"
        return "\(displayName) · \(macName)"
    }

    /// Keeps a label human: a value that is really a filesystem path (a models
    /// directory, an Application Support container) collapses to its last
    /// component, so no path can ever reach the screen.
    private static func humanLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("file:") else {
            return trimmed
        }
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// Header state mark (§5.1): animates while answering, static otherwise.
    private var headerMarkState: PocketMarkState {
        isGenerating ? .thinking(tokPerSec: liveTokPerSec > 0 ? liveTokPerSec : nil) : .idle
    }

    /// Model for the header subtitle (U2) — one short line. Remote routes name
    /// the Mac they run on; local ones are just the model. Never a filesystem
    /// path, and "Choose a model" while the conversation is unbound.
    private var modelLocationLabel: String {
        guard let id = currentModelId, !id.isEmpty else { return "Choose a model" }
        if id.hasPrefix("mac:") { return remoteModelChipLabel ?? "Mac" }
        if id == AppleFoundationModelsEngine.modelId { return "Apple Intelligence" }
        let catalogName = cachedCatalog.first { $0.manifest.id == id }?.manifest.displayName
        return Self.humanLabel(catalogName) ?? friendlyModelName(from: id)
    }

    /// Commits a per-chat model choice (U8): persist to the conversation and
    /// refresh header/composer. Never changes the global default.
    private func bindModel(_ id: String) {
        do {
            try model.core.setConversationModel(id: conversationId, modelId: id)
            conversationModelId = id
        } catch {
            // Don't let the header name a model this conversation isn't
            // actually bound to — the next reply would come from the old one.
            errorText = "Couldn't switch models: \(error.localizedDescription)"
        }
    }

    /// Resolves the *specific* paired Mac encoded in a `mac:<peer>/<model>` id
    /// (F16), never `peers().first`.
    private func peerName(for remoteId: String?) -> String? {
        guard let remoteId, let pid = RemoteEngine.peerId(from: remoteId) else { return nil }
        return model.core.peers().first { $0.id == pid }?.name
    }

    private func friendlyModelName(from localId: String) -> String {
        // One naming rule for both apps: ModelNaming also strips quantisation,
        // format and release-date tokens, which this used to leave in.
        ModelNaming.short(localId)
    }

    /// Real device thermal state — never a hardcoded "Nominal".
    private var thermalStateLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var lastReplyStats: LastReplyStats? {
        guard let last = messages.last(where: { $0.role == "assistant" && $0.stats != nil }),
              let stats = last.stats else { return nil }
        return LastReplyStats(
            ttftMs: Int(stats.ttftMs),
            tokens: Int(stats.completionTokens),
            tokPerSec: Double(stats.decodeTps),
            isMeasured: true
        )
    }

    private var composerHasAttachment: Bool {
        #if DEBUG
        if PerfDiagnostics.isEnabled {
            return true
        }
        #endif
        return pendingAttachment != nil
    }

    private struct ActiveSourceTurn: Identifiable {
        let id = UUID()
        let query: String
        let selectedCitation: Int?
    }

    private var messageScroller: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    // The error card lives in the message list, so an empty
                    // chat has to fall through to it — otherwise a failed
                    // rename/attach/delete reports to nobody.
                    if messages.isEmpty && errorText == nil {
                        emptyChatView
                    } else {
                        messageList
                    }
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                // UI-31: pull at the top of history resyncs this chat. System
                // spinner: UIRefreshControl can't host PocketMark. If "load
                // older" pagination lands, it takes the top pull and this
                // moves to the ⋯ menu.
                .refreshable { await refresh() }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    // Within ~32pt of the bottom counts as "pinned".
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 32
                } action: { _, atBottom in
                    isAtBottom = atBottom
                    if atBottom {
                        // Back at the bottom (by hand or by tap): re-pin.
                        userScrolledUp = false
                        setAccessoryCollapsed(false)
                        if showJumpToLatest {
                            withAnimation(.easeOut(duration: 0.2)) { showJumpToLatest = false }
                        }
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    // Only a real user drag may unpin the chat from the
                    // bottom — programmatic/streaming scrolls never do.
                    if newPhase == .interacting { userScrolledUp = true }
                    scrollInteracting = newPhase == .interacting
                }
                .modifier(AccessoryCollapseTracking(
                    isInteracting: scrollInteracting,
                    collapse: { if !isComposerFocused { setAccessoryCollapsed(true) } }
                ))
                .onChange(of: messages.count) { _, _ in
                    if userScrolledUp && !isAtBottom {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showJumpToLatest = true }
                    } else {
                        scrollToLatest(proxy: proxy, animated: false)
                    }
                }
                .onChange(of: genCharCount) { _, _ in
                    // Streaming grows the last bubble without changing the
                    // message count; stay pinned unless the user scrolled up.
                    if userScrolledUp && !isAtBottom {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showJumpToLatest = true }
                    } else {
                        scrollToLatest(proxy: proxy, animated: false)
                    }
                }
                // Opening on the newest message is handled by
                // .defaultScrollAnchor(.bottom) above: `messages` is still
                // empty while this view first lays out (reload() runs in a
                // sibling .task), so a scrollTo here has nothing to target.
                .overlay(alignment: .bottom) {
                    // Overlay, not stacked: showing it never shifts layout.
                    if showJumpToLatest {
                        jumpToLatestButton(proxy: proxy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var composerArea: some View {
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
                // UI-36: the model pill lives in `accessoryRow` so it can
                // collapse with the Think chip.
                modelChipLabel: nil,
                isFocused: false,
                isGenerating: isGenerating,
                hasAttachment: composerHasAttachment,
                onAttach: { kind in
                    switch kind {
                    case .photo:
                        guard currentModelSupportsVision else { showVisionRequiredAlert = true; return }
                        isPhotosPickerPresented = true
                    case .camera:
                        guard currentModelSupportsVision else { showVisionRequiredAlert = true; return }
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
                onStop: { stop() },
                externalFocus: $isComposerFocused
            )
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s8)
        }
    }

    /// UI-30: a Toggle inside a Menu shows nothing when off, so it reads as an
    /// action. Spell the state out instead; the header speaker icon and the
    /// composer Think chip show the same state.
    @ViewBuilder
    private var stateMenuItems: some View {
        if currentModelSupportsReasoning {
            Button {
                thinkingBinding.wrappedValue = !thinkingEnabled
            } label: {
                Label(thinkingEnabled ? "Thinking: On" : "Thinking: Off", systemImage: "brain")
            }
        }
        Button {
            autoSpeakReplies.toggle()
        } label: {
            Label(autoSpeakReplies ? "Speak replies: On" : "Speak replies: Off",
                  systemImage: autoSpeakReplies ? "speaker.wave.2.fill" : "speaker.slash")
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            // §5.1: the live state now lives in the header mark, not a full-width
            // bottom strip. Pulse details open from the header mark.
            #if DEBUG
            if PerfDiagnostics.isEnabled, let record = latestPerfRecord ?? perfDiagnostics.latestRecord {
                perfDiagnosticsOverlay(record)
            }
            #endif

            // NET-22: quiet, only while this chat waits to reach the Mac.
            ChatSyncNote(conversationId: conversationId)
                .padding(.bottom, PocketSpacing.s4)
            accessoryRow
            VStack(spacing: 0) { composerArea }
                .background(PocketColor.bgCanvas.ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) { if accessoryCollapsed { ChromeTopFade() } }
        }
        .onChange(of: isComposerFocused) { _, focused in
            if focused { setAccessoryCollapsed(false) }
        }
    }

    private var showsAccessoryRow: Bool {
        !(voiceDictation.isRecording || voiceDictation.isTranscribing)
            && (currentModelSupportsReasoning || remoteModelChipLabel != nil)
    }

    /// UI-36: Think chip and model pill. Collapsing fades them out but keeps
    /// their height, so the scroll inset (UI-29) never changes and the
    /// thread doesn't jump; the opaque canvas then starts at the field.
    @ViewBuilder
    private var accessoryRow: some View {
        if showsAccessoryRow {
            VStack(alignment: .leading, spacing: 0) {
                if currentModelSupportsReasoning {
                    ThinkingToggleChip(isOn: thinkingBinding)
                }
                if let label = remoteModelChipLabel {
                    modelPill(label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PocketSpacing.gutterIphone + PocketSpacing.s8)
            .padding(.bottom, PocketSpacing.s4)
            .opacity(accessoryCollapsed ? 0 : 1)
            .offset(y: accessoryCollapsed ? PocketSpacing.s8 : 0)
            .allowsHitTesting(!accessoryCollapsed)
            .accessibilityHidden(accessoryCollapsed)
            .background(PocketColor.bgCanvas.opacity(accessoryCollapsed ? 0 : 1))
            .overlay(alignment: .top) { if !accessoryCollapsed { ChromeTopFade() } }
        }
    }

    /// The chevron promised a picker; it was a dead label. Opens the same
    /// per-chat picker as the header.
    private func modelPill(_ label: String) -> some View {
        Button(action: openModelPicker) {
            HStack(spacing: PocketSpacing.s4) {
                Text(label).font(.pocket(.caption))
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(PocketColor.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model: \(label)")
        .accessibilityHint("Changes the model for this chat")
    }

    private func openModelPicker() {
        if isGenerating { showSwitchWhileGeneratingAlert = true } else { showModelPicker = true }
    }

    private func setAccessoryCollapsed(_ collapsed: Bool) {
        guard accessoryCollapsed != collapsed else { return }
        withAnimation(.easeOut(duration: 0.2)) { accessoryCollapsed = collapsed }
    }

    // Split into two computed views so SwiftUI's type-checker handles each
    // modifier chain in reasonable time (the combined chain times out).
    private var chatScaffold: some View {
        messageScroller
        // UI-29: the composer is a bottom safe-area inset, not a VStack
        // sibling, so the scroll content is inset by the composer's real
        // height on every device size, text size, keyboard and bar state.
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
        .background(PocketColor.bgCanvas)
        .navigationTitle(title ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(PocketColor.bgCanvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: PocketSpacing.s8) {
                    // Live state mark left of the title (§5.1); tap opens Pulse.
                    Button { showPulseDetailSheet = true } label: {
                        PocketMarkView(state: headerMarkState, size: 22)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pulse")
                    .accessibilityValue(isGenerating ? "Generating" : "Ready")
                    .accessibilityHint("Shows memory, speed and loaded models")
                    // The whole title block opens the per-chat model picker
                    // (U2/U8) — a 9pt chevron alone was undiscoverable.
                    Button(action: openModelPicker) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title ?? "New chat")
                                .font(.pocket(.headline))
                                .lineLimit(1)
                                .foregroundStyle(PocketColor.textPrimary)
                            HStack(spacing: 3) {
                                Text(modelLocationLabel)
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.accent)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(PocketColor.accent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The title is the chat's name; VoiceOver must hear it too.
                    .accessibilityLabel("\(title ?? "New chat"), \(modelLocationLabel)")
                    .accessibilityHint("Changes the model for this chat")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: PocketSpacing.s12) {
                    if speechPlayback.isSpeaking {
                        Button {
                            speechPlayback.stop()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(PocketColor.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Stop speaking")
                        .accessibilityHint("Stops speaking reply aloud")
                    } else {
                        Button {
                            autoSpeakReplies.toggle()
                        } label: {
                            Image(systemName: autoSpeakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                                .foregroundStyle(autoSpeakReplies ? PocketColor.accent : PocketColor.textTertiary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Speak replies")
                        .accessibilityValue(autoSpeakReplies ? "On" : "Off")
                        .accessibilityAddTraits(.isToggle)
                        .accessibilityHint("Reads each new reply aloud")
                    }

                    Menu {
                        Button("Change model", systemImage: "cpu", action: openModelPicker)
                        stateMenuItems
                        Divider()
                        Button("Generate image", systemImage: "sparkles") {
                            imageGenPrompt = ""
                            showImageGenSheet = true
                        }
                        Divider()
                        Button("Rename", systemImage: "pencil") { newTitle = title ?? ""; renamingTitle = true }
                        ShareLink(item: markdownTranscript()) {
                            Label("Export as Markdown", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Chat options")
                }
            }
        }
        .onChange(of: speechPlayback.lastError) { _, message in
            // A dead Speak used to be indistinguishable from a working one:
            // every failure path just reset the state. Route it through the
            // error card the rest of this screen already uses.
            guard let message else { return }
            errorText = message
            speechPlayback.clearError()
        }
        .alert("Delete this chat?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                do {
                    try model.core.deleteConversation(id: conversationId)
                    dismiss()
                } catch {
                    errorText = "Couldn't delete this chat: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the conversation and its messages.")
        }
        .alert("Rename chat", isPresented: $renamingTitle) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            // Saving reports like every other transition in this file: an empty
            // title can't be committed, and a failure says so instead of
            // showing a new name the store never took.
            Button("Save") {
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                do {
                    try model.core.renameConversation(id: conversationId, title: trimmed)
                    title = trimmed
                } catch {
                    errorText = "Couldn't rename this chat: \(error.localizedDescription)"
                }
            }
            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Allow voice input", isPresented: Binding(
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
        .alert("Voice input didn't work", isPresented: Binding(
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
        .sheet(isPresented: $showVoicePrimer) {
            PermissionPrimer(
                icon: "mic.fill",
                title: "Voice input",
                message: "PocketAI uses the microphone and on-device speech recognition to turn your voice into text. Audio is transcribed on this iPhone and never leaves it.",
                continueLabel: "Enable voice input",
                onContinue: {
                    Task { await voiceDictation.start(handsFree: pendingHandsFree) }
                }
            )
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
        .alert("Camera unavailable", isPresented: $cameraUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device has no camera PocketAI can use.")
        }
    }

    var body: some View {
        chatScaffold
        .sheet(isPresented: $showModelPicker) {
            NavigationStack {
                ModelPickerView(
                    scope: .conversation(id: conversationId),
                    selectedId: currentModelId,
                    onPicked: { bindModel($0) }
                )
            }
        }
        .alert("Stop to switch models", isPresented: $showSwitchWhileGeneratingAlert) {
            Button("Stop", role: .destructive) { stop() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Stop the current reply before switching models.")
        }
        .alert("This model can't see images", isPresented: $showVisionRequiredAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let name = installedVisionModelName {
                Text("Switch to a vision model like \(name) to attach photos. Pick it in Models.")
            } else {
                Text("Download a vision model (e.g. Qwen3-VL) in Models to attach photos.")
            }
        }
        .sheet(item: $activeSourceTurn) { turn in
            if let currentProjectId = projectId {
                SourceSheet(
                    projectId: currentProjectId,
                    query: turn.query,
                    selectedCitation: turn.selectedCitation,
                    core: model.core
                )
            }
        }
        .sheet(isPresented: $showPulseDetailSheet) {
            NavigationStack {
                PulseDetailSheet(
                    ramUsedBytes: Self.appUsedMemoryBytes(),
                    ramBudgetBytes: Int64(model.hooks.deviceProfile().appMemoryLimitBytes),
                    ramTotalBytes: Int64(model.hooks.deviceProfile().totalRamBytes),
                    thermalLabel: thermalStateLabel,
                    loadedModels: pulseLoadedModels,
                    lastReply: lastReplyStats,
                    egressCountToday: model.core.egressLog(limit: 500).count
                )
                .navigationTitle("Pulse")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showPulseDetailSheet = false }
                    }
                }
            }
        }
        .task(id: isGenerating) {
            #if DEBUG
            if PerfDiagnostics.isEnabled { return }
            #endif
            if isGenerating {
                while !Task.isCancelled && isGenerating {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    cursorBlink.toggle()
                }
            }
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

    /// Honest location line (§1.2): says where answers come from, never a
    /// generic claim that would be false for a Mac-routed chat.
    private var emptyChatSubtitle: String {
        guard let id = currentModelId else { return "Download a model in Models, or pair your Mac." }
        if id.hasPrefix("mac:") {
            return "Runs on \(Self.humanLabel(peerName(for: id)) ?? "your Mac"), over your own network."
        }
        return "Runs on this iPhone. Nothing leaves it."
    }

    @ViewBuilder
    private var emptyChatView: some View {
        VStack(spacing: PocketSpacing.s20) {
            Spacer(minLength: 40)
            PocketMarkView(state: .idle, size: 64)
            VStack(spacing: PocketSpacing.s8) {
                Text(currentModelId == nil ? "Choose a model to start" : "How can I help?")
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.textPrimary)
                Text(emptyChatSubtitle)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            // A chat with no model can only fail on send; give the fix first.
            if currentModelId == nil {
                Button("Choose a model", action: openModelPicker)
                    .font(.pocket(.headline))
                    .buttonStyle(.borderedProminent)
                    .tint(PocketColor.accent)
                    .frame(minHeight: 44)
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PocketSpacing.gutterIphone)
    }

    @ViewBuilder
    private var messageList: some View {
        // Once per render, not per row: rows re-render on every streamed delta.
        let lastAssistantId = messages.last(where: { $0.role == "assistant" })?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                // A message starts a new group when the role differs from the
                // one before it; grouped messages sit tight, groups breathe.
                let isGroupStart = index == 0 || messages[index - 1].role != message.role
                messageRow(message, showHeader: isGroupStart, isLatestReply: message.id == lastAssistantId)
                    .id(message.id)
                    .padding(.top, index == 0 ? 0 : (isGroupStart ? PocketSpacing.s16 : PocketSpacing.s4))
            }
            if let errorText {
                errorCard(errorText)
                    .padding(.top, PocketSpacing.s16)
            }
            // UI-29: content never touches chrome — ≥ s16 between the last
            // line and the composer. A scroll target rather than padding, so
            // scrollToLatest keeps the gap (scrolling to the last message's
            // bottom would push the padding back under the composer).
            Color.clear
                .frame(height: PocketSpacing.s16)
                .id(Self.tailId)
        }
        .padding(.horizontal, PocketSpacing.gutterIphone)
        .padding(.top, PocketSpacing.s16)
    }

    private static let tailId = "chat-tail"

    @ViewBuilder
    private func messageRow(_ message: Message, showHeader: Bool, isLatestReply: Bool) -> some View {
        let text = textForMessage(message)
        let thumbnails = imagesForMessage(message)

        if message.role == "user" {
            UserBubble(text: text, attachmentThumbnails: thumbnails)
                .accessibilityIdentifier("chat_bubble_user")
                .accessibilityElement(children: .combine)
                .accessibilityLabel(thumbnails.isEmpty ? "You: \(text)" : "You, with image: \(text)")
                .contextMenu {
                    if !text.isEmpty {
                        Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
        } else {
            let isCurrentSpeaking = speechPlayback.isSpeaking && speechPlayback.currentText == text
            // regenerateLastTurn() always redoes the newest reply, so Retry is
            // only honest on that one, and never mid-stream.
            let canRetry = !isGenerating && isLatestReply
            #if DEBUG
            let isCurrentStreaming = !PerfDiagnostics.isEnabled && isGenerating && message.id == messages.last?.id
            #else
            let isCurrentStreaming = isGenerating && message.id == messages.last?.id
            #endif
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                // Role affordance only on the first bubble of a run (grouping).
                if showHeader {
                    HStack(spacing: PocketSpacing.s8) {
                        PocketMarkView(state: isCurrentStreaming ? .thinking(tokPerSec: liveTokPerSec) : .still, size: 20)
                        Text("PocketAI")
                            .font(.pocket(.caption))
                            .fontWeight(.semibold)
                            .foregroundStyle(PocketColor.textPrimary)

                        if let stats = message.stats {
                            Text("·")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                            Text("\(Int(stats.decodeTps)) tok/s")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 2)
                }

                HStack(alignment: .bottom, spacing: 4) {
                    MessageView(
                        text: text,
                        reasoning: message.reasoning,
                        isThinking: message.status == .streaming && message.stats == nil,
                        statsText: message.stats.map { "\($0.completionTokens) tokens · \(Int($0.decodeTps)) tok/s" },
                        onCopy: { copyToPasteboard(text) },
                        onRetry: { if canRetry { regenerateLastTurn() } },
                        onSpeak: {
                            if isCurrentSpeaking {
                                speechPlayback.stop()
                            } else {
                                speechPlayback.speak(text)
                            }
                        }
                    )
                    .accessibilityIdentifier("chat_bubble_assistant")

                    if isCurrentStreaming {
                        Circle()
                            .fill(PocketColor.accent)
                            .frame(width: streamCursorSize, height: streamCursorSize)
                            .opacity(cursorBlink ? 1.0 : 0.2)
                            .animation(.easeInOut(duration: 0.45), value: cursorBlink)
                            .padding(.bottom, 4)
                            .accessibilityHidden(true)
                    }
                }

                if projectId != nil {
                    let citations = extractCitationNumbers(from: text)
                    // A run of citation chips outgrows a narrow phone (and any
                    // phone at large text), so the row scrolls instead of
                    // clipping. It stays put while the chips fit.
                    ScrollView(.horizontal) {
                        HStack(spacing: PocketSpacing.s8) {
                            Button {
                                openSourceSheet(for: message, selectedCitation: nil)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "quote.opening")
                                        .font(.system(size: 11))
                                    Text("Sources")
                                        .font(.pocket(.footnote))
                                }
                                .foregroundStyle(PocketColor.accent)
                                .padding(.horizontal, PocketSpacing.s8)
                                .padding(.vertical, 4)
                                .background(PocketColor.bgRaised, in: Capsule())
                                .overlay(Capsule().strokeBorder(PocketColor.lineHairline))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Sources")
                            .accessibilityHint("Opens sources sheet listing project document hits")

                            ForEach(citations, id: \.self) { num in
                                Button {
                                    openSourceSheet(for: message, selectedCitation: num)
                                } label: {
                                    Text("[\(num)]")
                                        .font(.pocket(.footnote))
                                        .foregroundStyle(PocketColor.accent)
                                        .padding(.horizontal, PocketSpacing.s8)
                                        .padding(.vertical, PocketSpacing.s4)
                                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.chip, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: PocketRadius.chip, style: .continuous).strokeBorder(PocketColor.lineHairline))
                                        .frame(minWidth: 44, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Citation \(num)")
                                .accessibilityHint("Opens chunk for citation \(num)")
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    // ponytail: inline [n] tap-through needs MessageView token parsing
                }
            }
            // VoiceOver: the reply reads as one element with its actions in
            // the rotor — the long-press menu is unreachable otherwise.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isCurrentStreaming ? .updatesFrequently : [])
            .accessibilityAction(named: "Copy") { copyToPasteboard(text) }
            .accessibilityAction(named: isCurrentSpeaking ? "Stop speaking" : "Speak") {
                if isCurrentSpeaking { speechPlayback.stop() } else { speechPlayback.speak(text) }
            }
            .accessibilityActions {
                if canRetry { Button("Retry") { regenerateLastTurn() } }
            }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                if !text.isEmpty {
                    ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                if isCurrentSpeaking {
                    Button("Stop speaking", systemImage: "stop.fill") {
                        speechPlayback.stop()
                    }
                    .accessibilityLabel("Stop speaking")
                } else {
                    Button("Speak", systemImage: "speaker.wave.2") {
                        speechPlayback.speak(text)
                    }
                    .accessibilityLabel("Speak reply aloud")
                }
                if projectId != nil {
                    Button("Sources", systemImage: "quote.opening") {
                        openSourceSheet(for: message, selectedCitation: nil)
                    }
                }
                if canRetry {
                    Button("Retry", systemImage: "arrow.clockwise") { regenerateLastTurn() }
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func extractCitationNumbers(from text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var numbers: [Int] = []
        for match in matches {
            if let range = Range(match.range(at: 1), in: text), let num = Int(text[range]) {
                if !numbers.contains(num) {
                    numbers.append(num)
                }
            }
        }
        return numbers.sorted()
    }

    private func openSourceSheet(for message: Message, selectedCitation: Int?) {
        let query = userQuery(for: message) ?? "Project query"
        activeSourceTurn = ActiveSourceTurn(query: query, selectedCitation: selectedCitation)
    }

    private func userQuery(for message: Message) -> String? {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else {
            return messages.last(where: { $0.role == "user" }).map { textForMessage($0) }
        }
        for i in (0..<idx).reversed() {
            if messages[i].role == "user" {
                let q = textForMessage(messages[i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !q.isEmpty { return q }
            }
        }
        return messages.last(where: { $0.role == "user" }).map { textForMessage($0) }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            scrollToLatest(proxy: proxy)
            showJumpToLatest = false
            userScrolledUp = false
            setAccessoryCollapsed(false)
        } label: {
            HStack(spacing: PocketSpacing.s4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                Text("Jump to latest")
                    .font(.pocket(.caption))
                    .fontWeight(.medium)
            }
            .foregroundStyle(PocketColor.accent)
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(PocketColor.lineHairline))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .frame(minHeight: 44) // pill stays slim; the hit target doesn't
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, PocketSpacing.s8)
        .accessibilityLabel("Jump to latest message")
    }

    private func scrollToLatest(proxy: ScrollViewProxy, animated: Bool = true) {
        guard !messages.isEmpty else { return }
        #if DEBUG
        if PerfDiagnostics.isEnabled {
            proxy.scrollTo(Self.tailId, anchor: .bottom)
            return
        }
        #endif
        if animated {
            withAnimation { proxy.scrollTo(Self.tailId, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.tailId, anchor: .bottom)
        }
    }

    /// §7.2 error state: reason + the fix that matches it. Retry only for a
    /// failed reply; model problems (stream or Mac re-check) offer the picker;
    /// every card can be dismissed.
    private func errorCard(_ text: String) -> some View {
        let isStreamError = text == lastStreamError
        let isModelProblem = isStreamError || text == lastRemoteCheckError
        return VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: PocketSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusBad)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    errorText = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.pocket(.footnote).weight(.semibold))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            if isModelProblem {
                HStack(spacing: PocketSpacing.s16) {
                    if isStreamError && !isGenerating {
                        Button("Retry") {
                            errorText = nil
                            regenerateLastTurn()
                        }
                        .frame(minHeight: 44)
                    }
                    Button("Change model", action: openModelPicker)
                        .frame(minHeight: 44)
                }
                .font(.pocket(.footnote).weight(.semibold))
                .tint(PocketColor.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, PocketSpacing.s12)
        .padding(.vertical, PocketSpacing.s4)
        .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous)
                .strokeBorder(PocketColor.statusBad.opacity(0.4), lineWidth: 0.5)
        )
    }

    private func reload() {
        messages = model.core.messages(conversationId: conversationId)
        cachedCatalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        // Resolve this conversation directly by ID (F17) — never page-scan
        // conversations(), which misses older chats past the default window.
        if let convo = model.core.conversation(id: conversationId) {
            title = convo.title
            conversationModelId = convo.modelId
        }
        thinkingEnabled = !UserDefaults.standard.bool(forKey: thinkingOffKey)
    }

    /// UI-31 pull-to-refresh: reload from the store and, for a Mac-routed
    /// chat, re-check that the Mac answers and still has the model.
    private func refresh() async {
        // Never touch an in-flight stream: reload() would drop its local echo
        // and streaming placeholder.
        guard !isGenerating else { return }
        reload()
        await recheckRemoteModel()
    }

    private func recheckRemoteModel() async {
        guard let id = currentModelId, let pid = RemoteEngine.peerId(from: id) else { return }
        // A manual pull earns the next send one more automatic reconnect.
        didReconnectRetry = false
        let problem = await remoteModelProblem(id: id, peerId: pid)
        guard !isGenerating else { return }
        if let problem {
            errorText = problem
        } else if errorText == lastRemoteCheckError {
            errorText = nil   // the Mac is back; clear our own stale notice only
        }
        lastRemoteCheckError = problem
    }

    /// nil when the Mac answers and has the model installed; otherwise what to
    /// tell the user. Same endpoint resolution as ModelPickerView.reloadRemote.
    private func remoteModelProblem(id: String, peerId: String) async -> String? {
        guard let peer = model.core.peers().first(where: { $0.id == peerId }) else {
            return "This chat's Mac is no longer paired. Choose another model."
        }
        let unreachable = "Your Mac isn't reachable. Open PocketAI on your Mac and make sure it's awake and on the same network, or switch to an on-device model."
        guard let token = model.hooks.keychainGet(key: peer.tokenRef)
            .flatMap({ String(data: $0, encoding: .utf8) }) else { return unreachable }
        let override = PeerAddressBook.shared.override(forHostId: peer.name)
        guard let host = override?.host ?? peer.addrs.first else { return unreachable }
        let endpoint = PeerEndpoint(host: host, port: override?.port ?? peer.port, fingerprint: peer.certSha256)
        let client = RemoteCatalogClient(peerClient: PeerClient(endpoint: endpoint, token: token))
        let entries: [RemoteCatalogEntry]
        do {
            entries = try await client.catalog()
        } catch let error as PeerClientError where error == .disconnected || error == .disconnectedByHost {
            return error.description // NET-17: "Mac disconnected · Connect…"
        } catch {
            return unreachable
        }
        let localId = RemoteEngine.localModelId(from: id)
        guard entries.contains(where: { $0.manifest.id == localId && $0.state == .installed }) else {
            return "\(modelLocationLabel) is no longer on your Mac. Choose another model."
        }
        return nil
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

        #if DEBUG
        let promptText = composerText.isEmpty && PerfDiagnostics.isEnabled ? "Analyze the architectural trade-offs of deploying large language models on edge devices." : composerText
        guard !promptText.isEmpty || pendingAttachment != nil else {
            NSLog("PERF_DEBUG: send() early exit: empty prompt")
            return
        }
        if PerfDiagnostics.isEnabled {
            PerfDiagnostics.shared.startGeneration()
        }
        #else
        guard !composerText.isEmpty || pendingAttachment != nil else { return }
        let promptText = composerText
        #endif
        speechPlayback.stop()
        let text = promptText
        composerText = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred() // §3.4 send
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let attachment = pendingAttachment
        pendingAttachment = nil
        errorText = nil
        isGenerating = true
        genStartTime = Date()
        genCharCount = 0
        liveTokPerSec = 0
        let streamId = UUID()
        activeStreamId = streamId
        let shouldAutoSpeak = handsFree || autoSpeakReplies

        // Bind this conversation to a usable model only when it is unbound or its
        // bound model is no longer runnable (deleted) — never overwrite a valid
        // per-chat choice with the global default on send (F04/§9.1). The proper
        // "model unavailable — choose another" UI + per-chat picker is T5/U8.
        let boundUsable = conversationModelId.map(isModelUsable) ?? false
        if !boundUsable, let fallback = model.selectedModelId, isModelUsable(fallback) {
            try? model.core.setConversationModel(id: conversationId, modelId: fallback)
            conversationModelId = fallback
        }

        // Vision runs through the MLX VLM engine (PocketMLXEngine handles
        // `.imageRef` parts); the composer only allows attachments when the
        // active model supports vision, so a non-VLM never receives an image.
        var parts: [ContentPart] = []
        if let attachment {
            parts.append(.imageRef(path: attachment.fileURL.path))
        }
        if !text.isEmpty {
            parts.append(.text(text: text))
        }

        // Instant local echo: the user's bubble appears the moment they hit
        // send — never after model load/inference. The .done reload replaces
        // it with the persisted row.
        messages.removeAll { $0.id == "local-echo-user" }
        messages.append(Message(
            id: "local-echo-user", conversationId: conversationId, role: "user",
            parts: parts, reasoning: nil, stats: nil, modelId: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000), status: .done
        ))
        // And an empty streaming bubble right away, so the reply visibly
        // "starts" while the model is still loading.
        upsertStreamingPlaceholder(text: "")

        let input = UserInput(parts: parts)
        // UI-27: explicit on/off only for reasoning-capable models; everything
        // else keeps the model's default via .auto.
        let reasoning: ReasoningMode = currentModelSupportsReasoning
            ? (thinkingEnabled ? .on : .off)
            : .auto
        streamTask = Task {
            await consumeStream(model.core.sendMessage(conversationId: conversationId, input: input, reasoning: reasoning), shouldAutoSpeak: shouldAutoSpeak, streamId: streamId)
        }
    }

    /// Regenerates the latest assistant reply for this conversation (F12): drops
    /// the failed/stopped attempt and re-runs from existing history. Never
    /// duplicates the user input or sends the assistant text back as a prompt.
    private func regenerateLastTurn() {
        guard !isGenerating else { return }
        errorText = nil
        isGenerating = true
        genStartTime = Date()
        genCharCount = 0
        liveTokPerSec = 0
        let streamId = UUID()
        activeStreamId = streamId
        let shouldAutoSpeak = autoSpeakReplies
        reload() // show the dropped assistant attempt disappearing
        upsertStreamingPlaceholder(text: "")
        streamTask = Task {
            await consumeStream(model.core.regenerate(conversationId: conversationId), shouldAutoSpeak: shouldAutoSpeak, streamId: streamId)
        }
    }

    /// Shared consumption for a send or a regenerate stream.
    @MainActor
    private func consumeStream(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>, shouldAutoSpeak: Bool, streamId: UUID) async {
        var partialText = ""
        var partialReasoning = ""
        var sawFirstToken = false
        do {
            // No reload here: it would race the core's DB write and wipe the
            // instant local echo. The .done event reloads with persisted rows.
            for try await event in stream {
                switch event {
                case .delta(let delta):
                    if !sawFirstToken, !(delta.text.isEmpty && delta.reasoning.isEmpty) {
                        // §3.4: one soft tap when the reply starts, never per token.
                        sawFirstToken = true
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    partialText += delta.text
                    partialReasoning += delta.reasoning
                    genCharCount += delta.text.count + delta.reasoning.count
                    if let start = genStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        // ~4 chars/token is the standard rough estimate; the
                        // exact tok/s arrives with the final message stats.
                        if elapsed > 0.2 { liveTokPerSec = (Double(genCharCount) / 4.0) / elapsed }
                    }
                    upsertStreamingPlaceholder(text: partialText, reasoning: partialReasoning)
                case .done(let finalMessage):
                    if let tps = finalMessage.stats?.decodeTps { liveTokPerSec = Double(tps) }
                    #if DEBUG
                    if PerfDiagnostics.isEnabled {
                        latestPerfRecord = perfDiagnostics.recordGeneration(
                            model: finalMessage.modelId ?? "preview-model",
                            stats: finalMessage.stats,
                            fallbackTtftMs: 120,
                            fallbackDecodeTps: 25
                        )
                    }
                    #endif
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
            if await handleRemoteReconnect(error: error) {
                // A reconnect + single retry was kicked off; that new turn
                // owns the generation state, so skip this turn's cleanup.
                return
            }
            if activeStreamId == streamId {
                let message = friendlyError(error)
                errorText = message
                lastStreamError = message
            }
        }
        // Only the stream that still owns the screen may clean up — a Stop
        // followed by an immediate Retry must not be clobbered by the old
        // stream's late teardown.
        guard activeStreamId == streamId else { return }
        isGenerating = false
        liveTokPerSec = 0
        // §8: one announcement when the reply completes, not per token.
        if errorText == nil {
            AccessibilityNotification.Announcement("Reply finished").post()
        }
        // Only a reply the reader was not watching is worth a notification,
        // and only one that actually took a while (§7.10) — an instant answer
        // needs no announcement.
        let took = genStartTime.map { Date().timeIntervalSince($0) } ?? 0
        if took >= Self.replyNotifyAfterSeconds, scenePhase != .active || showJumpToLatest {
            Notifier.shared.replyFinished(
                chatTitle: title ?? "New chat", conversationId: conversationId)
        }
        genStartTime = nil
        reload()
    }

    /// A reply shorter than this is not worth interrupting anyone for.
    private static let replyNotifyAfterSeconds: TimeInterval = 10

    /// Phone browse-to-reconnect (APL-08): a remote (`mac:`) turn that fails
    /// with a connection error is most likely a Mac IP change. Rediscover the
    /// same hostId on the LAN once, park the corrected address, and re-run the
    /// turn a single time. Bounded to one attempt per screen so a truly-down
    /// Mac still falls through to the clear error + the manual Retry button.
    @MainActor
    private func handleRemoteReconnect(error: Error) async -> Bool {
        guard let id = currentModelId, id.hasPrefix("mac:"), !didReconnectRetry else { return false }
        let desc = "\(error)".lowercased()
        let looksLikeConnection = ["could not connect", "cannot connect", "connection", "network",
                                   "unreachable", "refused", "timed out", "offline", "lost"]
            .contains { desc.contains($0) }
        guard looksLikeConnection else { return false }
        didReconnectRetry = true
        // Reconnect the *specific* paired Mac for this chat (F16), not peers().first.
        guard let pid = RemoteEngine.peerId(from: currentModelId ?? ""),
              let peer = model.core.peers().first(where: { $0.id == pid }),
              !PeerAddressBook.shared.isUserDisconnected(fingerprint: peer.certSha256),
              let resolved = await Browser.rediscover(hostId: peer.name, fingerprint: peer.certSha256) else { return false }
        PeerAddressBook.shared.setOverride(resolved, forHostId: peer.name)
        guard messages.contains(where: { $0.role == "user" }) else { return false }
        isGenerating = false
        regenerateLastTurn()
        return true
    }

    /// Turns a raw engine/core error into actionable guidance. The most common
    /// first-run failure is "no model installed / loadable" — guide the user to
    /// Models rather than showing a generic "Something went wrong".
    private func friendlyError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("no model") || desc.contains("not installed") || desc.contains("not exist")
            || desc.contains("config.json") || desc.contains("no engine") || desc.contains("notfound") {
            // Append the raw cause so a masked load/engine failure is visible.
            return "No model is ready yet. (\(error.localizedDescription))"
        }
        if desc.contains("not entitled") || desc.contains("notentitled") {
            return "This needs PocketAI Pro. Unlock it in Settings."
        }
        return "Something went wrong: \(error.localizedDescription)"
    }

    /// Shows the in-flight reply growing in place rather than waiting for
    /// `sendMessage`'s final `.done` event - `messages(conversationId:)`
    /// only reflects the persisted row, so this overlays a synthetic one.
    private func upsertStreamingPlaceholder(text: String, reasoning: String = "") {
        let placeholderId = "streaming-placeholder"
        if let index = messages.firstIndex(where: { $0.id == placeholderId }) {
            messages[index] = streamingMessage(id: placeholderId, text: text, reasoning: reasoning)
        } else {
            messages.append(streamingMessage(id: placeholderId, text: text, reasoning: reasoning))
        }
    }

    private func streamingMessage(id: String, text: String, reasoning: String = "") -> Message {
        Message(
            id: id, conversationId: conversationId, role: "assistant",
            parts: [.text(text: text)], reasoning: reasoning.isEmpty ? nil : reasoning,
            stats: nil, modelId: nil,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000), status: .streaming
        )
    }

    private func stop() {
        // Reach the engine directly (F11) so a synchronous generate stops, then
        // tear down the stream. Idempotent; no-op if nothing is running.
        model.core.cancelConversation(id: conversationId)
        streamTask?.cancel()
        streamTask = nil
        activeStreamId = UUID() // orphan the old stream's cleanup
        isGenerating = false
        // The orphaned stream never cleans up, so the placeholder has to be
        // settled here: left `.streaming`, MessageView keeps a "Thinking…"
        // spinner running forever on a reply that was stopped.
        settleStreamingPlaceholder()
        speechPlayback.stop()
    }

    /// Marks the in-flight placeholder finished (or drops it when nothing was
    /// generated), so no bubble claims to still be working after a Stop.
    private func settleStreamingPlaceholder() {
        guard let index = messages.firstIndex(where: { $0.id == "streaming-placeholder" }) else { return }
        let partial = textForMessage(messages[index])
        let reasoning = messages[index].reasoning
        if partial.isEmpty && (reasoning ?? "").isEmpty {
            messages.remove(at: index)
        } else {
            messages[index] = Message(
                id: "streaming-placeholder", conversationId: conversationId, role: "assistant",
                parts: [.text(text: partial)], reasoning: reasoning,
                stats: nil, modelId: nil,
                createdAt: messages[index].createdAt, status: .done
            )
        }
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop speaking")
            .accessibilityHint("Stops audio playback of the reply")
        }
        .padding(.horizontal, PocketSpacing.s12)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voiceDictation.isTranscribing)
            .accessibilityLabel("Cancel voice recording")
            .accessibilityHint("Discards the recorded audio")

            Spacer()

            if voiceDictation.isTranscribing {
                HStack(spacing: PocketSpacing.s8) {
                    PocketMarkView(state: .loading, size: 16)
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
                    .frame(width: recordGlyphSize, height: recordGlyphSize)
                    .background(PocketColor.accent, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voiceDictation.isTranscribing)
            .accessibilityLabel(voiceDictation.isHandsFree ? "Send voice message" : "Insert voice text")
            .accessibilityHint(voiceDictation.isHandsFree ? "Transcribes audio and sends the message" : "Transcribes audio and places text in the composer")
        }
        .padding(.horizontal, PocketSpacing.s8)
        .padding(.vertical, PocketSpacing.s4)
        .background(.regularMaterial, in: Capsule())
    }

    private func startDictation(handsFree: Bool) {
        speechPlayback.stop()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Explain mic + speech in-context before the one-shot system prompts.
        if VoicePermissions.needsPrimer {
            pendingHandsFree = handsFree
            showVoicePrimer = true
            return
        }
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
                    .frame(width: attachThumbSize, height: attachThumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: PocketSpacing.s8))
                    .overlay(
                        RoundedRectangle(cornerRadius: PocketSpacing.s8)
                            .stroke(PocketColor.lineHairline, lineWidth: 1)
                    )
                    .accessibilityLabel("Pending image attachment")

                // Takes the width a Spacer used to eat, so the filename keeps
                // the room it has instead of truncating early.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image attached")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text(pending.fileURL.lastPathComponent)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { removePendingAttachment() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove attached image")
            }
            .padding(PocketSpacing.s8)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s8)
        }
    }

    private func handlePickedImage(_ image: UIImage) {
        removePendingAttachment()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("attach-\(UUID().uuidString).jpg")
        do {
            guard let data = image.jpegData(compressionQuality: 0.85) else {
                errorText = "Couldn't read that image."
                return
            }
            try data.write(to: fileURL)
            pendingAttachment = PendingAttachment(id: UUID(), image: image, fileURL: fileURL)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            // Never show a chip pointing at a file that doesn't exist.
            errorText = "Couldn't attach the image: \(error.localizedDescription)"
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

    /// Builds a Markdown transcript of the conversation for ShareLink export.
    private func markdownTranscript() -> String {
        var out = "# \(title ?? "PocketAI chat")\n\n"
        for message in messages where message.id != "streaming-placeholder" {
            let who = message.role == "user" ? "You" : "PocketAI"
            let body = textForMessage(message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            out += "**\(who):**\n\n\(body)\n\n"
        }
        return out
    }

    /// Real app memory footprint (phys_footprint — the figure iOS uses for
    /// jetsam), not a fabricated fraction of the limit. Honest-instruments.
    static func appUsedMemoryBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private func textForMessage(_ message: Message) -> String {
        message.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()
    }

    #if DEBUG
    private func perfDiagnosticsOverlay(_ record: PerfDiagnostics.GenerationPerfRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PERF")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(PocketColor.accent)
                Spacer()
                Text(record.model)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PocketColor.textTertiary)
                    .accessibilityIdentifier("perf_model")
            }
            HStack(spacing: 8) {
                Text("TTFT: \(Int(record.ttftMs))ms")
                    .accessibilityIdentifier("perf_ttft_ms")
                Text("TPS: \(String(format: "%.1f", record.decodeTps))")
                    .accessibilityIdentifier("perf_decode_tps")
                Text("Mem: \(String(format: "%.1f", record.peakMemMB))MB")
                    .accessibilityIdentifier("perf_peak_mem_mb")
                Text("ΔAvail: \(String(format: "%.1f", record.availableMemDeltaMB))MB")
                    .accessibilityIdentifier("perf_avail_mem_delta_mb")
                Text("Therm: \(record.thermal)")
                    .accessibilityIdentifier("perf_thermal")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(PocketColor.textSecondary)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, PocketSpacing.gutterIphone)
        .padding(.bottom, PocketSpacing.s4)
    }
    #endif
}

/// UI-36: collapses the composer accessory row while the user reads history:
/// on an upward drag, or once the thread is more than a screen from the bottom.
private struct AccessoryCollapseTracking: ViewModifier {
    let isInteracting: Bool
    let collapse: () -> Void

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                if isInteracting && new < old - 4 { collapse() }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > geo.containerSize.height
            } action: { _, farFromBottom in
                if farFromBottom { collapse() }
            }
    }
}

/// UI-36: 12pt fade-to-canvas on the top edge of the opaque bottom chrome, so
/// scrolled text dissolves into it instead of being cut by a hard edge.
private struct ChromeTopFade: View {
    var body: some View {
        LinearGradient(colors: [PocketColor.bgCanvas.opacity(0), PocketColor.bgCanvas],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 12)
            .offset(y: -12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("Light") {
    NavigationStack { ChatView(conversationId: "fixture-0") }
        .environment(AppModel())
}

#Preview("Dark") {
    NavigationStack { ChatView(conversationId: "fixture-0") }
        .environment(AppModel())
        .preferredColorScheme(.dark)
}

#Preview("AX3") {
    NavigationStack { ChatView(conversationId: "fixture-0") }
        .environment(AppModel())
        .environment(\.dynamicTypeSize, .accessibility3)
}
