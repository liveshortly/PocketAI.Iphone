import SwiftUI
import PocketKit
import PocketUI

/// UI-20: Licensed capabilities + license key activation (S-PAY, `02-design-system.md` §7.7).
/// Presentation screen showing licensed capabilities and Keygen license key activation.
/// In-app purchase and StoreKit paywalls are removed under the Keygen-only model.
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
                    PocketMarkView(state: isLicensed ? .working(tokPerSec: nil) : .idle, size: 64)
                    Text("License Activation")
                        .font(.pocket(.title))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("Enter a license key to activate licensed features.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PocketSpacing.s16)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Licensed Capabilities") {
                benefitRow(icon: "laptopcomputer.and.iphone", text: "Use your Mac's models from iPhone")
                benefitRow(icon: "network", text: "Serve models to other apps on your network")
            }

            if isLicensed {
                Section {
                    HStack(spacing: PocketSpacing.s12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(PocketColor.statusOk)
                        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                            Text("License active")
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
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        HStack(spacing: PocketSpacing.s8) {
                            TextField("Paste license key", text: $licenseKey)
                                .font(.pocket(.body))
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)

                            Button("Activate") {
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
        .navigationTitle("License Activation")
        .navigationBarTitleDisplayMode(.inline)
        .task { entitlements = model.core.entitlements() }
        .pocketToast($toast)
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(PocketColor.accent)
                .frame(width: 28)
            Text(text)
                .font(.pocket(.body))
                .foregroundStyle(PocketColor.textPrimary)
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
        } catch {
            self.error = "Couldn't activate that key."
        }
    }
}

#Preview {
    NavigationStack {
        PaywallView()
            .environment(AppModel())
    }
}
