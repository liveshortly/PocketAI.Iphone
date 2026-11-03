import SwiftUI
import UniformTypeIdentifiers
import PocketKit
import PocketUI

@Observable
@MainActor
final class SharedInboxViewModel {
    let core: CoreClient
    var items: [SharedInboxItem] = []
    var projects: [Project] = []
    var isIngesting: Bool = false
    var ingestingStatus: String = ""
    var skippedWarnings: [String] = []
    var showingNewProjectSheet: Bool = false

    init(core: CoreClient) {
        self.core = core
        reload()
    }

    func reload() {
        items = SharedInbox.listItems()
        projects = core.listProjects()
    }

    func deleteItem(_ item: SharedInboxItem) {
        SharedInbox.deleteItem(item)
        items.removeAll { $0.id == item.id }
    }

    func discardAll() {
        for item in items {
            SharedInbox.deleteItem(item)
        }
        items.removeAll()
    }

    func ingestIntoProject(id projectId: String, projectName: String, onFinished: @escaping () -> Void) {
        guard !items.isEmpty, !isIngesting else { return }
        isIngesting = true
        skippedWarnings.removeAll()

        Task {
            let currentItems = items
            var warnings: [String] = []

            for (index, item) in currentItems.enumerated() {
                ingestingStatus = "Adding \(index + 1) of \(currentItems.count): \(item.originalName)…"

                guard let fileURL = SharedInbox.payloadURL(for: item),
                      FileManager.default.fileExists(atPath: fileURL.path) else {
                    warnings.append("Couldn't find the shared file for “\(item.originalName)”")
                    SharedInbox.deleteItem(item)
                    continue
                }

                do {
                    let payload = try await extractPagesOffMain(for: item, at: fileURL)
                    _ = try core.addDocument(
                        projectId: projectId,
                        name: payload.name,
                        mime: payload.mime,
                        pages: payload.pages
                    )
                    SharedInbox.deleteItem(item)
                } catch {
                    warnings.append("Skipped “\(item.originalName)”: \(error.localizedDescription)")
                    SharedInbox.deleteItem(item)
                }
            }

            isIngesting = false
            reload()
            if !warnings.isEmpty {
                skippedWarnings = warnings
            } else {
                onFinished()
            }
        }
    }

    private struct ExtractedPayload: Sendable {
        let name: String
        let mime: String
        let pages: [DocumentPage]
    }

    private func extractPagesOffMain(for item: SharedInboxItem, at url: URL) async throws -> ExtractedPayload {
        let kind = item.kind
        let originalName = item.originalName
        let note = item.note

        return try await Task.detached {
            switch kind {
            case .url:
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let content: String
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content = "\(text)\n\nNote: \(note)"
                } else {
                    content = text
                }
                let page = DocumentPage(page: 1, text: content)
                return ExtractedPayload(name: originalName, mime: "text/plain", pages: [page])

            case .text:
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let content: String
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content = "\(text)\n\nNote: \(note)"
                } else {
                    content = text
                }
                let page = DocumentPage(page: 1, text: content)
                return ExtractedPayload(name: originalName, mime: "text/plain", pages: [page])

            case .image:
                let desc: String
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    desc = "[Image: \(originalName)]\n\(note)"
                } else {
                    desc = "[Image: \(originalName)]"
                }
                let ext = url.pathExtension.lowercased()
                let mime = ext == "png" ? "image/png" : "image/jpeg"
                let page = DocumentPage(page: 1, text: desc)
                return ExtractedPayload(name: originalName, mime: mime, pages: [page])

            case .pdf:
                let extracted = try DocumentTextExtractor.extract(fileURL: url)
                var docPages = extracted.map { DocumentPage(page: UInt32(max(0, $0.page)), text: $0.text) }
                if docPages.isEmpty {
                    docPages = [DocumentPage(page: 1, text: "")]
                }
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let first = docPages[0]
                    docPages[0] = DocumentPage(page: first.page, text: "\(first.text)\n\nNote: \(note)")
                }
                return ExtractedPayload(name: originalName, mime: "application/pdf", pages: docPages)
            }
        }.value
    }
}

public struct SharedInboxIngestSheet: View {
    @State private var viewModel: SharedInboxViewModel
    @State private var confirmDiscardAll = false
    let onDismiss: () -> Void

    public init(core: CoreClient, onDismiss: @escaping () -> Void) {
        _viewModel = State(initialValue: SharedInboxViewModel(core: core))
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                    if !viewModel.skippedWarnings.isEmpty {
                        warningsCard
                    }

                    if viewModel.isIngesting {
                        ingestingCard
                    }

                    // Section 1: Shared items being imported
                    itemsSection

                    // Section 2: Destination project selection
                    destinationSection
                }
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.vertical, PocketSpacing.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PocketColor.bgCanvas)
            .navigationTitle("Add to project")
            .confirmationDialog(
                "Discard \(viewModel.items.count) shared item\(viewModel.items.count == 1 ? "" : "s")?",
                isPresented: $confirmDiscardAll, titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    viewModel.discardAll()
                    onDismiss()
                }
            } message: {
                Text("They're removed from PocketAI. Share them again to add them later.")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.skippedWarnings.isEmpty ? "Cancel" : "Done") {
                        onDismiss()
                    }
                    .disabled(viewModel.isIngesting)
                }
                if !viewModel.items.isEmpty && !viewModel.isIngesting {
                    ToolbarItem(placement: .topBarTrailing) {
                        // UI-134: discarding can't be undone, so it asks first.
                        Button("Discard all", role: .destructive) {
                            confirmDiscardAll = true
                        }
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusBad)
                    }
                }
            }
            .sheet(isPresented: $viewModel.showingNewProjectSheet) {
                NewProjectSheet { name, instructions in
                    do {
                        let newProj = try viewModel.core.createProject(name: name, instructions: instructions)
                        viewModel.reload()
                        viewModel.ingestIntoProject(id: newProj.id, projectName: newProj.name) {
                            onDismiss()
                        }
                    } catch {
                        // Reuses the warnings card: a failed create just closed
                        // the New Project sheet with nothing imported and
                        // nothing said.
                        viewModel.skippedWarnings = ["Couldn't create “\(name)”: \(error.localizedDescription)"]
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusWarn)
                Text("Some items were skipped")
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
            }
            ForEach(viewModel.skippedWarnings, id: \.self) { warning in
                Text("• \(warning)")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
        }
        .padding(PocketSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketColor.statusWarn.opacity(0.12), in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous).strokeBorder(PocketColor.statusWarn.opacity(0.3)))
    }

    private var ingestingCard: some View {
        VStack(spacing: PocketSpacing.s12) {
            PocketMarkView(state: .loading, size: 40)
                .accessibilityHidden(true) // the adjacent text carries the status
            Text(viewModel.ingestingStatus)
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(PocketSpacing.s20)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous).strokeBorder(PocketColor.lineHairline))
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack {
                Text("Shared items")
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.textPrimary)
                Text("\(viewModel.items.count)")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PocketColor.bgSunken, in: Capsule())
            }

            if viewModel.items.isEmpty {
                Text("Nothing waiting to be added.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(.vertical, PocketSpacing.s8)
            } else {
                VStack(spacing: PocketSpacing.s8) {
                    ForEach(viewModel.items) { item in
                        itemRow(item)
                    }
                }
            }
        }
    }

    private func itemRow(_ item: SharedInboxItem) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            itemIcon(for: item.kind)
                .font(.pocket(.title))
                .foregroundStyle(PocketColor.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.originalName)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                    .lineLimit(1)

                HStack(spacing: PocketSpacing.s8) {
                    Text(item.kind.rawValue.uppercased())
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.accent)
                    if let note = item.note, !note.isEmpty {
                        Text("•")
                            .foregroundStyle(PocketColor.textTertiary)
                        Text(note)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if !viewModel.isIngesting {
                Button(role: .destructive) {
                    viewModel.deleteItem(item)
                    if viewModel.items.isEmpty {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.originalName)")
            }
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous).strokeBorder(PocketColor.lineHairline))
    }

    private func itemIcon(for kind: SharedInboxItemKind) -> Image {
        switch kind {
        case .pdf:
            return Image(systemName: "doc.richtext")
        case .image:
            return Image(systemName: "photo")
        case .url:
            return Image(systemName: "link")
        case .text:
            return Image(systemName: "doc.text")
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            Text("Add to project")
                .font(.pocket(.title))
                .foregroundStyle(PocketColor.textPrimary)

            // New project button
            Button {
                viewModel.showingNewProjectSheet = true
            } label: {
                HStack(spacing: PocketSpacing.s12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New project…")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.accent)
                        Text("Create a new project and add these items")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .padding(PocketSpacing.s12)
                .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous).strokeBorder(PocketColor.lineHairline))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isIngesting || viewModel.items.isEmpty)

            // Existing projects
            if viewModel.projects.isEmpty {
                VStack(spacing: PocketSpacing.s4) {
                    Text("No projects yet.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .padding(.vertical, PocketSpacing.s8)
            } else {
                VStack(spacing: PocketSpacing.s8) {
                    ForEach(viewModel.projects, id: \.id) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        Button {
            viewModel.ingestIntoProject(id: project.id, projectName: project.name) {
                onDismiss()
            }
        } label: {
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: "folder")
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.accent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                        .lineLimit(1)

                    if let instructions = project.instructions, !instructions.isEmpty {
                        Text(instructions)
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "arrow.down.doc")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.accent)
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card, style: .continuous).strokeBorder(PocketColor.lineHairline))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isIngesting || viewModel.items.isEmpty)
        .accessibilityLabel("Add items to project \(project.name)")
    }
}
