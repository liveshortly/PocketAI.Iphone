import Foundation
import Observation
import PocketKit
import UIKit

/// NET-17/18: this phone's live link to its paired Macs. The Mac can't dial
/// the phone, so while the app is foreground the phone renews a lease with a
/// heartbeat every 15 s; three misses mark the Mac Unreachable and stop the
/// beats until the network changes or the app comes back to the foreground.
/// Going to the background sends a goodbye so the Mac shows Idle at once.
@Observable
@MainActor
final class MacLink {
    enum State: Equatable {
        case connected
        /// Heartbeat failed 3x - "Open PocketAI on your Mac".
        case unreachable
        /// The user tapped Disconnect on this phone.
        case disconnected
        /// The Mac disconnected this phone.
        case disconnectedByHost
    }

    static let shared = MacLink()
    static let heartbeatInterval: Duration = .seconds(15)
    static let maxMissedBeats = 3

    /// Keyed by `Peer.id`; nil until the first heartbeat answers.
    private(set) var states: [String: State] = [:]

    func state(for peer: Peer) -> State? {
        if PeerAddressBook.shared.isUserDisconnected(fingerprint: peer.certSha256) { return .disconnected }
        return states[peer.id]
    }

    /// Same endpoint resolution every caller uses: a corrected (manual or
    /// Bonjour) address wins over the one recorded at pairing.
    static func client(for peer: Peer, hooks: PlatformHooks) -> PeerClient? {
        guard let token = hooks.keychainGet(key: peer.tokenRef)
            .flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        let override = PeerAddressBook.shared.override(forHostId: peer.name)
        guard let host = override?.host ?? peer.addrs.first else { return nil }
        return PeerClient(
            endpoint: PeerEndpoint(host: host, port: override?.port ?? peer.port, fingerprint: peer.certSha256),
            token: token)
    }

    /// Runs while the caller's task lives (foreground + online); restart it to
    /// reset the miss counters.
    func runHeartbeats(core: CoreClient, hooks: PlatformHooks) async {
        var misses: [String: Int] = [:]
        while !Task.isCancelled {
            for peer in core.peers() where shouldBeat(peer, misses: misses) {
                guard let client = beatClient(for: peer, hooks: hooks) else { continue }
                do {
                    try await client.heartbeat()
                    misses[peer.id] = 0
                    states[peer.id] = .connected
                } catch PeerClientError.disconnectedByHost {
                    // Probe once per foreground run; the Mac may lift it.
                    states[peer.id] = .disconnectedByHost
                    misses[peer.id] = Self.maxMissedBeats
                } catch PeerClientError.disconnected {
                    // Disconnected mid-loop; nothing to record.
                } catch {
                    let count = misses[peer.id, default: 0] + 1
                    misses[peer.id] = count
                    if count >= Self.maxMissedBeats { states[peer.id] = .unreachable }
                }
            }
            try? await Task.sleep(for: Self.heartbeatInterval)
        }
    }

    /// One client per Mac for the beats: each `PeerClient` owns a URLSession,
    /// and a new one every 15 s would pile up.
    @ObservationIgnored private var beatClients: [String: PeerClient] = [:]

    private func beatClient(for peer: Peer, hooks: PlatformHooks) -> PeerClient? {
        guard let fresh = Self.client(for: peer, hooks: hooks) else { return nil }
        if let cached = beatClients[peer.id], cached.endpoint == fresh.endpoint, cached.token == fresh.token {
            return cached
        }
        beatClients[peer.id] = fresh
        return fresh
    }

    private func shouldBeat(_ peer: Peer, misses: [String: Int]) -> Bool {
        state(for: peer) != .disconnected && misses[peer.id, default: 0] < Self.maxMissedBeats
    }

    /// Best-effort goodbye on `.background`; iOS grants a few seconds, enough
    /// for one request per Mac.
    func sayGoodbye(core: CoreClient, hooks: PlatformHooks) {
        let clients = core.peers()
            .filter { state(for: $0) != .disconnected }
            .compactMap { Self.client(for: $0, hooks: hooks) }
        guard !clients.isEmpty, goodbyeTask == .invalid else { return }
        goodbyeTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.endGoodbye() }
        }
        Task {
            for client in clients { try? await client.closeSession(byUser: false) }
            endGoodbye()
        }
    }

    @ObservationIgnored private var goodbyeTask = UIBackgroundTaskIdentifier.invalid

    private func endGoodbye() {
        guard goodbyeTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(goodbyeTask)
        goodbyeTask = .invalid
    }

    /// Stop talking to this Mac now, keep the pairing. Cancels its in-flight
    /// requests and tells the Mac (best-effort) so it shows Disconnected.
    func disconnect(_ peer: Peer, hooks: PlatformHooks) {
        PeerAddressBook.shared.setUserDisconnected(true, fingerprint: peer.certSha256)
        states[peer.id] = nil
        guard let client = Self.client(for: peer, hooks: hooks) else { return }
        Task { try? await client.closeSession(byUser: true) }
    }

    /// Talk to this Mac again (also lifts a Disconnect the Mac made). Returns
    /// false when the Mac didn't answer.
    @discardableResult
    func connect(_ peer: Peer, hooks: PlatformHooks) async -> Bool {
        PeerAddressBook.shared.setUserDisconnected(false, fingerprint: peer.certSha256)
        guard let client = Self.client(for: peer, hooks: hooks) else { return false }
        do {
            try await client.openSession()
            try await client.heartbeat()
            states[peer.id] = .connected
            return true
        } catch {
            states[peer.id] = .unreachable
            return false
        }
    }
}
