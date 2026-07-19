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

    func testHeadlessPermissionDenialWinsOverPartialOutputAndPollCap() {
        let rawLog = """
        I0718 tool_confirmation_manager.go:183] Print mode: soft-denying tool confirmation \"McpTool\" at step 3
        I0718 http_helpers.go:228] URL: https://private.invalid/path Trace: secret-trace
        """

        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("partial answer\nError: timed out waiting for response\n".utf8),
            stderr: nil,
            logTail: rawLog,
            isFirstTurn: true
        )) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, AntigravityAgentProvider.headlessPermissionDenialMessage)
            XCTAssertFalse(detail.contains("private.invalid"))
            XCTAssertFalse(detail.contains("secret-trace"))
        }
    }

    func testDetectsHeadlessPermissionDenialFromStderr() {
        let stderr = "The tool required approval that headless mode cannot prompt for, so it was auto-denied."

        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("partial answer".utf8),
            stderr: stderr,
            logTail: nil,
            isFirstTurn: false
        )) { error in
            XCTAssertEqual(error.localizedDescription, AntigravityAgentProvider.headlessPermissionDenialMessage)
        }
    }

    func testDetectsVersionVaryingPermissionDenialSignatures() {
        let diagnostics = [
            "Tool confirmation for conversation abc step 3 (type=McpTool approved=false)",
            "user denied permission for mcp(RepoPromptCE)"
        ]

        for diagnostic in diagnostics {
            XCTAssertTrue(
                AntigravityAgentProvider.isHeadlessPermissionDenial(
                    stderr: nil,
                    logTail: diagnostic
                ),
                "Expected denial signature to match: \(diagnostic)"
            )
        }
    }

    func testProcessFailureRecognizesSoftDeniedSuccessfulExit() {
        let rawLog = """
        I0718 tool_confirmation_manager.go:183] Print mode: soft-denying tool confirmation \"McpTool\" at step 3
        I0718 http_helpers.go:228] URL: https://private.invalid/path Trace: secret-trace
        """

        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 0,
            timedOut: false,
            stderr: "",
            logTail: rawLog
        )

        XCTAssertEqual(error?.localizedDescription, AntigravityAgentProvider.headlessPermissionDenialMessage)
        XCTAssertFalse(error?.localizedDescription.contains("private.invalid") == true)
        XCTAssertFalse(error?.localizedDescription.contains("secret-trace") == true)
    }

    func testFirstTurnEmptySuccessReturnsActionableError() {
        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data(),
            logTail: nil,
            isFirstTurn: true
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Antigravity CLI returned no meaningful output. Ensure you are signed in by running `agy` once interactively."
            )
        }
    }

    func testFirstTurnEmptyOutputWithOrdinaryLogRemainsNoOutputError() {
        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data(" \n\t".utf8),
            logTail: "I0718 manager.go:1095] Slash commands unchanged, skipping update",
            isFirstTurn: true
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Antigravity CLI returned no meaningful output. Ensure you are signed in by running `agy` once interactively."
            )
            XCTAssertNotEqual(error.localizedDescription, AntigravityAgentProvider.headlessPermissionDenialMessage)
        }
    }

    func testTimeoutWithoutPermissionDenialRemainsTimeout() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 0,
            timedOut: true,
            stderr: "ordinary diagnostic",
            logTail: nil
        )

        XCTAssertEqual(error?.localizedDescription, "Antigravity CLI timed out.")
    }

    func testWhitespaceOnlyOutputIsIncompleteOnResume() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("  \n\t".utf8), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .incomplete)
    }

    func testInvalidUTF8IsNotSuccessfulCompletion() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data([0xFF, 0xFE]), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .incomplete)
    }

    func testMissingTerminationStatusIsAnError() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: nil,
            timedOut: false,
            stderr: "",
            logTail: nil
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.localizedDescription.contains("without reporting an exit status") == true)
    }

    func testNonzeroFailureDoesNotExposeRawDiagnostics() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 1,
            timedOut: false,
            stderr: "request failed for https://private.invalid Trace: secret-trace",
            logTail: "internal state"
        )

        XCTAssertEqual(error?.localizedDescription, "Antigravity CLI failed (exit 1). Run `agy` interactively to inspect the failure.")
        XCTAssertFalse(error?.localizedDescription.contains("private.invalid") == true)
        XCTAssertFalse(error?.localizedDescription.contains("secret-trace") == true)
    }

    func testInformationalTokenSourceDoesNotImplyAuthenticationFailure() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 17,
            timedOut: false,
            stderr: "Auto-saving refreshed token from token source callback",
            logTail: nil
        )

        XCTAssertEqual(
            error?.localizedDescription,
            "Antigravity CLI failed (exit 17). Run `agy` interactively to inspect the failure."
        )
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
