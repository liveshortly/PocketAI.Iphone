import SwiftUI

@main
struct PocketAIApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
        }
    }
}
