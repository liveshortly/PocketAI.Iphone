import SwiftUI
import PocketKit
import PocketUI

/// UI-12: Redesigned Mac tab + pairing (`02` §7.4 S-MAC, §7.5 S-PAIR).
/// Features hardware illustration, step-by-step guidance cards, paired status card,
/// and QR pairing flow.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var peers: [Peer] = []
    @State private var showPairing = false
    @State private var showPairingPrimer = false
    @State private var peerToRevoke: Peer?
    /// User-typed `host[:port]` for this Mac — the only way to reach it over a
    /// VPN / mesh network (Tailscale MagicDNS), where Bonjour never answers.
    @State private var manualAddress = ""
    @State private var manualAddressError: String?
    /// A failed revoke left the Mac on screen with nothing said about it.
    @State private var revokeError: String?
    /// Result of the last reachability probe: nil before one has run, and
    /// `.some(nil)` once one has run and failed.
    @State private var lastRTT: TimeInterval??
    @State private var isProbing = false
    /// Whether we've already explained + triggered the Local Network prompt once.
    @AppStorage("perm.primedPairing") private var primedPairing = false

    var body: some View {
        NavigationStack {
            Group {
                if let peer = peers.first {
                    pairedView(peer)
                } else {
                    notPairedView
                }
            }
            .navigationTitle("Mac")
            .navigationBarTitleDisplayMode(.large)
            .background(PocketColor.bgCanvas)
            .task { reload() }
            .sheet(isPresented: $showPairing) {
                PairingFlowView { reload() }
            }
            .sheet(isPresented: $showPairingPrimer) {
                PermissionPrimer(
                    icon: "wifi",
                    title: "Find your Mac",
                    message: "PocketAI uses the camera to scan your Mac's pairing code and Local Network access to connect to it. Everything stays on your local network.",
                    continueLabel: "Continue",
                    onContinue: {
                        primedPairing = true
                        LocalNetworkPrimer.request()
                        showPairing = true
                    }
                )
            }
            .confirmationDialog(
                "Forget \(peerToRevoke?.name ?? "Mac")?",
                isPresented: Binding(get: { peerToRevoke != nil }, set: { if !$0 { peerToRevoke = nil } }),
                titleVisibility: .visible
            ) {
                // NET-22: keeping synced chats is the first, default choice.
                Button("Forget · Keep Synced Chats") {
                    if let peer = peerToRevoke { revoke(peer) }
                    peerToRevoke = nil
                }
                Button("Forget and Remove Chats from \(peerToRevoke?.name ?? "Mac")", role: .destructive) {
                    if let peer = peerToRevoke { revoke(peer, removeChats: true) }
                    peerToRevoke = nil
                }
                Button("Cancel", role: .cancel) { peerToRevoke = nil }
            } message: {
                Text("This removes the pairing. Chats synced from this Mac stay on this iPhone unless you remove them; nothing is deleted on the Mac. To pause without unpairing, use Disconnect instead. You can pair again anytime by scanning the code on your Mac.")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })
            ) {
                Button("OK", role: .cancel) { revokeError = nil }
            } message: {
                Text(revokeError ?? "")
            }
        }
    }

    // MARK: - Not Paired View

    private var notPairedView: some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s24) {
                // Hardware illustration card
                hardwareIllustration
                    .padding(.top, PocketSpacing.s12)

                VStack(spacing: PocketSpacing.s8) {
                    Text("Use your Mac's models from this iPhone")
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Pair over local Wi-Fi to run larger models using your Mac's unified memory. Everything stays on your devices.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The heading had no gutter, so it ran to the screen edges.
                .padding(.horizontal, PocketSpacing.gutterIphone)

                // Step cards
                VStack(spacing: PocketSpacing.s12) {
                    stepCard(
                        number: "1",
                        title: "Open PocketAI on your Mac",
                        subtitle: "Go to Devices → Pair iPhone to show your QR code."
                    )
                    stepCard(
                        number: "2",
                        title: "Scan the pairing code",
                        subtitle: "Point this iPhone camera at your Mac screen."
                    )
                }
                .padding(.horizontal, PocketSpacing.gutterIphone)

                // CTA Button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    startPairing()
                } label: {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Scan pairing code")
                            .font(.pocket(.headline))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PocketSpacing.s12)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
                .padding(.horizontal, PocketSpacing.gutterIphone)
                .padding(.top, PocketSpacing.s8)

                Link(destination: URL(string: "https://pocket.liveshortly.com")!) {
                    HStack(spacing: 4) {
                        Text("Don't have PocketAI on Mac? pocket.liveshortly.com")
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                    }
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                }
                .padding(.bottom, PocketSpacing.s24)
            }
        }
    }

    /// The card grows with its content instead of being pinned to a fixed
    /// height, and the connecting beams compress on narrow screens.
    private var hardwareIllustration: some View {
        HStack(spacing: PocketSpacing.s24) {
            VStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(PocketColor.textPrimary)
                Text("Mac")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            // Connecting beam with Spark Mark
            HStack(spacing: 4) {
                beam

                PocketMarkView(state: .thinking(tokPerSec: nil), size: 36)

                beam
            }

            VStack(spacing: 6) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 44))
                    .foregroundStyle(PocketColor.textPrimary)
                Text("iPhone")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PocketSpacing.s40)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PocketColor.bgRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(PocketColor.lineHairline)
        )
        .padding(.horizontal, PocketSpacing.gutterIphone)
    }

    private var beam: some View {
        Rectangle()
            .fill(PocketColor.lineStrong)
            .frame(maxWidth: 24)
            .frame(height: 2)
    }

    private func stepCard(number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s12) {
            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 28, height: 28)
                Text(number)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PocketColor.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                Text(subtitle)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            Spacer()
        }
        .padding(PocketSpacing.s16)
        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
        .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.lineHairline))
    }

    // MARK: - Paired View

    private func pairedView(_ peer: Peer) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                    HStack(spacing: PocketSpacing.s12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(PocketColor.accentSoft)
                                .frame(width: 48, height: 48)
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 24))
                                .foregroundStyle(PocketColor.accent)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                                .font(.pocket(.title))
                                .foregroundStyle(PocketColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(PocketColor.statusOk)
                                    .frame(width: 8, height: 8)
                                // Honest: pairing is a stored credential, not a
                                // live link — reachability shows when it's used.
                                Text("Paired")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.statusOk)
                            }
                        }
                    }

                    Divider()

                    if let addr = peer.addrs.first {
                        HStack {
                            Text("Network Address")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                            Spacer(minLength: PocketSpacing.s8)
                            Text(addr)
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textPrimary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(alignment: .top) {
                        Text("Status")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                        Spacer(minLength: PocketSpacing.s8)
                        // Wraps instead of truncating at large type.
                        Text(statusText(peer))
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, PocketSpacing.s8)
            }

            Section {
                let route = PeerAddressBook.shared.route(forHostId: peer.name)
                HStack(alignment: .top) {
                    Text("Route")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    Spacer(minLength: PocketSpacing.s8)
                    VStack(alignment: .trailing, spacing: PocketSpacing.s4) {
                        Text(route.title)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textPrimary)
                        if let addr = route.address {
                            Text("\(addr.host):\(String(addr.port))")
                                .font(.pocket(.mono))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text(route.detail)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let probe = lastRTT {
                    HStack {
                        Circle()
                            .fill(probe == nil ? PocketColor.statusBad : PocketColor.statusOk)
                            .frame(width: 8, height: 8)
                        Text(probe.map { "Responded in \(Int($0 * 1000)) ms" } ?? "No answer from this Mac")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Recovers a wedged link without un-pairing: the old
                // "Disconnect" was a revoke, so a hung connection could only
                // be escaped by scanning a QR code again.
                Button {
                    reconnect(peer)
                } label: {
                    HStack(spacing: PocketSpacing.s8) {
                        if isProbing {
                            PocketMarkView(state: .loading, size: 16)
                                .accessibilityHidden(true) // the adjacent text carries the status
                        }
                        Text(isProbing ? "Reconnecting…" : "Reconnect")
                    }
                }
                .disabled(isProbing)
            } header: {
                Text("Connection")
            } footer: {
                Text("Reconnect drops this session's discovered address and tests the Mac again. It does not un-pair, so nothing has to be scanned again.")
            }

            Section {
                TextField("mac.tailnet.ts.net or 100.64.0.3:\(peer.port)", text: $manualAddress)
                    .font(.pocket(.mono))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit { saveManualAddress(for: peer) }

                if let manualAddressError {
                    Text(manualAddressError)
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusBad)
                }

                HStack {
                    Button("Save") { saveManualAddress(for: peer) }
                    Spacer()
                    Button("Use discovered address", role: .destructive) {
                        manualAddress = ""
                        saveManualAddress(for: peer)
                    }
                    .disabled(manualAddress.isEmpty)
                }
                .font(.pocket(.callout))
            } header: {
                Text("Custom Address")
            } footer: {
                Text("Optional. Use your Mac's hostname (and port, if it isn't \(String(peer.port))) to reach it over a VPN or mesh network like Tailscale, where local discovery doesn't work. This address is preferred over the discovered one. The connection is still verified against your Mac's paired certificate.")
            }

            MacLinkSection(peer: peer)

            ChatSyncSection(peer: peer)

            Section("Mac Capabilities") {
                NavigationLink {
                    ModelsView(startOnMac: true, embedded: true)
                } label: {
                    SettingsRow(icon: "cpu", title: "Browse models on this Mac…", accessory: .none)
                }
            }

            Section {
                Button(role: .destructive) {
                    peerToRevoke = peer
                } label: {
                    Text("Forget this Mac")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } footer: {
                // Named for what it does. It revokes the pairing, so getting
                // back means scanning the Mac's QR code again — not the thing
                // to reach for when a connection is merely stuck.
                Text("Removes the pairing and this Mac's models. You'll need to scan its code again to reconnect. To just stop using this Mac for now, tap Disconnect above.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func statusText(_ peer: Peer) -> String {
        switch MacLink.shared.state(for: peer) {
        case .connected: return "Connected — its models appear in the model picker"
        case .unreachable: return "Not answering. Open PocketAI on your Mac."
        case .disconnected: return "Disconnected — pairing kept"
        case .disconnectedByHost: return "Your Mac disconnected this iPhone"
        case nil: return "Paired — its models appear in the model picker"
        }
    }

    private func startPairing() {
        // First run (or camera still undetermined): explain camera + local
        // network before the system prompts fire. Afterwards, go straight in.
        if !primedPairing || CameraPermissions.needsPrimer {
            showPairingPrimer = true
        } else {
            showPairing = true
        }
    }

    private func reload() {
        peers = model.core.peers()
        if let peer = peers.first {
            manualAddress = PeerAddressBook.shared.manualAddress(forHostId: peer.name)
                .map { "\($0.host):\($0.port)" } ?? ""
        }
    }

    /// Persists (or clears, when empty) the typed address for this Mac. Every
    /// `PeerClient` builder reads it through `PeerAddressBook.override`, so one
    /// write here redirects chat, catalog and reconnect alike.
    private func saveManualAddress(for peer: Peer) {
        let ok = PeerAddressBook.shared.setManualAddress(
            manualAddress, defaultPort: peer.port, forHostId: peer.name
        )
        manualAddressError = ok
            ? nil
            : "Enter a hostname or IP, optionally with :port — e.g. mac.tailnet.ts.net:\(peer.port)."
        if ok {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            reload()
        }
    }

    /// Drops this run's rediscovered address and re-tests the Mac. A manual
    /// address survives, since the user set it deliberately and off-LAN it is
    /// the only route that works.
    private func reconnect(_ peer: Peer) {
        isProbing = true
        lastRTT = nil
        PeerAddressBook.shared.clearDiscovered(forHostId: peer.name)
        let token = model.hooks.keychainGet(key: peer.tokenRef)
            .flatMap { String(data: $0, encoding: .utf8) }
        Task {
            var rtt: TimeInterval?
            if let token {
                let override = PeerAddressBook.shared.override(forHostId: peer.name)
                let endpoint = PeerEndpoint(
                    host: override?.host ?? peer.addrs.first ?? "",
                    port: override?.port ?? peer.port,
                    fingerprint: peer.certSha256
                )
                rtt = await PeerClient(endpoint: endpoint, token: token).measureRTT()
            }
            await MainActor.run {
                lastRTT = .some(rtt)
                isProbing = false
            }
        }
    }

    private func revoke(_ peer: Peer, removeChats: Bool = false) {
        do {
            // Local only: no tombstones, so the Mac keeps every chat.
            if removeChats { try model.core.removeSyncedChats(peerId: peer.id) }
            try model.core.revokePeer(id: peer.id)
            // A default model that lived on this Mac is gone with it; leaving
            // the id selected made Home report "that Mac isn't available" and
            // sent every new chat at a route that can no longer work.
            if RemoteEngine.peerId(from: model.selectedModelId ?? "") == peer.id {
                model.selectedModelId = nil
            }
        } catch {
            revokeError = "Couldn't forget \(peer.name): \(error.localizedDescription)"
        }
        reload()
    }
}

/// S-PAIR: QR Scanner -> Connecting -> Waiting -> Success.
private struct PairingFlowView: View {
    let onPaired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    private enum Step { case scan, manualEntry, connecting, waitingForApproval, success, error(String) }
    @State private var step = Step.scan
    @State private var manualCode = ""
    @State private var offer: PairingOffer?
    /// Kept so Cancel / dismiss actually stop the pairing work — otherwise the
    /// poll loop spins forever and onPaired can fire after the sheet is gone.
    @State private var pairTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scan:
                    ZStack(alignment: .bottom) {
                        QRScannerView { code in handle(code: code) }
                        Button("Enter code manually") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            step = .manualEntry
                        }
                        .font(.pocket(.callout))
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, PocketSpacing.s16)
                        .padding(.vertical, PocketSpacing.s8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, PocketSpacing.s40)
                    }
                case .manualEntry:
                    VStack(spacing: PocketSpacing.s20) {
                        Text("Enter the host and code shown on your Mac")
                            .font(.pocket(.body))
                            .foregroundStyle(PocketColor.textPrimary)
                            .multilineTextAlignment(.center)

                        TextField("host:port#code", text: $manualCode)
                            .font(.pocket(.mono))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, PocketSpacing.gutterIphone)

                        Button("Connect") {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            handle(code: manualCode)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                        .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, PocketSpacing.s40)
                case .connecting:
                    VStack(spacing: PocketSpacing.s20) {
                        PocketMarkView(state: .loading, size: 72)
                        Text("Connecting to \(offer?.hostName ?? "your Mac")…")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                case .waitingForApproval:
                    VStack(spacing: PocketSpacing.s20) {
                        PocketMarkView(state: .loading, size: 72)
                        Text("Waiting for you to allow on your Mac")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Check the prompt on your Mac's screen.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                case .success:
                    VStack(spacing: PocketSpacing.s20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(PocketColor.statusOk)
                        Text("Paired with Mac")
                            .font(.pocket(.title))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("Your Mac's models now appear in the model picker.")
                            .font(.pocket(.body))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, PocketSpacing.gutterIphone)

                        // Named at the moment of pairing, because this is the
                        // only time the user is thinking about how the two
                        // machines reach each other. Finding out later, when
                        // it stops working away from home, is too late.
                        VStack(spacing: PocketSpacing.s8) {
                            HStack(spacing: PocketSpacing.s8) {
                                Image(systemName: "wifi")
                                    .foregroundStyle(PocketColor.accent)
                                Text("Connected over your local network")
                                    .font(.pocket(.callout))
                                    .foregroundStyle(PocketColor.textPrimary)
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            Text("This works while both are on this Wi-Fi. To reach this Mac from anywhere, add its VPN or mesh hostname — Tailscale, Tailnet, WireGuard — under Mac ▸ Custom Address.")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.chip))
                        .padding(.horizontal, PocketSpacing.gutterIphone)

                        // Named for what it does: it closes the sheet. It never
                        // opened a model picker, and the paired screen behind it
                        // carries "Browse models on this Mac…".
                        Button("Done") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                        .padding(.top, PocketSpacing.s8)
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                case .error(let message):
                    VStack(spacing: PocketSpacing.s20) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(PocketColor.statusBad)
                        Text(message)
                            .font(.pocket(.body))
                            .foregroundStyle(PocketColor.textPrimary)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            step = .scan
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketColor.accent)
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                }
            }
            .navigationTitle("Pair Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelPairing()
                        dismiss()
                    }
                }
            }
            .onDisappear { cancelPairing() }
        }
    }

    private func cancelPairing() {
        pairTask?.cancel()
        pollTask?.cancel()
        pairTask = nil
        pollTask = nil
    }

    private func handle(code: String) {
        step = .connecting
        guard let offer = try? model.core.parsePairingQr(code) else {
            step = .error("That isn't a PocketAI pairing code. On your Mac, open Devices ▸ Pair iPhone and scan the code shown there.")
            return
        }
        self.offer = offer

        guard let liveCore = model.core as? LiveCore else {
            // Only the explicit preview harness may fake a pairing; a degraded
            // real app (core failed to open) gets an honest error instead.
            if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
                step = .waitingForApproval
                let approved = ApprovedPairing(
                    hostId: offer.hostId, hostName: offer.hostName,
                    certFingerprint: offer.certFingerprint,
                    addr: offer.addrs.first ?? "", port: offer.port,
                    deviceId: UUID().uuidString, tokenKeychainRef: "peer-\(offer.hostId)"
                )
                _ = try? model.core.savePeer(approved)
                step = .success
                onPaired()
            } else {
                step = .error("Pairing isn't available right now — the on-device engine didn't start. Restart the app and try again.")
            }
            return
        }

        let coordinator = PairingCoordinator(core: liveCore.rawCore, keychain: model.hooks)
        pairTask = Task { await coordinator.pair(qr: code) }
        pollTask = Task {
            // Bounded: 2 minutes at 200ms ticks, then an honest timeout error.
            for _ in 0..<600 {
                if Task.isCancelled { return }
                switch coordinator.phase {
                case .waitingForApproval:
                    step = .waitingForApproval
                case .approved:
                    step = .success
                    onPaired()
                    return
                case .denied:
                    step = .error("Pairing was denied on your Mac.")
                    return
                case .failed(let message):
                    // MAC-21: the coordinator names the step that failed.
                    step = .error(message)
                    return
                case .idle, .connecting:
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            pairTask?.cancel()
            step = .error("Pairing timed out. Make sure your Mac is awake and on the same Wi-Fi, then try again.")
        }
    }
}

/// NET-17: Disconnect / Connect without unpairing. Disconnect stops all
/// traffic to the Mac (and tells it); Connect resumes, and also lifts a
/// Disconnect the Mac made.
private struct MacLinkSection: View {
    let peer: Peer
    @Environment(AppModel.self) private var model
    @State private var isConnecting = false
    @State private var connectFailed = false

    private var state: MacLink.State? { MacLink.shared.state(for: peer) }
    private var isOff: Bool { state == .disconnected || state == .disconnectedByHost }

    var body: some View {
        Section {
            if state == .disconnectedByHost {
                Text("Your Mac disconnected this iPhone.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.statusWarn)
            }
            if connectFailed {
                Text("No answer. Open PocketAI on your Mac.")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.statusBad)
            }
            Button(isOff ? (isConnecting ? "Connecting…" : "Connect") : "Disconnect") {
                isOff ? connect() : MacLink.shared.disconnect(peer, hooks: model.hooks)
            }
            .disabled(isConnecting)
        } footer: {
            Text(isOff
                ? "Connect to use this Mac's models again. Nothing has to be scanned."
                : "Disconnect stops this iPhone from using the Mac until you connect again. The pairing is kept.")
        }
    }

    private func connect() {
        isConnecting = true
        connectFailed = false
        Task {
            let ok = await MacLink.shared.connect(peer, hooks: model.hooks)
            connectFailed = !ok
            isConnecting = false
        }
    }
}
