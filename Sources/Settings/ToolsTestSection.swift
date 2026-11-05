import PocketKit
import PocketUI
import SwiftUI

/// UI-145: Settings → Tools → "Test tools". Sends one fixed prompt through
/// the same path as a chat (temporary chat with the Tools chip on) and prints
/// what Core reports: availability flags, the tool names offered, whether the
/// hint was appended, the raw first-round output and the parsed tool calls.
/// Nothing is stored: the temporary chat is deleted afterwards. No secrets
/// pass through here (only tool names, counts and the model's own output).
struct ToolsTestSection: View {
    static let prompt = "Use python to compute 17!/3**9 and tell me the result."

    @State private var running = false
    @State private var lines: [String] = []
    @State private var reply = ""

    var body: some View {
        Section {
            Button {
                Task { await run() }
            } label: {
                Text(running ? "Testing…" : "Test tools")
            }
            .disabled(running)
            .accessibilityIdentifier("settings_tools_test")

            if !lines.isEmpty || !reply.isEmpty {
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(.pocket(.mono))
                            .textSelection(.enabled)
                    }
                    if !reply.isEmpty {
                        Text(verbatim: "reply: \(String(reply.prefix(600)))")
                            .font(.pocket(.mono))
                            .textSelection(.enabled)
                    }
                }
                .foregroundStyle(PocketColor.textSecondary)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Sends a fixed question with the Tools button on and shows which tools the model was offered and what it answered. Needs a model on this iPhone.")
                .font(.pocket(.caption))
        }
    }

    @MainActor
    private func run() async {
        running = true
        lines = []
        reply = ""
        defer { running = false }
        let core = AppModel.shared.core
        guard let modelId = AppModel.shared.selectedModelId else {
            lines = ["No model selected."]
            return
        }
        let t = ToolsSettings()
        lines.append("settings: allow=\(t.allowTools) web=\(t.isOn(.webSearch)) js=\(t.isAvailable(.runJavaScript)) py=\(t.isAvailable(.runPython)) mac=\(t.isAvailable(.runOnMac))")
        var cid: String?
        do {
            let c = try core.createConversation(NewConversation(title: "Test tools", projectId: nil, modelId: modelId))
            cid = c.id
            try core.setConversationTools(id: c.id, on: true)
            let stream = core.sendMessage(conversationId: c.id, input: UserInput(parts: [.text(text: Self.prompt)]), reasoning: .off)
            for try await event in stream {
                switch event {
                case .diagnostic(let line):
                    lines.append(line.hasPrefix(ChatStreamEvent.contentLinePrefix) ? String(line.dropFirst(ChatStreamEvent.contentLinePrefix.count)) : line)
                case .toolStep(let step):
                    lines.append("step: \(step.kind) \(step.label)")
                case .status(let phase):
                    lines.append("phase: \(phase)")
                    // Nobody can answer a card from Settings; the model's call
                    // is already on screen, so decline by stopping.
                    if case .awaitingApproval = phase { core.cancelConversation(id: c.id) }
                case .delta(let d):
                    reply += d.text
                case .done:
                    break
                }
            }
        } catch {
            lines.append("error: \(error.localizedDescription)")
        }
        if let cid {
            // Approval cards may still be open for this chat; Stop first.
            core.cancelConversation(id: cid)
            try? core.deleteConversation(id: cid)
        }
    }
}
