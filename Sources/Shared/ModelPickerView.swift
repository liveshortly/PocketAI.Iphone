import PocketKit
import PocketUI
import SwiftUI

/// Shared model picker (§5.3/§11.1) used by Settings (default), Home, and a
/// chat's per-turn choice. Scope is explicit in the heading. Lists only
/// chat-capable targets: On this iPhone, Apple Intelligence (built-in), and
/// named paired Macs. Voice/image-generation/embedding models are not chat
/// choices and never appear here.
struct ModelPickerView: View {
    enum Scope: Equatable {
        case defaultModel
        case conversation(id: String)

        var heading: String {
            switch self {
            case .defaultModel: return "Default model"
            case .conversation: return "Model for this chat"
            }
        }

        var footer: String {
            switch self {
            case .defaultModel: return "Used for new chats. Existing chats keep their selected model."
            case .conversation: return "Changes the model for this conversation only. History is preserved."
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let scope: Scope
    /// Currently selected id (for the checkmark). For a conversation this is the
    /// bound model; for the default scope it's `selectedModelId`.
    var selectedId: String?
    /// Commits a chosen chat-capable model id. The caller persists it (default
    /// preference or `setConversationModel`) and updates its own state.
    var onPicked: (String) -> Void

    @State private var installed: [CatalogEntry] = []
    @State private var remote: [(peer: Peer, entries: [RemoteCatalogEntry])] = []

    private var appleAvailable: Bool { AppleFoundationModelsEngine.isAvailable }

    var body: some View {
        List {
            // On this iPhone — installed, chat-capable (text/vision) only.
            if !installed.isEmpty {
                Section("On this iPhone") {
                    ForEach(installed, id: \.manifest.id) { entry in
                        row(id: entry.manifest.id,
                            name: ModelNaming.short(entry.manifest.displayName),
                            detail: capabilityLine(entry.manifest))
                    }
                }
            }

            // Apple Intelligence — built-in, no download. Shown only when ready.
            if appleAvailable {
                Section("Apple Intelligence") {
                    row(id: AppleFoundationModelsEngine.modelId,
                        name: "Apple Intelligence",
                        detail: "Built in · On this iPhone")
                }
            }

            // Named paired Macs — remote chat-capable models.
            ForEach(remote, id: \.peer.id) { pair in
                Section(pair.peer.name) {
                    ForEach(pair.entries, id: \.manifest.id) { entry in
                        let remoteId = "mac:\(pair.peer.id)/\(entry.manifest.id)"
                        row(id: remoteId,
                            name: ModelNaming.short(entry.manifest.displayName),
                            detail: "\(entry.manifest.family) · \(pair.peer.name)")
                    }
                }
            }

            if installed.isEmpty && !appleAvailable && remote.isEmpty {
                Section {
                    VStack(spacing: PocketSpacing.s8) {
                        Text("No chat models yet")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("Download a model in Models, or pair your Mac.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PocketSpacing.s24)
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                NavigationLink("Manage models") { ModelsView(embedded: true) }
            } footer: {
                Text(scope.footer)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(scope.heading)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            await reloadRemote()
        }
    }

    private func row(id: String, name: String, detail: String) -> some View {
        Button {
            onPicked(id)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dismiss()
        } label: {
            HStack(spacing: PocketSpacing.s12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.pocket(.body)).foregroundStyle(PocketColor.textPrimary)
                    Text(detail).font(.pocket(.caption)).foregroundStyle(PocketColor.textSecondary)
                }
                Spacer()
                if selectedId == id {
                    Image(systemName: "checkmark")
                        .font(.pocket(.body).weight(.semibold))
                        .foregroundStyle(PocketColor.accent)
                }
            }
        }
        .accessibilityAddTraits(selectedId == id ? .isSelected : [])
    }

    /// Chat-capable = text or vision. Excludes embedding/voice/image-generation.
    private func isChatCapable(_ manifest: ModelManifest) -> Bool {
        manifest.modalities.contains(.text) || manifest.modalities.contains(.vision)
    }

    private func capabilityLine(_ manifest: ModelManifest) -> String {
        var caps: [String] = []
        if manifest.modalities.contains(.text) { caps.append("Text") }
        if manifest.modalities.contains(.vision) { caps.append("Vision") }
        return caps.isEmpty ? manifest.family : caps.joined(separator: " + ")
    }

    private func reload() {
        installed = model.core
            .catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
            .filter { $0.state == .installed && isChatCapable($0.manifest) }
    }

    /// Remote chat models per paired Mac (best-effort: an unreachable Mac just
    /// contributes no section — the picker never blocks or errors on it).
    private func reloadRemote() async {
        var result: [(peer: Peer, entries: [RemoteCatalogEntry])] = []
        for peer in model.core.peers() {
            guard let token = model.hooks.keychainGet(key: peer.tokenRef)
                .flatMap({ String(data: $0, encoding: .utf8) }) else { continue }
            let override = PeerAddressBook.shared.override(forHostId: peer.name)
            guard let host = override?.host ?? peer.addrs.first else { continue }
            let endpoint = PeerEndpoint(host: host, port: override?.port ?? peer.port, fingerprint: peer.certSha256)
            let client = RemoteCatalogClient(peerClient: PeerClient(endpoint: endpoint, token: token))
            guard let entries = try? await client.catalog() else { continue }
            // Remote manifests carry no modality info; installed on the Mac is
            // the honest filter — the Mac routes/validates the actual request.
            let chat = entries.filter { $0.state == .installed }
            if !chat.isEmpty { result.append((peer: peer, entries: chat)) }
        }
        remote = result
    }
}
