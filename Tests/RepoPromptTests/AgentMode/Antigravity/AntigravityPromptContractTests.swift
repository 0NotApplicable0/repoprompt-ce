@testable import RepoPrompt
import XCTest

final class AntigravityPromptContractTests: XCTestCase {
    func testCombinedPromptIncludesAsyncCommandCompletionGuidance() {
        let prompt = AntigravityAgentProvider.combinedPrompt(
            system: "System instructions",
            user: "Run focused tests."
        )

        XCTAssertTrue(prompt.contains("Tests and shell commands are allowed"))
        XCTAssertTrue(prompt.contains("background or async task"))
        XCTAssertTrue(prompt.contains("do not end the turn"))
        XCTAssertTrue(prompt.contains("final output and exit status"))
        XCTAssertTrue(prompt.contains("verification is still pending or unavailable"))
    }

    func testCombinedPromptKeepsUserRequestAfterGuidance() throws {
        let user = "Reply exactly RPCE_AGY_OK."
        let prompt = AntigravityAgentProvider.combinedPrompt(
            system: "System instructions",
            user: user
        )

        XCTAssertTrue(prompt.hasSuffix(user))
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: AntigravityAgentProvider.executionCompletionGuidance)?.lowerBound),
            try XCTUnwrap(prompt.range(of: user)?.lowerBound)
        )
    }

    func testCombinedPromptIncludesGuidanceWithoutSystemPrompt() {
        let user = "Run /usr/bin/true."
        let prompt = AntigravityAgentProvider.combinedPrompt(system: "", user: user)

        XCTAssertTrue(prompt.contains(AntigravityAgentProvider.executionCompletionGuidance))
        XCTAssertTrue(prompt.hasSuffix(user))
    }
}
