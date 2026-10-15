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
    public let store: StoreEntitlementManager
    public var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    private static let onboardedKey = "app.getpocketai.hasOnboarded"

    public init() {
        hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        let hooks = LivePlatformHooks()
        self.hooks = hooks
        let isPreview = ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore")
        let core: CoreClient
        if isPreview {
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
        self.core = core
        let store = StoreEntitlementManager(keychain: hooks) { [core] e in
            core.setStoreEntitlement(e)
        }
        self.store = store

        if !isPreview {
            Task {
                await store.start()
            }
        }
    }
}
