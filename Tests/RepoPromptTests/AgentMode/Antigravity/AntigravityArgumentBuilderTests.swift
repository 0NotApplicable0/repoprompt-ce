@testable import RepoPromptApp
import XCTest

final class AntigravityArgumentBuilderTests: XCTestCase {
    private func consecutive(_ array: [String], _ pair: [String]) -> Bool {
        guard pair.count == 2 else { return false }
        for index in array.indices.dropLast() where array[index] == pair[0] && array[index + 1] == pair[1] {
            return true
        }
        return false
    }

    func testCombinedPromptOmitsEmptySystem() {
        let prompt = AntigravityAgentProvider.combinedPrompt(system: "   ", user: "do x")
        XCTAssertTrue(prompt.contains(AntigravityAgentProvider.executionCompletionGuidance))
        XCTAssertTrue(prompt.hasSuffix("do x"))
    }

    func testCombinedPromptJoinsSystemAndUser() {
        let combined = AntigravityAgentProvider.combinedPrompt(system: "be terse", user: "do x")
        XCTAssertTrue(combined.contains("be terse"))
        XCTAssertTrue(combined.contains("do x"))
        XCTAssertTrue(combined.contains("\n\n"))
    }

    func testBuildArgumentsBaseShape() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil
        )
        // The prompt is delivered via STDIN, not argv: argv starts with a bare `--print`.
        XCTAssertEqual(args.first, "--print")
        XCTAssertFalse(args.contains("hello"))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("--print-timeout"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--add-dir"))
        XCTAssertFalse(args.contains("--log-file"))
    }

    func testBuildArgumentsIncludesModelWorkspaceAndLog() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "gemini-3.1-pro-preview"),
            workspacePath: "/tmp/ws",
            logFilePath: "/tmp/agy.log"
        )
        XCTAssertTrue(consecutive(args, ["--model", "gemini-3.1-pro-preview"]))
        XCTAssertTrue(consecutive(args, ["--add-dir", "/tmp/ws"]))
        XCTAssertTrue(consecutive(args, ["--log-file", "/tmp/agy.log"]))
    }

    func testBuildArgumentsOmitsBlankModel() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "   "),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--model"))
    }

    func testBuildArgumentsOmitsDefaultSentinelModel() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "default"),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--model"))
    }

    // MARK: - Inline prompt (agy honors `--model` only when the prompt is the `--print` argv value)

    func testBuildArgumentsInlinesPromptAsPrintValueWhenProvided() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: "do the thing"
        )
        // agy drops `--model` when the prompt arrives via a bare `--print` + STDIN, so the prompt
        // is delivered as the `--print` argument value: argv leads with `--print <prompt>`.
        XCTAssertEqual(Array(args.prefix(2)), ["--print", "do the thing"])
    }

    func testBuildArgumentsOmitsInlinePromptValueWhenNil() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: nil
        )
        // No inline prompt: the prompt is delivered via STDIN, so `--print` stays bare and the
        // token after it is a flag, not prompt text.
        XCTAssertEqual(args.first, "--print")
        XCTAssertTrue(args.count == 1 || args[1].hasPrefix("--"))
    }

    func testBuildArgumentsInlinePromptStillEmitsModelFlag() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "Gemini 3.1 Pro (Low)"),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: "hello"
        )
        XCTAssertEqual(Array(args.prefix(2)), ["--print", "hello"])
        XCTAssertTrue(consecutive(args, ["--model", "Gemini 3.1 Pro (Low)"]))
    }

    func testShouldInlinePromptTrueForSmallPrompt() {
        XCTAssertTrue(AntigravityAgentProvider.shouldInlinePrompt("small prompt"))
        XCTAssertTrue(AntigravityAgentProvider.shouldInlinePrompt(""))
    }

    func testShouldInlinePromptFalseForOversizedPrompt() {
        let oversized = String(repeating: "a", count: AntigravityAgentProvider.maxInlinePromptBytes + 1)
        XCTAssertFalse(AntigravityAgentProvider.shouldInlinePrompt(oversized))
    }

    func testShouldInlinePromptCountsUTF8BytesNotCharacters() {
        // A multi-byte grapheme prompt just over the byte budget in UTF-8 must fall back to STDIN
        // even though its Swift `count` (grapheme count) is far below the budget.
        let emojiCount = AntigravityAgentProvider.maxInlinePromptBytes / 4 + 1 // each is 4 UTF-8 bytes
        let oversized = String(repeating: "😀", count: emojiCount)
        XCTAssertLessThan(oversized.count, AntigravityAgentProvider.maxInlinePromptBytes)
        XCTAssertGreaterThan(oversized.utf8.count, AntigravityAgentProvider.maxInlinePromptBytes)
        XCTAssertFalse(AntigravityAgentProvider.shouldInlinePrompt(oversized))
    }

    func testMaxInlinePromptBytesLeavesArgMaxHeadroom() {
        // Must stay well under macOS ARG_MAX (1 MiB total for argv + environment) so the inlined
        // prompt plus flags plus the inherited environment can never hit E2BIG.
        XCTAssertLessThanOrEqual(AntigravityAgentProvider.maxInlinePromptBytes, 512 * 1024)
    }

    func testSandboxCanBeDisabled() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: false),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsSandboxedConfigEmitsSandbox() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: true, dangerouslySkipPermissions: false),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    func testBuildArgumentsFullAccessEmitsSkipPermissionsAndNoSandbox() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: false, dangerouslySkipPermissions: true),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsFullAccessWinsWhenBothFlagsSet() {
        // Defensive: dangerouslySkipPermissions takes precedence over useSandbox.
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: true, dangerouslySkipPermissions: true),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsOmitsConversationByDefault() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--conversation"))
    }

    func testBuildArgumentsIncludesConversationWhenResuming() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: "/tmp/agy.log",
            resumeConversationID: "abc-123"
        )
        XCTAssertTrue(consecutive(args, ["--conversation", "abc-123"]))
    }

    func testConfigDefaultMaxPrintResumesIsBounded() {
        XCTAssertEqual(AntigravityAgentConfig().maxPrintResumes, 6)
    }

    func testConfigClampsNegativeMaxPrintResumesToZero() {
        XCTAssertEqual(AntigravityAgentConfig(maxPrintResumes: -3).maxPrintResumes, 0)
    }

    func testPermissionLevelMapping() {
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.useSandbox)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.dangerouslySkipPermissions)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.useSandbox)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.dangerouslySkipPermissions)
    }

    func testPermissionLevelHasTwoCases() {
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.allCases.count, 2)
    }

    func testPermissionLevelFromRawValue() {
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "fullAccess"), .fullAccess)
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "managedDefault"), .managedDefault)
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: nil), .managedDefault)
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "bogus"), .managedDefault)
    }
}
