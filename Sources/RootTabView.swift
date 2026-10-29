import SwiftUI
import PocketUI

/// Tab shell per handoff §3: Home · Chats · Models · Mac · Settings, each a
/// real screen driven by a live `CoreClient` and its own NavigationStack.
/// Home is the initial destination post-onboarding. Tab selection lives in
/// `AppModel.nav` (an `AppNavigator`) so Home / App-Intent deep links can
/// switch tabs (F26). The tab bar stays expanded — the global on-scroll
/// minimization is removed (F02).
/// Surfaces a core-open failure banner instead of crashing.
struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSharedInboxSheet = false

    var body: some View {
        @Bindable var nav = model.nav
        return Group {
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
                tabView(selection: $nav.selectedTab)
            }
        }
        .overlay(alignment: .top) {
            if let err = model.coreOpenError {
                CoreErrorBanner(message: err)
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

    private func tabView(selection: Binding<AppNavigator.Tab>) -> some View {
        let selected = selection.wrappedValue
        return TabView(selection: selection) {
            HomeView()
                .tabItem {
                    Label(
                        "Home",
                        systemImage: selected == .home ? "house.fill" : "house"
                    )
                }
                .tag(AppNavigator.Tab.home)
                .accessibilityIdentifier("tab_home")

            ChatsListView()
                .tabItem {
                    Label(
                        "Chats",
                        systemImage: selected == .chats ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
                    )
                }
                .tag(AppNavigator.Tab.chats)
                .accessibilityIdentifier("tab_chats")

            ModelsView()
                .tabItem {
                    Label(
                        "Models",
                        systemImage: selected == .models ? "cpu.fill" : "cpu"
                    )
                }
                .tag(AppNavigator.Tab.models)
                .accessibilityIdentifier("tab_models")

            DevicesView()
                .tabItem {
                    Label(
                        "Mac",
                        systemImage: selected == .devices ? "laptopcomputer.and.iphone" : "laptopcomputer"
                    )
                }
                .tag(AppNavigator.Tab.devices)
                .accessibilityIdentifier("tab_devices")

            SettingsView()
                .tabItem {
                    Label(
                        "Settings",
                        systemImage: selected == .settings ? "gearshape.fill" : "gearshape"
                    )
                }
                .tag(AppNavigator.Tab.settings)
                .accessibilityIdentifier("tab_settings")
        }
        .tint(PocketColor.accent)
        // F02: no `.tabBarMinimizeBehavior(.onScrollDown)` — the tab bar stays
        // expanded on scrolling screens (the reported "appearing Settings gear").
    }
}

/// Non-crashing surface for a core-open failure (replaces the old fatalError).
private struct CoreErrorBanner: View {
    let message: String
    @State private var dismissed = false
    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: PocketSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusBad)
                Text(message)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PocketSpacing.s8)
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PocketColor.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(PocketSpacing.s12)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.statusBad.opacity(0.4)))
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.top, PocketSpacing.s8)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
    }
}

#Preview {
    RootTabView().environment(AppModel())
}
