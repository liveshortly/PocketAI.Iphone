import XCTest

/// UI-35: the Models filter row is a fixed row. It must not be (or contain) a
/// horizontal ScrollView, and no chip may be clipped by the screen edge.
/// Run on iPhone SE + Pro Max at default and AX text sizes.
final class ModelsFilterRowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFilterRowDoesNotScrollOrClip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        app.launch()

        let modelsTab = app.tabBars.buttons["Models"]
        XCTAssertTrue(modelsTab.waitForExistence(timeout: 5))
        modelsTab.tap()

        let row = app.descendants(matching: .any)["models_filter_row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "filter row should be on screen")
        XCTAssertNotEqual(row.elementType, .scrollView, "filter row must not be a ScrollView")
        XCTAssertEqual(row.scrollViews.count, 0, "filter row must not contain a ScrollView")

        let screen = app.windows.firstMatch.frame
        let buttons = row.buttons.allElementsBoundByIndex
        XCTAssertFalse(buttons.isEmpty, "every filter must stay reachable from the row")
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.minX, screen.minX - 0.5, "\(button.identifier) clipped left")
            XCTAssertLessThanOrEqual(button.frame.maxX, screen.maxX + 0.5, "\(button.identifier) clipped right")
        }
    }
}
