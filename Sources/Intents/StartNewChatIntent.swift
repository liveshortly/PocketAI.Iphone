import AppIntents
import Foundation
import PocketKit

struct StartNewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Start New Chat"
    static var description = IntentDescription("Create a new conversation in PocketAI.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        do {
            let convo = try model.core.createConversation(
                NewConversation(title: nil, projectId: nil, modelId: model.selectedModelId)
            )
            // Routes the shell to Chats and opens the exact new conversation
            // (F26, §9.4) via the shared navigation state used by Home.
            model.nav.openConversation(id: convo.id)
        } catch {
            throw PocketAIIntentError(String(localized: "PocketAI couldn't create a new chat: \(error.localizedDescription)"))
        }
        return .result(dialog: "Started a new chat in PocketAI.")
    }
}
