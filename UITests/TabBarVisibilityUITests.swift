import XCTest

/// UI-37: the tab bar never minimizes. After a long scroll on a list screen,
/// every tab is still hittable.
final class TabBarVisibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTabBarStaysAfterLongScroll() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        app.launch()

        let modelsTab = app.tabBars.buttons["Models"]
        XCTAssertTrue(modelsTab.waitForExistence(timeout: 5))
        modelsTab.tap()

        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<6 { list.swipeUp() }

        for tab in app.tabBars.buttons.allElementsBoundByIndex {
            XCTAssertTrue(tab.isHittable, "\(tab.label) tab hidden after scrolling")
        }
    }
}
