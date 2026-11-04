import PocketKit
import PocketUI
import SwiftUI

/// AGT-13: Settings → Tools. A master switch for code tools (off by default)
/// and one switch per tool. Stage 2 and 3 add `ToolsSettings.Tool` cases and
/// they show up here with no change to this view.
struct ToolsSettingsView: View {
    @AppStorage(ToolsSettings.allowToolsKey) private var allowTools = false

    var body: some View {
        List {
            Section {
                SettingsRow(icon: "wrench.and.screwdriver", title: "Allow tools",
                            accessory: .toggle($allowTools))
                    .accessibilityHint("Lets the model run code on this iPhone after you approve it")
                    .accessibilityIdentifier("settings_tools_allow")
            } footer: {
                Text("Off, the model can never run code. Even on, the Tools button must be on in a chat, and you approve every run.")
                    .font(.pocket(.caption))
            }

            Section {
                ForEach(ToolsSettings.Tool.allCases, id: \.rawValue) { tool in
                    ToolSwitchRow(tool: tool, masterOn: allowTools)
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Code never leaves this iPhone. Web search sends only the query or page you allow to the web.")
                    .font(.pocket(.caption))
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolSwitchRow: View {
    let tool: ToolsSettings.Tool
    let masterOn: Bool
    @AppStorage private var isOn: Bool

    init(tool: ToolsSettings.Tool, masterOn: Bool) {
        self.tool = tool
        self.masterOn = masterOn
        _isOn = AppStorage(wrappedValue: true, tool.defaultsKey)
    }

    var body: some View {
        let blocked = tool.runsCode && !masterOn
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            SettingsRow(icon: tool.symbol, title: tool.title(device: "iPhone"), accessory: .toggle($isOn))
            Text(blocked ? "Turn on Allow tools first." : tool.detail)
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
        .disabled(blocked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_tool_\(tool.rawValue)")
    }
}
