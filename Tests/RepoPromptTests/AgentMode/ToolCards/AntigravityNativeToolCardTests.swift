@testable import RepoPrompt
import XCTest

/// agy surfaces native tools (`view_file`, `run_command`, …) whose args use PascalCase keys
/// (`AbsolutePath`, `CommandLine`). These fall through `AgentToolCardRenderSummary.build` to the
/// generic native handler, which must expose the specific argument as the card subtitle so the card
/// says WHICH file / WHAT command — not just the humanized tool name.
final class AntigravityNativeToolCardTests: XCTestCase {
    private func card(_ tool: String, _ args: [String: Any]) -> AgentToolCardRenderSummary? {
        AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: tool, statusWord: "success", rawObject: args, argsObject: args
        )
    }

    func testViewFileCardShowsAbsolutePath() throws {
        let c = try XCTUnwrap(card("view_file", ["AbsolutePath": "/Users/dev/x.swift", "toolSummary": "View x.swift"]))
        XCTAssertEqual(c.title, "View File")
        XCTAssertEqual(c.subtitle, "/Users/dev/x.swift")
    }

    func testRunCommandCardShowsCommandLine() throws {
        let c = try XCTUnwrap(card("run_command", ["CommandLine": "git diff --name-only main", "Cwd": "/x", "toolSummary": "Run git diff"]))
        XCTAssertEqual(c.title, "Run Command")
        XCTAssertEqual(c.subtitle, "git diff --name-only main")
    }

    func testNativeToolFallsBackToToolSummaryWhenNoSpecificArg() throws {
        let c = try XCTUnwrap(card("some_native_tool", ["toolSummary": "Did a thing"]))
        XCTAssertEqual(c.subtitle, "Did a thing")
    }
}
