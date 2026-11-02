import SwiftUI
import PocketKit
import PocketUI

/// UI-10 / T6: Models catalog & manager (S-MOD).
/// Segmented navigation (On this iPhone / Browse / On your Mac), a compact
/// horizontally-scrolling capability filter row + Fits chip, a lightweight
/// sort menu, compact rows with live download rings, and honest empty/error
/// states. Uses real safe areas (no fixed bottom padding — F01) and real
/// download/disk bytes (F20), not runtime-RAM estimates.
struct ModelsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppModel.self) private var model

    /// Opens directly on the "On your Mac" segment (Devices → Mac capabilities).
    var startOnMac = false
    /// True when pushed into a caller's NavigationStack, so this screen must
    /// not create one of its own.
    var embedded = false

    private enum Segment: String, CaseIterable {
        case onDevice = "On this iPhone"
        case browse = "Browse"
        case onMac = "On your Mac"
    }

    private enum CapabilityFilter: String, CaseIterable {
        case all = "All", text = "Text", vision = "Vision", voice = "Voice", images = "Images"
    }

    private enum SortOrder: String, CaseIterable {
        case recommended = "Recommended", smallest = "Smallest download", name = "Name"
    }

    @State private var segment = Segment.browse
    @State private var searchText = ""
    @State private var fitsOnly = true          // §6.1: default on in Browse
    @State private var capabilityFilter = CapabilityFilter.all
    @State private var sortOrder = SortOrder.recommended
    @State private var catalog: [CatalogEntry] = []          // curated browse source
    @State private var installedEntries: [CatalogEntry] = [] // merged installs (incl. noncurated — F25)
    /// Live detail is resolved from this id on every render, never a captured
    /// (stale) CatalogEntry (F09/§6.2).
    @State private var detailId: String?
    @State private var pendingDelete: CatalogEntry?
    @State private var hubResults: [CatalogEntry] = []
    @State private var hubSearchError: String?
    @State private var isSearchingHub = false
    @State private var peers: [Peer] = []
    /// Which paired Mac "On your Mac" is showing. nil = follow `macPeer`'s
    /// default (the Mac behind the selected model, else the only one).
    @State private var macPeerId: String?
    @State private var remoteCatalog: [RemoteCatalogEntry] = []
    @State private var remoteError: String?
    /// Surfaces a failed delete / remote download start — both used to fail
    /// silently and leave the row exactly as it was.
    @State private var actionError: String?
    /// Honest instruments: measured download throughput per model id, derived
    /// from real bytesDone deltas between polls — never a fabricated constant.
    @State private var downloadRates: [String: Int64] = [:]
    @State private var downloadSamples: [String: (bytes: UInt64, at: Date)] = [:]
    @State private var network = NetworkMonitor.shared

    /// Model ids the user explicitly paused, persisted so an interrupted (not
    /// user-paused) download can be told apart and auto-resumed on launch /
    /// reconnect — without ever resuming a download the user chose to stop.
    private static let userPausedKey = "models.userPausedIds"
    private func isUserPaused(_ id: String) -> Bool {
        (UserDefaults.standard.array(forKey: Self.userPausedKey) as? [String] ?? []).contains(id)
    }
    private func setUserPaused(_ id: String, _ paused: Bool) {
        var ids = Set(UserDefaults.standard.array(forKey: Self.userPausedKey) as? [String] ?? [])
        if paused { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: Self.userPausedKey)
    }

    private var hasInProgressDownloads: Bool {
        // Includes merged installs: a non-curated download isn't in `catalog`,
        // so the offline banner never appeared for one.
        (catalog + installedEntries).contains { $0.state == .downloading || $0.state == .paused }
    }

    /// Paused but not by the user == interrupted (app killed / network drop):
    /// safe to resume automatically once we're online again.
    private func autoResumeInterrupted() {
        guard network.isOnline else { return }
        var didResume = false
        for entry in catalog where entry.state == .paused && !isUserPaused(entry.manifest.id) {
            try? model.core.resumeDownload(modelId: entry.manifest.id)
            didResume = true
        }
        if didResume { reload() }
    }

    private var availableSegments: [Segment] {
        peers.isEmpty ? [.onDevice, .browse] : [.onDevice, .browse, .onMac]
    }

    private var heroEntry: CatalogEntry? {
        catalog.first { $0.manifest.tags.contains("recommended") && $0.fit.verdict == .runsWell }
            ?? catalog.first { $0.fit.verdict == .runsWell }
    }

    /// Hero shows at most once, only while browsing unfiltered (§6.1): removed
    /// during search or capability filtering. Fits-only is not a filter here.
    private var showsHero: Bool {
        segment == .browse && searchText.isEmpty && capabilityFilter == .all
    }

    private var hasActiveFilter: Bool {
        !searchText.isEmpty || capabilityFilter != .all || (segment == .browse && fitsOnly)
    }

    var body: some View {
        // Pushed into an existing stack (Mac ▸ Mac capabilities, picker ▸ Manage
        // models), a second NavigationStack stacks two navigation bars and
        // strands the title and search field under the back button.
        if embedded {
            catalogScreen
        } else {
            NavigationStack { catalogScreen }
        }
    }

    private var catalogScreen: some View {
        VStack(spacing: 0) {
                Picker("Catalog", selection: $segment) {
                    ForEach(availableSegments, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.top, PocketSpacing.s4)
                .padding(.bottom, PocketSpacing.s4)

                if segment != .onMac {
                    filterRow
                        .padding(.bottom, PocketSpacing.s4)
                }

                list
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .background(PocketColor.bgCanvas)
            .toolbar {
                if segment != .onMac {
                    ToolbarItem(placement: .topBarTrailing) { sortMenu }
                }
            }
            .task {
                network.start()
                reload()
                peers = model.core.peers()
                autoResumeInterrupted()
                if startOnMac, !peers.isEmpty, segment != .onMac {
                    segment = .onMac
                    await reloadRemote()
                }
            }
            .task { await pollDownloads() }
            .onChange(of: network.isOnline) { _, online in
                if online { autoResumeInterrupted() }
            }
            .onChange(of: searchText) {
                reload()
                hubResults = []
                hubSearchError = nil
            }
            .onChange(of: segment) { _, newValue in
                if newValue == .onMac { Task { await reloadRemote() } }
            }
            .onChange(of: macPeerId) {
                // Switching Mac has to re-fetch: the old Mac's catalog is not
                // the new one's.
                remoteCatalog = []
                remoteError = nil
                if segment == .onMac { Task { await reloadRemote() } }
            }
            .refreshable {
                reload()
                // A Mac paired after this tab first appeared never showed up:
                // peers were read once in .task and the pull did not re-read.
                peers = model.core.peers()
                if segment == .onMac { await reloadRemote() }
            }
            .sheet(isPresented: Binding(get: { detailId != nil }, set: { if !$0 { detailId = nil } })) {
                if let id = detailId, let entry = liveEntry(id: id) {
                    ModelDetailSheet(
                        entry: entry,
                        primaryActionLabel: primaryActionLabel(for: entry),
                        onPrimaryAction: { performPrimaryAction(for: entry) },
                        onCancel: {
                            try? model.core.cancelDownload(modelId: entry.manifest.id)
                            reload()
                            detailId = nil
                        },
                        onDelete: entry.state == .installed ? { pendingDelete = entry; detailId = nil } : nil,
                        downloadBytesPerSecond: downloadRates[entry.manifest.id] ?? 0,
                        isOffline: !network.isOnline || model.core.isOffline()
                    )
                }
            }
            .alert(
                "Delete \(pendingDelete?.manifest.displayName ?? "model")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button("Delete", role: .destructive) {
                    if let entry = pendingDelete {
                        do {
                            try model.core.deleteModel(modelId: entry.manifest.id)
                            if model.selectedModelId == entry.manifest.id { model.selectedModelId = nil }
                        } catch {
                            actionError = "Couldn't delete \(entry.manifest.displayName): \(error.localizedDescription)"
                        }
                        reload()
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let entry = pendingDelete {
                    Text("Frees \(formatBytes(diskBytes(entry))).")
                }
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

    // MARK: - Filter row & sort

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PocketSpacing.s8) {
                ForEach(CapabilityFilter.allCases, id: \.self) { cap in
                    filterChip(cap.rawValue, selected: capabilityFilter == cap) {
                        capabilityFilter = capabilityFilter == cap ? .all : cap
                    }
                }
                if segment == .browse {
                    Divider().frame(height: 20)
                    fitsChip
                }
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)
        }
    }

    private func filterChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.pocket(.footnote))
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? PocketColor.accentOnAccent : PocketColor.textSecondary)
                .padding(.horizontal, PocketSpacing.s12)
                .padding(.vertical, 6)
                .background(selected ? PocketColor.accent : PocketColor.bgSunken, in: Capsule())
                .frame(minHeight: 44) // 44pt hit target; visual capsule stays compact
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("models_filter_\(label)")
    }

    /// UI-26: the fits filter never cuts silently — while on, the chip itself
    /// says how many models it is hiding ("Fits this iPhone · 23 hidden").
    private var fitsChipLabel: String {
        let hidden = fitsHiddenCount
        return fitsOnly && hidden > 0 ? "Fits this iPhone · \(hidden) hidden" : "Fits this iPhone"
    }

    /// Browse entries (after search/capability filters) that the fits filter
    /// removes: everything not runsWell/runsSlow.
    private var fitsHiddenCount: Int {
        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if capabilityFilter != .all {
            entries = entries.filter { matchesCapability($0.manifest) }
        }
        return entries.filter { $0.fit.verdict != .runsWell && $0.fit.verdict != .runsSlow }.count
    }

    private var fitsChip: some View {
        Button {
            fitsOnly.toggle()
        } label: {
            HStack(spacing: PocketSpacing.s4) {
                if fitsOnly { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                Text(fitsChipLabel).font(.pocket(.footnote)).fontWeight(fitsOnly ? .semibold : .regular)
            }
            .foregroundStyle(fitsOnly ? PocketColor.accentOnAccent : PocketColor.textSecondary)
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, 6)
            .background(fitsOnly ? PocketColor.accent : PocketColor.bgSunken, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(fitsOnly ? .isSelected : [])
        .accessibilityIdentifier("models_filter_fits")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort models")
        .accessibilityIdentifier("models_sort_menu")
    }

    // MARK: - List

    private var list: some View {
        List {
            if (!network.isOnline || model.core.isOffline()), hasInProgressDownloads {
                Section {
                    offlineDownloadBanner
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if showsHero, let hero = heroEntry {
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
                if peers.count > 1 {
                    // With two paired Macs the screen used to show the first
                    // one's catalog with no way to tell, let alone switch.
                    Picker("Mac", selection: Binding(
                        get: { macPeer?.id ?? "" },
                        set: { macPeerId = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(peers, id: \.id) { peer in
                            Text(peer.name).tag(peer.id)
                        }
                    }
                    .font(.pocket(.footnote))
                }
                Section(macPeer.map { peers.count > 1 ? $0.name : "On your Mac" } ?? "On your Mac") {
                    ForEach(remoteCatalog) { entry in
                        ModelRow(
                            data: remoteRowData(for: entry),
                            primaryActionLabel: remotePrimaryActionLabel(for: entry),
                            onPrimaryAction: { performRemotePrimaryAction(for: entry) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if entry.state == .installed { performRemotePrimaryAction(for: entry) }
                        }
                    }
                }
            } else if groupedSections.isEmpty {
                Section {
                    emptyStateView
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
                    } else if isSearchingHub {
                        HStack(spacing: PocketSpacing.s8) {
                            ProgressView()
                            Text("Searching Hugging Face…")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
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
                        .onTapGesture { detailId = entry.manifest.id }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        // UI-26: Browse reaches the whole HF hub, and the placeholder says so.
        .searchable(text: $searchText, prompt: segment == .browse ? "Search all of Hugging Face" : "Search models")
    }

    // MARK: - Hero Card

    private func heroCard(_ hero: CatalogEntry) -> some View {
        Button {
            detailId = hero.manifest.id
        } label: {
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                // At accessibility sizes the eyebrow and the badge cannot
                // share a row: the label was squeezed into a column and
                // hyphenated mid-word. Stack them instead.
                heroHeaderLayout {
                    HStack(spacing: PocketSpacing.s4) {
                        PocketMarkView(state: .idle, size: 10)
                        Text("Recommended for this iPhone")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: PocketSpacing.s4) {
                        FitBadge(kind: fitKind(hero.fit.verdict), reason: hero.fit.reason)
                        if ReasoningSupport.supportsReasoning(modelID: hero.manifest.id) { ThinkingBadge() }
                    }
                }

                heroActionLayout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ModelNaming.short(hero.manifest.displayName))
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(heroMetaLine(hero))
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                            .background(
                                isPrimaryActionDisabled(hero) ? PocketColor.textTertiary : PocketColor.accent,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isPrimaryActionDisabled(hero))
                    .accessibilityIdentifier("model_action_button_\(hero.manifest.id)")
                }

                if isManaged(hero.state) {
                    managedStateView(hero)
                }
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("model_hero_\(hero.manifest.id)")
        .accessibilityValue(modelStateAccessibilityValue(hero.state))
    }

    /// One compact meta line: family · quant · size · honest tok/s (measured
    /// bare, estimate marked "~…est." — never a measured-looking number on a
    /// model that has not run).
    /// Row normally, column once the text is large enough that two items
    /// cannot share a line without one being crushed.
    private var heroHeaderLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PocketSpacing.s8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: PocketSpacing.s8))
    }

    private var heroActionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: PocketSpacing.s12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: PocketSpacing.s12))
    }

    private func heroMetaLine(_ entry: CatalogEntry) -> String {
        var parts = ["\(entry.manifest.family) · \(entry.manifest.quant) · \(formatBytes(diskBytes(entry)))"]
        if let tok = entry.fit.measuredTokensPerSec {
            parts.append("\(Int(tok)) tok/s")
        } else if let tok = entry.fit.estTokensPerSec {
            parts.append("~\(Int(tok)) tok/s est.")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyStateView: some View {
        if segment == .onDevice, installedEntries.isEmpty, !hasActiveFilter {
            emptyOnDeviceState
        } else {
            filteredEmptyState
        }
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

            Button("Browse catalog") { segment = .browse }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PocketSpacing.s32)
    }

    /// Honest filtered-empty copy: names the active query/filter and offers
    /// Clear filters — never "No models on this iPhone" for a filtered list.
    private var filteredEmptyState: some View {
        VStack(spacing: PocketSpacing.s12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title)
                .foregroundStyle(PocketColor.textTertiary)
            Text("No models match \(activeFilterDescription)")
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
                .multilineTextAlignment(.center)
            Button("Clear filters") {
                searchText = ""
                capabilityFilter = .all
                fitsOnly = false
            }
            .buttonStyle(.bordered)
            .tint(PocketColor.accent)
            .accessibilityIdentifier("models_clear_filters")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PocketSpacing.s32)
    }

    private var activeFilterDescription: String {
        var parts: [String] = []
        if capabilityFilter != .all { parts.append("“\(capabilityFilter.rawValue)”") }
        if segment == .browse, fitsOnly { parts.append("Fits this iPhone") }
        if !searchText.isEmpty { parts.append("“\(searchText)”") }
        return parts.isEmpty ? "these filters" : parts.joined(separator: " · ")
    }

    // MARK: - Offline download states

    private var offlineDownloadBanner: some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: model.core.isOffline() ? "airplane" : "wifi.slash")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PocketColor.statusWarn)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.core.isOffline() ? "Paused — Offline mode is on" : "Waiting for network…")
                    .font(.pocket(.footnote))
                    .fontWeight(.medium)
                    .foregroundStyle(PocketColor.textPrimary)
                Text(model.core.isOffline()
                     ? "Turn off Offline mode in Settings to resume downloads."
                     : "Download paused — no connection. It resumes automatically when you're back online.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            Spacer()
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
    }

    /// Replaces the progress ring while offline — no fabricated speed/ETA when
    /// nothing can actually transfer. Honest instruments.
    private func waitingForNetworkRow(_ entry: CatalogEntry) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PocketColor.statusWarn)
            Text("Waiting for network · \(formatBytes(entry.bytesDone)) of \(formatBytes(transferTotal(entry)))")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            Spacer()
        }
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
                rowView(for: entry)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("model_row_\(entry.manifest.id)")
                    .accessibilityValue(modelStateAccessibilityValue(entry.state))
            }
        } header: {
            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: section.icon).font(.pocket(.footnote))
                Text(section.title).font(.pocket(.footnote))
            }
            .foregroundStyle(PocketColor.textSecondary)
        }
    }

    /// A compact row. Installed/available use the shared `ModelRow`; any model
    /// mid-transfer (queued/downloading/paused/verifying/failed) uses a managed
    /// row whose Pause/Resume/Cancel controls have distinct hit targets and do
    /// NOT open details (§6.2) — only the name taps through.
    @ViewBuilder
    private func rowView(for entry: CatalogEntry) -> some View {
        if isManaged(entry.state) {
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                Button {
                    detailId = entry.manifest.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.manifest.displayName)
                            .font(.pocket(.callout))
                            .fontWeight(.semibold)
                            .foregroundStyle(PocketColor.textPrimary)
                            .lineLimit(1)
                        Text("\(entry.manifest.family) · \(entry.manifest.quant)")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                managedStateView(entry)
            }
            .padding(.vertical, PocketSpacing.s4)
        } else {
            ModelRow(
                data: rowData(for: entry),
                primaryActionLabel: primaryActionLabel(for: entry),
                onPrimaryAction: { performPrimaryAction(for: entry) }
            )
            .contentShape(Rectangle())
            .onTapGesture { detailId = entry.manifest.id }
        }
    }

    /// The transfer-state presentation shared by rows, hero, and detail — one
    /// honest view per state (§6.2 / §8).
    @ViewBuilder
    private func managedStateView(_ entry: CatalogEntry) -> some View {
        let id = entry.manifest.id
        switch entry.state {
        case .downloading:
            if !network.isOnline {
                waitingForNetworkRow(entry)
            } else {
                DownloadProgress(
                    state: .downloading(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(transferTotal(entry)), bytesPerSecond: downloadRates[id] ?? 0),
                    onPauseResume: {
                        try? model.core.pauseDownload(modelId: id)
                        setUserPaused(id, true)
                        reload()
                    },
                    onCancel: { try? model.core.cancelDownload(modelId: id); reload() }
                )
            }
        case .paused:
            if model.core.isOffline() {
                offlineModePausedRow(entry)
            } else if !network.isOnline {
                waitingForNetworkRow(entry)
            } else {
                DownloadProgress(
                    state: .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(transferTotal(entry))),
                    onPauseResume: {
                        try? model.core.resumeDownload(modelId: id)
                        setUserPaused(id, false)
                        reload()
                    },
                    onCancel: { try? model.core.cancelDownload(modelId: id); reload() }
                )
            }
        case .queued:
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: "clock").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                Text("Queued").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                Spacer()
                Button("Cancel") { try? model.core.cancelDownload(modelId: id); reload() }
                    .font(.pocket(.footnote))
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketColor.accent)
            }
        case .verifying:
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: "checkmark.shield").font(.pocket(.footnote)).foregroundStyle(PocketColor.statusInfo)
                Text("Checking files…").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                Spacer()
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                Text(failureText(reason))
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.statusBad)
                HStack(spacing: PocketSpacing.s16) {
                    Button("Retry") { try? model.core.startDownload(modelId: id); setUserPaused(id, false); reload() }
                        .buttonStyle(.plain).foregroundStyle(PocketColor.accent)
                    Button("Remove") { try? model.core.cancelDownload(modelId: id); reload() }
                        .buttonStyle(.plain).foregroundStyle(PocketColor.textSecondary)
                    Spacer()
                }
                .font(.pocket(.footnote))
            }
        default:
            EmptyView()
        }
    }

    private func offlineModePausedRow(_ entry: CatalogEntry) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "airplane").font(.system(size: 14, weight: .medium)).foregroundStyle(PocketColor.statusWarn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paused — Offline mode is on").font(.pocket(.footnote)).foregroundStyle(PocketColor.textPrimary)
                Text("Turn off Offline mode in Settings to resume.").font(.pocket(.caption)).foregroundStyle(PocketColor.textSecondary)
            }
            Spacer()
            Button("Cancel") { try? model.core.cancelDownload(modelId: entry.manifest.id); reload() }
                .font(.pocket(.footnote)).buttonStyle(.plain).foregroundStyle(PocketColor.accent)
        }
    }

    private func failureText(_ reason: String) -> String {
        switch reason {
        case "network": return "Download failed — check your connection, then retry."
        case "disk": return "Download failed — not enough storage."
        case "checksum": return "Download failed — files didn't verify. Retry to download again."
        default: return "Download failed."
        }
    }

    /// Entries shown in the On this iPhone segment: merged installs (incl.
    /// noncurated — F25) plus any curated model mid-transfer, so a browse
    /// capability filter can never hide transfer controls (queued/verifying
    /// included — F09/§6.1).
    private var onDeviceEntries: [CatalogEntry] {
        var byId: [String: CatalogEntry] = [:]
        for e in catalog where isManaged(e.state) || e.state == .installed { byId[e.manifest.id] = e }
        for e in installedEntries { byId[e.manifest.id] = e }
        return Array(byId.values)
    }

    private var groupedSections: [ModelSection] {
        if segment == .onDevice {
            var entries = onDeviceEntries
            if !searchText.isEmpty {
                entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
            }
            if capabilityFilter != .all {
                entries = entries.filter { matchesCapability($0.manifest) }
            }
            entries = sorted(entries)
            return entries.isEmpty ? [] : [ModelSection(title: "On this iPhone", icon: "iphone", entries: entries)]
        }

        var entries = catalog
        if !searchText.isEmpty {
            entries = entries.filter { $0.manifest.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        if fitsOnly {
            entries = entries.filter { $0.fit.verdict == .runsWell || $0.fit.verdict == .runsSlow }
        }

        // A specific capability filter → one flat, sorted "Results" section.
        if capabilityFilter != .all {
            entries = sorted(entries.filter { matchesCapability($0.manifest) })
            return entries.isEmpty ? [] : [ModelSection(title: capabilityFilter.rawValue, icon: capabilityIcon, entries: entries)]
        }

        // Unfiltered Browse → capability-grouped sections.
        var sections: [ModelSection] = []
        let text = entries.filter {
            $0.manifest.modalities.contains(.text)
                && !$0.manifest.modalities.contains(.vision)
                && !$0.manifest.modalities.contains(.image)
        }
        if !text.isEmpty { sections.append(ModelSection(title: "Text", icon: "text.bubble", entries: sorted(text))) }

        let vision = entries.filter { $0.manifest.modalities.contains(.vision) }
        if !vision.isEmpty { sections.append(ModelSection(title: "Vision", icon: "eye", entries: sorted(vision))) }

        let image = entries.filter { $0.manifest.modalities.contains(.image) }
        if !image.isEmpty { sections.append(ModelSection(title: "Image generation", icon: "photo", entries: sorted(image))) }

        let voice = entries.filter {
            $0.manifest.modalities.contains(.speechToText) || $0.manifest.modalities.contains(.textToSpeech)
        }
        if !voice.isEmpty { sections.append(ModelSection(title: "Voice", icon: "waveform", entries: sorted(voice))) }

        return sections
    }

    private var capabilityIcon: String {
        switch capabilityFilter {
        case .all: return "square.grid.2x2"
        case .text: return "text.bubble"
        case .vision: return "eye"
        case .voice: return "waveform"
        case .images: return "photo"
        }
    }

    private func matchesCapability(_ m: ModelManifest) -> Bool {
        switch capabilityFilter {
        case .all: return true
        case .text: return m.modalities.contains(.text)       // includes text-capable vision models
        case .vision: return m.modalities.contains(.vision)
        case .voice: return m.modalities.contains(.speechToText) || m.modalities.contains(.textToSpeech)
        case .images: return m.modalities.contains(.image)
        }
    }

    private func sorted(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        switch sortOrder {
        case .recommended: return entries
        case .smallest: return entries.sorted { transferTotal($0) < transferTotal($1) }
        case .name: return entries.sorted { $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending }
        }
    }

    private func isManaged(_ state: ModelState) -> Bool {
        switch state {
        case .queued, .downloading, .paused, .verifying, .failed: return true
        default: return false
        }
    }

    /// Resolve a live entry by id across every local source (catalog, merged
    /// installs, hub results), so detail/row/hero agree without reopening.
    private func liveEntry(id: String) -> CatalogEntry? {
        catalog.first { $0.manifest.id == id }
            ?? installedEntries.first { $0.manifest.id == id }
            ?? hubResults.first { $0.manifest.id == id }
    }

    /// Real download/disk size (summed manifest file sizes), never a runtime-RAM
    /// estimate (F20). 0 when unknown (e.g. unresolved hub results).
    private func diskBytes(_ entry: CatalogEntry) -> UInt64 {
        entry.fit.diskBytes != 0 ? entry.fit.diskBytes : entry.manifest.estRuntimeBytes
    }

    /// Transfer total for a progress ring = real download bytes, with a nonzero
    /// floor so the ring never divides by zero (§6.2 clamp/guard).
    private func transferTotal(_ entry: CatalogEntry) -> UInt64 {
        let b = diskBytes(entry)
        return b == 0 ? max(entry.bytesDone, 1) : b
    }

    private func reload() {
        catalog = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
        // Full merged catalog, locally narrowed to installed + mid-transfer, so
        // a non-curated (Hugging Face) download stays visible while in flight.
        installedEntries = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
            .filter { $0.state == .installed || isManaged($0.state) }
    }

    /// While any model is actively in-flight, re-read the catalog every ~0.7s so
    /// bytesDone/state refresh, and derive a real throughput from consecutive
    /// bytesDone samples. Idle ticks only do a cheap state scan + sleep and clear
    /// stale rate samples.
    private func pollDownloads() async {
        while !Task.isCancelled {
            let isActive = (catalog + installedEntries).contains {
                $0.state == .downloading || $0.state == .verifying || $0.state == .queued
            }
            if !isActive {
                if !downloadSamples.isEmpty { downloadSamples.removeAll() }
                if !downloadRates.isEmpty { downloadRates.removeAll() }
            } else {
                // Same read as reload(): the poller used to re-query with
                // installedOnly, which dropped a non-curated (Hugging Face)
                // download out of "On this iPhone" a tick after it started.
                reload()
                let now = Date()
                for entry in catalog where entry.state == .downloading {
                    let id = entry.manifest.id
                    if let prev = downloadSamples[id] {
                        let elapsed = now.timeIntervalSince(prev.at)
                        if elapsed >= 0.4, entry.bytesDone >= prev.bytes {
                            downloadRates[id] = Int64(Double(entry.bytesDone - prev.bytes) / elapsed)
                            downloadSamples[id] = (entry.bytesDone, now)
                        }
                    } else {
                        downloadSamples[id] = (entry.bytesDone, now)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// The Mac this screen acts on. An explicit pick wins; otherwise follow the
    /// peer named in the selected `mac:<peerId>/<modelId>`, the way the rest of
    /// the app resolves it. `peers.first` is only the single-Mac case, and was
    /// silently wrong with two paired Macs.
    private var macPeer: Peer? {
        if let macPeerId, let picked = peers.first(where: { $0.id == macPeerId }) { return picked }
        if let selected = model.selectedModelId,
           let pid = RemoteEngine.peerId(from: selected),
           let owner = peers.first(where: { $0.id == pid }) { return owner }
        return peers.first
    }

    /// Current best address for a stored peer: a Bonjour-rediscovered override
    /// (set after an IP change) wins over the stale stored address.
    private func peerEndpoint(for peer: Peer) -> PeerEndpoint {
        let override = PeerAddressBook.shared.override(forHostId: peer.name)
        return PeerEndpoint(
            host: override?.host ?? peer.addrs.first ?? "",
            port: override?.port ?? peer.port,
            fingerprint: peer.certSha256
        )
    }

    private func reloadRemote() async {
        guard let peer = macPeer else { return }
        guard let token = model.hooks.keychainGet(key: peer.tokenRef).flatMap({ String(data: $0, encoding: .utf8) }) else {
            remoteError = "No saved credential for \(peer.name) - try pairing again."
            return
        }
        let client = RemoteCatalogClient(peerClient: PeerClient(endpoint: peerEndpoint(for: peer), token: token))
        do {
            remoteCatalog = try await client.catalog()
            remoteError = nil
        } catch {
            if let resolved = await Browser.rediscover(hostId: peer.name) {
                PeerAddressBook.shared.setOverride(resolved, forHostId: peer.name)
                let endpoint = PeerEndpoint(host: resolved.host, port: resolved.port, fingerprint: peer.certSha256)
                let retryClient = RemoteCatalogClient(peerClient: PeerClient(endpoint: endpoint, token: token))
                do {
                    remoteCatalog = try await retryClient.catalog()
                    remoteError = nil
                    return
                } catch {
                    remoteError = "Couldn't reach \(peer.name): \(error.localizedDescription)"
                    return
                }
            }
            remoteError = "Couldn't reach \(peer.name): \(error.localizedDescription)"
        }
    }

    private func remoteRowData(for entry: RemoteCatalogEntry) -> ModelRowData {
        ModelRowData(
            name: entry.manifest.displayName,
            familyParamsQuant: "\(entry.manifest.family) · \(entry.manifest.quant)",
            fitKind: remoteFitKind(entry.fit.verdict),
            fitReason: "Fits on Mac: \(entry.fit.reason)",
            sizeOnDisk: entry.manifest.estRuntimeBytes != 0 ? formatBytes(entry.manifest.estRuntimeBytes) : nil,
            speedText: entry.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
            speedIsMeasured: false,
            licenseLabel: "",
            supportsReasoning: ReasoningSupport.supportsReasoning(modelID: entry.manifest.id)
        )
    }

    private func isRemoteModelSelected(_ entry: RemoteCatalogEntry) -> Bool {
        guard let peer = macPeer else { return false }
        return model.selectedModelId == "mac:\(peer.id)/\(entry.manifest.id)"
    }

    private func remotePrimaryActionLabel(for entry: RemoteCatalogEntry) -> String {
        switch entry.state {
        case .installed: return isRemoteModelSelected(entry) ? "Default" : "Use on phone"
        case .downloading: return "Downloading…"
        case .paused: return "Paused"
        case .verifying: return "Checking files…"
        case .failed: return "Retry"
        case .available, .queued: return "Download on Mac"
        }
    }

    private func performRemotePrimaryAction(for entry: RemoteCatalogEntry) {
        guard let peer = macPeer else { return }
        switch entry.state {
        case .installed:
            let remoteId = "mac:\(peer.id)/\(entry.manifest.id)"
            model.selectedModelId = remoteId
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .available, .queued, .failed:
            guard let token = model.hooks.keychainGet(key: peer.tokenRef).flatMap({ String(data: $0, encoding: .utf8) })
            else {
                actionError = "No saved credential for \(peer.name) — try pairing again."
                return
            }
            let client = RemoteCatalogClient(peerClient: PeerClient(endpoint: peerEndpoint(for: peer), token: token))
            Task {
                do {
                    try await client.startDownload(modelId: entry.manifest.id)
                } catch {
                    // Without this the row came back unchanged and the tap on
                    // "Download on Mac" looked like nothing happened.
                    actionError = "Couldn't start that download on \(peer.name): \(error.localizedDescription)"
                }
                await reloadRemote()
            }
        case .downloading, .paused, .verifying:
            break
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
        isSearchingHub = true
        defer { isSearchingHub = false }
        // searchHub is a blocking network call — keep it off the main actor.
        let core = model.core
        let query = searchText
        do {
            let results = try await Task.detached(priority: .userInitiated) {
                try core.searchHub(query: query, format: .mlxSafetensors)
            }.value
            hubResults = results
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
            sizeOnDisk: diskBytes(entry) != 0 ? formatBytes(diskBytes(entry)) : nil,
            speedText: (entry.fit.measuredTokensPerSec ?? entry.fit.estTokensPerSec).map { "\(Int($0)) tok/s" },
            speedIsMeasured: entry.fit.measuredTokensPerSec != nil,
            licenseLabel: entry.manifest.license.spdx,
            supportsReasoning: ReasoningSupport.supportsReasoning(modelID: entry.manifest.id)
        )
    }

    /// Installed chat models get Default/Set as default (selection is "Default",
    /// never "In use" — "In use" is reserved for a genuinely loaded model, which
    /// Core does not currently expose, §6.2).
    private func primaryActionLabel(for entry: CatalogEntry) -> String {
        switch entry.state {
        case .installed: return model.selectedModelId == entry.manifest.id ? "Default" : "Set as default"
        case .downloading: return "Pause"
        case .paused: return "Resume"
        case .verifying: return "Checking files…"
        case .queued: return "Queued"
        case .failed: return "Retry"
        case .available: return entry.fit.verdict == .willNotFit ? "Won't fit" : "Download"
        }
    }

    private func performPrimaryAction(for entry: CatalogEntry) {
        let id = entry.manifest.id
        switch entry.state {
        case .downloading:
            try? model.core.pauseDownload(modelId: id)
            setUserPaused(id, true)
        case .paused:
            try? model.core.resumeDownload(modelId: id)
            setUserPaused(id, false)
        case .available, .failed:
            // "Won't fit" is honest — don't start a download that can't run.
            guard entry.fit.verdict != .willNotFit else { break }
            try? model.core.startDownload(modelId: id)
            setUserPaused(id, false)
        case .installed:
            model.selectedModelId = id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .queued, .verifying:
            // Both labels are status, not actions ("Queued", "Checking files…").
            // Queued used to cancel the download from a button that only said
            // "Queued"; the row's own Cancel is the way to stop it.
            break
        }
        reload()
    }

    /// A primary button whose label is a status rather than an action can't be
    /// tapped — it reads as disabled because it is (§6.2).
    private func isPrimaryActionDisabled(_ entry: CatalogEntry) -> Bool {
        switch entry.state {
        case .queued, .verifying: return true
        case .available: return entry.fit.verdict == .willNotFit
        default: return false
        }
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
        case .paused: return model.core.isOffline() ? "paused, offline mode on" : "paused"
        case .installed: return "installed"
        case .queued: return "queued"
        case .verifying: return "checking files"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

private struct ModelDetailSheet: View {
    let entry: CatalogEntry
    let primaryActionLabel: String
    let onPrimaryAction: () -> Void
    var onCancel: () -> Void = {}
    let onDelete: (() -> Void)?
    /// Last measured throughput from the catalog screen's poller (0 = not yet measured).
    var downloadBytesPerSecond: Int64 = 0
    var isOffline = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    /// The model's last benchmark (read from the store when the sheet opens,
    /// replaced by a fresh run), whether one is running, and why one failed.
    @State private var benchmark: Benchmark?
    @State private var benchmarking = false
    @State private var benchmarkError: String?

    private var realDiskBytes: UInt64 {
        entry.fit.diskBytes != 0 ? entry.fit.diskBytes : entry.manifest.estRuntimeBytes
    }

    private var isManaged: Bool {
        switch entry.state {
        case .queued, .downloading, .paused, .verifying, .failed: return true
        default: return false
        }
    }

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
                    if realDiskBytes != 0 {
                        LabeledContent("Download Size", value: formatBytes(realDiskBytes))
                    }
                    LabeledContent("Format", value: "\(entry.manifest.format)")
                    if let speed = entry.fit.measuredTokensPerSec {
                        LabeledContent("Speed", value: "\(Int(speed)) tok/s (measured)")
                    } else if let speed = entry.fit.estTokensPerSec {
                        LabeledContent("Speed", value: "~\(Int(speed)) tok/s (est.)")
                    }
                }

                if entry.state == .installed {
                    Section("Performance") {
                        benchmarkRows
                    }
                }

                Section("License & Source") {
                    LabeledContent("License", value: entry.manifest.license.spdx)
                    if let url = URL(string: "https://huggingface.co/\(entry.manifest.hfRepo)") {
                        Link(destination: url) {
                            HStack {
                                Text("Hugging Face Model Page")
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption)
                            }
                        }
                    }
                    if let licenseURL = URL(string: entry.manifest.license.url), !entry.manifest.license.url.isEmpty {
                        Link(destination: licenseURL) {
                            HStack {
                                Text("License Terms")
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption)
                            }
                        }
                    }
                }

                if isManaged {
                    Section("Status") {
                        detailStatus
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
                    .disabled(disablePrimary)

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
            .task(id: entry.manifest.id) {
                // A local read, not a run: shows a previous result rather than
                // making the user re-measure to see a number they already have.
                if entry.state == .installed, benchmark == nil {
                    benchmark = model.core.storedBenchmark(id: entry.manifest.id)
                }
            }
            .alert(
                "Benchmark failed",
                isPresented: Binding(get: { benchmarkError != nil }, set: { if !$0 { benchmarkError = nil } })
            ) {
                Button("OK", role: .cancel) { benchmarkError = nil }
            } message: {
                Text(benchmarkError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// What this model actually did on this iPhone, plus the control to measure
    /// it. A run generates real tokens for a few seconds, so the row says so
    /// while it happens instead of sitting there looking tappable.
    @ViewBuilder
    private var benchmarkRows: some View {
        if let benchmark {
            LabeledContent("Throughput", value: String(format: "%.1f tok/s", benchmark.tps))
            LabeledContent("Time to First Token", value: "\(benchmark.ttftMs) ms")
            if benchmark.peakBytes > 0 {
                LabeledContent("Peak Memory", value: formatBytes(benchmark.peakBytes))
            }
        }
        if benchmarking {
            HStack(spacing: PocketSpacing.s8) {
                ProgressView()
                Text("Benchmarking… generating tokens on this iPhone")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
        } else {
            Button(benchmark == nil ? "Benchmark This Model" : "Run Again") { runBenchmark() }
                .tint(PocketColor.accent)
        }
    }

    /// Measures the model for real: seconds of inference behind a blocking FFI
    /// call (D21), so it runs off the main actor rather than freezing the sheet.
    private func runBenchmark() {
        guard !benchmarking else { return }
        benchmarking = true
        benchmarkError = nil
        let core = model.core
        let id = entry.manifest.id
        Task {
            let outcome = await Task.detached { () -> Result<Benchmark, Error> in
                do { return .success(try core.benchmarkModel(id: id)) } catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let measured): benchmark = measured
            case .failure(let error): benchmarkError = error.localizedDescription
            }
            benchmarking = false
        }
    }

    @ViewBuilder
    private var detailStatus: some View {
        switch entry.state {
        case .verifying:
            Label("Checking files…", systemImage: "checkmark.shield").font(.pocket(.footnote))
        case .queued:
            HStack {
                Label("Queued", systemImage: "clock").font(.pocket(.footnote))
                Spacer()
                // The only way to stop a queued transfer from here; the primary
                // button below says "Queued", which is a status, not an action.
                Button("Cancel", action: onCancel)
                    .font(.pocket(.footnote))
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketColor.accent)
            }
        case .failed(let reason):
            Text(reason == "network" ? "Download failed — check your connection." : "Download failed (\(reason)).")
                .font(.pocket(.footnote)).foregroundStyle(PocketColor.statusBad)
        case .downloading, .paused:
            if isOffline {
                HStack(spacing: PocketSpacing.s12) {
                    Image(systemName: "wifi.slash").font(.system(size: 14, weight: .medium)).foregroundStyle(PocketColor.statusWarn)
                    Text("Waiting · \(formatBytes(entry.bytesDone)) of \(formatBytes(realDiskBytes == 0 ? entry.bytesDone : realDiskBytes))")
                        .font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                    Spacer()
                }
            } else {
                DownloadProgress(
                    state: entry.state == .paused
                        ? .paused(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(realDiskBytes == 0 ? max(entry.bytesDone, 1) : realDiskBytes))
                        : .downloading(bytesDone: Int64(entry.bytesDone), bytesTotal: Int64(realDiskBytes == 0 ? max(entry.bytesDone, 1) : realDiskBytes), bytesPerSecond: downloadBytesPerSecond),
                    onPauseResume: onPrimaryAction,
                    onCancel: onCancel
                )
            }
        default:
            EmptyView()
        }
    }

    /// A status label is not an action (§6.2): "Checking files…" and "Queued"
    /// can't be tapped. Cancelling a queued transfer is the Status row's job.
    private var disablePrimary: Bool {
        switch entry.state {
        case .verifying, .queued: return true
        case .available: return entry.fit.verdict == .willNotFit
        default: return false
        }
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
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

#Preview("Light") {
    ModelsView()
        .environment(AppModel())
}

#Preview("Dark") {
    ModelsView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}

#Preview("AX3") {
    ModelsView()
        .environment(AppModel())
        .environment(\.dynamicTypeSize, .accessibility3)
}
