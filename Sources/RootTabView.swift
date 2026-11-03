import SwiftUI
import PocketKit
import PocketUI

/// Tab shell per 02-design-system.md §6.1: Home (UI-25, owner 2026-11-02:
/// "a basic summary of everything"), Chats, Models, Mac, Settings.
struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSharedInboxSheet = false

    private struct HeartbeatKey: Equatable { var active: Bool; var online: Bool }
    private var heartbeatKey: HeartbeatKey {
        HeartbeatKey(active: scenePhase == .active, online: NetworkMonitor.shared.isOnline)
    }

    private typealias AppTab = AppNavigator.Tab

    /// The tab bar reads and writes `model.nav`, so Home's cards, deep links
    /// and App Intents switch tabs the same way a tap does. Launch-argument
    /// overrides live in `AppNavigator.initialTab()`.
    private var selectedTab: Binding<AppTab> {
        Binding(get: { model.nav.selectedTab }, set: { model.nav.select(tab: $0) })
    }

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-PocketComponentGallery") }) {
                ComponentGallery()
            } else if ProcessInfo.processInfo.arguments.contains("-PocketScreenChat") {
                NavigationStack {
                    ChatView(conversationId: "fixture-0")
                }
            } else if ProcessInfo.processInfo.arguments.contains("-PocketScreenProjectDetail") {
                NavigationStack {
                    ProjectDetailView(projectId: "proj-1")
                }
            } else if !model.hasOnboarded {
                OnboardingFlow(core: model.core, deviceProfile: model.hooks.deviceProfile()) {
                    model.hasOnboarded = true
                    checkSharedInbox()
                }
            } else {
                tabs
            }
        }
        .sheet(isPresented: $isShowingSharedInboxSheet) {
            SharedInboxIngestSheet(core: model.core) {
                isShowingSharedInboxSheet = false
            }
        }
        .task {
            checkSharedInbox()
        }
        .task {
            // Download notifications live here, not on the Models screen: a
            // download that finishes while you are reading a chat is the whole
            // point, and ModelsView's poll stops when it goes away.
            await watchDownloads()
        }
        .task(id: heartbeatKey) {
            // NET-18: lease renewal only while foreground and online; a
            // network change or coming back restarts it with fresh counters.
            NetworkMonitor.shared.start()
            guard heartbeatKey.active, heartbeatKey.online, model.hasOnboarded else { return }
            await MacLink.shared.runHeartbeats(core: model.core, hooks: model.hooks)
        }
        .task(id: heartbeatKey) {
            // NET-22: chat sync with the paired Mac while foreground + online.
            guard heartbeatKey.active, heartbeatKey.online, model.hasOnboarded else { return }
            await ChatSync.shared.runForeground(core: model.core, hooks: model.hooks)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                MacLink.shared.sayGoodbye(core: model.core, hooks: model.hooks)
                ChatSync.scheduleBackgroundTask()
            }
            if newPhase == .active {
                checkSharedInbox()
                // "Arrives when you open PocketAI" — honest, and the only
                // thing a suspended app can do (§7.10).
                checkPendingApprovals()
            }
        }
    }

    /// Reports a download that finished or failed since the last poll. Only
    /// transitions notify, so models already installed at launch are silent.
    private func watchDownloads() async {
        var last: [String: ModelState] = [:]
        var seeded = false
        while !Task.isCancelled {
            let entries = model.core.catalog(
                filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
            var next: [String: ModelState] = [:]
            for entry in entries {
                let id = entry.manifest.id
                next[id] = entry.state
                guard seeded, let previous = last[id], previous != entry.state else { continue }
                guard previous == .downloading || previous == .verifying else { continue }
                let name = ModelNaming.short(entry.manifest.displayName)
                switch entry.state {
                case .installed:
                    Notifier.shared.downloadFinished(modelName: name)
                case .failed(let reason):
                    Notifier.shared.downloadFailed(modelName: name, reason: reason)
                default:
                    break
                }
            }
            last = next
            seeded = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// On return to the foreground, surface any agent session that asked for a
    /// decision while the app was away. Each session is announced once per
    /// probe, keyed on the probe's own event id.
    private func checkPendingApprovals() {
        guard model.hasOnboarded, Notifier.shared.isEnabled(.approvalNeeded) else { return }
        Task { await LSApprovalWatcher.shared.check(account: model.liveShortly) }
    }

    private func checkSharedInbox() {
        guard model.hasOnboarded else { return }
        if !SharedInbox.listItems().isEmpty {
            isShowingSharedInboxSheet = true
        }
    }

    private func isSelected(_ tab: AppTab) -> Bool { model.nav.selectedTab == tab }

    private var tabs: some View {
        TabView(selection: selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: isSelected(.home) ? "house.fill" : "house")
                }
                .tag(AppTab.home)
                .accessibilityIdentifier("tab_home")

            ChatsListView()
                .tabItem {
                    Label(
                        "Chats",
                        systemImage: isSelected(.chats) ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
                    )
                }
                .tag(AppTab.chats)
                .accessibilityIdentifier("tab_chats")

            ModelsView()
                .tabItem {
                    Label(
                        "Models",
                        systemImage: isSelected(.models) ? "cpu.fill" : "cpu"
                    )
                }
                .tag(AppTab.models)
                .accessibilityIdentifier("tab_models")

            DevicesView()
                .tabItem {
                    Label(
                        "Mac",
                        systemImage: isSelected(.devices) ? "laptopcomputer.and.iphone" : "laptopcomputer"
                    )
                }
                .tag(AppTab.devices)
                .accessibilityIdentifier("tab_devices")

            SettingsView()
                .tabItem {
                    Label(
                        "Settings",
                        systemImage: isSelected(.settings) ? "gearshape.fill" : "gearshape"
                    )
                }
                .tag(AppTab.settings)
                .accessibilityIdentifier("tab_settings")
        }
        .tint(PocketColor.accent)
        .modifier(TabBarMinimizeModifier())
    }
}

/// UI-37 (owner): the tab bar stays full size on every screen and scroll
/// direction. Explicit `.never` so a future system default can't minimize it.
private struct TabBarMinimizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

#Preview {
    RootTabView().environment(AppModel())
}
