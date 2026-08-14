import XCTest
@testable import stt_hotkey

final class TranscriptionModelTests: XCTestCase {
    func testUsesGPTTranscribeModel() {
        XCTAssertEqual(openAITranscriptionModel, "gpt-transcribe")
    }
}
