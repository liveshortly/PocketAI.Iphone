import AppIntents
import Foundation
import PocketKit

struct SummarizeTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Summarize Text"
    static var description = IntentDescription("Summarize a block of text using PocketAI.")

    @Parameter(title: "Text")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let core = AppModel.shared.core
        let conversation: Conversation
        do {
            conversation = try core.createConversation(
                NewConversation(title: "Siri", projectId: nil, modelId: nil)
            )
        } catch {
            throw PocketAIIntentError("PocketAI couldn't generate a response.")
        }

        let prompt = "Summarize the following text concisely:\n\n\(text)"
        let input = UserInput(parts: [.text(text: prompt)])
        var summary = ""
        do {
            for try await event in core.sendMessage(conversationId: conversation.id, input: input) {
                switch event {
                case .delta(let delta):
                    summary += delta.text
                case .done:
                    break
                }
            }
        } catch {
            throw PocketAIIntentError("PocketAI couldn't generate a response.")
        }

        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
