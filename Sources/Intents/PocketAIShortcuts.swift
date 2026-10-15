import AppIntents

struct PocketAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPocketAIIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask PocketAI",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: SummarizeTextIntent(),
            phrases: [
                "Summarize with \(.applicationName)",
                "Summarize text with \(.applicationName)",
            ],
            shortTitle: "Summarize Text",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: StartNewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start new chat in \(.applicationName)",
            ],
            shortTitle: "New Chat",
            systemImageName: "plus.bubble"
        )
    }
}
