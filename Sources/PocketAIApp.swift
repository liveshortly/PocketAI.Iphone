import SwiftUI

private struct ActivationSheetItem: Identifiable {
    let id = UUID()
    let key: String?
}

@main
struct PocketAIApp: App {
    @State private var model = AppModel.shared
    @State private var activationSheet: ActivationSheetItem?

    init() {
        DiagnosticsLog.shared.append("PocketAIApp: application initialized")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .sheet(item: $activationSheet) { item in
                    NavigationStack {
                        PaywallView(prefilledKey: item.key)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { activationSheet = nil }
                                }
                            }
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "pocketai", url.host == "activate" else { return }
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let key = components?.queryItems?.first(where: { $0.name == "k" })?.value
                    activationSheet = ActivationSheetItem(key: key)
                }
        }
    }
}
