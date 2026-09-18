@testable import RepoPromptApp
import XCTest

final class GrokArgumentBuilderTests: XCTestCase {
    private func consecutive(_ array: [String], _ pair: [String]) -> Bool {
        guard pair.count == 2 else { return false }
        for index in array.indices.dropLast() where array[index] == pair[0] && array[index + 1] == pair[1] {
            return true
        }
        return false
    }

    // MARK: - combinedPrompt

    func testCombinedPromptOmitsEmptySystem() {
        XCTAssertEqual(GrokAgentProvider.combinedPrompt(system: "   ", user: "do x"), "do x")
    }

    func testCombinedPromptJoinsSystemAndUser() {
        let combined = GrokAgentProvider.combinedPrompt(system: "be terse", user: "do x")
        XCTAssertTrue(combined.contains("be terse"))
        XCTAssertTrue(combined.contains("do x"))
        XCTAssertTrue(combined.contains("\n\n"))
    }

    // MARK: - buildArguments base shape

    func testBuildArgumentsBaseShape() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        // The prompt is delivered via a temp file referenced by `--prompt-file`, never on argv.
        XCTAssertEqual(args.first, "--prompt-file")
        XCTAssertTrue(consecutive(args, ["--prompt-file", "/tmp/prompt.txt"]))
        // `--output-format streaming-json` is always passed so grok streams NDJSON events.
        XCTAssertTrue(consecutive(args, ["--output-format", "streaming-json"]))
        // No model, no workspace, no debug configured here.
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--cwd"))
        XCTAssertFalse(args.contains("--debug"))
        XCTAssertFalse(args.contains("--debug-file"))
    }

    func testBuildArgumentsIncludesModelWorkspaceAndDebug() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(modelString: "grok-build", enableDebugLogging: true),
            workspacePath: "/tmp/ws",
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: "/tmp/grok.log"
        )
        XCTAssertTrue(consecutive(args, ["--model", "grok-build"]))
        XCTAssertTrue(consecutive(args, ["--cwd", "/tmp/ws"]))
        XCTAssertTrue(args.contains("--debug"))
        XCTAssertTrue(consecutive(args, ["--debug-file", "/tmp/grok.log"]))
    }

    // MARK: - model flag handling

    func testBuildArgumentsOmitsBlankModel() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(modelString: "   "),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertFalse(args.contains("--model"))
    }

    func testBuildArgumentsOmitsDefaultSentinelModel() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(modelString: "default"),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertFalse(args.contains("--model"))
    }

    // MARK: - workspace / cwd handling

    func testBuildArgumentsOmitsCwdWhenWorkspaceNil() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertFalse(args.contains("--cwd"))
    }

    func testBuildArgumentsOmitsCwdWhenWorkspaceEmpty() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(),
            workspacePath: "",
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertFalse(args.contains("--cwd"))
    }

    // MARK: - permission / sandbox handling

    func testBuildArgumentsManagedDefaultEmitsSandboxAndBypass() {
        // Managed default: sandbox the workspace AND bypass permissions so MCP tool calls
        // never stall on approval prompts in headless mode.
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(useSandbox: true, dangerouslySkipPermissions: false),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertTrue(consecutive(args, ["--sandbox", "workspace"]))
        XCTAssertTrue(consecutive(args, ["--permission-mode", "bypassPermissions"]))
    }

    func testBuildArgumentsFullAccessBypassesPermissionsWithoutSandbox() {
        // Full Access: bypass permissions WITHOUT a sandbox.
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(useSandbox: false, dangerouslySkipPermissions: true),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertTrue(consecutive(args, ["--permission-mode", "bypassPermissions"]))
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsFullAccessWinsWhenBothFlagsSet() {
        // Defensive: dangerouslySkipPermissions takes precedence — no sandbox is emitted.
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(useSandbox: true, dangerouslySkipPermissions: true),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertTrue(consecutive(args, ["--permission-mode", "bypassPermissions"]))
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsAlwaysBypassesPermissions() {
        // Both permission levels must bypass approvals, so `--permission-mode bypassPermissions`
        // is present regardless of the sandbox/full-access choice.
        for skip in [false, true] {
            let args = GrokAgentProvider.buildArguments(
                config: GrokAgentConfig(dangerouslySkipPermissions: skip),
                workspacePath: nil,
                promptFilePath: "/tmp/prompt.txt",
                debugFilePath: nil
            )
            XCTAssertTrue(consecutive(args, ["--permission-mode", "bypassPermissions"]))
        }
    }

    // MARK: - debug flag handling

    func testBuildArgumentsOmitsDebugWhenPathNil() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertFalse(args.contains("--debug"))
        XCTAssertFalse(args.contains("--debug-file"))
    }

    func testBuildArgumentsOmitsDebugWhenPathEmpty() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: ""
        )
        XCTAssertFalse(args.contains("--debug"))
        XCTAssertFalse(args.contains("--debug-file"))
    }

    // MARK: - full argv ordering

    func testBuildArgumentsFullManagedConfigOrdering() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(modelString: "grok-build"),
            workspacePath: "/tmp/ws",
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: "/tmp/grok.log"
        )
        XCTAssertEqual(args, [
            "--prompt-file", "/tmp/prompt.txt",
            "--output-format", "streaming-json",
            "--model", "grok-build",
            "--cwd", "/tmp/ws",
            "--sandbox", "workspace",
            "--permission-mode", "bypassPermissions",
            "--debug", "--debug-file", "/tmp/grok.log"
        ])
    }

    func testBuildArgumentsFullAccessConfigOrdering() {
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(
                useSandbox: false,
                dangerouslySkipPermissions: true
            ),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertEqual(args, [
            "--prompt-file", "/tmp/prompt.txt",
            "--output-format", "streaming-json",
            "--permission-mode", "bypassPermissions"
        ])
    }

    // MARK: - permission preferences

    func testPermissionLevelMapping() {
        XCTAssertTrue(GrokAgentToolPreferences.PermissionLevel.managedDefault.useSandbox)
        XCTAssertFalse(GrokAgentToolPreferences.PermissionLevel.managedDefault.dangerouslySkipPermissions)
        XCTAssertFalse(GrokAgentToolPreferences.PermissionLevel.fullAccess.useSandbox)
        XCTAssertTrue(GrokAgentToolPreferences.PermissionLevel.fullAccess.dangerouslySkipPermissions)
    }

    func testPermissionLevelHasTwoCases() {
        XCTAssertEqual(GrokAgentToolPreferences.PermissionLevel.allCases, [.managedDefault, .fullAccess])
    }

    func testPermissionLevelFromRawValue() {
        XCTAssertEqual(GrokAgentToolPreferences.PermissionLevel.from(rawValue: "fullAccess"), .fullAccess)
        XCTAssertEqual(GrokAgentToolPreferences.PermissionLevel.from(rawValue: "managedDefault"), .managedDefault)
        XCTAssertEqual(GrokAgentToolPreferences.PermissionLevel.from(rawValue: nil), .managedDefault)
        let unknown = GrokAgentToolPreferences.PermissionLevel.from(rawValue: "bogus")
        XCTAssertFalse(GrokAgentToolPreferences.PermissionLevel.allCases.contains(unknown))
        XCTAssertNil(AgentProviderPermissionLevelID(providerID: .grok, subagentRawValue: unknown.rawValue))
    }

    @MainActor
    func testRuntimePermissionBindingPreservesKnownGrokProfiles() throws {
        let suiteName = "GrokArgumentBuilderTests.runtime-permissions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: nil,
            codexMCPServerEntries: { [] }
        )

        XCTAssertEqual(store.runtimePermission(for: .grok, profile: .mcpSafeDefaults).grokPermissionLevel, .managedDefault)
        for level in GrokAgentToolPreferences.PermissionLevel.allCases {
            XCTAssertEqual(
                store.runtimePermission(for: .grok, profile: .providerOverride(.grok(level))).grokPermissionLevel,
                level
            )
            XCTAssertEqual(
                AgentProviderPermissionLevelID(providerID: .grok, subagentRawValue: level.rawValue),
                .grok(level)
            )
            XCTAssertTrue(AgentRuntimeProviderService.shared.makeProvider(
                for: .grok, grokPermissionLevel: level
            ) is GrokAgentProvider)
        }
    }

    func testBuildArgumentsHonorsUseSandboxFalse() {
        // useSandbox=false (not full-access) must bypass permissions WITHOUT a sandbox.
        let args = GrokAgentProvider.buildArguments(
            config: GrokAgentConfig(useSandbox: false, dangerouslySkipPermissions: false),
            workspacePath: nil,
            promptFilePath: "/tmp/prompt.txt",
            debugFilePath: nil
        )
        XCTAssertTrue(consecutive(args, ["--permission-mode", "bypassPermissions"]))
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testUnavailableCapabilitySummaryDoesNotAdvertiseFullAccess() throws {
        let suiteName = "GrokArgumentBuilderTests.unavailable-capability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future_permission", forKey: "grokToolPermissionLevel")

        let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
            for: .grok,
            profile: .userConfigured,
            availability: .none.assumingAvailable(.grok)
        )

        XCTAssertFalse(summary.isAvailable)
        XCTAssertTrue(summary.fileMutation.lowercased().contains("unavailable"))
        XCTAssertEqual(summary.shell, "Not launched")
        XCTAssertEqual(summary.externalMCP, "Not launched")
        XCTAssertTrue(summary.approvalModeDescription.lowercased().contains("reset"))
        XCTAssertTrue(summary.warnings.contains { $0.lowercased().contains("permission") })
    }

    func testManagedCapabilitySummaryDisclosesGlobalAutoApprovalRisk() throws {
        let suiteName = "GrokArgumentBuilderTests.managed-capability-summary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
            for: .grok,
            profile: .providerOverride(.grok(.managedDefault)),
            availability: .none
        )

        XCTAssertEqual(summary.shell, "Grok workspace sandbox enabled")
        XCTAssertEqual(summary.externalMCP, "All configured MCP tools auto-approved")
        XCTAssertEqual(summary.approvalModeDescription, "Approval: Auto-approve all; workspace sandbox on")
        XCTAssertTrue(summary.warnings.contains { $0.contains("external MCP side effects") })
    }
}
