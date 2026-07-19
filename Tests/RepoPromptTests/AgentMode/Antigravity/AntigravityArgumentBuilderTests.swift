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
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
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

    func testBuildArgumentsExplicitSandboxOnlyConfigEmitsSandbox() {
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

    func testBuildArgumentsSandboxedAutoApproveEmitsBothFlags() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: true, dangerouslySkipPermissions: true),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(args.contains("--sandbox"))
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
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.isWarning)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.supportsHeadlessRun)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.useSandbox)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.dangerouslySkipPermissions)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.isWarning)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.supportsHeadlessRun)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.useSandbox)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.dangerouslySkipPermissions)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.isWarning)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.supportsHeadlessRun)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.dangerouslySkipPermissions)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.supportsHeadlessRun)
    }

    func testPermissionLevelHasThreeUserSelectableCases() {
        XCTAssertEqual(
            AntigravityAgentToolPreferences.PermissionLevel.allCases,
            [.managedDefault, .sandboxedAutoApprove, .fullAccess]
        )
        XCTAssertFalse(
            AntigravityAgentToolPreferences.PermissionLevel.allCases.contains(.safeManagedUnavailable)
        )
    }

    func testPermissionLevelFromRawValue() {
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "fullAccess"), .fullAccess)
        XCTAssertEqual(
            AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "sandboxedAutoApprove"),
            .sandboxedAutoApprove
        )
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "managedDefault"), .managedDefault)
        XCTAssertEqual(
            AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "safeManagedUnavailable"),
            .managedDefault
        )
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: nil), .managedDefault)
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "bogus"), .managedDefault)
    }

    func testRuntimeOnlyPermissionLevelCannotBePersisted() throws {
        let suiteName = "AntigravityArgumentBuilderTests.runtime-only-permission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AntigravityAgentToolPreferences.setPermissionLevel(
            .safeManagedUnavailable,
            defaults: defaults
        )

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults),
            .managedDefault
        )
    }

    func testPermissionBindingParserRejectsInternalSafeManagedSentinel() {
        XCTAssertNil(AgentProviderPermissionLevelID(
            providerID: .antigravity,
            subagentRawValue: AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.rawValue
        ))
        XCTAssertEqual(
            AgentProviderPermissionLevelID(
                providerID: .antigravity,
                subagentRawValue: AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.rawValue
            ),
            .antigravity(.sandboxedAutoApprove)
        )
    }

    func testSubagentPreferenceSetterCannotPersistInternalSafeManagedSentinel() throws {
        let suiteName = "AntigravityArgumentBuilderTests.subagent-runtime-only-permission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .antigravity(.safeManagedUnavailable),
            for: .antigravity,
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.string(forKey: AgentModePermissionPreferences.providerPermissionLevelKey(for: .antigravity)),
            AntigravityAgentToolPreferences.PermissionLevel.managedDefault.rawValue
        )
        XCTAssertEqual(
            AgentModePermissionPreferences.providerSubagentPermissionLevel(
                for: .antigravity,
                defaults: defaults
            ),
            .antigravity(.managedDefault)
        )
    }

    @MainActor
    func testRuntimePermissionBindingPropagatesSafeAndExplicitProfiles() throws {
        let suiteName = "AntigravityArgumentBuilderTests.runtime-permissions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: nil,
            codexMCPServerEntries: { [] }
        )

        XCTAssertEqual(
            store.runtimePermission(for: .antigravity, profile: .mcpSafeDefaults)
                .antigravityPermissionLevel,
            .safeManagedUnavailable
        )
        XCTAssertEqual(
            store.runtimePermission(
                for: .antigravity,
                profile: .providerOverride(.antigravity(.sandboxedAutoApprove))
            ).antigravityPermissionLevel,
            .sandboxedAutoApprove
        )
    }

    func testSafeManagedPreparationFailsBeforeLaunchingAntigravity() async {
        let config = AntigravityAgentConfig(supportsHeadlessRun: false)
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "/definitely/not/an/agy/binary",
            additionalPaths: []
        ))
        let provider = AntigravityAgentProvider(runner: runner, config: config)

        do {
            _ = try await provider.streamAgentMessage(AgentMessage(userMessage: "do not launch"))
            XCTFail("Safe Managed must fail before returning a runnable stream")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                AntigravityAgentProvider.safeManagedUnavailableMessage
            )
        }
        await provider.dispose()
        XCTAssertEqual(
            AntigravityAgentProvider.preparationPolicyFailureMessage(for: config),
            AntigravityAgentProvider.safeManagedUnavailableMessage
        )
    }

    func testSafeManagedCapabilitySummaryReportsAntigravityUnavailable() throws {
        let suiteName = "AntigravityArgumentBuilderTests.safe-managed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
            for: .antigravity,
            profile: .mcpSafeDefaults,
            availability: .none
        )

        XCTAssertEqual(summary.fileMutation, "Unavailable under Safe Managed")
        XCTAssertEqual(summary.shell, "Not launched")
        XCTAssertTrue(summary.externalMCP.contains("cannot be isolated"))
        XCTAssertTrue(summary.warnings.contains { $0.contains("disabled for Safe Managed") })
    }

    func testSandboxedAutoApproveCapabilitySummaryDisclosesGlobalMCPRisk() throws {
        let suiteName = "AntigravityArgumentBuilderTests.sandboxed-auto-approve.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
            for: .antigravity,
            profile: .providerOverride(.antigravity(.sandboxedAutoApprove)),
            availability: .none
        )

        XCTAssertEqual(summary.shell, "Antigravity terminal sandbox enabled")
        XCTAssertEqual(summary.externalMCP, "All configured MCP tools auto-approved")
        XCTAssertTrue(summary.warnings.contains { $0.contains("third-party MCP side effects") })
    }
}
