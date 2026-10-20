import XCTest

/// UI-10: Models download-state UI tests.
/// Verifies download state transitions simulated by PreviewCore on the Models screen:
/// available -> downloading -> paused.
final class DownloadStateUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDownloadStateTransitions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PocketSkipOnboarding",
            "-PocketPreviewCore",
            "-PocketTabModels"
        ]
        app.launch()

        // 1. Assert Models screen is visible
        let modelsTitle = app.navigationBars["Models"]
        XCTAssertTrue(modelsTitle.waitForExistence(timeout: 10), "Models navigation bar must exist")

        // 2. Target fixture model: Qwen3-1.7B-4bit (available by default in PreviewCore fixture catalog)
        let modelId = "mlx-community/Qwen3-1.7B-4bit@3b1b1768f8f8cf8351c712464f906e86c2b8269e"
        let rowIdentifier = "model_row_\(modelId)"

        let modelRow = app.descendants(matching: .any)[rowIdentifier]
        XCTAssertTrue(modelRow.waitForExistence(timeout: 10), "Fixture model row '\(rowIdentifier)' must exist")

        // Assert initial state is available (emitted by PreviewCore fixtureCatalog)
        XCTAssertEqual(modelRow.value as? String, "available", "Initial model state must be 'available'")

        // 3. Find and tap Download control
        // On the row, primaryActionLabel starts as "Download"
        let downloadControl = modelRow.buttons["Download"]
        XCTAssertTrue(downloadControl.waitForExistence(timeout: 5), "Download control on model row must exist")
        downloadControl.tap()

        // 4. Assert the row transitions to downloading within bounded wait (≤ 25s)
        // PreviewCore sets .downloading and ticks bytesDone over ~20s.
        // In ModelsView, primaryActionLabel transforms to "Pause" and accessibilityValue to "downloading".
        let pauseControl = modelRow.buttons["Pause"]
        XCTAssertTrue(
            pauseControl.waitForExistence(timeout: 5),
            "Row must transition to downloading state (showing 'Pause' control) within bounded wait"
        )
        XCTAssertEqual(
            modelRow.value as? String,
            "downloading",
            "Row accessibility state must emit 'downloading'"
        )

        // 5. Exercise another transition that PreviewCore supports: pause (assert .paused)
        pauseControl.tap()

        // PreviewCore moves state to .paused; ModelsView primaryActionLabel transforms to "Resume"
        let resumeControl = modelRow.buttons["Resume"]
        XCTAssertTrue(
            resumeControl.waitForExistence(timeout: 5),
            "Row must transition to paused state (showing 'Resume' control)"
        )
        XCTAssertEqual(
            modelRow.value as? String,
            "paused",
            "Row accessibility state must emit 'paused'"
        )
    }
}
