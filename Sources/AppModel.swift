import Foundation
import PocketUI
import Observation
import PocketKit
import PocketLiveShortly
import PocketMLX
import UIKit

@Observable
@MainActor
public final class AppModel {
    public static let shared = AppModel()

    public let core: CoreClient
    /// The offline switch, owned once rather than copied into each screen
    /// that offers it. See `OfflineMode`.
    public private(set) var offlineMode: OfflineMode!
    /// AGT-13: the code sandbox and its "Run this?" cards (Settings → Tools).
    public private(set) var tools: ToolsRuntime!
    public let hooks: PlatformHooks
    public let store: StoreEntitlementManager
    /// LiveShortly integration (opt-in; connected from Settings → Integrations).
    public let liveShortly = LSAccountModel()
    public var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }
    public var selectedModelId: String? {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.selectedModelKey) }
    }
    /// Non-nil when the Rust core failed to open at launch. The app stays alive
    /// (degraded) and surfaces this instead of crashing with `fatalError`.
    public private(set) var coreOpenError: String?

    /// Shell navigation state (tab selection + pending deep link). Kept in its
    /// own `@Observable` so AppModel's observable surface stays unchanged for
    /// existing consumers; `@ObservationIgnored` because views observe `nav`
    /// directly, not through AppModel.
    @ObservationIgnored public let nav: AppNavigator

    /// The app-wide toast (C18, UI-140): reports failures that used to be
    /// swallowed by `try?`, shown over every tab and onboarding.
    public var toast: ToastData?

    /// Runs a user action; a failure becomes a toast instead of vanishing.
    public func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch {
            toast = ToastData(message: "Couldn't \(what): \(error.localizedDescription)")
        }
    }

    private static let onboardedKey = "app.getpocketai.hasOnboarded"
    private static let selectedModelKey = "app.getpocketai.selectedModelId"

    public init() {
        DiagnosticsLog.shared.append("AppModel: initialization started")
        if ProcessInfo.processInfo.arguments.contains("-PocketResetOnboarding") {
            hasOnboarded = false
        } else if ProcessInfo.processInfo.arguments.contains("-PocketSkipOnboarding") {
            hasOnboarded = true
        } else {
            hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        }
        selectedModelId = UserDefaults.standard.string(forKey: Self.selectedModelKey)
        nav = AppNavigator(initialTab: AppNavigator.initialTab())
        let hooks = LivePlatformHooks()
        self.hooks = hooks
        let isPreview = ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PocketPerfDiagnostics") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        let core: CoreClient
        if isPreview {
            core = PreviewCore()
            DiagnosticsLog.shared.append("AppModel: PreviewCore active")
        } else {
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .ios)
            do {
                let live = try LiveCore(config: config, platform: hooks)
                let lazyRemote = LazyRemoteEngine { [weak live, hooks] modelId in
                    guard let live else { return nil }
                    // Resolve the specific paired Mac encoded in mac:<peer>/<model>
                    // (F16), not peers().first; nil id uses the first peer.
                    let peers = live.peers()
                    let peer: Peer?
                    if let modelId, let pid = RemoteEngine.peerId(from: modelId) {
                        peer = peers.first { $0.id == pid }
                    } else {
                        peer = peers.first
                    }
                    guard let peer else { return nil }
                    guard let tokenData = hooks.keychainGet(key: peer.tokenRef),
                          let token = String(data: tokenData, encoding: .utf8) else {
                        return nil
                    }
                    // A Bonjour rediscovery (after an IP change) may have parked a
                    // corrected address here; prefer it over the stale stored addr.
                    let override = PeerAddressBook.shared.override(forHostId: peer.name)
                    guard let host = override?.host ?? peer.addrs.first else { return nil }
                    let port = override?.port ?? peer.port
                    let endpoint = PeerEndpoint(host: host, port: port, fingerprint: peer.certSha256)
                    return PeerClient(endpoint: endpoint, token: token)
                }
                // Apple first so its built-in sentinel can't be intercepted by
                // generic MLX support (F15/§9.1).
                live.registerEngine(RoutingEngine(engines: [
                    AppleFoundationModelsEngine(),
                    PocketMLXEngine(),
                    lazyRemote,
                ]))
                core = live
                DiagnosticsLog.shared.append("AppModel: LiveCore initialized, RoutingEngine registered with MLX, AFM, and LazyRemoteEngine")
            } catch {
                DiagnosticsLog.shared.append("AppModel: LiveCore failed to open: \(error)")
                // Graceful degradation instead of a hard crash: keep the app
                // navigable and tell the user, rather than fatalError().
                coreOpenError = "PocketAI's on-device engine couldn't start. Quit and reopen PocketAI; if it keeps happening, reinstall it. (\(error))"
                core = PreviewCore()
            }
        }
        self.core = core
        self.offlineMode = OfflineMode(core: core)
        self.tools = ToolsRuntime(core: core)
        // The iPhone app is free (D138); there is no App Store IAP path.
        // StoreEntitlementManager is retained as a disabled stub.
        self.store = StoreEntitlementManager(keychain: hooks) { [core] e in
            core.setStoreEntitlement(e)
        }
        // Under memory pressure, let the core drop idle model handles instead
        // of the OS killing the app mid-chat.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [core] _ in
            core.onMemoryWarning()
        }
    }

}

/// Shell navigation state (§3, F26): which tab is shown and a one-shot pending
/// conversation id for deep links. Home's New chat / Recent chat and
/// `StartNewChatIntent` route through `openConversation`, selecting the Chats
/// tab and handing it the exact conversation. An ordinary tab change here never
/// touches `selectedModelId` or active transfers.
@Observable
@MainActor
public final class AppNavigator {
    public enum Tab: Hashable, Sendable {
        case home, chats, models, devices, settings
    }

    public var selectedTab: Tab
    public var pendingOpenConversationId: String?
    /// One-shot first message for a brand-new chat (e.g. an onboarding
    /// suggestion); Chats consumes it and creates the chat with it.
    public var pendingFirstMessage: String?
    /// One-shot: Chats should show its Projects segment (Home's Projects card).
    public var pendingShowProjects = false

    public init(initialTab: Tab = .home) {
        selectedTab = initialTab
    }

    /// Launch-argument tab override (used by UI tests); Home is the default.
    public static func initialTab() -> Tab {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-PocketTabChats") { return .chats }
        if args.contains("-PocketTabModels") { return .models }
        if args.contains("-PocketTabDevices") { return .devices }
        if args.contains("-PocketTabSettings") { return .settings }
        return .home
    }

    /// Ordinary tab change (keeps each tab's model/transfers/scroll state).
    public func select(tab: Tab) { selectedTab = tab }

    /// Routes to the Chats tab and asks it to open `id`. The Chats stack reads
    /// `pendingOpenConversationId` via `consumePendingConversation()` on
    /// appearance — avoiding a duplicate stack showing the same chat from Home.
    public func openConversation(id: String) {
        pendingOpenConversationId = id
        selectedTab = .chats
    }

    /// Chats calls this on appearance; returns a one-shot pending id and clears it.
    public func consumePendingConversation() -> String? {
        defer { pendingOpenConversationId = nil }
        return pendingOpenConversationId
    }

    /// Routes to Chats with a first message for a new chat (one-shot).
    public func startNewChat(firstMessage: String?) {
        pendingFirstMessage = firstMessage
        selectedTab = .chats
    }

    /// Routes to Chats with the Projects segment selected (one-shot).
    public func openProjects() {
        pendingShowProjects = true
        selectedTab = .chats
    }

    public func consumePendingFirstMessage() -> String? {
        defer { pendingFirstMessage = nil }
        return pendingFirstMessage
    }
}
