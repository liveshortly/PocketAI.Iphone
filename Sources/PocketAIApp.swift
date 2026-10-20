import SwiftUI

@main
struct PocketAIApp: App {
    @State private var model = AppModel.shared

    init() {
        DiagnosticsLog.shared.append("PocketAIApp: application initialized")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
        }
    }
}
