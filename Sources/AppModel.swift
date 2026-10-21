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
    public var selectedModelId: String? {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.selectedModelKey) }
    }

    private static let onboardedKey = "app.getpocketai.hasOnboarded"
    private static let selectedModelKey = "app.getpocketai.selectedModelId"

    public init() {
        DiagnosticsLog.shared.append("AppModel: initialization started")
        if ProcessInfo.processInfo.arguments.contains("-PocketResetOnboarding") {
            hasOnboarded = false
        } else if ProcessInfo.processInfo.arguments.contains("-PocketSkipOnboarding") {
            hasOnboarded = true
        } else {
            hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        }
        selectedModelId = UserDefaults.standard.string(forKey: Self.selectedModelKey)
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
                let lazyRemote = LazyRemoteEngine { [weak live, hooks] in
                    guard let live else { return nil }
                    guard let peer = live.peers().first else { return nil }
                    guard let tokenData = hooks.keychainGet(key: peer.tokenRef),
                          let token = String(data: tokenData, encoding: .utf8),
                          let host = peer.addrs.first else {
                        return nil
                    }
                    let endpoint = PeerEndpoint(host: host, port: peer.port, fingerprint: peer.certSha256)
                    return PeerClient(endpoint: endpoint, token: token)
                }
                live.registerEngine(RoutingEngine(engines: [
                    PocketMLXEngine(),
                    AppleFoundationModelsEngine(),
                    lazyRemote,
                ]))
                core = live
                DiagnosticsLog.shared.append("AppModel: LiveCore initialized, RoutingEngine registered with MLX, AFM, and LazyRemoteEngine")
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
