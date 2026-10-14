import SwiftUI
import PocketUI

/// Tab shell per 02-design-system.md §6.1. Screens are placeholders until
/// UI-04/UI-07+ land; this proves the shell, PocketUI tokens, and the
/// PocketMark chip render against a real `CoreClient` (Live or Preview).
struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-PocketComponentGallery") }) {
            ComponentGallery()
        } else if !model.hasOnboarded {
            OnboardingFlow(core: model.core, deviceProfile: model.hooks.deviceProfile()) {
                model.hasOnboarded = true
            }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            ChatsListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            Text("Models").tabItem { Label("Models", systemImage: "cpu") }
            Text("Devices").tabItem { Label("Devices", systemImage: "laptopcomputer") }
            Text("Settings").tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(PocketColor.accent)
    }
}

#Preview {
    RootTabView().environment(AppModel())
}
