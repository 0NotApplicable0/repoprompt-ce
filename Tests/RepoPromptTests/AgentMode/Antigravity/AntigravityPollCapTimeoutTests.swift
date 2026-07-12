@testable import RepoPromptApp
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

    // MARK: - Auto-resume decision

    func testResumesWhenCappedWithinBudget() {
        XCTAssertTrue(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 0, maxResumes: 6, hasConversationID: true))
        XCTAssertTrue(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 5, maxResumes: 6, hasConversationID: true))
    }

    func testDoesNotResumeWhenCompleted() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .completed, turn: 0, maxResumes: 6, hasConversationID: true))
    }

    func testDoesNotResumeWhenBudgetExhausted() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 6, maxResumes: 6, hasConversationID: true))
    }

    func testDoesNotResumeWhenDisabled() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 0, maxResumes: 0, hasConversationID: true))
    }

    func testDoesNotResumeWithoutConversationID() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 0, maxResumes: 6, hasConversationID: false))
    }

    func testClassifiesResumedEmptyOutputAsIncomplete() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data(), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .incomplete)
    }

    func testClassifiesNonEmptyOutputAsCompleted() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("final answer".utf8), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .completed)
    }

    func testClassifiesPollCapOutputAsCapped() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("Error: timed out waiting for response\n".utf8),
            logTail: nil,
            isFirstTurn: false
        )

        XCTAssertEqual(outcome, .capped)
    }

    func testResumesIncompleteTurnWhenConversationIDIsAvailable() {
        XCTAssertTrue(AntigravityAgentProvider.shouldResume(
            outcome: .incomplete, turn: 0, maxResumes: 6, hasConversationID: true
        ))
    }

    func testDoesNotResumeIncompleteTurnWithoutConversationID() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(
            outcome: .incomplete, turn: 0, maxResumes: 6, hasConversationID: false
        ))
    }

    func testExhaustedMessageMentionsResumeCountWhenEnabled() {
        let msg = AntigravityAgentProvider.cappedExhaustedMessage(maxResumes: 6, resumed: 6)
        XCTAssertTrue(msg.contains("6 auto-resume"))
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("split"))
    }

    func testIncompleteExhaustedMessageDoesNotBlamePrintCap() {
        let msg = AntigravityAgentProvider.incompleteExhaustedMessage(maxResumes: 6, resumed: 6)

        XCTAssertTrue(msg.contains("6 auto-resume"))
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("without printing a final response"))
        XCTAssertFalse(msg.contains("1494 polls"))
    }

    func testExhaustedMessageWhenResumeDisabled() {
        let msg = AntigravityAgentProvider.cappedExhaustedMessage(maxResumes: 0, resumed: 0)
        XCTAssertTrue(msg.contains("1494 polls"))
    }
}
