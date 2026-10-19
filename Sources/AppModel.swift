import Foundation
import Observation
import PocketKit
import PocketMLX
import UIKit

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
        DiagnosticsLog.shared.append("AppModel: initialization started")
        if ProcessInfo.processInfo.arguments.contains("-PocketResetOnboarding") {
            hasOnboarded = false
        } else if ProcessInfo.processInfo.arguments.contains("-PocketSkipOnboarding") {
            hasOnboarded = true
        } else {
            hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        }
        let hooks = LivePlatformHooks()
        self.hooks = hooks
        let isPreview = ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PocketPerfDiagnostics") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
        let core: CoreClient
        if isPreview {
            core = PreviewCore()
            DiagnosticsLog.shared.append("AppModel: PreviewCore active")
        } else {
            let config = CoreConfig(appSupportDir: hooks.appSupportDir(), platform: .ios)
            do {
                let live = try LiveCore(config: config, platform: hooks)
                // Register the on-device chat engines (MLX .safetensors +
                // Apple Intelligence) so send() can actually run inference.
                live.registerEngine(RoutingEngine())
                core = live
                DiagnosticsLog.shared.append("AppModel: LiveCore initialized, RoutingEngine registered")
            } catch {
                DiagnosticsLog.shared.append("AppModel: LiveCore failed to open")
                fatalError("PocketCore.open failed: \(error)")
            }
        }
        self.core = core
        // In the Keygen-only licensing model, there is no App Store IAP path.
        // StoreEntitlementManager is retained as a disabled stub.
        self.store = StoreEntitlementManager(keychain: hooks) { [core] e in
            core.setStoreEntitlement(e)
        }
    }
}
