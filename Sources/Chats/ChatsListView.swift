import SwiftUI
import PocketKit
import PocketLiveShortly
import PocketUI

/// UI-08/UI-16: Redesigned Chats list + Projects segment (S-CHAT list, S-PRJ).
/// Features large-title nav, date-sectioned grouping, rich preview snippets,
/// native swipe actions, polished empty states, and project card management.
struct ChatsListView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppModel.self) private var model

    @State private var segment = ProcessInfo.processInfo.arguments.contains("-PocketSegmentProjects") ? Segment.projects : Segment.chats
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var messagePreviews: [String: String] = [:]
    @State private var projects: [Project] = []
    @State private var projectDocCounts: [String: Int] = [:]
    /// Value-based navigation: rows are real NavigationLinks (native tap
    /// handling + highlight), programmatic opens append to the same path.
    private enum Route: Hashable {
        case chat(String)
        case project(String)
    }
    @State private var path: [Route] = []
    /// First message for a just-created chat, keyed to that chat's id so a
    /// later empty chat can never auto-send a stale suggestion.
    @State private var pendingInitial: (id: String, text: String)?
    @State private var isShowingCreateProject = false
    @State private var lsNewSession = false
    @State private var installedModels: [CatalogEntry] = []
    @State private var renamingProject: Project?
    @State private var renameProjectName = ""
    @State private var pendingDelete: ConversationSummary?
    @State private var pendingDeleteProject: Project?
    /// Multi-select (long-press a chat → Select, or toolbar Select).
    @State private var editMode: EditMode = .inactive
    @State private var selectedIds = Set<String>()
    @State private var showBulkDeleteConfirm = false
    /// Surfaces a failed create/rename/delete — a store write that throws used
    /// to leave the tap looking ignored.
    @State private var actionError: String?
    // Row glyphs grow with the labels beside them; a fixed 36pt disc next to
    // accessibility-sized text reads as a bug.
    @ScaledMetric(relativeTo: .headline) private var rowGlyphSize: CGFloat = 36
    @ScaledMetric(relativeTo: .callout) private var suggestionIconWidth: CGFloat = 24

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
        NavigationStack(path: $path) {
            Group {
                if segment == .projects {
                    projectsContent
                } else {
                    chatsContent
                }
            }
            .background(PocketColor.bgCanvas)
            .navigationBarTitleDisplayMode(.inline)
            // Without an opaque bar, scrolled content shows through the
            // segmented control and search field — unreadable at large text
            // sizes where the content is tall.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(PocketColor.bgCanvas, for: .navigationBar)
            .toolbar {
                // Single navigation model: the segmented control IS the title,
                // replacing the redundant large-title + separate picker row.
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    // Fills the title area on any width instead of sitting at
                    // a constant 240pt that only suited one phone.
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("chats_segment")
                }
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
                    } else if editMode == .active {
                        Button("Done") {
                            withAnimation { editMode = .inactive }
                            selectedIds = []
                        }
                        .fontWeight(.semibold)
                        .foregroundStyle(PocketColor.accent)
                    } else {
                        // One menu, every way to start: local chat (current
                        // model), Apple on-device, any installed local model,
                        // or a LiveShortly agent session.
                        Menu {
                            Button {
                                newChat(firstMessage: nil)
                            } label: {
                                Label("New chat", systemImage: "square.and.pencil")
                            }
                            if AppleFoundationModelsEngine.isAvailable {
                                Button {
                                    newChat(firstMessage: nil, modelId: AppleFoundationModelsEngine.modelId)
                                } label: {
                                    Label("Apple Intelligence", systemImage: "apple.logo")
                                }
                            }
                            if !installedModels.isEmpty {
                                Menu {
                                    ForEach(installedModels, id: \.manifest.id) { entry in
                                        Button(entry.manifest.displayName) {
                                            newChat(firstMessage: nil, modelId: entry.manifest.id)
                                        }
                                    }
                                } label: {
                                    Label("Local model", systemImage: "cpu")
                                }
                            }
                            if model.liveShortly.isConnected {
                                Button {
                                    lsNewSession = true
                                } label: {
                                    Label("LiveShortly session…", systemImage: "dot.radiowaves.left.and.right")
                                }
                            }
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
                if segment == .chats, editMode == .active {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(role: .destructive) {
                            showBulkDeleteConfirm = true
                        } label: {
                            Text("Delete (\(selectedIds.count))")
                                .fontWeight(.semibold)
                        }
                        .disabled(selectedIds.isEmpty)
                        Spacer()
                        Button("Select All") {
                            selectedIds = Set(conversations.map(\.id))
                        }
                    }
                }
            }
            .task {
                reload()
                // Open a conversation requested from Home / an App Intent (F26).
                if let id = model.nav.consumePendingConversation() { path.append(.chat(id)) }
                // Start a new chat with a suggested first message (onboarding).
                if let first = model.nav.consumePendingFirstMessage() { newChat(firstMessage: first) }
            }
            .onChange(of: model.nav.pendingOpenConversationId) { _, newId in
                if let id = newId { path.append(.chat(id)); model.nav.consumePendingConversation() }
            }
            .onChange(of: searchText) { reload() }
            .onChange(of: segment) {
                reload()
                editMode = .inactive
                selectedIds = []
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let id):
                    ChatView(conversationId: id, initialMessage: pendingInitial?.id == id ? pendingInitial?.text : nil)
                case .project(let id):
                    ProjectDetailView(projectId: id)
                }
            }
            .onChange(of: path) { _, newValue in
                if newValue.isEmpty {
                    pendingInitial = nil
                    reload() // titles/previews updated while a chat was open
                }
            }
            .sheet(isPresented: $isShowingCreateProject) {
                NewProjectSheet { name, instructions in
                    createProject(name: name, instructions: instructions)
                }
            }
            .sheet(isPresented: $lsNewSession) {
                LSNewSessionSheet(account: model.liveShortly)
            }
            .alert(
                "Delete this chat?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let c = pendingDelete { delete(c) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This permanently deletes the conversation and its messages.")
            }
            .alert(
                "Delete \(pendingDeleteProject?.name ?? "project")?",
                isPresented: Binding(get: { pendingDeleteProject != nil }, set: { if !$0 { pendingDeleteProject = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let p = pendingDeleteProject { deleteProject(p) }
                    pendingDeleteProject = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteProject = nil }
            } message: {
                Text("This permanently deletes the project and its documents.")
            }
            .alert("Rename Project", isPresented: Binding(
                get: { renamingProject != nil },
                set: { if !$0 { renamingProject = nil } }
            )) {
                TextField("Project name", text: $renameProjectName)
                Button("Cancel", role: .cancel) { renamingProject = nil }
                // Save used to accept an empty name and then do nothing.
                Button("Save") { renameCurrentProject() }
                    .disabled(renameProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    // MARK: - Chats Content

    @ViewBuilder
    private var chatsContent: some View {
        // .searchable lives on the Group so the search field survives an empty
        // result set — otherwise a no-hit query hides its own clear control.
        Group {
            // A connected LiveShortly account keeps the List branch alive even
            // with zero local chats — its sessions ARE the content then.
            if conversations.isEmpty && !model.liveShortly.isConnected {
                if searchText.isEmpty {
                    emptyChatsState
                } else {
                    noSearchResultsState
                }
            } else {
                List(selection: $selectedIds) {
                    LSSessionsSection(
                        account: model.liveShortly,
                        onNewSession: { lsNewSession = true })
                    ForEach(groupedConversations) { group in
                        Section(header: Text(group.title).font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)) {
                            ForEach(group.conversations, id: \.id) { conversation in
                                conversationRow(conversation)
                                    .tag(conversation.id)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
        }
        .searchable(text: $searchText, prompt: "Search chats")
        .alert(
            "Delete \(selectedIds.count) chat\(selectedIds.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                var failed = 0
                for id in selectedIds {
                    do { try model.core.deleteConversation(id: id) } catch { failed += 1 }
                }
                selectedIds = []
                editMode = .inactive
                reload()
                if failed > 0 {
                    actionError = "\(failed) chat\(failed == 1 ? "" : "s") couldn't be deleted."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the selected conversations and their messages.")
        }
    }

    private var noSearchResultsState: some View {
        VStack(spacing: PocketSpacing.s12) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(PocketColor.textTertiary)
            Text("No chats match “\(searchText)”")
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
                .multilineTextAlignment(.center)
            Button("Clear search") { searchText = "" }
                .buttonStyle(.bordered)
                .tint(PocketColor.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PocketSpacing.s32)
    }

    private func conversationRow(_ conversation: ConversationSummary) -> some View {
        NavigationLink(value: Route.chat(conversation.id)) {
            HStack(alignment: .top, spacing: PocketSpacing.s12) {
                // Capped: the avatar is decoration and the title is what
                // identifies the chat, so an uncapped circle that took half
                // the row hyphenated it ("Ex-plain this Rust bor-row").
                let glyph = min(rowGlyphSize, 44)
                ZStack {
                    Circle()
                        .fill(PocketColor.accentSoft)
                        .frame(width: glyph, height: glyph)
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: glyph * 0.42))
                        .foregroundStyle(PocketColor.accent)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text(conversation.title ?? "New chat")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

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
        .contextMenu {
            Button("Select Chats", systemImage: "checkmark.circle") {
                selectedIds = [conversation.id]
                withAnimation { editMode = .active }
            }
            Button("Archive", systemImage: "archivebox") { archive(conversation) }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = conversation }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                pendingDelete = conversation // confirm before deleting (F21)
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
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Private AI that lives on your iPhone. Nothing leaves.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, PocketSpacing.s24)

            VStack(spacing: PocketSpacing.s12) {
                suggestionButton(icon: "doc.text", title: "Summarize a long email")
                suggestionButton(icon: "lightbulb", title: "Explain a concept simply")
                suggestionButton(icon: "bubble.left.and.text.bubble.right", title: "Draft a quick reply")
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestionButton(icon: String, title: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            newChat(firstMessage: title)
        } label: {
            HStack(spacing: PocketSpacing.s12) {
                // Capped: a glyph that grows without limit leaves the title a
                // sliver of width, which is what made it hyphenate mid-word.
                Image(systemName: icon)
                    .font(.system(size: min(suggestionIconWidth, 34) * 0.63))
                    .foregroundStyle(PocketColor.accent)
                    .frame(width: min(suggestionIconWidth, 34))
                Text(title)
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PocketColor.textTertiary)
                }
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
        NavigationLink(value: Route.project(project.id)) {
            HStack(alignment: .top, spacing: PocketSpacing.s12) {
                ZStack {
                    Circle()
                        .fill(PocketColor.accentSoft)
                        .frame(width: rowGlyphSize, height: rowGlyphSize)
                    Image(systemName: "folder.fill")
                        .font(.system(size: rowGlyphSize * 0.42))
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
        .accessibilityLabel("Project: \(project.name)")
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renamingProject = project
                renameProjectName = project.name
            }
            Button("Delete", role: .destructive) {
                pendingDeleteProject = project
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeleteProject = project
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
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Group chats with customized instructions and documents.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, PocketSpacing.s24)

            if projects.isEmpty {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isShowingCreateProject = true
                } label: {
                    Label("Create Project", systemImage: "plus")
                        .font(.pocket(.headline))
                        // Spans the content column rather than hugging a
                        // constant, so it reads the same on every width.
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PocketSpacing.s12)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
                .padding(.horizontal, PocketSpacing.gutterIphone)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions & Data Loading

    private func reload() {
        // Re-read here, not once in .task: a model downloaded while this tab
        // stayed alive was missing from the "Local model" menu until relaunch.
        installedModels = model.core.catalog(
            filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
        // ponytail: flat limit 1000, add real pagination if anyone ever has more chats
        conversations = model.core.conversations(
            query: ConversationQuery(search: searchText.isEmpty ? nil : searchText, archived: false, limit: 1000, offset: 0)
        )
        // Preview snippets are a per-conversation DB read each — do them off
        // the main thread so typing in search never stutters.
        let core = model.core
        let ids = conversations.map(\.id)
        Task.detached(priority: .userInitiated) {
            var previews: [String: String] = [:]
            for id in ids {
                guard let lastMsg = core.messages(conversationId: id).last else { continue }
                let text = lastMsg.parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined(separator: " ")
                // Strip markdown code fences and excessive newlines for a clean preview
                previews[id] = text
                    .replacingOccurrences(of: "```[a-zA-Z]*", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "```", with: "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let done = previews
            await MainActor.run { messagePreviews = done }
        }

        projects = model.core.listProjects()
        var counts: [String: Int] = [:]
        for prj in projects {
            counts[prj.id] = model.core.listDocuments(projectId: prj.id).count
        }
        projectDocCounts = counts
    }

    private func newChat(firstMessage: String?, modelId: String? = nil) {
        // New chat is the primary action on this screen: a failure has to say
        // so, never leave the tap looking ignored.
        do {
            let conversation = try model.core.createConversation(
                NewConversation(title: nil, projectId: nil, modelId: modelId ?? model.selectedModelId))
            reload()
            pendingInitial = firstMessage.map { (conversation.id, $0) }
            path.append(.chat(conversation.id))
        } catch {
            actionError = "Couldn't start a new chat: \(error.localizedDescription)"
        }
    }

    private func createProject(name: String, instructions: String?) {
        do {
            let project = try model.core.createProject(name: name, instructions: instructions)
            reload()
            path.append(.project(project.id))
        } catch {
            actionError = "Couldn't create the project: \(error.localizedDescription)"
        }
    }

    private func renameCurrentProject() {
        guard let project = renamingProject else { return }
        let trimmed = renameProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            do {
                try model.core.renameProject(id: project.id, name: trimmed)
                reload()
            } catch {
                actionError = "Couldn't rename “\(project.name)”: \(error.localizedDescription)"
            }
        }
        renamingProject = nil
    }

    private func deleteProject(_ project: Project) {
        do {
            try model.core.deleteProject(id: project.id)
        } catch {
            actionError = "Couldn't delete “\(project.name)”: \(error.localizedDescription)"
        }
        reload()
    }

    private func delete(_ conversation: ConversationSummary) {
        do {
            try model.core.deleteConversation(id: conversation.id)
        } catch {
            actionError = "Couldn't delete that chat: \(error.localizedDescription)"
        }
        reload()
    }

    private func archive(_ conversation: ConversationSummary) {
        do {
            try model.core.archiveConversation(id: conversation.id, archived: true)
        } catch {
            actionError = "Couldn't archive that chat: \(error.localizedDescription)"
        }
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
