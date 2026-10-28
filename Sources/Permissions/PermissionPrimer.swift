import SwiftUI
import Network
import AVFoundation
import Speech
import UIKit
import PocketUI

/// A pre-permission "primer" sheet shown in-context, right before the one-shot
/// iOS system prompt fires. HIG pattern: asking cold while a capability is
/// `.notDetermined` spends the single request on a user who has no idea why —
/// this explains the why first, so the real prompt lands with consent primed.
///
/// Reusable across Local Network (Mac pairing), Speech + Microphone (voice
/// input) and Camera (QR scan / vision capture). Honest instruments: it states
/// exactly what the grant is used for, nothing more.
struct PermissionPrimer: View {
    let icon: String
    let title: String
    let message: String
    let continueLabel: String
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer(minLength: PocketSpacing.s16)

            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(PocketColor.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: PocketSpacing.s8) {
                Text(title)
                    .font(.pocket(.title))
                    .foregroundStyle(PocketColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, PocketSpacing.s24)

            Spacer()

            VStack(spacing: PocketSpacing.s12) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    dismiss()
                    onContinue()
                } label: {
                    Text(continueLabel)
                        .font(.pocket(.headline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PocketSpacing.s12)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)

                Button("Not now") { dismiss() }
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, PocketSpacing.gutterIphone)
            .padding(.bottom, PocketSpacing.s24)
        }
        .frame(maxWidth: .infinity)
        .background(PocketColor.bgCanvas)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Determination checks

/// Whether a voice-input primer is worth showing: true only while Speech or
/// Microphone is still `.notDetermined`. Once the user has answered either way,
/// the real state (granted path / denied alert) takes over and we don't nag.
enum VoicePermissions {
    static var needsPrimer: Bool {
        let speechUndetermined = SFSpeechRecognizer.authorizationStatus() == .notDetermined
        let micUndetermined: Bool
        if #available(iOS 17.0, *) {
            micUndetermined = AVAudioApplication.shared.recordPermission == .undetermined
        } else {
            micUndetermined = AVAudioSession.sharedInstance().recordPermission == .undetermined
        }
        return speechUndetermined || micUndetermined
    }
}

/// Whether the camera grant is still `.notDetermined` (so a primer helps).
enum CameraPermissions {
    static var needsPrimer: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }
}

/// Triggers the iOS Local Network permission prompt by briefly browsing for the
/// app's Bonjour service. The Mac pairing connection needs this grant; firing
/// it here — after the primer explains why — means the system prompt doesn't
/// ambush the user mid-scan.
///
/// ponytail: iOS exposes no API to read local-network authorization status, so
/// this is fire-and-forget; the pairing connect reports the real result.
enum LocalNetworkPrimer {
    static func request() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_pocketai._tcp", domain: nil), using: params)
        browser.start(queue: .main)
        // The prompt has fired once browsing begins; tear down shortly after so
        // we don't hold an idle browser open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { browser.cancel() }
    }
}

#Preview("Light") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PermissionPrimer(
            icon: "wifi",
            title: "Find your Mac on Wi-Fi",
            message: "PocketAI uses Local Network access to discover and connect to your Mac. Nothing leaves your local network.",
            continueLabel: "Continue",
            onContinue: {}
        )
    }
}

#Preview("Dark") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PermissionPrimer(
            icon: "mic.fill",
            title: "Voice input",
            message: "PocketAI uses the microphone and on-device speech recognition to turn your voice into text. Audio is transcribed on this iPhone.",
            continueLabel: "Enable voice input",
            onContinue: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("AX3") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PermissionPrimer(
            icon: "camera.fill",
            title: "Scan your Mac's code",
            message: "PocketAI uses the camera to scan the pairing QR code shown on your Mac.",
            continueLabel: "Open camera",
            onContinue: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
