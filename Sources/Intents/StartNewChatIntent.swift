import AppIntents
import Foundation
import PocketKit

struct StartNewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Start New Chat"
    static var description = IntentDescription("Create a new conversation in PocketAI.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let core = AppModel.shared.core
        do {
            _ = try core.createConversation(
                NewConversation(title: nil, projectId: nil, modelId: AppModel.shared.selectedModelId)
            )
        } catch {
            throw PocketAIIntentError("PocketAI couldn't create a new chat: \(error.localizedDescription)")
        }

        // ponytail: Deep-linking to the exact new conversation is deferred until a navigation coordinator is implemented.
        return .result(dialog: "Started a new chat in PocketAI.")
    }
}
