@testable import RepoPrompt
import XCTest

final class AntigravityPollCapTimeoutTests: XCTestCase {
    func testDetectsStdoutTimedOutMarker() {
        XCTAssertTrue(AntigravityStreamParser.isPrintModePollCapTimeout(
            stdout: "I will read X.\nError: timed out waiting for response\n", logTail: nil
        ))
    }

    func testDetectsLogPollCapSignature() {
        XCTAssertTrue(AntigravityStreamParser.isPrintModePollCapTimeout(
            stdout: "", logTail: "printmode.go:289] Print mode: timed out after 1494 polls (printed=253)"
        ))
    }

    func testNormalOutputIsNotFlagged() {
        XCTAssertFalse(AntigravityStreamParser.isPrintModePollCapTimeout(
            stdout: "Here is the review:\n- looks good\n", logTail: "some normal log line"
        ))
    }
}
