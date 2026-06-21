@testable import RepoPrompt
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
        XCTAssertEqual(AntigravityAgentProvider.combinedPrompt(system: "   ", user: "do x"), "do x")
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
