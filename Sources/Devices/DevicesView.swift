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
                "Disconnect \(peerToRevoke?.name ?? "Mac")?",
                isPresented: Binding(get: { peerToRevoke != nil }, set: { if !$0 { peerToRevoke = nil } }),
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    if let peer = peerToRevoke {
                        revoke(peer)
                    }
                    peerToRevoke = nil
                }
                Button("Cancel", role: .cancel) { peerToRevoke = nil }
            } message: {
                Text("You can pair again anytime by scanning the code on your Mac.")
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

                Link(destination: URL(string: "https://getpocketai.app")!) {
                    HStack(spacing: 4) {
                        Text("Don't have PocketAI on Mac? getpocketai.app")
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

                PocketMarkView(state: .working(tokPerSec: nil), size: 36)

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
                        Text("Paired — its models appear in the model picker")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textPrimary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, PocketSpacing.s8)
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

            Section("Mac Capabilities") {
                NavigationLink {
                    ModelsView(startOnMac: true)
                } label: {
                    SettingsRow(icon: "cpu", title: "Browse models on this Mac…", accessory: .navigation)
                }
            }

            Section {
                Button(role: .destructive) {
                    peerToRevoke = peer
                } label: {
                    Text("Disconnect Mac")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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

    private func revoke(_ peer: Peer) {
        try? model.core.revokePeer(id: peer.id)
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

                        Button("Choose a Mac model") {
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
            step = .error("Mac not reachable. Make sure both are on the same Wi-Fi, or enter the address.")
            return
        }
        self.offer = offer

        guard let liveCore = model.core as? LiveCore else {
            // Only the explicit preview harness may fake a pairing; a degraded
            // real app (core failed to open) gets an honest error instead.
            if ProcessInfo.processInfo.arguments.contains("-PocketPreviewCore") {
                step = .waitingForApproval
                let approved = ApprovedPairing(
                    hostId: offer.hostId, certFingerprint: offer.certFingerprint,
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
                    step = .error("Mac not reachable. Make sure both are on the same Wi-Fi, or enter the address. (\(message))")
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
