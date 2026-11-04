import PocketKit
import PocketUI
import SwiftUI

/// NET-22: "Sync chats with <Mac>" on Devices › Mac. On by default; the Pro
/// line appears only after the Mac declined (licensing is enforced there).
struct ChatSyncSection: View {
    let peer: Peer
    @Environment(AppModel.self) private var model
    @State private var isOn = true

    private var sync: ChatSync { ChatSync.shared }

    var body: some View {
        Section {
            Toggle("Sync chats with \(peer.name)", isOn: $isOn)
                .tint(PocketColor.accent)
                .accessibilityIdentifier("devices_sync_chats_toggle")
                .onChange(of: isOn) { _, on in
                    sync.setEnabled(on, peer: peer, core: model.core, hooks: model.hooks)
                }
        } footer: {
            Text(footer)
        }
        .onAppear { isOn = ChatSync.isEnabled(peer) }
    }

    private var footer: String {
        if !isOn { return "Chats stay on this iPhone only." }
        if sync.syncDisabled.contains(peer.id) {
            return "Sync is off on \(peer.name). Turn on Sync chats for this iPhone there, under Devices. Your chats stay on this iPhone until then."
        }
        if sync.notEntitled.contains(peer.id) {
            return "Chat sync isn't available with this Mac yet. Your chats stay on this iPhone until then."
        }
        guard let last = sync.lastSyncedAt[peer.id] else {
            return "Chats sync both ways while PocketAI is open on this iPhone and your Mac is reachable."
        }
        return "Last synced \(last.formatted(date: .omitted, time: .shortened)). Chats sync both ways while PocketAI is open."
    }
}

/// Quiet line on a chat whose changes haven't reached the Mac yet.
struct ChatSyncNote: View {
    let conversationId: String

    var body: some View {
        if ChatSync.shared.pendingConversationIds.contains(conversationId) {
            Text(Self.text(lastSynced: ChatSync.shared.lastSyncedAny))
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
                .accessibilityIdentifier("chat_sync_note")
        }
    }

    static func text(lastSynced: Date?) -> String {
        guard let lastSynced else { return "Not synced yet" }
        return "Not synced · last synced \(lastSynced.formatted(date: .omitted, time: .shortened))"
    }
}

/// Per-chat dot in the chat list: shown only while the chat waits to sync.
struct ChatSyncDot: View {
    let conversationId: String

    var body: some View {
        if ChatSync.shared.pendingConversationIds.contains(conversationId) {
            Circle()
                .fill(PocketColor.statusWarn)
                .frame(width: PocketSpacing.s8, height: PocketSpacing.s8)
                .accessibilityLabel("Not synced")
        }
    }
}

private let previewPeer = Peer(
    id: "preview-mac", name: "Studio Mac", certSha256: "preview", addrs: ["192.168.1.5"],
    port: 7480, tokenRef: "preview", pairedAt: 0, lastSeenAt: nil)

private struct ChatSyncPreview: View {
    var body: some View {
        List {
            ChatSyncSection(peer: previewPeer)
            Section {
                Text(ChatSyncNote.text(lastSynced: Date(timeIntervalSince1970: 1_762_000_000)))
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .environment(AppModel())
    }
}

#Preview("Light") { ChatSyncPreview() }
#Preview("Dark") { ChatSyncPreview().preferredColorScheme(.dark) }
#Preview("AX3") { ChatSyncPreview().environment(\.dynamicTypeSize, .accessibility3) }
