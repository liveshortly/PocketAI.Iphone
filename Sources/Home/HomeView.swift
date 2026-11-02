import SwiftUI
import PocketKit
import PocketLiveShortly
import PocketUI

/// Home dashboard (handoff §4): Ready-to-chat, two activity tiles, downloaded
/// models, active downloads, recent chats, and a Mac status row when paired.
/// Honest instruments only — counts and "most used model" are computed from
/// saved records (no fabricated activity), and a failed store (`coreOpenError`)
/// shows a recovery state rather than PreviewCore sample data (F22).
///
/// All aggregate work runs off the main actor in `HomeData.compute`; the main
/// thread only renders the resulting snapshot. The metric scan reads one
/// transcript per conversation because the Core read API exposes no reply/count
/// aggregate yet.
// ponytail: O(n) transcript scan for counts/most-used, off-main and cached per
// refresh. Upgrade path: a Core summary/aggregate query (§9.4) when it exists.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var data = HomeData()
    @State private var showingPicker = false
    @State private var lsNewSession = false
    @State private var showAllInstalled = false
    /// Surfaces a failed create/pause/cancel — these used to leave the tap
    /// looking ignored.
    @State private var actionError: String?

    private var refreshKey: String {
        "\(model.nav.selectedTab)|\(model.selectedModelId ?? "none")"
    }

    /// Creates a conversation bound to `modelId` (default: the global default)
    /// and routes the Chats tab to open the exact new conversation (F26).
    private func startChat(modelId: String?) {
        do {
            let convo = try model.core.createConversation(
                NewConversation(title: nil, projectId: nil, modelId: modelId ?? model.selectedModelId)
            )
            model.nav.openConversation(id: convo.id)
        } catch {
            actionError = "Couldn't start a new chat: \(error.localizedDescription)"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.coreOpenError != nil {
                    unavailableState
                } else {
                    content
                }
            }
            .background(PocketColor.bgCanvas)
            .navigationTitle("PocketAI")
            // Refresh on first appearance, when returning to Home, and when the
            // default model changes (§4: refresh after model changes / foreground).
            .task(id: refreshKey) { await reload() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
            .sheet(isPresented: $lsNewSession) {
                LSNewSessionSheet(account: model.liveShortly)
            }
            .sheet(isPresented: $showingPicker) {
                NavigationStack {
                    ModelPickerView(scope: .defaultModel, selectedId: model.selectedModelId) { id in
                        model.selectedModelId = id
                    }
                    .environment(model)
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
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s24) {
                readyCard
                activityTiles
                if !data.installed.isEmpty { installedSection }
                if !data.activeDownloads.isEmpty { downloadsSection }
                if !data.recent.isEmpty { recentSection }
                if let mac = data.macName { macRow(mac) }
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.vertical, PocketSpacing.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No fixed bottom padding (F01): the scroll view uses real safe-area insets.
    }

    // MARK: - Ready to chat (§4.1)

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s16) {
            HStack(spacing: PocketSpacing.s12) {
                PocketMarkView(state: data.ready.markState, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.ready.title)
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text(data.ready.subtitle)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Group {
                if case .ready = data.ready {
                    // Every way to start a chat, LiveShortly included.
                    Menu {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            startChat(modelId: nil)
                        } label: {
                            Label("New chat", systemImage: "square.and.pencil")
                        }
                        if AppleFoundationModelsEngine.isAvailable {
                            Button {
                                startChat(modelId: AppleFoundationModelsEngine.modelId)
                            } label: {
                                Label("Apple Intelligence", systemImage: "apple.logo")
                            }
                        }
                        if model.liveShortly.isConnected {
                            Button {
                                lsNewSession = true
                            } label: {
                                Label { Text("LiveShortly session…") } icon: { Image.lsLogo }
                            }
                        }
                    } label: {
                        readyActionLabel
                    }
                } else {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showingPicker = true
                    } label: {
                        readyActionLabel
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityIdentifier("home_ready_action")
        }
        .padding(PocketSpacing.s16)
        .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketRadius.card))
    }

    private var readyActionLabel: some View {
        Text(data.ready.actionLabel)
            .font(.pocket(.headline))
            .foregroundStyle(PocketColor.accentOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, PocketSpacing.s12)
            .background(PocketColor.accent, in: RoundedRectangle(cornerRadius: PocketRadius.field))
    }

    // MARK: - Activity tiles (§4.2)

    private var activityTiles: some View {
        // Side by side when both tiles fit; stacked once Dynamic Type makes
        // them too wide, instead of squeezing the labels.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PocketSpacing.s12) { tiles }
            VStack(spacing: PocketSpacing.s12) { tiles }
        }
    }

    @ViewBuilder private var tiles: some View {
        StatTile(label: "Chats on this iPhone", value: "\(data.chatCount)")
        StatTile(
            label: "Most used model",
            value: data.mostUsed ?? "No replies yet",
            hint: data.mostUsed == nil ? nil : data.mostUsedLocation
        )
    }

    // MARK: - Downloaded models (§4.3)

    private var installedSection: some View {
        let visible = showAllInstalled ? data.installed : Array(data.installed.prefix(3))
        return VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            sectionHeader("Downloaded models", actionTitle: "Manage") {
                model.nav.select(tab: .models)
            }
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(PocketColor.lineHairline) }
                    ModelRow(
                        data: item.row,
                        primaryActionLabel: item.isChatCapable ? "Chat" : "Manage"
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if item.isChatCapable {
                            startChat(modelId: item.id)
                        } else {
                            // Speech/image models aren't chat targets: route to
                            // Models rather than claim a chat it can't do (§4.3).
                            model.nav.select(tab: .models)
                        }
                    }
                    .padding(.horizontal, PocketSpacing.s12)
                }
            }
            .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketRadius.card))

            if data.installed.count > 3 {
                Button(showAllInstalled ? "Show less" : "Show all (\(data.installed.count))") {
                    withAnimation { showAllInstalled.toggle() }
                }
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.accent)
            }
        }
    }

    // MARK: - Active downloads (§4.4 — omitted when empty)

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            sectionHeader("Active downloads", actionTitle: nil, action: nil)
            VStack(spacing: PocketSpacing.s12) {
                ForEach(data.activeDownloads) { d in
                    HomeDownloadRow(
                        download: d,
                        onPauseResume: {
                            do {
                                switch d.phase {
                                case .downloading: try model.core.pauseDownload(modelId: d.id)
                                case .paused: try model.core.resumeDownload(modelId: d.id)
                                case .queued, .verifying: break
                                }
                            } catch {
                                actionError = "Couldn't change that download: \(error.localizedDescription)"
                            }
                            Task { await reload() }
                        },
                        onCancel: {
                            do {
                                try model.core.cancelDownload(modelId: d.id)
                            } catch {
                                actionError = "Couldn't cancel that download: \(error.localizedDescription)"
                            }
                            Task { await reload() }
                        }
                    )
                }
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketRadius.card))
        }
    }

    // MARK: - Recent chats (§4.5)

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            sectionHeader("Recent chats", actionTitle: "See all") {
                model.nav.select(tab: .chats)
            }
            VStack(spacing: 0) {
                ForEach(Array(data.recent.enumerated()), id: \.element.id) { index, chat in
                    if index > 0 { Divider().overlay(PocketColor.lineHairline) }
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        model.nav.openConversation(id: chat.id)
                    } label: {
                        recentRow(chat)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home_recent_\(chat.id)")
                }
            }
            .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketRadius.card))
        }
    }

    private func recentRow(_ chat: HomeData.RecentChat) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            Text(chat.title)
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
                .lineLimit(1)
            if !chat.preview.isEmpty {
                Text(chat.preview)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: PocketSpacing.s8) {
                Text(chat.subtitle)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: PocketSpacing.s8)
                Text(Self.relative.localizedString(
                    for: Date(timeIntervalSince1970: Double(chat.timestamp) / 1000),
                    relativeTo: Date()
                ))
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PocketSpacing.s12)
        .contentShape(Rectangle())
    }

    // MARK: - Mac status (§4.6)

    private func macRow(_ name: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.nav.select(tab: .devices)
        } label: {
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 18))
                    .foregroundStyle(PocketColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("Paired · Tap to manage")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Unavailable / recovery (F22, §9.4)

    private var unavailableState: some View {
        // Centred when it fits, scrollable when Dynamic Type overflows it.
        ViewThatFits(in: .vertical) {
            unavailableBody
            ScrollView { unavailableBody }
        }
        .accessibilityIdentifier("home_unavailable")
    }

    private var unavailableBody: some View {
        VStack(spacing: PocketSpacing.s16) {
            Spacer(minLength: PocketSpacing.s24)
            PocketMarkView(state: .offline, size: 72)
            Text("PocketAI is unavailable")
                .font(.pocket(.title))
                .foregroundStyle(PocketColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("The on-device engine couldn't start. Your chats and models are safe on this iPhone. Please restart the app to try again.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PocketSpacing.s24)
            if let err = model.coreOpenError {
                Text(err)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PocketSpacing.s24)
            }
            Spacer(minLength: PocketSpacing.s24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.accent)
            }
        }
    }

    private func reload() async {
        // Only recompute when Home is the visible tab; the shared `.task(id:)`
        // also fires on tab switches that leave Home.
        guard model.nav.selectedTab == .home, model.coreOpenError == nil else { return }
        let core = model.core
        let selected = model.selectedModelId
        let appleAvailable = AppleFoundationModelsEngine.isAvailable
        let snapshot = await Task.detached(priority: .userInitiated) {
            HomeData.compute(core: core, selectedModelId: selected, appleAvailable: appleAvailable)
        }.value
        data = snapshot
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// Honest compact transfer row for Home: ring + "X of Y" + state label and
/// Pause/Resume/Cancel. No speed or ETA — Home has no live rate poller, so it
/// never fabricates one (that lives in Models, §6.2).
private struct HomeDownloadRow: View {
    let download: HomeData.ActiveDownload
    let onPauseResume: () -> Void
    let onCancel: () -> Void

    private var fraction: Double {
        download.bytesTotal > 0 ? min(1, Double(download.bytesDone) / Double(download.bytesTotal)) : 0
    }

    private var caption: String {
        switch download.phase {
        case .queued: return "Queued"
        case .verifying: return "Checking files…"
        case .paused: return "Paused · \(HomeData.byteString(download.bytesDone)) of \(HomeData.byteString(download.bytesTotal))"
        case .downloading: return "\(HomeData.byteString(download.bytesDone)) of \(HomeData.byteString(download.bytesTotal))"
        }
    }

    var body: some View {
        HStack(spacing: PocketSpacing.s12) {
            ZStack {
                Circle().stroke(PocketColor.lineHairline, lineWidth: 3)
                if download.phase == .verifying || download.phase == .queued {
                    Circle().stroke(PocketColor.accent.opacity(0.4), lineWidth: 3)
                } else {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(PocketColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(download.name)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textPrimary)
                    .lineLimit(1)
                Text(caption)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            Spacer(minLength: PocketSpacing.s8)

            if download.phase == .downloading || download.phase == .paused {
                Button(action: onPauseResume) {
                    Image(systemName: download.phase == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(download.phase == .paused ? "Resume download" : "Pause download")
            }
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(PocketColor.textTertiary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Cancel download")
        }
    }
}

// MARK: - Snapshot + off-main computation

struct HomeData: Sendable {
    enum Ready: Sendable {
        case ready(name: String, location: String)
        case noModel(reason: String)

        var markState: PocketMarkState {
            switch self {
            case .ready: return .idle
            case .noModel: return .offline
            }
        }
        var title: String {
            switch self {
            case .ready: return "Ready to chat"
            case .noModel: return "No model selected"
            }
        }
        var subtitle: String {
            switch self {
            case let .ready(name, location): return location.isEmpty ? name : "\(name) · \(location)"
            case let .noModel(reason): return reason
            }
        }
        var actionLabel: String {
            switch self {
            case .ready: return "New chat"
            case .noModel: return "Choose model"
            }
        }
    }

    struct InstalledModel: Sendable, Identifiable {
        let id: String
        let row: ModelRowData
        let isChatCapable: Bool
    }

    struct ActiveDownload: Sendable, Identifiable {
        enum Phase: Sendable, Equatable { case queued, downloading, paused, verifying }
        let id: String
        let name: String
        let phase: Phase
        let bytesDone: Int64
        let bytesTotal: Int64
    }

    struct RecentChat: Sendable, Identifiable {
        let id: String
        let title: String
        let preview: String
        let subtitle: String
        let timestamp: Int64
    }

    var ready: Ready = .noModel(reason: "Choose a model to start chatting.")
    var chatCount: Int = 0
    var mostUsed: String?
    var mostUsedLocation: String?
    var installed: [InstalledModel] = []
    var activeDownloads: [ActiveDownload] = []
    var recent: [RecentChat] = []
    var macName: String?

    // MARK: Compute (nonisolated — runs off the main actor)

    static func compute(core: CoreClient, selectedModelId: String?, appleAvailable: Bool) -> HomeData {
        var data = HomeData()

        // Name index across the merged catalog (installed + curated) for display.
        let fullCatalog = core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
        var nameIndex: [String: String] = [:]
        for e in fullCatalog { nameIndex[e.manifest.id] = ModelNaming.short(e.manifest.displayName) }

        let peers = core.peers()
        // Name the Mac the selected model actually runs on; peers.first named
        // the wrong one as soon as a second Mac was paired.
        if let selectedModelId, let pid = RemoteEngine.peerId(from: selectedModelId),
           let owner = peers.first(where: { $0.id == pid }) {
            data.macName = owner.name
        } else {
            data.macName = peers.first?.name
        }

        // Downloaded models: verified local installs only (§4.3 metric).
        let installedEntries = fullCatalog.filter { $0.state == .installed }
        data.installed = installedEntries.map { entry in
            InstalledModel(
                id: entry.manifest.id,
                row: rowData(entry),
                isChatCapable: isChatCapable(entry.manifest)
            )
        }

        // Active downloads: same catalog source as Models.
        data.activeDownloads = fullCatalog.compactMap { entry -> ActiveDownload? in
            let phase: ActiveDownload.Phase
            switch entry.state {
            case .queued: phase = .queued
            case .downloading: phase = .downloading
            case .paused: phase = .paused
            case .verifying: phase = .verifying
            default: return nil
            }
            // Honest total: summed manifest file sizes (not runtime RAM; §6.2).
            let total = entry.manifest.files.reduce(UInt64(0)) { $0 + $1.size }
            return ActiveDownload(
                id: entry.manifest.id,
                name: ModelNaming.short(entry.manifest.displayName),
                phase: phase,
                bytesDone: Int64(entry.bytesDone),
                bytesTotal: Int64(total)
            )
        }

        data.ready = resolveReady(
            selectedModelId: selectedModelId,
            appleAvailable: appleAvailable,
            installedEntries: installedEntries,
            peers: peers,
            nameIndex: nameIndex
        )

        // Metrics across ALL conversations (incl. archived); paginate past the
        // 50-row default (F18) with an explicit page size.
        var all: [ConversationSummary] = []
        var offset: UInt32 = 0
        let page: UInt32 = 200
        while true {
            let batch = core.conversations(query: ConversationQuery(search: nil, archived: nil, limit: page, offset: offset))
            all.append(contentsOf: batch)
            if batch.count < Int(page) { break }
            offset += page
            if offset > 100_000 { break }
        }

        var chatCount = 0
        var replyCounts: [String: Int] = [:]
        var lastReply: [String: Int64] = [:]
        for c in all {
            let msgs = core.messages(conversationId: c.id)
            if msgs.contains(where: { $0.role == "user" }) { chatCount += 1 }
            for m in msgs where m.role == "assistant" && m.status == .done {
                // Title-generation requests are kept out of the transcript
                // (§5.2), so they don't reach this scan.
                guard let mid = m.modelId else { continue }
                replyCounts[mid, default: 0] += 1
                lastReply[mid] = max(lastReply[mid] ?? 0, m.createdAt)
            }
        }
        data.chatCount = chatCount

        if let best = replyCounts.max(by: { a, b in
            a.value != b.value ? a.value < b.value : (lastReply[a.key] ?? 0) < (lastReply[b.key] ?? 0)
        }) {
            let (name, location) = displayName(for: best.key, peers: peers, appleAvailable: appleAvailable, nameIndex: nameIndex)
            data.mostUsed = name
            data.mostUsedLocation = location.isEmpty ? nil : location
        }

        // Recent chats: five most recent nonarchived conversations.
        let recentSummaries = core.conversations(query: ConversationQuery(search: nil, archived: false, limit: 5, offset: 0))
        data.recent = recentSummaries.map { s in
            let convo = core.conversation(id: s.id)
            let preview = latestText(core.messages(conversationId: s.id))
            let subtitle: String
            if let mid = convo?.modelId {
                let (name, location) = displayName(for: mid, peers: peers, appleAvailable: appleAvailable, nameIndex: nameIndex)
                subtitle = location.isEmpty ? name : "\(name) · \(location)"
            } else {
                subtitle = "Choose a model"
            }
            return RecentChat(
                id: s.id,
                title: s.title ?? "New chat",
                preview: preview,
                subtitle: subtitle,
                timestamp: s.updatedAt
            )
        }

        return data
    }

    // MARK: Resolution helpers (nonisolated, pure)

    private static func resolveReady(
        selectedModelId: String?,
        appleAvailable: Bool,
        installedEntries: [CatalogEntry],
        peers: [Peer],
        nameIndex: [String: String]
    ) -> Ready {
        guard let id = selectedModelId else {
            return .noModel(reason: "Choose a model to start chatting.")
        }
        if id == AppleFoundationModelsEngine.modelId {
            return appleAvailable
                ? .ready(name: "Apple Intelligence", location: "On this iPhone")
                : .noModel(reason: "Apple Intelligence isn't ready on this device.")
        }
        if id.hasPrefix("mac:") {
            let (name, location) = displayName(for: id, peers: peers, appleAvailable: appleAvailable, nameIndex: nameIndex)
            let peerId = peerId(from: id)
            return peers.contains(where: { $0.id == peerId })
                ? .ready(name: name, location: location)
                : .noModel(reason: "That Mac isn't available right now.")
        }
        if installedEntries.contains(where: { $0.manifest.id == id }) {
            let name = nameIndex[id] ?? ModelNaming.short(id)
            return .ready(name: name, location: "On this iPhone")
        }
        return .noModel(reason: "The selected model isn't installed. Choose another.")
    }

    /// Resolves a model id to a readable name + execution location.
    static func displayName(for id: String, peers: [Peer], appleAvailable: Bool, nameIndex: [String: String]) -> (name: String, location: String) {
        if id == AppleFoundationModelsEngine.modelId {
            return ("Apple Intelligence", "On this iPhone")
        }
        if id.hasPrefix("mac:") {
            let pid = peerId(from: id)
            let inner = innerModelId(from: id)
            let peerName = peers.first(where: { $0.id == pid })?.name ?? "Mac"
            // A model the catalog doesn't carry still gets a short label; the
            // raw id is a fetch address, not something to print.
            let name = nameIndex[inner] ?? ModelNaming.short(inner)
            return (name, peerName)
        }
        return (nameIndex[id] ?? ModelNaming.short(id), "On this iPhone")
    }

    private static func peerId(from id: String) -> String {
        // "mac:<peerId>/<modelId>"
        let body = id.hasPrefix("mac:") ? String(id.dropFirst(4)) : id
        return String(body.prefix(while: { $0 != "/" }))
    }

    private static func innerModelId(from id: String) -> String {
        let body = id.hasPrefix("mac:") ? String(id.dropFirst(4)) : id
        if let slash = body.firstIndex(of: "/") {
            return String(body[body.index(after: slash)...])
        }
        return body
    }

    private static func isChatCapable(_ manifest: ModelManifest) -> Bool {
        manifest.modalities.contains(.text) || manifest.modalities.contains(.vision)
    }

    private static func capabilityLine(_ manifest: ModelManifest) -> String {
        var caps: [String] = []
        if manifest.modalities.contains(.text) { caps.append("Text") }
        if manifest.modalities.contains(.vision) { caps.append("Vision") }
        if manifest.modalities.contains(.speechToText) { caps.append("Speech") }
        if manifest.modalities.contains(.textToSpeech) { caps.append("Voice") }
        if manifest.modalities.contains(.image) { caps.append("Images") }
        return caps.isEmpty ? manifest.family : caps.joined(separator: " + ")
    }

    private static func rowData(_ entry: CatalogEntry) -> ModelRowData {
        let m = entry.manifest
        // Honest tok/s: only a genuinely measured rate (installed & run).
        let speedText = entry.fit.measuredTokensPerSec.map { "\(Int($0)) tok/s" }
        return ModelRowData(
            name: m.displayName,
            familyParamsQuant: "\(capabilityLine(m)) · \(m.family) · \(trimParams(m.paramsB))B",
            fitKind: fitKind(entry.fit.verdict),
            fitReason: entry.fit.reason,
            // Actual local bytes for the install (§4 "Model storage"), not RAM.
            sizeOnDisk: byteString(Int64(entry.fit.diskBytes)),
            speedText: speedText,
            speedIsMeasured: speedText != nil,
            licenseLabel: m.license.spdx
        )
    }

    private static func fitKind(_ verdict: FitVerdict) -> FitBadgeKind {
        switch verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }

    private static func latestText(_ msgs: [Message]) -> String {
        guard let last = msgs.last else { return "" }
        let text = last.parts.compactMap { part -> String? in
            if case let .text(t) = part { return t }
            return nil
        }.joined(separator: " ")
        return text
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimParams(_ p: Float) -> String {
        p == p.rounded() ? String(Int(p)) : String(format: "%.1f", p)
    }

    static func byteString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("Light") {
    HomeView().environment(AppModel())
}

#Preview("Dark") {
    HomeView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}

#Preview("AX3") {
    HomeView()
        .environment(AppModel())
        .environment(\.dynamicTypeSize, .accessibility3)
}
