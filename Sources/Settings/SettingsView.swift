import SwiftUI
import PocketKit
import PocketLiveShortly
import PocketUI

/// UI-11 / T6: Settings + Privacy (S-SET, S-NP).
/// Native grouped list, sections Models / Voice / Privacy / Mac & devices /
/// About (§7). Default chat model opens the shared `ModelPickerView` (incl.
/// Apple + paired Macs). Storage is real disk bytes (F20); version/build come
/// from the bundle (F23); Network Proof is scoped honestly to this session
/// (F19). No fixed bottom padding — real safe areas (F01).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("app.getpocketai.autoSpeakReplies") private var autoSpeakReplies = false
    @AppStorage("app.getpocketai.diagnosticsEnabled") private var diagnosticsEnabled = false
    @AppStorage(ToolsSettings.allowToolsKey) private var toolsAllowed = false
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue
    @AppStorage(ModelsView.allowMayNotFitKey) private var allowMayNotFit = false
    @State private var egressCount = 0
    @State private var defaultModelName = "Choose"
    @State private var storageTotal: UInt64 = 0
    /// UI-109: the Mac row names the paired Mac instead of always offering
    /// "Pair a Mac" to someone who already has.
    @State private var pairedMacName: String?

    /// Reads and writes the one shared flag. Settings and Network Proof both
    /// offer this switch; when each kept its own copy they disagreed.
    private var offlineBinding: Binding<Bool> {
        Binding(get: { model.offlineMode.isOn }, set: { on in
            model.offlineMode.set(on)
            // Logged here rather than in one screen's onChange, so a change
            // made from Network Proof is recorded too.
            DiagnosticsLog.shared.append("Offline mode set to \(on)")
        })
    }

    /// Session scope is honest: Core's egress log is in-memory and resets each
    /// launch, so we label it "this session", never a false "today" zero (F19).
    private static let egressScopeLimit: UInt32 = 500

    var body: some View {
        NavigationStack {
            List {
                // MARK: Models
                Section("Models") {
                    NavigationLink {
                        ModelPickerView(
                            scope: .defaultModel,
                            selectedId: model.selectedModelId,
                            onPicked: { model.selectedModelId = $0 }
                        )
                    } label: {
                        SettingsRow(icon: "cpu", title: "Default chat model", accessory: .value(defaultModelName))
                    }
                    .accessibilityIdentifier("settings_default_model_row")

                    NavigationLink {
                        StorageUsedView()
                    } label: {
                        SettingsRow(icon: "internaldrive", title: "Storage used", accessory: .value(storageTotal == 0 ? String(localized: "None") : formatBytes(storageTotal)))
                    }
                    .accessibilityIdentifier("settings_storage_row")

                    NavigationLink {
                        EnginesView()
                    } label: {
                        // UI-109: a count, not three engine names that wrapped
                        // or truncated beside the title.
                        SettingsRow(icon: "bolt.fill", title: "Engines", accessory: .value(AppleFoundationModelsEngine.isAvailable ? String(localized: "3 available") : String(localized: "2 available")))
                    }
                    .accessibilityIdentifier("settings_engines_row")
                }

                // MARK: Appearance
                Section("Appearance") {
                    Picker(selection: $appearance) {
                        Text("System").tag(AppearancePreference.system.rawValue)
                        Text("Light").tag(AppearancePreference.light.rawValue)
                        Text("Dark").tag(AppearancePreference.dark.rawValue)
                    } label: {
                        SettingsRow(icon: "circle.lefthalf.filled", title: "Appearance", accessory: .none)
                    }
                    .accessibilityIdentifier("settings_appearance_picker")
                }

                // MARK: Voice
                Section("Voice") {
                    SettingsRow(
                        icon: "speaker.wave.2.fill",
                        title: "Speak replies",
                        accessory: .toggle($autoSpeakReplies)
                    )
                    NavigationLink {
                        SpeechToTextView()
                    } label: {
                        SettingsRow(icon: "mic.fill", title: "Speech-to-text", accessory: .none)
                    }
                    .accessibilityIdentifier("settings_speech_to_text_row")
                    NavigationLink {
                        TextToSpeechVoiceView()
                    } label: {
                        SettingsRow(icon: "waveform", title: "Text-to-speech voice", accessory: .none)
                    }
                    .accessibilityIdentifier("settings_tts_voice_row")
                }

                // MARK: Privacy
                Section("Privacy") {
                    SettingsRow(
                        icon: "airplane",
                        title: "Offline mode",
                        accessory: .toggle(offlineBinding)
                    )
                    .accessibilityIdentifier("settings_offline_row")

                    NavigationLink {
                        NetworkProofView(offline: offlineBinding)
                    } label: {
                        SettingsRow(icon: "checkmark.shield.fill", title: "Network Proof", accessory: .value(String(localized: "\(egressCount) this session")))
                    }
                    .accessibilityIdentifier("settings_network_proof_row")

                    SettingsRow(
                        icon: "heart.text.square",
                        title: "Share diagnostic reports",
                        accessory: .toggle($diagnosticsEnabled)
                    )
                    // UI-113: the switch now carries its own label; combining
                    // the row hid the switch's toggle action from VoiceOver.
                    .accessibilityHint("Enables the option to send an in-app diagnostic report to support")

                    if diagnosticsEnabled {
                        NavigationLink {
                            DiagnosticsPreviewView()
                        } label: {
                            SettingsRow(icon: "envelope", title: "Send diagnostic report…", accessory: .none)
                        }
                        .accessibilityLabel("Send diagnostic report")
                        .accessibilityHint("Opens a preview of the diagnostic report before sending")
                    }
                }

                // MARK: Tools
                Section("Tools") {
                    NavigationLink {
                        ToolsSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "wrench.and.screwdriver",
                            title: "Tools",
                            accessory: .value(toolsStatus))
                    }
                    .accessibilityIdentifier("settings_tools_row")
                }

                // MARK: Notifications
                Section("Notifications") {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "bell.badge",
                            title: "Notifications",
                            accessory: .none)
                    }
                    .accessibilityIdentifier("settings_notifications_row")
                }

                // MARK: Integrations
                Section("Integrations") {
                    NavigationLink {
                        LSConnectView(account: model.liveShortly)
                    } label: {
                        SettingsRow(
                            icon: "dot.radiowaves.left.and.right",
                            title: "LiveShortly",
                            accessory: .value(liveShortlyStatus))
                    }
                    .accessibilityIdentifier("settings_liveshortly_row")
                }

                // MARK: Mac
                Section("Mac") {
                    NavigationLink {
                        PairMacView()
                    } label: {
                        SettingsRow(
                            icon: "laptopcomputer",
                            title: pairedMacName == nil ? "Pair a Mac" : "Paired Mac",
                            accessory: pairedMacName.map { SettingsRowAccessory.value($0) } ?? SettingsRowAccessory.none)
                    }
                    .accessibilityIdentifier("settings_pair_mac_row")
                }

                // MARK: Advanced
                Section {
                    SettingsRow(
                        icon: "exclamationmark.triangle",
                        title: "Allow models that may not fit",
                        accessory: .toggle($allowMayNotFit)
                    )
                    .accessibilityIdentifier("settings_allow_may_not_fit")
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Shows models too large for this iPhone and lets you download them. They may run very slowly or crash the app.")
                }

                // MARK: About
                Section("About") {
                    SettingsRow(icon: "info.circle.fill", title: "Version", accessory: .value(appVersionString))
                        // UI-109: support asks for this; long-press copies it.
                        .contextMenu {
                            Button("Copy version", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = appVersionString
                            }
                        }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PocketColor.bgCanvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            // onAppear, not task: coming back from Storage used (where a model
            // can be deleted) or Network Proof left these rows showing the
            // numbers from the first visit.
            .onAppear {
                egressCount = model.core.egressLog(limit: Self.egressScopeLimit).count
                refreshModelsInfo()
                pairedMacName = model.core.peers().first?.name
            }
            .onChange(of: model.selectedModelId) { refreshModelsInfo() }
            .onChange(of: diagnosticsEnabled) { _, newValue in
                DiagnosticsLog.shared.append("Settings: diagnostics sharing set to \(newValue)")
            }
        }
    }

    private var toolsStatus: String { toolsAllowed ? String(localized: "Code allowed") : String(localized: "Code off") }

    private var liveShortlyStatus: String {
        if case .connected(let user) = model.liveShortly.phase {
            return user.name.isEmpty ? user.email : user.name
        }
        return String(localized: "Not connected")
    }

    /// Version + build from the installed bundle — never a hardcoded string (F23).
    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// Resolve the default model's display name and the real on-disk total from
    /// the merged installed catalog (incl. noncurated — F25). Apple's built-in
    /// sentinel shows its name without a PocketAI-managed download.
    private func refreshModelsInfo() {
        let installed = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
        storageTotal = installed.reduce(0) { $0 + realDiskBytes($1) }

        if let id = model.selectedModelId {
            if id == AppleFoundationModelsEngine.modelId {
                defaultModelName = "Apple Intelligence"
            } else if let hit = installed.first(where: { $0.manifest.id == id }) {
                defaultModelName = ModelNaming.short(hit.manifest.displayName)
            } else if id.hasPrefix("mac:") {
                defaultModelName = "On your Mac"
            } else {
                defaultModelName = "Choose"
            }
        } else {
            defaultModelName = "Choose"
        }
    }

    private func realDiskBytes(_ entry: CatalogEntry) -> UInt64 {
        entry.fit.diskBytes != 0 ? entry.fit.diskBytes : entry.manifest.estRuntimeBytes
    }
}

/// C16: Network Proof (`02` §7.9). Scope is this session — Core's egress log is
/// in-memory and resets on launch, so a durable "today" is not yet available
/// (F19/§9.4). We report the real recorded requests, never a false zero.
private struct NetworkProofView: View {
    @Environment(AppModel.self) private var model
    @Binding var offline: Bool
    @State private var entries: [EgressEntry] = []

    private static let scopeLimit: UInt32 = 500

    /// `ts` is ms since the epoch (same unit as chat timestamps).
    private static func time(_ ts: Int64) -> String {
        Date(timeIntervalSince1970: Double(ts) / 1000).formatted(date: .omitted, time: .standard)
    }

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
                            .font(.pocket(.display))
                            .foregroundStyle(PocketColor.textPrimary)
                        Text("requests this session")
                            .font(.pocket(.headline))
                            .foregroundStyle(PocketColor.textSecondary)
                            // Wraps beside the big count instead of truncating.
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("PocketAI made \(entries.count) internet request\(entries.count == 1 ? "" : "s") since this app launched.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)

                    Text("Apple-managed purchases, system speech downloads, and anything you open yourself in a browser or Mail aren't counted here.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
                .padding(.vertical, PocketSpacing.s8)
                // UI-110: one element, read as a sentence, not "12" then a label.
                .accessibilityElement(children: .combine)
            }

            Section {
                Toggle(isOn: $offline) {
                    Label("Offline mode", systemImage: "airplane")
                }
                .tint(PocketColor.statusWarn)
                .accessibilityIdentifier("network_proof_offline_toggle")
            }

            if !entries.isEmpty {
                Section("This session") {
                    // UI-110: two requests in the same millisecond shared an
                    // id, and SwiftUI dropped or duplicated one of the rows.
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                            Text(NetPurpose.label(for: entry.purpose)).font(.pocket(.body))
                            Text("\(entry.host) · \(formatBytes(entry.bytesOut + entry.bytesIn)) · \(Self.time(entry.ts))")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                // UI-110: the iPhone tab is called Mac, not Devices.
                Text("Chat sync with your paired Mac shows here as “To your Mac”. Other connections to it are listed in the Mac tab.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Network Proof")
        .navigationBarTitleDisplayMode(.inline)
        .task { entries = model.core.egressLog(limit: Self.scopeLimit) }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

#Preview("Light") {
    SettingsView()
        .environment(AppModel())
}

#Preview("Dark") {
    SettingsView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}

#Preview("AX3") {
    SettingsView()
        .environment(AppModel())
        .environment(\.dynamicTypeSize, .accessibility3)
}
