import XCTest

final class RunnerTests: XCTestCase {
  func testRecordingHasAMicrophonePermissionExplanation() {
    let reason = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    XCTAssertFalse(reason?.isEmpty ?? true)
  }
}
