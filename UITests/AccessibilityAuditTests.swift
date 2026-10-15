import XCTest

/// QA-10: Automated Accessibility Audit Test Suite.
///
/// GATE NOTE:
/// Automated accessibility audits via `app.performAccessibilityAudit()` require an active
/// Simulator GUI session (XCUIApplication connection). Headless test executions lack
/// the graphics/window server context necessary to inspect UIKit/SwiftUI accessibility elements.
/// This suite verifies test compilation and defines automated audit coverage across all 6 core surfaces:
/// 1. Onboarding Flow (`OnboardingFlow`)
/// 2. Chats List (`ChatsListView`)
/// 3. Chat Detail (`ChatView`)
/// 4. Models Catalog (`ModelsView`)
/// 5. Settings & Privacy (`SettingsView`)
/// 6. PocketAI Pro Paywall (`PaywallView`)
final class AccessibilityAuditTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Performs accessibility audit on the currently active screen.
    /// iOS 17+ `performAccessibilityAudit` checks for contrast, element labels, dynamic type,
    /// touch target sizes, and accessibility hierarchy validity.
    private func runAudit(app: XCUIApplication, screenName: String) throws {
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: .all) { issue in
                // Zero-tolerance policy by default: return false so issues are flagged.
                // If system-level UIKit decorative elements produce false positives,
                // filter here with documented rationale.
                return false
            }
        }
    }

    /// 1. Onboarding Screen Accessibility Audit
    func testOnboardingAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketResetOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to PocketAI"].waitForExistence(timeout: 5) ||
                      app.buttons["Get started"].waitForExistence(timeout: 5))
        try runAudit(app: app, screenName: "Onboarding")
    }

    /// 2. Chats List Screen Accessibility Audit
    func testChatsListAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Chats"].waitForExistence(timeout: 5))
        try runAudit(app: app, screenName: "Chats List")
    }

    /// 3. Chat Screen Accessibility Audit
    func testChatAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        app.launch()

        let newChatButton = app.buttons["new_chat_button"]
        if newChatButton.waitForExistence(timeout: 5) {
            newChatButton.tap()
        }

        XCTAssertTrue(app.navigationBars["New chat"].waitForExistence(timeout: 5) ||
                      app.otherElements["chat_composer"].waitForExistence(timeout: 5))
        try runAudit(app: app, screenName: "Chat")
    }

    /// 4. Models Screen Accessibility Audit
    func testModelsAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        app.launch()

        let modelsTab = app.tabBars.buttons["Models"]
        XCTAssertTrue(modelsTab.waitForExistence(timeout: 5))
        modelsTab.tap()

        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        try runAudit(app: app, screenName: "Models")
    }

    /// 5. Settings Screen Accessibility Audit
    func testSettingsAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try runAudit(app: app, screenName: "Settings")
    }

    /// 6. Paywall Screen Accessibility Audit
    func testPaywallAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding", "-PocketScreenPaywall"]
        app.launch()

        XCTAssertTrue(app.staticTexts["PocketAI Pro"].waitForExistence(timeout: 5) ||
                      app.buttons["Done"].waitForExistence(timeout: 5) ||
                      app.buttons["Continue"].waitForExistence(timeout: 5))
        try runAudit(app: app, screenName: "Paywall")
    }
}
