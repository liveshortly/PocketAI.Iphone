import Foundation
import Observation
import PocketKit
import PocketMLX

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
                let live = try LiveCore(config: config, platform: hooks)
                // Register the on-device chat engines (MLX .safetensors +
                // Apple Intelligence) so send() can actually run inference.
                live.registerEngine(RoutingEngine())
                core = live
            } catch {
                fatalError("PocketCore.open failed: \(error)")
            }
        }
    }
}
