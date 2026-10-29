import AppIntents
import Foundation
import PocketKit

struct PocketAIIntentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AskPocketAIIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask PocketAI"
    static var description = IntentDescription("Ask PocketAI's on-device model a question.")

    @Parameter(title: "Prompt")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let core = AppModel.shared.core
        let conversation: Conversation
        do {
            conversation = try core.createConversation(
                NewConversation(title: "Siri", projectId: nil, modelId: AppModel.shared.selectedModelId)
            )
        } catch {
            throw PocketAIIntentError(String(localized: "PocketAI couldn't generate a response: \(error.localizedDescription)"))
        }
        // Keep Siri one-shots out of the visible Chats list.
        try? core.archiveConversation(id: conversation.id, archived: true)

        let input = UserInput(parts: [.text(text: prompt)])
        var answer = ""
        do {
            for try await event in core.sendMessage(conversationId: conversation.id, input: input) {
                switch event {
                case .delta(let delta):
                    answer += delta.text
                case .done:
                    break
                }
            }
        } catch {
            throw PocketAIIntentError(String(localized: "PocketAI couldn't generate a response: \(error.localizedDescription)"))
        }

        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}
