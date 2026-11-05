import XCTest
@testable import PocketAI

final class ModelsSegmentsTests: XCTestCase {
    func testMacSegmentExistsOnlyWhenAMacIsPaired() {
        XCTAssertEqual(ModelsView.segmentTitles(hasPairedMac: false), ["On this iPhone", "Browse"])
        XCTAssertEqual(ModelsView.segmentTitles(hasPairedMac: true), ["On this iPhone", "Browse", "On your Mac"])
    }
}
