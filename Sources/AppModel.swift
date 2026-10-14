import Foundation
import Observation
import PocketKit

@Observable
@MainActor
public final class AppModel {
    public let core: CoreClient

    public init() {
        if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
            core = PreviewCore()
        } else {
            let hooks = LivePlatformHooks()
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .ios)
            do {
                core = try LiveCore(config: config, platform: hooks)
            } catch {
                fatalError("PocketCore.open failed: \(error)")
            }
        }
    }
}
