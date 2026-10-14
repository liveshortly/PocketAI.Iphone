import SwiftUI
import PocketKit
import PocketUI

/// UI-12: Mac tab + pairing (`02` §7.4 S-MAC, §7.5 S-PAIR). Not-paired,
/// paired, and not-reachable states for the tab; the pairing flow itself
/// (scan -> connecting -> waiting -> success/error) as a sheet.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var peers: [Peer] = []
    @State private var showPairing = false

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
            .background(PocketColor.bgCanvas)
            .task { reload() }
            .sheet(isPresented: $showPairing) {
                PairingFlowView { reload() }
            }
        }
    }

    private var notPairedView: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 56))
                .foregroundStyle(PocketColor.accent)
            Text("Use your Mac's models from this iPhone")
                .font(.pocket(.title))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                Text("1. Open PocketAI on your Mac → Devices → Pair iPhone.")
                Text("2. Scan the code.")
            }
            .font(.pocket(.footnote))
            .foregroundStyle(PocketColor.textSecondary)

            Button("Scan code") { showPairing = true }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)

            Link("Don't have PocketAI on Mac? getpocketai.app", destination: URL(string: "https://getpocketai.app")!)
                .font(.pocket(.caption))
            Spacer()
        }
        .padding(.horizontal, PocketSpacing.gutterIphone)
    }

    private func pairedView(_ peer: Peer) -> some View {
        List {
            Section {
                DeviceRow(
                    name: peer.name, isConnected: true, lastSeenText: "",
                    route: peer.addrs.first.map { "Wi-Fi · \($0)" }, icon: "laptopcomputer",
                    onRevoke: { revoke(peer) }
                )
            }
            Section {
                SettingsRow(icon: "cpu", title: "Load model…", accessory: .navigation)
                SettingsRow(icon: "info.circle", title: "Server info", accessory: .navigation)
            }
        }
    }

    private func reload() {
        peers = model.core.peers()
    }

    private func revoke(_ peer: Peer) {
        try? model.core.revokePeer(id: peer.id)
        reload()
    }
}

/// S-PAIR: scanner -> connecting -> waiting -> success, with the
/// "Enter code manually" fallback (same `parsePairingQr` call, just fed a
/// typed string instead of a scanned one).
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
                        Button("Enter code manually") { step = .manualEntry }
                            .foregroundStyle(.white)
                            .padding(.bottom, PocketSpacing.s32)
                    }
                case .manualEntry:
                    VStack(spacing: PocketSpacing.s16) {
                        Text("Enter the host and code shown on your Mac").font(.pocket(.body))
                        TextField("host:port#code", text: $manualCode)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, PocketSpacing.gutterIphone)
                        Button("Connect") { handle(code: manualCode) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, PocketSpacing.s32)
                case .connecting:
                    VStack(spacing: PocketSpacing.s16) {
                        PocketMarkView(state: .loading, size: 64)
                        Text("Connecting to \(offer?.hostName ?? "your Mac")…").font(.pocket(.body))
                    }
                case .waitingForApproval:
                    VStack(spacing: PocketSpacing.s16) {
                        PocketMarkView(state: .loading, size: 64)
                        Text("Waiting for you to allow on your Mac").font(.pocket(.body))
                    }
                case .success:
                    VStack(spacing: PocketSpacing.s16) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(PocketColor.statusOk)
                        Text("Paired. Your Mac's models now appear in the model picker.")
                            .font(.pocket(.body))
                            .multilineTextAlignment(.center)
                        Button("Choose a Mac model") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                case .error(let message):
                    VStack(spacing: PocketSpacing.s16) {
                        Text(message).font(.pocket(.body)).multilineTextAlignment(.center)
                        Button("Try again") { step = .scan }
                    }
                    .padding(.horizontal, PocketSpacing.gutterIphone)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handle(code: String) {
        step = .connecting
        do {
            let offer = try model.core.parsePairingQr(code)
            self.offer = offer
            step = .waitingForApproval
            // No live approve/deny round trip wired yet (NET-10's server
            // side of pairing) - save immediately so the flow is testable.
            let approved = ApprovedPairing(
                hostId: offer.hostId, certFingerprint: offer.certFingerprint,
                addr: offer.addrs.first ?? "", port: offer.port,
                deviceId: UUID().uuidString, tokenKeychainRef: "peer-\(offer.hostId)"
            )
            _ = try model.core.savePeer(approved)
            step = .success
            onPaired()
        } catch {
            step = .error("Mac not reachable. Make sure both are on the same Wi-Fi, or enter the address.")
        }
    }
}
