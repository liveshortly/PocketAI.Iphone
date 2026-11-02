import Foundation
import PocketLiveShortly

/// Finds agent sessions waiting on a decision and notifies once per request
/// (S-NOTIF "Approval needed", design system §7.10).
///
/// This runs when the app comes to the foreground, never in the background:
/// iOS suspends us within seconds of leaving and PocketAI runs no push
/// provider, so a probe raised while the phone was asleep can only be found on
/// return. The notification copy says exactly that rather than pretending the
/// phone was reachable.
@MainActor
final class LSApprovalWatcher {
    static let shared = LSApprovalWatcher()

    /// Event ids of probes already announced, so re-opening the app does not
    /// re-announce the same pending request.
    private var announced: Set<String> = []
    private var inFlight = false

    private init() {}

    func check(account: LSAccountModel) async {
        guard let client = account.client, account.isConnected else { return }
        // Foregrounding can fire more than once in quick succession.
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let live: [LSSession]
        do {
            live = try await client.sessions(scope: "mine", limit: 50).filter(\.isLive)
        } catch {
            // Silent: the sessions list itself shows the state, and a failed
            // poll is not worth a notification.
            return
        }

        for session in live {
            guard let probe = await pendingProbe(client: client, sessionID: session.id) else {
                continue
            }
            guard !announced.contains(probe.id) else { continue }
            announced.insert(probe.id)
            Notifier.shared.approvalNeeded(
                sessionTitle: session.title.isEmpty ? "A session" : session.title,
                sessionId: session.id)
        }
    }

    /// The newest unanswered probe. Same rule as the session views: walking
    /// back from the newest event, a `viewer_decision`, `prompt` or `response`
    /// means the probe before it was already settled, so only an
    /// `input_requested` reached first is still open. Kept identical on
    /// purpose — a notification that disagrees with the banner is worse than
    /// no notification.
    private func pendingProbe(client: LSClient, sessionID: String) async -> LSEvent? {
        let detail: LSSessionDetail
        do {
            detail = try await client.session(sessionID)
        } catch {
            return nil
        }
        for event in detail.events.reversed() {
            switch event.eventType {
            case "viewer_decision", "prompt", "response": return nil
            case "input_requested": return event
            default: continue
            }
        }
        return nil
    }
}
