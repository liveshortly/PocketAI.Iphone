import SwiftUI
import PocketKit
import PocketUI

/// UI-08/UI-16: Redesigned Chats list + Projects segment (S-CHAT list, S-PRJ).
/// Features large-title nav, date-sectioned grouping, rich preview snippets,
/// native swipe actions, polished empty states, and project card management.
struct ChatsListView: View {
    @Environment(AppModel.self) private var model

    @State private var segment = ProcessInfo.processInfo.arguments.contains("-PocketSegmentProjects") ? Segment.projects : Segment.chats
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var messagePreviews: [String: String] = [:]
    @State private var projects: [Project] = []
    @State private var projectDocCounts: [String: Int] = [:]
    @State private var openConversationId: String?
    @State private var openProjectId: String?
    @State private var pendingInitialMessage: String?
    @State private var isShowingCreateProject = false
    @State private var renamingProject: Project?
    @State private var renameProjectName = ""

    private enum Segment: String, CaseIterable {
        case chats = "Chats"
        case projects = "Projects"
    }

    private struct ConversationGroup: Identifiable {
        var id: String { title }
        let title: String
        let conversations: [ConversationSummary]
    }

    private var groupedConversations: [ConversationGroup] {
        let calendar = Calendar.current
        let now = Date()

        var today: [ConversationSummary] = []
        var yesterday: [ConversationSummary] = []
        var last7Days: [ConversationSummary] = []
        var last30Days: [ConversationSummary] = []
        var earlier: [ConversationSummary] = []

        for conv in conversations {
            let date = Date(millisecondsSince1970: conv.updatedAt)
            if calendar.isDateInToday(date) {
                today.append(conv)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(conv)
            } else if let diff = calendar.dateComponents([.day], from: date, to: now).day, diff < 7 {
                last7Days.append(conv)
            } else if let diff = calendar.dateComponents([.day], from: date, to: now).day, diff < 30 {
                last30Days.append(conv)
            } else {
                earlier.append(conv)
            }
        }

        var groups: [ConversationGroup] = []
        if !today.isEmpty { groups.append(ConversationGroup(title: "Today", conversations: today)) }
        if !yesterday.isEmpty { groups.append(ConversationGroup(title: "Yesterday", conversations: yesterday)) }
        if !last7Days.isEmpty { groups.append(ConversationGroup(title: "Previous 7 Days", conversations: last7Days)) }
        if !last30Days.isEmpty { groups.append(ConversationGroup(title: "Previous 30 Days", conversations: last30Days)) }
        if !earlier.isEmpty { groups.append(ConversationGroup(title: "Earlier", conversations: earlier)) }
        return groups
    }

    private var filteredProjects: [Project] {
        if searchText.isEmpty {
            return projects
        }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.instructions?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented picker pinned below navigation header
                Picker("View", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.top, PocketSpacing.s8)
                .padding(.bottom, PocketSpacing.s12)

                if segment == .projects {
                    projectsContent
                } else {
                    chatsContent
                }
            }
            .background(PocketColor.bgCanvas)
            .navigationTitle(segment == .chats ? "Chats" : "Projects")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if segment == .projects {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            isShowingCreateProject = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(PocketColor.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Create project")
                        .accessibilityHint("Opens sheet to create a new project")
                    } else {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            newChat(firstMessage: nil)
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(PocketColor.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("New chat")
                        .accessibilityIdentifier("new_chat_button")
                    }
                }
            }
            .task { reload() }
            .onChange(of: searchText) { reload() }
            .onChange(of: segment) { reload() }
            .navigationDestination(item: $openConversationId) { id in
                ChatView(conversationId: id, initialMessage: pendingInitialMessage)
            }
            .navigationDestination(item: $openProjectId) { id in
                ProjectDetailView(projectId: id)
            }
            .sheet(isPresented: $isShowingCreateProject) {
                NewProjectSheet { name, instructions in
                    createProject(name: name, instructions: instructions)
                }
            }
            .alert("Rename Project", isPresented: Binding(
                get: { renamingProject != nil },
                set: { if !$0 { renamingProject = nil } }
            )) {
                TextField("Project name", text: $renameProjectName)
                Button("Cancel", role: .cancel) { renamingProject = nil }
                Button("Save") { renameCurrentProject() }
            }
        }
    }

    // MARK: - Chats Content

    @ViewBuilder
    private var chatsContent: some View {
        if conversations.isEmpty {
            emptyChatsState
        } else {
            List {
                ForEach(groupedConversations) { group in
                    Section(header: Text(group.title).font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)) {
                        ForEach(group.conversations, id: \.id) { conversation in
                            conversationRow(conversation)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $searchText, prompt: "Search chats")
        }
    }

    private func conversationRow(_ conversation: ConversationSummary) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openConversationId = conversation.id
        } label: {
            HStack(alignment: .top, spacing: PocketSpacing.s12) {
                ZStack {
                    Circle()
                        .fill(PocketColor.accentSoft)
                        .frame(width: 36, height: 36)
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(PocketColor.accent)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text(conversation.title ?? "New chat")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)

                    if let preview = messagePreviews[conversation.id], !preview.isEmpty {
                        Text(preview)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    Text(Self.relativeFormatter.localizedString(for: Date(millisecondsSince1970: conversation.updatedAt), relativeTo: Date()))
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            .padding(.vertical, PocketSpacing.s4)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                delete(conversation)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                archive(conversation)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(PocketColor.statusWarn)
        }
    }

    private var emptyChatsState: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            PocketMarkView(state: .idle, size: 72)
            VStack(spacing: PocketSpacing.s8) {
                Text("Start your first chat")
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.textPrimary)
                Text("Private AI that lives on your iPhone. Nothing leaves.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PocketSpacing.s24)
            }

            VStack(spacing: PocketSpacing.s12) {
                suggestionButton(icon: "doc.text", title: "Summarize a long email")
                suggestionButton(icon: "lightbulb", title: "Explain a concept simply")
                suggestionButton(icon: "bubble.left.and.text.bubble.right", title: "Draft a quick reply")
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer()
        }
    }

    private func suggestionButton(icon: String, title: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            newChat(firstMessage: title)
        } label: {
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(PocketColor.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s12)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Projects Content

    @ViewBuilder
    private var projectsContent: some View {
        if filteredProjects.isEmpty {
            emptyProjectsState
        } else {
            List {
                ForEach(filteredProjects, id: \.id) { project in
                    projectRow(project)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $searchText, prompt: "Search projects")
        }
    }

    private func projectRow(_ project: Project) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openProjectId = project.id
        } label: {
            HStack(alignment: .top, spacing: PocketSpacing.s12) {
                ZStack {
                    Circle()
                        .fill(PocketColor.accentSoft)
                        .frame(width: 36, height: 36)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(PocketColor.accent)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name)
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: PocketSpacing.s8)

                        if let count = projectDocCounts[project.id], count > 0 {
                            Text("\(count) doc\(count == 1 ? "" : "s")")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PocketColor.bgSunken, in: Capsule())
                        }
                    }

                    if let instructions = project.instructions, !instructions.isEmpty {
                        Text(instructions)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .lineLimit(2)
                    }

                    Text(Self.relativeFormatter.localizedString(for: Date(millisecondsSince1970: project.createdAt), relativeTo: Date()))
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
            .padding(.vertical, PocketSpacing.s4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project: \(project.name)")
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renamingProject = project
                renameProjectName = project.name
            }
            Button("Delete", role: .destructive) {
                deleteProject(project)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteProject(project)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renamingProject = project
                renameProjectName = project.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(PocketColor.accent)
        }
    }

    private var emptyProjectsState: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 72, height: 72)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(PocketColor.accent)
            }
            VStack(spacing: PocketSpacing.s8) {
                Text(projects.isEmpty ? "No projects yet" : "No matching projects")
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.textPrimary)
                Text("Group chats with customized instructions and documents.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PocketSpacing.s24)
            }

            if projects.isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isShowingCreateProject = true
                } label: {
                    Label("Create Project", systemImage: "plus")
                        .font(.pocket(.headline))
                        .padding(.horizontal, PocketSpacing.s20)
                        .padding(.vertical, PocketSpacing.s12)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
            }

            Spacer()
        }
    }

    // MARK: - Actions & Data Loading

    private func reload() {
        conversations = model.core.conversations(
            query: ConversationQuery(search: searchText.isEmpty ? nil : searchText, archived: false, limit: 0, offset: 0)
        )
        // Extract preview snippets for conversations
        var previews: [String: String] = [:]
        for conv in conversations {
            let msgs = model.core.messages(conversationId: conv.id)
            if let lastMsg = msgs.last {
                let text = lastMsg.parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined(separator: " ")
                // Strip markdown code fences and excessive newlines for a clean preview
                let cleaned = text
                    .replacingOccurrences(of: "```[a-zA-Z]*", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "```", with: "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                previews[conv.id] = cleaned
            }
        }
        messagePreviews = previews

        projects = model.core.listProjects()
        var counts: [String: Int] = [:]
        for prj in projects {
            counts[prj.id] = model.core.listDocuments(projectId: prj.id).count
        }
        projectDocCounts = counts
    }

    private func newChat(firstMessage: String?) {
        guard let conversation = try? model.core.createConversation(NewConversation(title: nil, projectId: nil, modelId: model.selectedModelId)) else { return }
        reload()
        pendingInitialMessage = firstMessage
        openConversationId = conversation.id
    }

    private func createProject(name: String, instructions: String?) {
        guard let project = try? model.core.createProject(name: name, instructions: instructions) else { return }
        reload()
        openProjectId = project.id
    }

    private func renameCurrentProject() {
        guard let project = renamingProject else { return }
        let trimmed = renameProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? model.core.renameProject(id: project.id, name: trimmed)
            reload()
        }
        renamingProject = nil
    }

    private func deleteProject(_ project: Project) {
        try? model.core.deleteProject(id: project.id)
        reload()
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

private extension Date {
    init(millisecondsSince1970 ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}
