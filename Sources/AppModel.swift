import Foundation
import Observation
import PocketKit

@Observable
@MainActor
public final class AppModel {
    public static let shared = AppModel()

    public let core: CoreClient
    public let hooks: PlatformHooks
    public var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    private static let onboardedKey = "app.getpocketai.hasOnboarded"

    public init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        let hooks = LivePlatformHooks()
        self.hooks = hooks
        if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
            core = PreviewCore()
        } else {
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .ios)
            do {
                core = try LiveCore(config: config, platform: hooks)
            } catch {
                fatalError("PocketCore.open failed: \(error)")
            }
        }
    }
}
