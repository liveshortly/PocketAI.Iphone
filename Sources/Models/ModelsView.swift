import SwiftUI
import PocketKit
import PocketUI

/// UI-10: Redesigned Models catalog & manager (S-MOD).
/// Features segmented navigation (On this iPhone / Browse / On your Mac),
/// "Recommended for this iPhone" hero card, Fit badges, clean download progress,
/// categorized model sections, and a refined detail sheet.
struct ModelsView: View {
    @Environment(AppModel.self) private var model

    private enum Segment: String, CaseIterable {
        case onDevice = "On this iPhone"
        case browse = "Browse"
        case onMac = "On your Mac"
    }

    @State private var segment = Segment.browse
    @State private var searchText = ""
    @State private var fitsOnly = false
    @State private var catalog: [CatalogEntry] = []
    @State private var detail: CatalogEntry?
    @State private var pendingDelete: CatalogEntry?
    @State private var hubResults: [CatalogEntry] = []
    @State private var hubSearchError: String?
    @State private var peers: [Peer] = []
    @State private var remoteCatalog: [RemoteCatalogEntry] = []
    @State private var remoteError: String?

    private var availableSegments: [Segment] {
        peers.isEmpty ? [.onDevice, .browse] : [.onDevice, .browse, .onMac]
    }

    private var heroEntry: CatalogEntry? {
        catalog.first { $0.manifest.tags.contains("recommended") && $0.fit.verdict == .runsWell }
            ?? catalog.first { $0.fit.verdict == .runsWell }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented picker
                Picker("Catalog", selection: $segment) {
                    ForEach(availableSegments, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.top, PocketSpacing.s8)
                .padding(.bottom, PocketSpacing.s8)

                if segment == .browse {
                    HStack {
                        Toggle("Fits only", isOn: $fitsOnly)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                    .padding(.bottom, PocketSpacing.s8)
                }

                List {
                    // Hero card in Browse mode when no active search
                    if segment == .browse, searchText.isEmpty, let hero = heroEntry {
                        Section {
                            heroCard(hero)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }

                    if segment == .onMac {
                        if let remoteError {
                            Text(remoteError).font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
                        }
                        Section("On your Mac") {
                            ForEach(remoteCatalog) { entry in
                                ModelRow(
                                    data: remoteRowData(for: entry),
                                    primaryActionLabel: remotePrimaryActionLabel(for: entry),
                                    onPrimaryAction: { performRemotePrimaryAction(for: entry) }
                                )
                            }
                        }
                    } else if segment == .onDevice && groupedSections.isEmpty {
                        Section {
                            emptyOnDeviceState
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(groupedSections) { section in
                            modelSectionView(section)
                        }
                    }

                    if segment == .browse, !searchText.isEmpty {
                        Section {
                            if model.core.isOffline() {
                                Label("Offline mode is on — turn it off in Settings to search Hugging Face.", systemImage: "airplane")
                                    .font(.pocket(.footnote))
                                    .foregroundStyle(PocketColor.textSecondary)
                            } else {
                                Button {
                                    Task { await searchHub() }
                                } label: {
                                    Label("Search Hugging Face for \"\(searchText)\"", systemImage: "magnifyingglass")
                                }
                            }
                            if let hubSearchError {
                                Text(hubSearchError).font(.pocket(.caption)).foregroundStyle(PocketColor.statusBad)
                            }
                            ForEach(hubResults, id: \.manifest.id) { entry in
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
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Search models")
                .padding(.bottom, 110)
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.large)
            .background(PocketColor.bgCanvas)
            .task {
                reload()
                peers = model.core.peers()
            }
            .onChange(of: searchText) { reload() }
            .onChange(of: segment) { _, newValue in
                if newValue == .onMac { Task { await reloadRemote() } }
            }
            .onChange(of: fitsOnly) { reload() }
            .refreshable {
                reload()
                if segment == .onMac { await reloadRemote() }
            }
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

    // MARK: - Hero Card

    private func heroCard(_ hero: CatalogEntry) -> some View {
        Button {
            detail = hero
        } label: {
            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                HStack {
                    HStack(spacing: PocketSpacing.s4) {
                        PocketMarkView(state: .idle, size: 14)
                        Text("RECOMMENDED FOR THIS IPHONE")
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                            .foregroundStyle(PocketColor.accent)
                    }
                    .padding(.horizontal, PocketSpacing.s8)
                    .padding(.vertical, 4)
                    .background(PocketColor.accentSoft, in: Capsule())

                    Spacer()

                    FitBadge(kind: fitKind(hero.fit.verdict), reason: hero.fit.reason)
                }

                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text(hero.manifest.displayName)
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.textPrimary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(hero.manifest.family) · \(hero.manifest.quant) · \(formatBytes(hero.manifest.estRuntimeBytes))")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(hero.fit.reason)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                HStack(spacing: PocketSpacing.s12) {
                    if let tok = hero.fit.estTokensPerSec {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.caption2)
                                .foregroundStyle(PocketColor.accent)
                            Text("\(Int(tok)) tok/s")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    }

                    Text(hero.manifest.license.spdx)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)

                    Spacer()

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        performPrimaryAction(for: hero)
                    } label: {
                        Text(primaryActionLabel(for: hero))
                            .font(.pocket(.footnote))
                            .fontWeight(.semibold)
                            .foregroundStyle(PocketColor.accentOnAccent)
                            .padding(.horizontal, PocketSpacing.s12)
                            .padding(.vertical, 6)
                            .background(PocketColor.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("model_action_button_\(hero.manifest.id)")
                }
                .padding(.top, PocketSpacing.s4)
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(PocketColor.lineHairline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("model_hero_\(hero.manifest.id)")
        .accessibilityValue(modelStateAccessibilityValue(hero.state))
    }

    private var emptyOnDeviceState: some View {
        VStack(spacing: PocketSpacing.s16) {
            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "arrow.down.circle")
                    .font(.title)
                    .foregroundStyle(PocketColor.accent)
            }
            Text("No models on this iPhone")
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
            Text("Download models from the Browse tab to run them offline.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
                .multilineTextAlignment(.center)

            Button("Browse catalog") {
                segment = .browse
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketColor.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PocketSpacing.s32)
    }

    // MARK: - Sections & Grouping

    private struct ModelSection: Identifiable {
        var id: String { title }
        let title: String
        let icon: String
        let entries: [CatalogEntry]
    }

    private func modelSectionView(_ section: ModelSection) -> some View {
        Section {
            ForEach(section.entries, id: \.manifest.id) { entry in
                ModelRow(
                    data: rowData(for: entry),
                    primaryActionLabel: primaryActionLabel(for: entry),
                    onPrimaryAction: { performPrimaryAction(for: entry) }
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("model_row_\(entry.manifest.id)")
                .accessibilityValue(modelStateAccessibilityValue(entry.state))
                .contentShape(Rectangle())
                .onTapGesture { detail = entry }
            }
        } header: {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: section.icon)
                    .font(.pocket(.footnote))
                Text(section.title)
                    .font(.pocket(.footnote))
            }
            .foregroundStyle(PocketColor.textSecondary)
        }
    }

    private var groupedSections: [ModelSection] {
        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if segment == .onDevice {
            entries = entries.filter { $0.state == .installed || $0.state == .downloading || $0.state == .paused }
            return entries.isEmpty ? [] : [ModelSection(title: "On this iPhone", icon: "iphone", entries: entries)]
        }
        if fitsOnly {
            entries = entries.filter { $0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow }
        }
        var sections: [ModelSection] = []

        let text = entries.filter {
            $0.manifest.modalities.contains(.text)
                && !$0.manifest.modalities.contains(.vision)
                && !$0.manifest.modalities.contains(.image)
        }
        if !text.isEmpty {
            sections.append(ModelSection(title: "Text", icon: "text.bubble", entries: text))
        }

        let vision = entries.filter { $0.manifest.modalities.contains(.vision) }
        if !vision.isEmpty {
            sections.append(ModelSection(title: "Vision", icon: "eye", entries: vision))
        }

        let image = entries.filter { $0.manifest.modalities.contains(.image) }
        if !image.isEmpty {
            sections.append(ModelSection(title: "Image generation", icon: "photo", entries: image))
        }

        let voice = entries.filter {
            $0.manifest.modalities.contains(.speechToText) || $0.manifest.modalities.contains(.textToSpeech)
        }
        if !voice.isEmpty {
            sections.append(ModelSection(title: "Voice", icon: "waveform", entries: voice))
        }

        return sections
    }

    private func reload() {
        catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        hubResults = []
        hubSearchError = nil
    }

    private func reloadRemote() async {
        guard let peer = peers.first else { return }
        guard let token = model.hooks.keychainGet(key: peer.tokenRef).flatMap({ String(data: $0, encoding: .utf8) }) else {
            remoteError = "No saved credential for \(peer.name) - try pairing again."
            return
        }
        let endpoint = PeerEndpoint(host: peer.addrs.first ?? "", port: peer.port, fingerprint: peer.certSha256)
        let client = RemoteCatalogClient(peerClient: PeerClient(endpoint: endpoint, token: token))
        do {
            remoteCatalog = try await client.catalog()
            remoteError = nil
        } catch {
            remoteError = "Couldn't reach \(peer.name): \(error.localizedDescription)"
        }
    }

    private func remoteRowData(for entry: RemoteCatalogEntry) -> ModelRowData {
        ModelRowData(
            name: entry.manifest.displayName,
            familyParamsQuant: "\(entry.manifest.family) · \(entry.manifest.quant)",
            fitKind: remoteFitKind(entry.fit.verdict),
            fitReason: "Fits on Mac: \(entry.fit.reason)",
            sizeOnDisk: formatBytes(entry.manifest.estRuntimeBytes),
            speedText: entry.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
            speedIsMeasured: false,
            licenseLabel: ""
        )
    }

    private func remotePrimaryActionLabel(for entry: RemoteCatalogEntry) -> String {
        switch entry.state {
        case .installed: return "Loaded on Mac"
        case .downloading: return "Downloading…"
        case .paused: return "Paused"
        case .verifying: return "Checking…"
        case .failed: return "Retry"
        case .available, .queued: return "Download on Mac"
        }
    }

    private func performRemotePrimaryAction(for entry: RemoteCatalogEntry) {
        guard let peer = peers.first,
              let token = model.hooks.keychainGet(key: peer.tokenRef).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }
        let endpoint = PeerEndpoint(host: peer.addrs.first ?? "", port: peer.port, fingerprint: peer.certSha256)
        let client = RemoteCatalogClient(peerClient: PeerClient(endpoint: endpoint, token: token))
        Task {
            try? await client.startDownload(modelId: entry.manifest.id)
            await reloadRemote()
        }
    }

    private func remoteFitKind(_ verdict: String) -> FitBadgeKind {
        switch verdict {
        case "RunsWell": return .runsWell
        case "RunsSlow": return .runsSlow
        case "WillNotFit": return .willNotFit
        default: return .notSupported
        }
    }

    private func searchHub() async {
        hubSearchError = nil
        do {
            hubResults = try model.core.searchHub(query: searchText, format: .mlxSafetensors)
        } catch {
            hubResults = []
            hubSearchError = "Search failed: \(error)"
        }
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
        case .available, .queued: return entry.fit.verdict == .willNotFit ? "Won't fit" : "Download"
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

    private func modelStateAccessibilityValue(_ state: ModelState) -> String {
        switch state {
        case .available: return "available"
        case .downloading: return "downloading"
        case .paused: return "paused"
        case .installed: return "installed"
        case .queued: return "queued"
        case .verifying: return "verifying"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

private struct ModelDetailSheet: View {
    let entry: CatalogEntry
    let primaryActionLabel: String
    let onPrimaryAction: () -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                        HStack(spacing: PocketSpacing.s12) {
                            PocketMarkView(state: .idle, size: 36)
                            VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                                Text(entry.manifest.displayName)
                                    .font(.pocket(.title))
                                    .foregroundStyle(PocketColor.textPrimary)
                                Text(entry.manifest.family)
                                    .font(.pocket(.callout))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }
                        }
                        FitBadge(kind: fitKind, reason: entry.fit.reason)
                    }
                    .padding(.vertical, PocketSpacing.s8)
                }

                Section("Specs") {
                    LabeledContent("Quantization", value: entry.manifest.quant)
                    LabeledContent("Context Length", value: "\(entry.manifest.contextLength) tokens")
                    LabeledContent("Download Size", value: formatBytes(entry.manifest.estRuntimeBytes))
                    LabeledContent("Format", value: "\(entry.manifest.format)")
                    if let speed = entry.fit.estTokensPerSec {
                        LabeledContent("Estimated Speed", value: "\(Int(speed)) tok/s")
                    }
                }

                Section("License & Source") {
                    LabeledContent("License", value: entry.manifest.license.spdx)
                    if let url = URL(string: entry.manifest.license.url) {
                        Link(destination: url) {
                            HStack {
                                Text("Hugging Face Model Page")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                        }
                    }
                }

                if entry.state == .downloading || entry.state == .paused {
                    Section("Download Status") {
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
                    Button {
                        onPrimaryAction()
                    } label: {
                        Text(primaryActionLabel)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fontWeight(.semibold)
                    }
                    .tint(PocketColor.accent)

                    if let onDelete {
                        Button(role: .destructive, action: onDelete) {
                            Text("Delete from Device")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Model Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
