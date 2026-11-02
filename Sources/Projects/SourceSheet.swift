import SwiftUI
import PocketKit
import PocketUI

struct SourceSheet: View {
    let projectId: String
    let query: String
    let selectedCitation: Int?
    let core: CoreClient

    @Environment(\.dismiss) private var dismiss
    @State private var hits: [ChunkHit] = []
    @State private var documentsById: [String: PocketKit.Document] = [:]
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: PocketSpacing.s16) {
                        ProgressView()
                        Text("Searching project documents…")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hits.isEmpty {
                    VStack(spacing: PocketSpacing.s12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(PocketColor.textTertiary)
                        Text("No Sources Found")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("No matching passages found in project documents for this query.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, PocketSpacing.s24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                                    Text("Query")
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textTertiary)
                                    Text(query)
                                        .font(.pocket(.footnote))
                                        .foregroundStyle(PocketColor.textPrimary)
                                        .padding(PocketSpacing.s8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .padding(.horizontal, PocketSpacing.gutterIphone)
                                .padding(.top, PocketSpacing.s8)

                                ForEach(Array(hits.enumerated()), id: \.offset) { index, hit in
                                    let citationNum = index + 1
                                    let isHighlighted = selectedCitation == citationNum
                                    let doc = documentsById[hit.documentId]

                                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                                        HStack {
                                            Text("[\(citationNum)]")
                                                .font(.pocket(.headline))
                                                .foregroundStyle(isHighlighted ? PocketColor.accent : PocketColor.textPrimary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(
                                                    isHighlighted ? PocketColor.accent.opacity(0.15) : PocketColor.bgSunken,
                                                    in: RoundedRectangle(cornerRadius: 6)
                                                )

                                            Image(systemName: doc?.mime.contains("pdf") == true ? "doc.richtext" : "doc.text")
                                                .foregroundStyle(PocketColor.accent)

                                            Text(doc?.name ?? "Document")
                                                .font(.pocket(.headline))
                                                .foregroundStyle(PocketColor.textPrimary)
                                                .lineLimit(1)

                                            Spacer()

                                            if let page = hit.page {
                                                Text("Page \(page)")
                                                    .font(.pocket(.caption))
                                                    .foregroundStyle(PocketColor.textTertiary)
                                            }
                                        }

                                        Text(hit.text)
                                            .font(.pocket(.callout))
                                            .foregroundStyle(PocketColor.textPrimary)
                                            .textSelection(.enabled)
                                            .padding(PocketSpacing.s12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: 8))

                                        if hit.score > 0 {
                                            Text(String(format: "Relevance score: %.2f", hit.score))
                                                .font(.pocket(.caption))
                                                .foregroundStyle(PocketColor.textTertiary)
                                        }
                                    }
                                    .padding(PocketSpacing.s12)
                                    .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(isHighlighted ? PocketColor.accent : PocketColor.lineHairline, lineWidth: isHighlighted ? 2 : 1)
                                    )
                                    .padding(.horizontal, PocketSpacing.gutterIphone)
                                    .id(citationNum)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("Citation \(citationNum) from \(doc?.name ?? "Document"), \(hit.page.map { "Page \($0)" } ?? ""): \(hit.text)")
                                }
                            }
                            .padding(.bottom, PocketSpacing.s24)
                        }
                        .onAppear {
                            if let selectedCitation {
                                withAnimation {
                                    proxy.scrollTo(selectedCitation, anchor: .top)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Dismiss sources")
                }
            }
            .background(PocketColor.bgCanvas)
            .task {
                await loadSources()
            }
        }
    }

    /// Off the main actor like every other search in the app: run on main, the
    /// embedding search froze the sheet with its own spinner on screen.
    private func loadSources() async {
        isLoading = true
        let core = self.core
        let projectId = self.projectId
        let query = self.query
        let loaded = await Task.detached(priority: .userInitiated) { () -> ([String: PocketKit.Document], [ChunkHit]) in
            var map: [String: PocketKit.Document] = [:]
            for doc in core.listDocuments(projectId: projectId) {
                map[doc.id] = doc
            }
            return (map, core.searchProject(projectId: projectId, query: query, k: 5))
        }.value
        documentsById = loaded.0
        hits = loaded.1
        isLoading = false
    }
}
