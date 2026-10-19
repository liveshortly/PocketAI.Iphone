import SwiftUI
import PocketKit
import PocketUI

/// UI-20: Redesigned Licensed capabilities + license key activation (S-PAY, `02-design-system.md` §7.7).
/// Premium presentation screen with PocketMark, benefit cards, license key activation,
/// and stubbed App Store in-app purchase options.
public struct PaywallView: View {
    @Environment(AppModel.self) private var model

    @State private var entitlements: Entitlements?
    @State private var licenseKey: String
    @State private var activatedKey: String?
    @State private var error: String?
    @State private var toast: ToastData?

    public init(prefilledKey: String? = nil) {
        _licenseKey = State(initialValue: prefilledKey ?? "")
    }

    private var isLicensed: Bool {
        entitlements?.pro ?? false
    }

    public var body: some View {
        List {
            Section {
                VStack(spacing: PocketSpacing.s12) {
                    PocketMarkView(state: isLicensed ? .working(tokPerSec: 32) : .idle, size: 72)
                        .padding(.top, PocketSpacing.s8)

                    VStack(spacing: PocketSpacing.s4) {
                        Text("PocketAI Pro")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(PocketColor.textPrimary)

                        Text("License Activation")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.accent)
                            .fontWeight(.semibold)

                        Text("One purchase. Works on your iPhone and Mac.")
                            .font(.pocket(.callout))
                            .foregroundStyle(PocketColor.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PocketSpacing.s12)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Pro Capabilities") {
                proBenefitRow(
                    icon: "laptopcomputer.and.iphone",
                    title: "Use your Mac's models from iPhone",
                    subtitle: "Pair over Wi-Fi to tap into large 70B+ models right from your pocket."
                )
                proBenefitRow(
                    icon: "network",
                    title: "Serve models to other apps on your network",
                    subtitle: "Private OpenAI-compatible API endpoint running directly on your devices."
                )
            }

            if isLicensed {
                Section("Status") {
                    HStack(spacing: PocketSpacing.s12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(PocketColor.statusOk)
                        VStack(alignment: .leading, spacing: PocketSpacing.s2) {
                            Text("License Active")
                                .font(.pocket(.headline))
                                .foregroundStyle(PocketColor.textPrimary)
                            Text(licenseSubtitle)
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    }
                    .padding(.vertical, PocketSpacing.s8)
                }
            } else {
                Section("Have a license key?") {
                    VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                        HStack(spacing: PocketSpacing.s8) {
                            TextField("Paste license key", text: $licenseKey)
                                .font(.pocket(.body))
                                .textFieldStyle(.plain)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(PocketSpacing.s8)
                                .background(PocketColor.bgSunken, in: RoundedRectangle(cornerRadius: 8))

                            Button("Paste") {
                                if let string = UIPasteboard.general.string {
                                    licenseKey = string.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(PocketColor.textSecondary)

                            Button("Activate") {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                activate()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(PocketColor.accent)
                            .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let error {
                            Text(error)
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.statusBad)
                        }
                    }
                    .padding(.vertical, PocketSpacing.s4)
                }

                Section("App Store Purchase") {
                    Button {
                        // Stubbed IAP
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack {
                            Text("Buy PocketAI Pro")
                                .fontWeight(.semibold)
                            Spacer()
                            Text("One-time")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    }
                    .tint(PocketColor.accent)

                    Button {
                        // Stubbed Restore
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text("Restore Purchases")
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                }
            }

            Section {
                Text("Everything on-device stays free. No subscription.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("PocketAI Pro")
        .navigationBarTitleDisplayMode(.inline)
        .task { entitlements = model.core.entitlements() }
        .pocketToast($toast)
    }

    private func proBenefitRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: PocketSpacing.s12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PocketColor.accentSoft)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
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
        }
        .padding(.vertical, PocketSpacing.s4)
    }

    private var licenseSubtitle: String {
        if let key = activatedKey ?? (licenseKey.isEmpty ? nil : licenseKey), key.count >= 4 {
            return "License · key ending \(key.suffix(4))"
        }
        if let source = entitlements?.source, !source.isEmpty {
            if source.hasPrefix("license:") {
                let rest = source.dropFirst("license:".count)
                let suffix = rest.count >= 4 ? String(rest.suffix(4)) : String(rest)
                return "License · key ending \(suffix)"
            }
            return "License · \(source)"
        }
        return "License active"
    }

    private func activate() {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            entitlements = try model.core.activateLicense(key: trimmed)
            activatedKey = trimmed
            error = nil
            toast = ToastData(message: "License activated")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = "Couldn't activate that key."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

#Preview {
    NavigationStack {
        PaywallView()
            .environment(AppModel())
    }
}
