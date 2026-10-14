import SwiftUI
import PocketKit
import PocketUI

/// UI-08: chats list + Projects segment (S-CHAT list). Search, swipe
/// delete/archive, new chat button. Projects' own list (W3) is still a
/// placeholder tab - this card only covers the Chats segment and the
/// segmented control itself.
struct ChatsListView: View {
    @Environment(AppModel.self) private var model

    @State private var segment = Segment.chats
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var openConversationId: String?

    private enum Segment: String, CaseIterable {
        case chats = "Chats"
        case projects = "Projects"
    }

    var body: some View {
        NavigationStack {
            Group {
                if segment == .projects {
                    EmptyState(
                        title: "Projects are coming soon",
                        suggestions: [],
                        onTapSuggestion: { _ in }
                    )
                } else if conversations.isEmpty {
                    EmptyState(
                        title: "Start your first chat",
                        suggestions: ["Summarize a long email", "Explain a concept simply", "Draft a quick reply"],
                        onTapSuggestion: { suggestion in newChat(firstMessage: suggestion) }
                    )
                } else {
                    List {
                        ForEach(conversations, id: \.id) { conversation in
                            Button {
                                openConversationId = conversation.id
                            } label: {
                                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                                    Text(conversation.title ?? "New chat")
                                        .font(.pocket(.headline))
                                        .foregroundStyle(PocketColor.textPrimary)
                                    Text(Self.relativeFormatter.localizedString(for: Date(millisecondsSince1970: conversation.updatedAt), relativeTo: Date()))
                                        .font(.pocket(.footnote))
                                        .foregroundStyle(PocketColor.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(conversation) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { archive(conversation) } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(PocketColor.statusWarn)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search chats")
                }
            }
            .navigationTitle("PocketAI")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newChat(firstMessage: nil) } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .background(PocketColor.bgCanvas)
            .task { reload() }
            .onChange(of: searchText) { reload() }
            .onChange(of: segment) { reload() }
            .navigationDestination(item: $openConversationId) { id in
                ConversationStubDetail(conversationId: id)
            }
        }
    }

    private func reload() {
        conversations = model.core.conversations(
            query: ConversationQuery(search: searchText.isEmpty ? nil : searchText, archived: false, limit: 0, offset: 0)
        )
    }

    private func newChat(firstMessage: String?) {
        guard let conversation = try? model.core.createConversation(NewConversation(title: nil, projectId: nil, modelId: nil)) else { return }
        reload()
        openConversationId = conversation.id
    }

    private func delete(_ conversation: ConversationSummary) {
        try? model.core.deleteConversation(id: conversation.id)
        reload()
    }

    private func archive(_ conversation: ConversationSummary) {
        try? model.core.archiveConversation(id: conversation.id, archived: true)
        reload()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// A read-only stand-in for UI-09's real chat screen - just enough to
/// prove `messages(conversationId:)` round-trips through whatever
/// `createConversation` returned above.
private struct ConversationStubDetail: View {
    let conversationId: String
    @Environment(AppModel.self) private var model
    @State private var messages: [Message] = []

    var body: some View {
        List(messages, id: \.id) { message in
            Text(message.role).font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
        }
        .overlay {
            if messages.isEmpty {
                Text("No messages yet - full chat UI is UI-09.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .task { messages = model.core.messages(conversationId: conversationId) }
    }
}

private extension Date {
    init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}
