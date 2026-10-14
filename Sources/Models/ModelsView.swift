import SwiftUI
import PocketKit
import PocketUI

/// UI-10: Models (S-MOD). "On your Mac" segment is NET-10/UI-12 scope
/// (needs pairing) and isn't added until a Mac is actually paired, so this
/// only covers "On this iPhone" and "Browse" for now.
struct ModelsView: View {
    @Environment(AppModel.self) private var model

    private enum Segment: String, CaseIterable { case onDevice = "On this iPhone", browse = "Browse" }

    @State private var segment = Segment.browse
    @State private var searchText = ""
    @State private var fitsOnly = true
    @State private var catalog: [CatalogEntry] = []
    @State private var detail: CatalogEntry?
    @State private var pendingDelete: CatalogEntry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.vertical, PocketSpacing.s8)

                if segment == .browse {
                    Toggle("Fits only", isOn: $fitsOnly)
                        .font(.pocket(.footnote))
                        .padding(.horizontal, PocketSpacing.gutterIphone)
                        .padding(.bottom, PocketSpacing.s8)
                }

                List {
                    ForEach(groupedSections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.entries, id: \.manifest.id) { entry in
                                ModelRow(
                                    data: rowData(for: entry),
                                    primaryActionLabel: primaryActionLabel(for: entry),
                                    onPrimaryAction: { performPrimaryAction(for: entry) }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { detail = entry }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Search models")
            }
            .navigationTitle("Models")
            .background(PocketColor.bgCanvas)
            .task { reload() }
            .onChange(of: searchText) { reload() }
            .onChange(of: segment) { reload() }
            .onChange(of: fitsOnly) { reload() }
            .refreshable { reload() }
            .sheet(item: $detail) { entry in
                ModelDetailSheet(
                    entry: entry,
                    primaryActionLabel: primaryActionLabel(for: entry),
                    onPrimaryAction: { performPrimaryAction(for: entry) },
                    onDelete: entry.state == .installed ? { pendingDelete = entry; detail = nil } : nil
                )
            }
            .confirmationDialog(
                "Delete \(pendingDelete?.manifest.displayName ?? "model")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let entry = pendingDelete {
                        try? model.core.deleteModel(modelId: entry.manifest.id)
                        reload()
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let entry = pendingDelete {
                    Text("Frees \(formatBytes(entry.manifest.estRuntimeBytes)).")
                }
            }
        }
    }

    private struct ModelSection {
        let title: String
        let entries: [CatalogEntry]
    }

    private var groupedSections: [ModelSection] {
        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if segment == .onDevice {
            entries = entries.filter { $0.state == .installed || $0.state == .downloading || $0.state == .paused }
            return entries.isEmpty ? [] : [ModelSection(title: "On this iPhone", entries: entries)]
        }
        if fitsOnly {
            entries = entries.filter { $0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow }
        }
        var sections: [ModelSection] = []
        let recommended = entries.filter { $0.manifest.tags.contains("recommended") }
        if !recommended.isEmpty { sections.append(ModelSection(title: "Recommended for this iPhone", entries: recommended)) }
        let vision = entries.filter { $0.manifest.modalities.contains(.vision) }
        if !vision.isEmpty { sections.append(ModelSection(title: "Vision", entries: vision)) }
        let voice = entries.filter { $0.manifest.modalities.contains(.speechToText) || $0.manifest.modalities.contains(.textToSpeech) }
        if !voice.isEmpty { sections.append(ModelSection(title: "Voice", entries: voice)) }
        let images = entries.filter { $0.manifest.modalities.contains(.image) }
        if !images.isEmpty { sections.append(ModelSection(title: "Images", entries: images)) }
        let rest = entries.filter {
            !$0.manifest.tags.contains("recommended")
                && !$0.manifest.modalities.contains(.vision)
                && !$0.manifest.modalities.contains(.speechToText)
                && !$0.manifest.modalities.contains(.textToSpeech)
                && !$0.manifest.modalities.contains(.image)
        }
        if !rest.isEmpty { sections.append(ModelSection(title: "Fast & small", entries: rest)) }
        return sections
    }

    private func reload() {
        catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
    }

    private func rowData(for entry: CatalogEntry) -> ModelRowData {
        ModelRowData(
            name: entry.manifest.displayName,
            familyParamsQuant: "\(entry.manifest.family) · \(entry.manifest.quant)",
            fitKind: fitKind(entry.fit.verdict),
            fitReason: entry.fit.reason,
            sizeOnDisk: formatBytes(entry.manifest.estRuntimeBytes),
            speedText: entry.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
            speedIsMeasured: entry.fit.measuredTokensPerSec != nil,
            licenseLabel: entry.manifest.license.spdx
        )
    }

    private func primaryActionLabel(for entry: CatalogEntry) -> String {
        switch entry.state {
        case .installed: return "Open"
        case .downloading: return "Pause"
        case .paused: return "Resume"
        case .verifying: return "Checking…"
        case .failed: return "Retry"
        case .available, .queued: return entry.fit.verdict == .willNotFit ? "Won't fit" : "Download \(formatBytes(entry.manifest.estRuntimeBytes))"
        }
    }

    private func performPrimaryAction(for entry: CatalogEntry) {
        switch entry.state {
        case .downloading: try? model.core.pauseDownload(modelId: entry.manifest.id)
        case .paused: try? model.core.resumeDownload(modelId: entry.manifest.id)
        case .available, .queued, .failed: try? model.core.startDownload(modelId: entry.manifest.id)
        case .installed, .verifying: break
        }
        reload()
    }

    private func fitKind(_ verdict: FitVerdict) -> FitBadgeKind {
        switch verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }
}

private struct ModelDetailSheet: View {
    let entry: CatalogEntry
    let primaryActionLabel: String
    let onPrimaryAction: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(entry.manifest.displayName).font(.pocket(.title))
                    Text(entry.manifest.family).font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                    FitBadge(kind: fitKind, reason: entry.fit.reason)
                }
                Section("Specs") {
                    LabeledContent("Quant", value: entry.manifest.quant)
                    LabeledContent("Context", value: "\(entry.manifest.contextLength)")
                    LabeledContent("Size", value: formatBytes(entry.manifest.estRuntimeBytes))
                    LabeledContent("Format", value: "\(entry.manifest.format)")
                }
                Section("License") {
                    Text(entry.manifest.license.spdx)
                    Link(entry.manifest.license.url, destination: URL(string: entry.manifest.license.url) ?? URL(string: "https://huggingface.co")!)
                }
                if entry.state == .downloading || entry.state == .paused {
                    Section {
                        DownloadProgress(
                            state: entry.state == .paused
                                ? .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes))
                                : .downloading(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(entry.manifest.estRuntimeBytes), bytesPerSecond: 18_000_000),
                            onPauseResume: onPrimaryAction,
                            onCancel: {}
                        )
                    }
                }
                Section {
                    Button(primaryActionLabel, action: onPrimaryAction)
                    if let onDelete {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                }
            }
            .navigationTitle("Model details")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var fitKind: FitBadgeKind {
        switch entry.fit.verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }
}

extension CatalogEntry: @retroactive Identifiable {
    public var id: String { manifest.id }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
