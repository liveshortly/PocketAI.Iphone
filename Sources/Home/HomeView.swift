import SwiftUI
import PocketKit
import PocketLiveShortly
import PocketUI

/// Home (UI-25, owner 2026-11-02): "a basic summary of everything". A calm
/// stack of cards, each tappable to the screen that owns it. Honest
/// instruments only: every number comes from Core, MacLink or LiveShortly,
/// and a line with no real source is left out rather than estimated.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var snapshot: HomeSnapshot?
    /// nil until loaded, or when the fetch failed (`lsFailed`).
    @State private var lsSessions: [LSSession]?
    @State private var lsFailed = false
    @State private var openSessionId: String?
    @State private var newChatError: String?

    private struct RefreshKey: Equatable {
        var tab: AppNavigator.Tab
        var modelId: String?
        var lsConnected: Bool
    }

    private var refreshKey: RefreshKey {
        RefreshKey(tab: model.nav.selectedTab, modelId: model.selectedModelId, lsConnected: model.liveShortly.isConnected)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.coreOpenError != nil {
                    HomeUnavailableView(detail: model.coreOpenError)
                } else if let snapshot {
                    cards(snapshot)
                } else {
                    PocketMarkView(state: .loading, size: 44)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Loading")
                }
            }
            .background(PocketColor.bgCanvas)
            .navigationTitle("PocketAI")
            .toolbar {
                // UI-49: the one thing people open the app to do, one tap away.
                ToolbarItem(placement: .primaryAction) {
                    Button { startNewChat() } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .disabled(model.coreOpenError != nil)
                    .accessibilityIdentifier("home_new_chat")
                }
            }
            .alert("Couldn't start a new chat", isPresented: Binding(
                get: { newChatError != nil },
                set: { if !$0 { newChatError = nil } }
            )) {
                Button("OK", role: .cancel) { newChatError = nil }
            } message: {
                Text(newChatError ?? "")
            }
            .navigationDestination(item: $openSessionId) { id in
                LSSessionView(account: model.liveShortly, sessionID: id)
            }
            .task(id: refreshKey) { await reload() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reload() } }
            }
        }
    }

    private func cards(_ s: HomeSnapshot) -> some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s12) {
                ContinueCard(chats: s.recent, onNewChat: { startNewChat() })
                ModelCard(snapshot: s)
                MacCard(peer: s.macPeer, chatModelOnMac: s.macChatModel)
                if model.liveShortly.isConnected {
                    LiveShortlyCard(sessions: lsSessions, failed: lsFailed) { openSessionId = $0 }
                }
                ProjectsCard(count: s.projectCount, newest: s.newestProject)
                PrivacyCard(diskBytes: s.modelDiskBytes, modelCount: s.installedCount, requests: s.egressCount)
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.vertical, PocketSpacing.s16)
        }
        .refreshable { await reload() }
    }

    /// Same create call as Chats' New chat button; the Chats tab then opens
    /// it through the existing `openConversation` route.
    private func startNewChat() {
        do {
            let c = try model.core.createConversation(
                NewConversation(title: nil, projectId: nil, modelId: model.selectedModelId))
            model.nav.openConversation(id: c.id)
        } catch {
            newChatError = error.localizedDescription
        }
    }

    private func reload() async {
        // The shared `.task(id:)` also fires on tab switches away from Home.
        guard model.nav.selectedTab == .home, model.coreOpenError == nil else { return }
        let core = model.core
        let selected = model.selectedModelId
        let apple = AppleFoundationModelsEngine.isAvailable
        let ram = model.hooks.deviceProfile().totalRamBytes
        snapshot = await Task.detached(priority: .userInitiated) {
            HomeSnapshot.compute(core: core, selectedModelId: selected, appleAvailable: apple, totalRam: ram)
        }.value
        await reloadSessions()
    }

    private func reloadSessions() async {
        guard model.liveShortly.isConnected, let client = model.liveShortly.client else {
            lsSessions = nil
            return
        }
        do {
            lsSessions = try await client.sessions(limit: 30)
            lsFailed = false
        } catch {
            lsFailed = true
        }
    }
}

// MARK: - Card shell

/// One summary card: leading glyph, small title, content, chevron when the
/// whole card navigates. `action == nil` leaves the rows to handle taps.
private struct HomeCard<Leading: View, Content: View>: View {
    let title: String
    var action: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let content: Content
    /// Grows with Dynamic Type so the glyph never overflows its column.
    @ScaledMetric(relativeTo: .headline) private var iconSize = PocketSpacing.s32

    var body: some View {
        if let action {
            Button(action: action) {
                shell(chevron: true).accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
        } else {
            shell(chevron: false)
        }
    }

    private func shell(chevron: Bool) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s12) {
            leading.frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                Text(title)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(PocketSpacing.s16)
        .background(PocketColor.bgSurface, in: RoundedRectangle(cornerRadius: PocketRadius.card))
        .contentShape(Rectangle())
    }
}

private struct CardIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.pocket(.headline))
            .foregroundStyle(PocketColor.accent)
            .accessibilityHidden(true)
    }
}

/// Headline + secondary line, the shape most cards share.
private struct CardLines: View {
    let primary: String
    var secondary: String?
    var body: some View {
        Text(primary)
            .font(.pocket(.headline))
            .foregroundStyle(PocketColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        if let secondary {
            Text(secondary)
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Continue

private struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    let chats: [HomeSnapshot.Chat]
    let onNewChat: () -> Void

    var body: some View {
        if chats.isEmpty {
            HomeCard(title: "Continue", action: onNewChat) {
                CardIcon(systemName: "bubble.left.and.bubble.right")
            } content: {
                CardLines(primary: "Start your first chat", secondary: "It stays on this iPhone.")
            }
        } else {
            HomeCard(title: "Continue") {
                CardIcon(systemName: "bubble.left.and.bubble.right")
            } content: {
                ForEach(chats) { chat in
                    Button { model.nav.openConversation(id: chat.id) } label: { ChatLine(chat: chat) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home_recent_\(chat.id)")
                }
            }
        }
    }
}

private struct ChatLine: View {
    let chat: HomeSnapshot.Chat

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s2) {
            Text(chat.title)
                .font(.pocket(.headline))
                .foregroundStyle(PocketColor.textPrimary)
                .lineLimit(1)
            Text("\(chat.model) · \(relative)")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var relative: String {
        let date = Date(timeIntervalSince1970: Double(chat.updatedAt) / 1000)
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

// MARK: - Model

private struct ModelCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: HomeSnapshot

    var body: some View {
        HomeCard(title: "Model", action: { model.nav.select(tab: .models) }) {
            // Decorative here: its "PocketAI is offline" label would misstate
            // a model that is merely not chosen; the lines say the real state.
            PocketMarkView(state: snapshot.model?.ready == true ? .idle : .offline, size: PocketSpacing.s32)
                .accessibilityHidden(true)
        } content: {
            if let m = snapshot.model {
                CardLines(primary: m.name, secondary: m.detail)
                if let fit = m.fit {
                    FitBadge(kind: fit, reason: m.fitReason)
                }
            } else if snapshot.hasInstalledChatModel {
                CardLines(primary: "No model chosen", secondary: "Choose one in Models.")
            } else {
                CardLines(primary: "No model yet — Get one", secondary: "Download a model that runs on this iPhone.")
            }
        }
        .accessibilityIdentifier("home_model_card")
    }
}

// MARK: - Mac

private struct MacCard: View {
    @Environment(AppModel.self) private var model
    let peer: Peer?
    let chatModelOnMac: String?

    var body: some View {
        HomeCard(title: "Mac", action: { model.nav.select(tab: .devices) }) {
            CardIcon(systemName: peer == nil ? "laptopcomputer" : "laptopcomputer.and.iphone")
        } content: {
            if let peer {
                CardLines(primary: peer.name, secondary: status(peer))
                if let chatModelOnMac {
                    Text("Your chat model: \(chatModelOnMac)")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            } else {
                CardLines(primary: "Not paired", secondary: "Pair your Mac to use its bigger models from this iPhone.")
            }
        }
        .accessibilityIdentifier("home_mac_card")
    }

    /// NET-17/18 link state. nil = paired, no heartbeat answered yet (e.g.
    /// just launched or offline), which the Mac side shows as Idle too.
    private func status(_ peer: Peer) -> String {
        switch MacLink.shared.state(for: peer) {
        case .connected: return "Connected"
        case nil: return "Idle"
        case .unreachable: return "Not answering — open PocketAI on your Mac"
        case .disconnected, .disconnectedByHost: return "Disconnected"
        }
    }
}

// MARK: - LiveShortly

private struct LiveShortlyCard: View {
    @Environment(AppModel.self) private var model
    let sessions: [LSSession]?
    let failed: Bool
    let open: (String) -> Void

    /// Live first, then newest — the same order as the Chats section.
    private var latest: LSSession? {
        sessions?.min {
            $0.isLive != $1.isLive ? $0.isLive : $0.createdAt > $1.createdAt
        }
    }

    var body: some View {
        HomeCard(title: "LiveShortly", action: action) {
            if let latest {
                LSSessionMark(isLive: latest.isLive, size: PocketSpacing.s32)
            } else if sessions == nil, !failed {
                PocketMarkView(state: .loading, size: PocketSpacing.s32)
            } else {
                LSSessionMark(isLive: false, size: PocketSpacing.s32)
            }
        } content: {
            lines
        }
        .accessibilityIdentifier("home_ls_card")
    }

    @ViewBuilder private var lines: some View {
        if failed, sessions == nil {
            CardLines(primary: "Couldn't load sessions", secondary: "Tap to see them in Chats.")
        } else if let sessions, let latest {
            let live = sessions.filter(\.isLive).count
            CardLines(primary: latest.title, secondary: live == 0 ? "No live sessions" : "\(live) live")
        } else if sessions != nil {
            CardLines(primary: "No sessions yet", secondary: "Run \u{201C}live claude\u{201D} in a terminal to stream an agent here.")
        } else {
            CardLines(primary: "Loading sessions…")
        }
    }

    private var action: () -> Void {
        if let id = latest?.id { return { open(id) } }
        return { model.nav.select(tab: .chats) }
    }
}

// MARK: - Projects

private struct ProjectsCard: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let newest: String?

    var body: some View {
        HomeCard(title: "Projects", action: { model.nav.openProjects() }) {
            CardIcon(systemName: "folder")
        } content: {
            if let newest {
                CardLines(primary: count == 1 ? "1 project" : "\(count) projects", secondary: "Newest: \(newest)")
            } else {
                CardLines(primary: "No projects yet", secondary: "Group chats with your own documents.")
            }
        }
        .accessibilityIdentifier("home_projects_card")
    }
}

// MARK: - Storage & privacy

private struct PrivacyCard: View {
    @Environment(AppModel.self) private var model
    let diskBytes: UInt64
    let modelCount: Int
    let requests: Int

    var body: some View {
        HomeCard(title: "Storage & privacy", action: { model.nav.select(tab: .settings) }) {
            CardIcon(systemName: "checkmark.shield")
        } content: {
            Text(storage)
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textPrimary)
            // Core's egress log is in-memory (F19), so "this session" is the
            // honest scope — the same number Settings › Network Proof shows.
            Text(requests == 1 ? "1 internet request this session" : "\(requests) internet requests this session")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
        }
        .accessibilityIdentifier("home_privacy_card")
    }

    private var storage: String {
        guard modelCount > 0 else { return "No models stored" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(diskBytes), countStyle: .file)
        return modelCount == 1 ? "1 model · \(size)" : "\(modelCount) models · \(size)"
    }
}

// MARK: - Unavailable (F22)

private struct HomeUnavailableView: View {
    let detail: String?

    var body: some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s16) {
                PocketMarkView(state: .offline, size: 72)
                Text("PocketAI is unavailable")
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.textPrimary)
                Text("The on-device engine couldn't start. Your chats and models are safe on this iPhone. Quit and reopen PocketAI to try again.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                if let detail {
                    Text(detail)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                        .textSelection(.enabled)
                }
            }
            .multilineTextAlignment(.center)
            .padding(PocketSpacing.s24)
        }
        .accessibilityIdentifier("home_unavailable")
    }
}

// MARK: - Snapshot (computed off the main actor)

struct HomeSnapshot: Sendable {
    struct Chat: Sendable, Identifiable {
        let id: String
        let title: String
        let model: String
        let updatedAt: Int64
    }

    struct CurrentModel: Sendable {
        let name: String
        let detail: String
        let ready: Bool
        var fit: FitBadgeKind?
        var fitReason = ""
    }

    var recent: [Chat] = []
    /// nil when no default model is chosen.
    var model: CurrentModel?
    var hasInstalledChatModel = false
    var macPeer: Peer?
    var macChatModel: String?
    var projectCount = 0
    var newestProject: String?
    var installedCount = 0
    var modelDiskBytes: UInt64 = 0
    var egressCount = 0

    static func compute(core: CoreClient, selectedModelId: String?, appleAvailable: Bool, totalRam: UInt64) -> HomeSnapshot {
        var s = HomeSnapshot()
        let installed = core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
        let peers = core.peers()
        var names: [String: String] = [:]
        for e in installed { names[e.manifest.id] = ModelNaming.short(e.manifest.displayName) }

        s.installedCount = installed.count
        // Same real-bytes rule as Settings › Storage used.
        for e in installed {
            s.modelDiskBytes += e.fit.diskBytes != 0 ? e.fit.diskBytes : e.manifest.estRuntimeBytes
        }
        s.hasInstalledChatModel = installed.contains {
            $0.manifest.modalities.contains(.text) || $0.manifest.modalities.contains(.vision)
        }
        s.model = selectedModelId.map {
            current($0, installed: installed, peers: peers, appleAvailable: appleAvailable, totalRam: totalRam)
        }

        let ownerId = selectedModelId.flatMap(RemoteEngine.peerId(from:))
        s.macPeer = peers.first { $0.id == ownerId } ?? peers.first
        if let id = selectedModelId, ownerId != nil, ownerId == s.macPeer?.id {
            s.macChatModel = ModelNaming.short(id)
        }

        s.recent = core.conversations(query: ConversationQuery(search: nil, archived: false, limit: 3, offset: 0)).map { c in
            let modelId = core.conversation(id: c.id)?.modelId
            return Chat(id: c.id, title: c.title ?? "New chat",
                        model: modelId.map { label($0, names: names, peers: peers) } ?? "No model",
                        updatedAt: c.updatedAt)
        }

        let projects = core.listProjects()
        s.projectCount = projects.count
        // Project has no updatedAt yet; "newest" is by creation, and says so.
        s.newestProject = projects.max { $0.createdAt < $1.createdAt }?.name
        s.egressCount = core.egressLog(limit: 500).count
        return s
    }

    private static func label(_ id: String, names: [String: String], peers: [Peer]) -> String {
        if id == AppleFoundationModelsEngine.modelId { return "Apple Intelligence" }
        if let pid = RemoteEngine.peerId(from: id) {
            return ModelNaming.remote(id, machine: peers.first { $0.id == pid }?.name)
        }
        return names[id] ?? ModelNaming.short(id)
    }

    private static func current(_ id: String, installed: [CatalogEntry], peers: [Peer], appleAvailable: Bool, totalRam: UInt64) -> CurrentModel {
        if id == AppleFoundationModelsEngine.modelId {
            return CurrentModel(name: "Apple Intelligence",
                                detail: appleAvailable ? "Built into this iPhone" : "Not ready on this device",
                                ready: appleAvailable)
        }
        if let pid = RemoteEngine.peerId(from: id) {
            let mac = peers.first { $0.id == pid }
            return CurrentModel(name: ModelNaming.short(id),
                                detail: mac.map { "Runs on \($0.name)" } ?? "That Mac is no longer paired",
                                ready: mac != nil)
        }
        guard let entry = installed.first(where: { $0.manifest.id == id }) else {
            return CurrentModel(name: ModelNaming.short(id), detail: "Not downloaded — choose another", ready: false)
        }
        return CurrentModel(name: ModelNaming.short(entry.manifest.displayName),
                            detail: ramLine(entry.fit.estRuntimeBytes, totalRam: totalRam),
                            ready: true,
                            fit: fitKind(entry.fit.verdict),
                            fitReason: entry.fit.reason)
    }

    /// Core's runtime estimate against this iPhone's RAM; "~" because it is one.
    private static func ramLine(_ need: UInt64, totalRam: UInt64) -> String {
        guard need > 0, totalRam > 0 else { return "On this iPhone" }
        let f: (UInt64) -> String = { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) }
        return "On this iPhone · needs ~\(f(need)) of \(f(totalRam)) RAM"
    }

    private static func fitKind(_ v: FitVerdict) -> FitBadgeKind {
        switch v {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
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
