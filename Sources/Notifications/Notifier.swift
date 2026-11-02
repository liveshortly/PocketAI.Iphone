import Foundation
import Observation
import UserNotifications

/// Local notifications, iPhone side (S-NOTIF, design system §7.10).
///
/// Everything here is a *local* notification posted by a process that is
/// already running. iOS suspends a backgrounded app within seconds and APNs
/// needs a provider server PocketAI does not run, so a sleeping iPhone cannot
/// be reached. The copy never implies otherwise — that is the one dishonest
/// promise a product built on honest instruments must not make, so
/// "approval needed" says plainly that it surfaced on opening the app.
///
/// Every type has an in-app equivalent (the models list, the transcript, the
/// session view), so declining the permission hides nothing.
@MainActor
@Observable
public final class Notifier {
    public static let shared = Notifier()

    /// The notification types, each independently switchable in Settings.
    public enum Kind: String, CaseIterable, Sendable {
        case downloadFinished
        case replyFinished
        case approvalNeeded

        public var title: String {
            switch self {
            case .downloadFinished: return "Download finished or failed"
            case .replyFinished: return "Reply finished"
            case .approvalNeeded: return "Approval needed"
            }
        }

        public var detail: String {
            switch self {
            case .downloadFinished:
                return "When a model finishes downloading, or can't."
            case .replyFinished:
                return "When a long reply completes while you're elsewhere in the app."
            case .approvalNeeded:
                return "When an agent session is waiting on you. Arrives when you open "
                    + "PocketAI — a sleeping iPhone can't be reached."
            }
        }

        var defaultsKey: String { "notify.\(rawValue)" }
    }

    /// nil until asked. Mirrors `UNAuthorizationStatus` without leaking it to
    /// callers that only need to know whether to offer the switches.
    public private(set) var isAuthorized: Bool?

    private let center = UNUserNotificationCenter.current()
    private let delegate = NotifierDelegate()

    private init() {
        center.delegate = delegate
    }

    // MARK: - Per-type switches

    public func isEnabled(_ kind: Kind) -> Bool {
        // Default on: the switch gates a notification the user already granted
        // permission for, and all three are consequential, never nags.
        UserDefaults.standard.object(forKey: kind.defaultsKey) as? Bool ?? true
    }

    public func setEnabled(_ kind: Kind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: kind.defaultsKey)
    }

    // MARK: - Authorization

    /// Current status, without prompting. Call before showing the Settings
    /// switches so a denied app says so instead of offering dead toggles.
    public func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .denied:
            isAuthorized = false
        case .notDetermined:
            isAuthorized = nil
        @unknown default:
            isAuthorized = nil
        }
    }

    /// Asks iOS for permission. Call this only after the in-app primer has
    /// explained why (§7.10: never cold) — the system prompt is one-shot.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge]))
            ?? false
        isAuthorized = granted
        return granted
    }

    // MARK: - Posting

    public func downloadFinished(modelName: String) {
        post(
            .downloadFinished, title: "Model ready",
            body: "\(modelName) finished downloading.", threadId: "downloads")
    }

    public func downloadFailed(modelName: String, reason: String) {
        post(
            .downloadFinished, title: "Download failed",
            body: "\(modelName) couldn't finish: \(reason)", threadId: "downloads")
    }

    public func replyFinished(chatTitle: String, conversationId: String) {
        post(
            .replyFinished, title: "Reply ready",
            body: "\(chatTitle) finished generating.",
            // One thread per conversation, so a busy chat collapses instead of
            // stacking.
            threadId: "chat.\(conversationId)")
    }

    public func approvalNeeded(sessionTitle: String, sessionId: String) {
        post(
            .approvalNeeded, title: "Approval needed",
            body: "\(sessionTitle) is waiting on you — it asked while PocketAI was closed.",
            threadId: "session.\(sessionId)")
    }

    private func post(_ kind: Kind, title: String, body: String, threadId: String) {
        guard isEnabled(kind) else { return }
        Task {
            // Never prompts on its own: an app that was never granted
            // permission silently posts nothing, and the in-app surface for
            // this event carries it instead.
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = threadId
            try? await center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Shows our own notifications while the app is frontmost too — without this
/// iOS drops them, and "finished while you were on another screen" is exactly
/// the foreground case §7.10 names.
private final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .sound])
    }
}
