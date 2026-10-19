import SwiftUI
import PocketUI

/// Tab shell per 02-design-system.md §6.1. Screens are placeholders until
/// UI-04/UI-07+ land; this proves the shell, PocketUI tokens, and the
/// PocketMark chip render against a real `CoreClient` (Live or Preview).
struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSharedInboxSheet = false

    private enum AppTab: Hashable {
        case chats, models, devices, settings
    }

    @State private var selectedTab: AppTab = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-PocketTabModels") { return .models }
        if args.contains("-PocketTabDevices") { return .devices }
        if args.contains("-PocketTabSettings") { return .settings }
        return .chats
    }()

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-PocketComponentGallery") }) {
                ComponentGallery()
            } else if ProcessInfo.processInfo.arguments.contains("-PocketScreenPaywall") {
                NavigationStack {
                    PaywallView()
                }
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                checkSharedInbox()
            }
        }
    }

    private func checkSharedInbox() {
        guard model.hasOnboarded else { return }
        if !SharedInbox.listItems().isEmpty {
            isShowingSharedInboxSheet = true
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ChatsListView()
                .tabItem {
                    Label(
                        "Chats",
                        systemImage: selectedTab == .chats ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
                    )
                }
                .tag(AppTab.chats)
                .accessibilityIdentifier("tab_chats")

            ModelsView()
                .tabItem {
                    Label(
                        "Models",
                        systemImage: selectedTab == .models ? "cpu.fill" : "cpu"
                    )
                }
                .tag(AppTab.models)
                .accessibilityIdentifier("tab_models")

            DevicesView()
                .tabItem {
                    Label(
                        "Mac",
                        systemImage: selectedTab == .devices ? "laptopcomputer.and.iphone" : "laptopcomputer"
                    )
                }
                .tag(AppTab.devices)
                .accessibilityIdentifier("tab_devices")

            SettingsView()
                .tabItem {
                    Label(
                        "Settings",
                        systemImage: selectedTab == .settings ? "gearshape.fill" : "gearshape"
                    )
                }
                .tag(AppTab.settings)
                .accessibilityIdentifier("tab_settings")
        }
        .tint(PocketColor.accent)
        .modifier(TabBarMinimizeModifier())
    }
}

private struct TabBarMinimizeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

#Preview {
    RootTabView().environment(AppModel())
}
