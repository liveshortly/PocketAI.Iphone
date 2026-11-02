import PocketUI
import SwiftUI
import UIKit

/// Settings → Notifications (S-NOTIF, design system §7.8/§7.10).
///
/// Three switches and one honest sentence. The sentence is the point: on iOS
/// every one of these is a *local* notification from a running app, so an
/// approval raised while the phone is asleep is found when PocketAI next
/// opens, not pushed. Saying so here is cheaper than a support thread, and
/// §7.10 forbids implying otherwise.
struct NotificationSettingsView: View {
    @State private var notifier = Notifier.shared
    /// Shown before the one-shot system prompt, never instead of it.
    @State private var showPrimer = false

    var body: some View {
        List {
            Section {
                switch notifier.isAuthorized {
                case .some(true):
                    ForEach(Notifier.Kind.allCases, id: \.rawValue) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                    .font(.pocket(.body))
                                    .foregroundStyle(PocketColor.textPrimary)
                                Text(kind.detail)
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textTertiary)
                            }
                        }
                        .accessibilityIdentifier("notify_toggle_\(kind.rawValue)")
                    }
                case .some(false):
                    // Dead switches would be a lie; send them where the grant
                    // actually lives.
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Text("Notifications are off for PocketAI in iOS Settings.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                        Button("Open iOS Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                                return
                            }
                            UIApplication.shared.open(url)
                        }
                        .font(.pocket(.footnote))
                    }
                case nil:
                    Button("Turn on notifications") { showPrimer = true }
                        .accessibilityIdentifier("notify_enable_button")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(
                    "These are local notifications from the running app. PocketAI has no server "
                    + "pushing to your phone, so an approval requested while PocketAI is closed "
                    + "appears when you open it — not while the phone is asleep."
                )
                .font(.pocket(.caption))
            }

            Section {
                Text(
                    "Everything here is also visible in the app: downloads in Models, replies in "
                    + "the chat, approvals in the session. Declining notifications hides nothing."
                )
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .navigationTitle("Notifications")
        .task { await notifier.refreshAuthorization() }
        .sheet(isPresented: $showPrimer) {
            PermissionPrimer(
                icon: "bell.badge",
                title: "Notify you when things finish",
                message:
                    "PocketAI can tell you when a model finishes downloading, when a long reply "
                    + "is ready, and when an agent session is waiting on your approval.\n\n"
                    + "These come from the app while it is running — nothing is sent to a server, "
                    + "and your phone is never reached while PocketAI is closed.",
                continueLabel: "Continue"
            ) {
                Task { await notifier.requestAuthorization() }
            }
        }
    }

    private func binding(for kind: Notifier.Kind) -> Binding<Bool> {
        Binding(
            get: { notifier.isEnabled(kind) },
            set: { notifier.setEnabled(kind, $0) })
    }
}
