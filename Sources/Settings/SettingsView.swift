import SwiftUI
import PocketKit
import PocketUI

/// UI-11: Settings + Privacy (S-SET, S-NP). Only the Privacy section is
/// real (offline mode + Network Proof, this card's actual "Done when");
/// the other `02` §7.8 sections are present as navigable rows but their
/// owning features (engine prefs, voice, Pro, etc.) aren't built yet.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("app.getpocketai.autoSpeakReplies") private var autoSpeakReplies = false
    @AppStorage("app.getpocketai.diagnosticsEnabled") private var diagnosticsEnabled = false
    @State private var offline = false

    var body: some View {
        NavigationStack {
            List {
                Section("Privacy") {
                    NavigationLink {
                        NetworkProofView(offline: $offline)
                    } label: {
                        SettingsRow(icon: "network", title: "Network Proof", accessory: .navigation)
                    }
                    SettingsRow(
                        icon: "airplane", tint: PocketColor.statusWarn, title: "Offline mode",
                        accessory: .toggle($offline)
                    )
                    SettingsRow(
                        icon: "heart.text.square", tint: PocketColor.accent, title: "Share diagnostic reports",
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
                                icon: "envelope", tint: PocketColor.statusInfo, title: "Send diagnostic report…",
                                accessory: .navigation
                            )
                        }
                        .accessibilityLabel("Send diagnostic report")
                        .accessibilityHint("Opens a preview of the diagnostic report before sending")
                    }
                }
                Section("Models & memory") {
                    SettingsRow(icon: "cpu", title: "Default model", accessory: .navigation)
                    SettingsRow(icon: "internaldrive", title: "Storage used", accessory: .navigation)
                }
                Section("Engines") {
                    SettingsRow(icon: "bolt", title: "MLX / llama.cpp", accessory: .navigation)
                    SettingsRow(icon: "apple.logo", title: "Apple Intelligence", accessory: .value(AppleFoundationModelsEngine.isAvailable ? "Available" : "Unavailable"))
                }
                Section("Voice") {
                    SettingsRow(
                        icon: "speaker.wave.2",
                        title: "Speak replies",
                        accessory: .toggle($autoSpeakReplies)
                    )
                    SettingsRow(icon: "mic", title: "Speech-to-text", accessory: .navigation)
                    SettingsRow(icon: "speaker.wave.2", title: "Text-to-speech voice", accessory: .navigation)
                }
                Section("Mac") {
                    SettingsRow(icon: "laptopcomputer", title: "Pair a Mac", accessory: .navigation)
                }
                Section("Pro") {
                    NavigationLink {
                        PaywallView()
                    } label: {
                        SettingsRow(icon: "star", title: "PocketAI Pro", accessory: .navigation)
                    }
                }
                Section("About") {
                    SettingsRow(icon: "info.circle", title: "Version", accessory: .value("0.2.0"))
                }
            }
            .navigationTitle("Settings")
            .task { offline = model.core.isOffline() }
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
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text("\(entries.count)")
                        .font(.pocket(.display))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("PocketAI made \(entries.count) internet request\(entries.count == 1 ? "" : "s") today.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    Text("Apple-managed purchases, system speech downloads, and anything you open yourself in a browser or Mail aren't counted here.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
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
        .navigationTitle("Network Proof")
        .task { entries = model.core.egressLog(limit: 0) }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
