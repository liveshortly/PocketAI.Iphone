import SwiftUI
import UniformTypeIdentifiers
import PocketKit
import PocketUI

/// UI-16: Project detail screen (S-PRJ)
/// Header with editable project name & instructions.
/// Documents section with fileImporter -> DocumentTextExtractor -> addDocument.
/// Off-main extraction, swipe delete, indexing state indicator.
/// "New chat in project" creates conversation scoped to projectId.
struct ProjectDetailView: View {
    let projectId: String
    @Environment(AppModel.self) private var model

    @State private var project: Project?
    @State private var documents: [Document] = []
    @State private var activeConversationId: String?

    // Project rename & instructions
    @State private var renamingProject = false
    @State private var newProjectName = ""
    @State private var editingInstructions = false
    @State private var editableInstructions = ""

    // Document import & indexing
    @State private var isShowingFileImporter = false
    @State private var isIndexing = false
    @State private var indexingFilename = ""
    @State private var justAddedDocName: String?
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                // Header: Project info & instructions
                headerCard

                // Primary action: Chat in project
                newChatButton

                // Documents section
                documentsSection
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.vertical, PocketSpacing.s16)
        }
        .background(PocketColor.bgCanvas)
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename Project", systemImage: "pencil") {
                        newProjectName = project?.name ?? ""
                        renamingProject = true
                    }
                    Button("Edit Instructions", systemImage: "text.quote") {
                        editableInstructions = project?.instructions ?? ""
                        editingInstructions = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Project options")
            }
        }
        .task {
            reload()
        }
        .alert("Rename Project", isPresented: $renamingProject) {
            TextField("Project name", text: $newProjectName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    try? model.core.renameProject(id: projectId, name: trimmed)
                    reload()
                }
            }
        }
        .sheet(isPresented: $editingInstructions) {
            NavigationStack {
                Form {
                    Section("Project Instructions") {
                        TextEditor(text: $editableInstructions)
                            .frame(minHeight: 150)
                            .accessibilityLabel("Edit project instructions")
                    }
                }
                .navigationTitle("Instructions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingInstructions = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            // Note: FFI currently exposes renameProject; instructions update is staged in view state.
                            if var p = project {
                                p.instructions = editableInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : editableInstructions
                                project = p
                            }
                            editingInstructions = false
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.pdf, .plainText, .text, .sourceCode, .json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Document Import Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
        .navigationDestination(item: $activeConversationId) { convId in
            ChatView(conversationId: convId, projectId: projectId)
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text(project?.name ?? "Project")
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.textPrimary)
                    if let createdAt = project?.createdAt {
                        Text("Created \(Self.relativeFormatter.localizedString(for: Date(millisecondsSince1970: createdAt), relativeTo: Date()))")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textTertiary)
                    }
                }
                Spacer()
                Button {
                    newProjectName = project?.name ?? ""
                    renamingProject = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PocketColor.accent)
                        .padding(PocketSpacing.s8)
                        .background(PocketColor.bgSunken, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename project")
                .accessibilityHint("Edits project name")
            }

            Divider()

            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                HStack {
                    Text("Instructions")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textSecondary)
                    Spacer()
                    Button("Edit") {
                        editableInstructions = project?.instructions ?? ""
                        editingInstructions = true
                    }
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.accent)
                    .accessibilityLabel("Edit instructions")
                }

                if let instructions = project?.instructions, !instructions.isEmpty {
                    Text(instructions)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textPrimary)
                        .lineLimit(4)
                } else {
                    Text("No custom instructions set. Tap Edit to add instructions guiding assistant answers.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                        .italic()
                }
            }
        }
        .padding(PocketSpacing.s16)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketColor.lineHairline))
    }

    // MARK: - Primary Action

    private var newChatButton: some View {
        Button {
            newChatInProject()
        } label: {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("New chat in this project")
                    .font(.pocket(.headline))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(PocketColor.accentOnAccent)
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s12)
            .background(PocketColor.accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat in this project")
        .accessibilityHint("Starts a new conversation grounded in this project's documents")
    }

    // MARK: - Documents Section

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack {
                HStack(spacing: PocketSpacing.s8) {
                    Text("Documents")
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("\(documents.count)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PocketColor.bgSunken, in: Capsule())
                }

                Spacer()

                Button {
                    isShowingFileImporter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Add document")
                            .font(.pocket(.footnote))
                    }
                    .foregroundStyle(PocketColor.accent)
                    .padding(.horizontal, PocketSpacing.s12)
                    .padding(.vertical, 6)
                    .background(PocketColor.bgSunken, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add document")
                .accessibilityHint("Opens file picker to add a document to this project")
            }

            // Brief indexing state indicator
            if isIndexing {
                HStack(spacing: PocketSpacing.s12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Indexing \(indexingFilename)…")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    Spacer()
                }
                .padding(PocketSpacing.s12)
                .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Indexing \(indexingFilename)")
            }

            // Brief added indicator
            if let added = justAddedDocName {
                HStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PocketColor.accent)
                    Text("Added & indexed \(added)")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textPrimary)
                    Spacer()
                }
                .padding(PocketSpacing.s12)
                .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Added and indexed \(added)")
            }

            if documents.isEmpty && !isIndexing {
                VStack(spacing: PocketSpacing.s8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(PocketColor.textTertiary)
                        .padding(.top, PocketSpacing.s8)
                    Text("No documents yet")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("Add PDF, Markdown, or text files to ground chats in this project.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, PocketSpacing.s16)
                    Button {
                        isShowingFileImporter = true
                    } label: {
                        Text("Choose File")
                            .font(.pocket(.callout))
                            .foregroundStyle(PocketColor.accent)
                            .padding(.horizontal, PocketSpacing.s16)
                            .padding(.vertical, PocketSpacing.s8)
                            .background(PocketColor.bgSunken, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, PocketSpacing.s4)
                    .accessibilityLabel("Choose file to add")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PocketSpacing.s24)
                .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PocketColor.lineHairline))
            } else {
                VStack(spacing: PocketSpacing.s8) {
                    ForEach(documents, id: \.id) { doc in
                        documentRow(doc)
                    }
                }
            }
        }
    }

    private func documentRow(_ doc: Document) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: doc.mime.contains("pdf") ? "doc.richtext" : "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(PocketColor.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                    .lineLimit(1)

                HStack(spacing: PocketSpacing.s8) {
                    Text("\(doc.textChars) chars")
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(doc.bytes), countStyle: .file))
                }
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textSecondary)
            }

            Spacer()

            Text(doc.state.capitalized)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PocketColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))

            Button(role: .destructive) {
                deleteDocument(doc)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete document \(doc.name)")
            .accessibilityHint("Removes this document from the project")
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PocketColor.lineHairline))
        .contextMenu {
            Button("Delete", role: .destructive) {
                deleteDocument(doc)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(doc.name), \(doc.textChars) characters, \(doc.state)")
    }

    // MARK: - Actions

    private func reload() {
        let projects = model.core.listProjects()
        project = projects.first { $0.id == projectId }
        documents = model.core.listDocuments(projectId: projectId)
    }

    private func newChatInProject() {
        guard let conversation = try? model.core.createConversation(
            NewConversation(title: nil, projectId: projectId, modelId: model.selectedModelId)
        ) else { return }
        activeConversationId = conversation.id
    }

    private func deleteDocument(_ doc: Document) {
        try? model.core.deleteDocument(id: doc.id)
        reload()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Could not access the selected file."
                showingErrorAlert = true
                return
            }

            let filename = url.lastPathComponent
            let mime = mimeType(for: url)
            let core = model.core
            let currentProjectId = projectId

            isIndexing = true
            indexingFilename = filename

            Task {
                defer {
                    url.stopAccessingSecurityScopedResource()
                    isIndexing = false
                }

                do {
                    // Extract pages and add document off-main thread
                    _ = try await Task.detached {
                        let extractedPages = try DocumentTextExtractor.extract(fileURL: url)
                        let docPages = extractedPages.map { DocumentPage(page: UInt32(max(0, $0.page)), text: $0.text) }
                        return try core.addDocument(projectId: currentProjectId, name: filename, mime: mime, pages: docPages)
                    }.value

                    // Publish back on main actor
                    await MainActor.run {
                        reload()
                        withAnimation {
                            justAddedDocName = filename
                        }
                    }

                    // Clear brief added state after 3 seconds
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        if justAddedDocName == filename {
                            withAnimation {
                                justAddedDocName = nil
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showingErrorAlert = true
                    }
                }
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
            showingErrorAlert = true
        }
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return "application/pdf"
        case "md", "markdown":
            return "text/markdown"
        case "json":
            return "application/json"
        case "html", "htm":
            return "text/html"
        default:
            return "text/plain"
        }
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
