import SwiftUI
import PocketKit
import PocketUI

/// UI-11: Redesigned Settings + Privacy (S-SET, S-NP).
/// Features grouped Form with native iOS section headers, icon badges,
/// an at-a-glance Network Proof status card, and offline mode toggle.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("app.getpocketai.autoSpeakReplies") private var autoSpeakReplies = false
    @AppStorage("app.getpocketai.diagnosticsEnabled") private var diagnosticsEnabled = false
    @State private var offline = false
    @State private var egressCount = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        NetworkProofView(offline: $offline)
                    } label: {
                        HStack(spacing: PocketSpacing.s12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(PocketColor.accentSoft)
                                    .frame(width: 44, height: 44)
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(.title2))
                                    .foregroundStyle(PocketColor.statusOk)
                            }
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Network Proof")
                                        .font(.pocket(.headline))
                                        .foregroundStyle(PocketColor.textPrimary)
                                    Spacer()
                                    Text("\(egressCount)")
                                        .font(.pocket(.title))
                                        .foregroundStyle(PocketColor.accent)
                                }
                                Text(egressCount == 0 ? "0 outbound requests today · Verified on-device" : "\(egressCount) requests today")
                                    .font(.pocket(.footnote))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }
                        }
                        .padding(.vertical, PocketSpacing.s4)
                    }
                }

                Section("Privacy") {
                    SettingsRow(
                        icon: "airplane",
                        tint: PocketColor.statusWarn,
                        title: "Offline mode",
                        accessory: .toggle($offline)
                    )
                    SettingsRow(
                        icon: "heart.text.square",
                        tint: PocketColor.accent,
                        title: "Share diagnostic reports",
                        accessory: .toggle($diagnosticsEnabled)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Share diagnostic reports")
                    .accessibilityValue(diagnosticsEnabled ? "On" : "Off")
                    .accessibilityHint("Enables the option to send an in-app diagnostic report to support")

                    if diagnosticsEnabled {
                        NavigationLink {
                            DiagnosticsPreviewView()
                        } label: {
                            SettingsRow(
                                icon: "envelope",
                                tint: PocketColor.statusInfo,
                                title: "Send diagnostic report…",
                                accessory: .navigation
                            )
                        }
                        .accessibilityLabel("Send diagnostic report")
                        .accessibilityHint("Opens a preview of the diagnostic report before sending")
                    }
                }

                Section("Models & Memory") {
                    SettingsRow(icon: "cpu", tint: PocketColor.statusInfo, title: "Default model", accessory: .navigation)
                    SettingsRow(icon: "internaldrive", tint: PocketColor.textSecondary, title: "Storage used", accessory: .navigation)
                }

                Section("Engines") {
                    SettingsRow(icon: "bolt.fill", tint: PocketColor.statusWarn, title: "MLX / llama.cpp", accessory: .navigation)
                    SettingsRow(
                        icon: "apple.logo",
                        tint: PocketColor.textPrimary,
                        title: "Apple Intelligence",
                        accessory: .value(AppleFoundationModelsEngine.isAvailable ? "Available" : "Unavailable")
                    )
                }

                Section("Voice") {
                    SettingsRow(
                        icon: "speaker.wave.2.fill",
                        tint: PocketColor.accent,
                        title: "Speak replies",
                        accessory: .toggle($autoSpeakReplies)
                    )
                    SettingsRow(icon: "mic.fill", tint: PocketColor.statusInfo, title: "Speech-to-text", accessory: .navigation)
                    SettingsRow(icon: "waveform", tint: PocketColor.statusOk, title: "Text-to-speech voice", accessory: .navigation)
                }

                Section("Mac & Devices") {
                    SettingsRow(icon: "laptopcomputer", tint: PocketColor.statusInfo, title: "Pair a Mac", accessory: .navigation)
                }

                Section("License") {
                    NavigationLink {
                        PaywallView()
                    } label: {
                        SettingsRow(icon: "key.fill", tint: PocketColor.accent, title: "License Activation", accessory: .navigation)
                    }
                }

                Section("About") {
                    SettingsRow(icon: "info.circle.fill", tint: PocketColor.textSecondary, title: "Version", accessory: .value("0.2.0"))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PocketColor.bgCanvas)
            .padding(.bottom, 80)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task {
                offline = model.core.isOffline()
                egressCount = model.core.egressLog(limit: 0).count
            }
            .onChange(of: offline) { _, newValue in
                model.core.setOfflineMode(on: newValue)
                DiagnosticsLog.shared.append("Settings: offline mode set to \(newValue)")
            }
            .onChange(of: diagnosticsEnabled) { _, newValue in
                DiagnosticsLog.shared.append("Settings: diagnostics sharing set to \(newValue)")
            }
        }
    }
}

/// C16: Network Proof (`02` §7.9).
private struct NetworkProofView: View {
    @Environment(AppModel.self) private var model
    @Binding var offline: Bool
    @State private var entries: [EgressEntry] = []

    var body: some View {
        List {
            if offline {
                Section {
                    Label("Offline mode — PocketAI internet requests paused", systemImage: "airplane")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.statusWarn)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(entries.count)")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("requests today")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textSecondary)
                    }

                    Text("PocketAI made \(entries.count) internet request\(entries.count == 1 ? "" : "s") today.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)

                    Text("Apple-managed purchases, system speech downloads, and anything you open yourself in a browser or Mail aren't counted here.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .padding(.vertical, PocketSpacing.s8)
            }

            Section {
                Toggle(isOn: $offline) {
                    Label("Offline mode", systemImage: "airplane")
                }
                .tint(PocketColor.statusWarn)
            }

            if !entries.isEmpty {
                Section("Today") {
                    ForEach(entries, id: \.ts) { entry in
                        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                            Text(entry.purpose).font(.pocket(.body))
                            Text("\(entry.host) · \(formatBytes(entry.bytesOut + entry.bytesIn))")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                    }
                }
            }

            Section {
                Text("Connections to your paired Mac are listed under Devices.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network Proof")
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = model.core.egressLog(limit: 0) }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
