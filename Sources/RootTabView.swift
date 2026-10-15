import SwiftUI
import PocketUI

/// Tab shell per 02-design-system.md §6.1. Screens are placeholders until
/// UI-04/UI-07+ land; this proves the shell, PocketUI tokens, and the
/// PocketMark chip render against a real `CoreClient` (Live or Preview).
struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSharedInboxSheet = false

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-PocketComponentGallery") }) {
                ComponentGallery()
            } else if ProcessInfo.processInfo.arguments.contains("-PocketScreenPaywall") {
                NavigationStack {
                    PaywallView()
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
        TabView {
            ChatsListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .accessibilityIdentifier("tab_chats")
            ModelsView()
                .tabItem { Label("Models", systemImage: "cpu") }
                .accessibilityIdentifier("tab_models")
            DevicesView()
                .tabItem { Label("Devices", systemImage: "laptopcomputer") }
                .accessibilityIdentifier("tab_devices")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .accessibilityIdentifier("tab_settings")
        }
        .tint(PocketColor.accent)
    }
}

#Preview {
    RootTabView().environment(AppModel())
}
