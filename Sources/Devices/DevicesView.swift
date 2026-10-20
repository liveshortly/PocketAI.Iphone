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
    @State private var peerToRevoke: Peer?

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

                    Text("Pair over local Wi-Fi to run larger models using your Mac's unified memory. Everything stays on your devices.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, PocketSpacing.s16)
                }

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
                    showPairing = true
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

    private var hardwareIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PocketColor.bgRaised)
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(PocketColor.lineHairline))
                .frame(height: 160)

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
                    Rectangle()
                        .fill(PocketColor.lineStrong)
                        .frame(width: 24, height: 2)

                    PocketMarkView(state: .working(tokPerSec: nil), size: 36)

                    Rectangle()
                        .fill(PocketColor.lineStrong)
                        .frame(width: 24, height: 2)
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
        }
        .padding(.horizontal, PocketSpacing.gutterIphone)
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

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(PocketColor.statusOk)
                                    .frame(width: 8, height: 8)
                                Text("Connected · Local Wi-Fi")
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
                            Spacer()
                            Text(addr)
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textPrimary)
                        }
                    }

                    HStack {
                        Text("Status")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                        Spacer()
                        Text("Ready for remote inference")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textPrimary)
                    }
                }
                .padding(.vertical, PocketSpacing.s8)
            }

            Section("Mac Capabilities") {
                NavigationLink {
                    // Models view auto-selects Mac segment when paired
                    Text("Mac Catalog")
                } label: {
                    SettingsRow(icon: "cpu", title: "Load model on Mac…", accessory: .navigation)
                }

                SettingsRow(icon: "info.circle", title: "Server info & API key", accessory: .navigation)
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

    private func reload() {
        peers = model.core.peers()
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
                    }
                case .waitingForApproval:
                    VStack(spacing: PocketSpacing.s20) {
                        PocketMarkView(state: .loading, size: 72)
                        Text("Waiting for you to allow on your Mac")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("Check the prompt on your Mac's screen.")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
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
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handle(code: String) {
        step = .connecting
        guard let offer = try? model.core.parsePairingQr(code) else {
            step = .error("Mac not reachable. Make sure both are on the same Wi-Fi, or enter the address.")
            return
        }
        self.offer = offer

        guard let liveCore = model.core as? LiveCore else {
            step = .waitingForApproval
            let approved = ApprovedPairing(
                hostId: offer.hostId, certFingerprint: offer.certFingerprint,
                addr: offer.addrs.first ?? "", port: offer.port,
                deviceId: UUID().uuidString, tokenKeychainRef: "peer-\(offer.hostId)"
            )
            _ = try? model.core.savePeer(approved)
            step = .success
            onPaired()
            return
        }

        let coordinator = PairingCoordinator(core: liveCore.rawCore, keychain: model.hooks)
        let pairTask = Task { await coordinator.pair(qr: code) }
        Task {
            while !pairTask.isCancelled {
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
        }
    }
}
