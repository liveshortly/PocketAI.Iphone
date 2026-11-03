import BackgroundTasks
import Foundation
import Observation
import PocketKit

/// NET-22: the iPhone drives every chat sync with its paired Mac (the Mac is
/// server only). Triggers: a Mac coming online (connect / first good
/// heartbeat), a local write (debounced), a modest foreground timer, and a
/// `BGProcessingTask` catch-up. The Mac enforces Pro; a 403 parks auto-sync
/// for that Mac until the user flips the toggle or taps Sync now.
/// ponytail: near-live Mac->phone is the foreground timer - the Mac has no
/// "new ops" signal to the phone yet (needs a Rust heartbeat/SSE hint).
@Observable
@MainActor
final class ChatSync {
    static let shared = ChatSync()
    static let foregroundInterval: Duration = .seconds(60)
    static let debounce: Duration = .seconds(2)
    nonisolated static let backgroundTaskId = "app.getpocketai.chatsync"

    /// Chats with local changes the Mac hasn't received.
    private(set) var pendingConversationIds: Set<String> = []
    /// Keyed by `Peer.id`.
    private(set) var lastSyncedAt: [String: Date] = [:]
    /// Macs that answered 403 not_entitled (keyed by `Peer.id`).
    private(set) var notEntitled: Set<String> = []
    private(set) var isSyncing = false

    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    // MARK: - Toggle (per Mac, on by default)

    private static func enabledKey(_ peerId: String) -> String { "sync.chats.enabled.\(peerId)" }

    static func isEnabled(_ peer: Peer) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(peer.id)) as? Bool ?? true
    }

    func setEnabled(_ on: Bool, peer: Peer, core: CoreClient, hooks: PlatformHooks) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey(peer.id))
        notEntitled.remove(peer.id)
        refreshStatus(core: core)
        if on { Task { await syncNow(core: core, hooks: hooks) } }
    }

    // MARK: - Triggers

    /// Debounced: a burst of writes (a streamed reply, a rename) is one sync.
    func syncSoon(core: CoreClient, hooks: PlatformHooks) {
        refreshStatus(core: core)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await syncNow(core: core, hooks: hooks)
        }
    }

    /// Runs while the caller's task lives (foreground + online): syncs now,
    /// then every `foregroundInterval`, and after every local chat write.
    func runForeground(core: CoreClient, hooks: PlatformHooks) async {
        let writes = Task {
            for await _ in NotificationCenter.default.notifications(named: .pocketLocalChatWrite) {
                syncSoon(core: core, hooks: hooks)
            }
        }
        defer { writes.cancel() }
        while !Task.isCancelled {
            await syncNow(core: core, hooks: hooks)
            try? await Task.sleep(for: Self.foregroundInterval)
        }
    }

    /// Single-flight; a call that lands mid-sync runs one more pass after.
    /// `userInitiated` also retries a Mac that said not_entitled.
    func syncNow(core: CoreClient, hooks: PlatformHooks, userInitiated: Bool = false) async {
        if userInitiated { notEntitled.removeAll() }
        guard !isSyncing else { again = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            again = false
            for peer in core.peers() where shouldSync(peer) {
                guard let client = MacLink.client(for: peer, hooks: hooks) else { continue }
                await sync(peer, client: client, core: core)
            }
        } while again && !Task.isCancelled
        refreshStatus(core: core)
    }

    private func shouldSync(_ peer: Peer) -> Bool {
        let link = MacLink.shared.state(for: peer)
        return Self.isEnabled(peer) && !notEntitled.contains(peer.id)
            && link != .disconnected && link != .disconnectedByHost && link != .unreachable
    }

    private func sync(_ peer: Peer, client: PeerClient, core: CoreClient) async {
        let peerId = peer.id
        let result: Result<SyncReport, Error> = await withCheckedContinuation { done in
            // The FFI call blocks (and so does each transport request), so it
            // gets a plain GCD thread, never the main actor or the task pool.
            DispatchQueue.global(qos: .utility).async {
                done.resume(returning: Result { try PeerSyncTransport.sync(core: core, peerId: peerId, client: client) })
            }
        }
        switch result {
        case .success(let report):
            lastSyncedAt[peerId] = Date(timeIntervalSince1970: TimeInterval(report.syncedAt) / 1000)
        case .failure(let error):
            if case .NotEntitled? = error as? PocketError {
                notEntitled.insert(peerId)
            } else {
                DiagnosticsLog.shared.append("ChatSync: \(peer.name) failed: \(error)")
            }
        }
    }

    // MARK: - Status

    /// Outbox for every Mac this phone syncs with; also seeds last-synced
    /// from the core so it survives relaunch.
    func refreshStatus(core: CoreClient) {
        var pending = Set<String>()
        for peer in core.peers() where Self.isEnabled(peer) {
            let status = core.syncStatus(peerId: peer.id)
            pending.formUnion(status.pendingConversationIds)
            if let ms = status.lastSyncedAt {
                lastSyncedAt[peer.id] = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            }
        }
        if pending != pendingConversationIds { pendingConversationIds = pending }
    }

    /// The newest sync with any Mac, for the "last synced" copy.
    var lastSyncedAny: Date? { lastSyncedAt.values.max() }

    // MARK: - Background catch-up

    /// Must run before launch finishes (`PocketAIApp.init`).
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            scheduleBackgroundTask()
            let finished = Once()
            let work = Task { @MainActor in
                let model = AppModel.shared
                await ChatSync.shared.syncNow(core: model.core, hooks: model.hooks)
                if finished.claim() { task.setTaskCompleted(success: true) }
            }
            task.expirationHandler = {
                work.cancel()
                if finished.claim() { task.setTaskCompleted(success: false) }
            }
        }
    }

    /// Asked for on every trip to the background; iOS decides when.
    nonisolated static func scheduleBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// `setTaskCompleted` exactly once, whichever of done/expired comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
