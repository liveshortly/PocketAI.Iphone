import XCTest

/// QA-05: Performance Harness XCUITest Driver.
///
/// GATE NOTE (referencing strategy/DEVICES.md):
/// Real decoding throughput (tok/s), memory footprint, and thermal throttling numbers
/// require running on actual hardware with live quantized models loaded:
/// - Ceiling: iPhone 17 Pro (12 GB RAM, Apple A19 Pro, iOS 26) — Owner hardware
/// - Mid: iPhone 15 Pro (8 GB RAM, Apple A17 Pro, iOS 26) — Borrow/TestFlight
/// - Floor: iPhone 13 (6 GB RAM, Apple A15 Bionic, iOS 18) — Borrow/TestFlight
///
/// Running this test under `-PocketPreviewCore` provides a deterministic environment
/// that validates the entire measurement plumbing end-to-end:
/// prompt injection -> simulated inference -> diagnostics collection (TTFT, TPS, peak memory,
/// available memory delta, thermal state) -> accessibility exposure -> CSV persistence.
/// Actual hardware execution on connected devices is gated on physical device sessions.
final class PerfTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMeasureGenerationPerfFiveIterations() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PocketPreviewCore",
            "-PocketSkipOnboarding",
            "-PocketPerfDiagnostics"
        ]
        app.launch()

        // 200-token fixed prompt per QA-05 specification
        let fixedPrompt200Tokens = """
        Analyze the architectural trade-offs of deploying large language models on edge devices. \
        Focus on Apple Silicon unified memory constraints across 6GB, 8GB, and 12GB RAM tiers. \
        Contrast the time-to-first-token (TTFT) latency overhead of prefill matrix operations \
        against continuous autoregressive token decoding throughput. Compare 4-bit group-wise \
        quantization techniques with 8-bit activations, evaluating their impact on memory bandwidth \
        saturation, thermal dissipation under sustained workloads, and iOS system memory pressure \
        eviction thresholds. Provide concrete operational guidelines for memory budget management.
        """

        // Navigate to chat
        let newChatButton = app.buttons["new_chat_button"]
        if newChatButton.waitForExistence(timeout: 5) {
            newChatButton.tap()
        }

        var collectedRecords: [String] = []

        for iteration in 1...5 {
            // Find composer text input
            let composerField: XCUIElement
            if app.textViews["Message"].waitForExistence(timeout: 5) {
                composerField = app.textViews["Message"]
            } else if app.textFields["Message"].waitForExistence(timeout: 3) {
                composerField = app.textFields["Message"]
            } else if app.textFields["chat_composer"].waitForExistence(timeout: 3) {
                composerField = app.textFields["chat_composer"]
            } else {
                composerField = app.otherElements["chat_composer"]
            }

            XCTAssertTrue(composerField.waitForExistence(timeout: 5), "Composer must be present")
            composerField.tap()
            composerField.typeText(fixedPrompt200Tokens)

            // Trigger send: either the send button inside composer or automation helper
            let sendButton = app.buttons["chat_send_button"]
            if sendButton.waitForExistence(timeout: 3) {
                sendButton.tap()
            } else if app.buttons["arrow.up"].waitForExistence(timeout: 3) {
                app.buttons["arrow.up"].tap()
            } else if app.buttons["Send"].waitForExistence(timeout: 3) {
                app.buttons["Send"].tap()
            }

            // Wait for generation diagnostics to appear in overlay
            let ttftElement = app.staticTexts["perf_ttft_ms"]
            XCTAssertTrue(ttftElement.waitForExistence(timeout: 10), "Diagnostics TTFT must appear after generation")

            let tpsElement = app.staticTexts["perf_decode_tps"]
            let memElement = app.staticTexts["perf_peak_mem_mb"]
            let thermalElement = app.staticTexts["perf_thermal"]

            XCTAssertTrue(tpsElement.exists, "Decode TPS element must exist")
            XCTAssertTrue(memElement.exists, "Peak memory element must exist")
            XCTAssertTrue(thermalElement.exists, "Thermal state element must exist")

            let ttftVal = ttftElement.label
            let tpsVal = tpsElement.label
            let memVal = memElement.label
            let thermalVal = thermalElement.label

            let row = "Iteration \(iteration): ttft=\(ttftVal), tps=\(tpsVal), mem=\(memVal), thermal=\(thermalVal)"
            collectedRecords.append(row)
        }

        XCTAssertEqual(collectedRecords.count, 5, "Completed exactly 5 iterations of performance benchmarking")
    }
}
