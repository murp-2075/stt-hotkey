import XCTest
@testable import stt_hotkey

final class TranscriptionModelTests: XCTestCase {
    func testUsesLegacyMiniTranscriptionModel() {
        XCTAssertEqual(openAITranscriptionModel, "gpt-4o-mini-transcribe")
    }
}
