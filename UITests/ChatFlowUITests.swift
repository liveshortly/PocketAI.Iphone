import XCTest

/// UI-09: Chat flow UI tests.
/// Verifies the full compose -> send -> stream-render UI path.
final class ChatFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChatComposerSendShowsResponse() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PocketSkipOnboarding",
            "-PocketPreviewCore",
            "-PocketScreenChat"
        ]
        app.launch()

        // 1. Find composer text field / view
        let composerField: XCUIElement
        if app.textFields["chat_composer"].waitForExistence(timeout: 5) {
            composerField = app.textFields["chat_composer"]
        } else if app.textViews["chat_composer"].waitForExistence(timeout: 5) {
            composerField = app.textViews["chat_composer"]
        } else if app.otherElements["chat_composer"].waitForExistence(timeout: 5) {
            composerField = app.otherElements["chat_composer"]
        } else {
            composerField = app.descendants(matching: .any)["chat_composer"]
        }

        XCTAssertTrue(composerField.waitForExistence(timeout: 10), "Composer text field must be present")
        composerField.tap()
        composerField.typeText("Hello")

        // 2. Find and tap Send button
        let sendButton: XCUIElement
        if app.buttons["chat_send_button"].waitForExistence(timeout: 5) {
            sendButton = app.buttons["chat_send_button"]
        } else {
            sendButton = app.descendants(matching: .button)["chat_send_button"]
        }

        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button must appear when text is entered")
        sendButton.tap()

        // 3. Assert user message bubble with "Hello" appears
        let userMessageBubble = app.staticTexts["Hello"]
        XCTAssertTrue(
            userMessageBubble.waitForExistence(timeout: 10),
            "User message bubble with 'Hello' should appear"
        )

        let userBubbleContainer = app.descendants(matching: .any)["chat_bubble_user"]
        XCTAssertTrue(
            userBubbleContainer.waitForExistence(timeout: 10),
            "User message bubble container with identifier 'chat_bubble_user' should exist"
        )

        // 4. Assert assistant response bubble appears
        // PreviewCore streams: "Hello from Preview Core — deterministic fake streaming at forty tokens per second."
        let assistantMessagePredicate = NSPredicate(format: "label CONTAINS[c] 'Preview Core'")
        let assistantMessage = app.staticTexts.matching(assistantMessagePredicate).firstMatch
        XCTAssertTrue(
            assistantMessage.waitForExistence(timeout: 10),
            "Assistant response bubble with streamed reply should appear within timeout"
        )
        XCTAssertFalse(
            assistantMessage.label.isEmpty,
            "Assistant response text should be non-empty"
        )

        let assistantBubbleContainer = app.descendants(matching: .any)["chat_bubble_assistant"]
        XCTAssertTrue(
            assistantBubbleContainer.waitForExistence(timeout: 10),
            "Assistant message bubble container with identifier 'chat_bubble_assistant' should exist"
        )
    }
}
