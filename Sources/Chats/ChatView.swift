import SwiftUI
import PocketKit
import PocketUI

/// UI-09: Chat screen (S-CHAT), `02` §7.2. Covers streaming, stop, retry,
/// title rename, long-press actions, an error card, and the Pulse strip.
/// Not implemented: model switch per chat (no model picker sheet yet,
/// UI-13 scope), branch-from-here, state restoration after an app kill
/// mid-reply (needs a real engine + background task, not exercisable
/// here), and jump-to-latest (always auto-scrolls to bottom instead).
struct ChatView: View {
    let conversationId: String
    var initialMessage: String?
    @Environment(AppModel.self) private var model

    @State private var title: String?
    @State private var messages: [Message] = []
    @State private var composerText = ""
    @State private var isGenerating = false
    @State private var streamTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var renamingTitle = false
    @State private var newTitle = ""

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

            Composer(
                text: $composerText,
                modelChipLabel: nil,
                isFocused: false,
                isGenerating: isGenerating,
                onAttach: { _ in },
                onMic: {},
                onSend: { send() },
                onStop: { stop() }
            )
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s8)
        }
        .background(PocketColor.bgCanvas)
        .navigationTitle(title ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
        .alert("Rename chat", isPresented: $renamingTitle) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                try? model.core.renameConversation(id: conversationId, title: newTitle)
                title = newTitle
            }
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
        let text = message.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()

        if message.role == "user" {
            UserBubble(text: text)
                .contextMenu {
                    Button("Copy") { UIPasteboard.general.string = text }
                }
        } else {
            MessageView(
                text: text,
                reasoning: message.reasoning,
                statsText: message.stats.map { "\($0.completionTokens) tokens · \(Int($0.decodeTps)) tok/s" },
                onCopy: { UIPasteboard.general.string = text },
                onRetry: { retry(after: message) }
            )
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

    private func send() {
        guard !composerText.isEmpty else { return }
        let text = composerText
        composerText = ""
        errorText = nil
        isGenerating = true

        streamTask = Task {
            let input = UserInput(parts: [.text(text: text)])
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
    }

    private func retry(after message: Message) {
        let text = message.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }.joined()
        composerText = text
        send()
    }
}
