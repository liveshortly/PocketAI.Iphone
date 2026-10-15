import SwiftUI
import PocketKit
import PocketUI

/// UI-08/UI-16: chats list + Projects segment (S-CHAT list, S-PRJ). Search, swipe
/// delete/archive, new chat button, projects list with create/rename/delete and
/// detail navigation.
struct ChatsListView: View {
    @Environment(AppModel.self) private var model

    @State private var segment = Segment.chats
    @State private var searchText = ""
    @State private var conversations: [ConversationSummary] = []
    @State private var projects: [Project] = []
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
            Group {
                if segment == .projects {
                    projectsView
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
                    if segment == .projects {
                        Button {
                            isShowingCreateProject = true
                        } label: {
                            Image(systemName: "plus")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Create project")
                        .accessibilityHint("Opens sheet to create a new project")
                    } else {
                        Button { newChat(firstMessage: nil) } label: {
                            Image(systemName: "square.and.pencil")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("New chat")
                        .accessibilityIdentifier("new_chat_button")
                    }
                }
            }
            .background(PocketColor.bgCanvas)
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

    @ViewBuilder
    private var projectsView: some View {
        if filteredProjects.isEmpty {
            EmptyState(
                title: projects.isEmpty ? "No projects yet" : "No matching projects",
                suggestions: projects.isEmpty ? ["Create a project", "Architecture notes", "Product specs"] : [],
                onTapSuggestion: { _ in isShowingCreateProject = true }
            )
        } else {
            List {
                ForEach(filteredProjects, id: \.id) { project in
                    Button {
                        openProjectId = project.id
                    } label: {
                        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                            Text(project.name)
                                .font(.pocket(.headline))
                                .foregroundStyle(PocketColor.textPrimary)
                            if let instructions = project.instructions, !instructions.isEmpty {
                                Text(instructions)
                                    .font(.pocket(.footnote))
                                    .foregroundStyle(PocketColor.textSecondary)
                                    .lineLimit(1)
                            }
                            Text(Self.relativeFormatter.localizedString(for: Date(millisecondsSince1970: project.createdAt), relativeTo: Date()))
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
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
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search projects")
        }
    }

    private func reload() {
        conversations = model.core.conversations(
            query: ConversationQuery(search: searchText.isEmpty ? nil : searchText, archived: false, limit: 0, offset: 0)
        )
        projects = model.core.listProjects()
    }

    private func newChat(firstMessage: String?) {
        guard let conversation = try? model.core.createConversation(NewConversation(title: nil, projectId: nil, modelId: nil)) else { return }
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
