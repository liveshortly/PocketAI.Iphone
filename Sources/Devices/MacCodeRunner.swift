import Foundation
import PocketKit

/// AGT-13 stage 2: lets the model's `run_on_mac` tool reach the paired Mac.
/// "Available" means a Mac is paired and the heartbeat says it is connected
/// right now; the run goes over the same pinned-TLS, bearer-token channel as
/// chat sync.
final class MacCodeRunner: MacCodeRunning, @unchecked Sendable {
    private let core: CoreClient
    private let hooks: PlatformHooks

    init(core: CoreClient, hooks: PlatformHooks) {
        self.core = core
        self.hooks = hooks
    }

    /// Core reads this from its reply worker thread, never the main thread;
    /// hop to main for `MacLink`'s state.
    var isMacConnected: Bool {
        let read = { MainActor.assumeIsolated { self.connectedPeer() != nil } }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    @MainActor private func connectedPeer() -> Peer? {
        core.peers().first { MacLink.shared.state(for: $0) == .connected }
    }

    func run(language: String, code: String, timeoutMs: UInt32) async -> ToolRunResult {
        let client = await MainActor.run { () -> PeerClient? in
            connectedPeer().flatMap { MacLink.client(for: $0, hooks: hooks) }
        }
        guard let client else { return MacRunReply.failure(MacRunReply.unreachable) }
        return await client.runOnMac(language: language, code: code, timeoutMs: timeoutMs)
    }

    /// Settings → Tools: a Mac is paired (connected or not).
    @MainActor static func hasPairedMac(_ core: CoreClient) -> Bool { !core.peers().isEmpty }
}
