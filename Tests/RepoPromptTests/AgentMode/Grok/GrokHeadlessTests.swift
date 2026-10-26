import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptProcess
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

/// Tests for grok's TOML MCP config management (`~/.grok/config.toml`,
/// `[mcp_servers.RepoPromptCE]`). Mirrors the agy integration-config tests but targets grok's
/// surgical TOML section manager instead of the gemini JSON map.
final class GrokIntegrationConfigurationTests: XCTestCase {
    func testConfigURLIsHomeLevelGrokConfigToml() {
        let url = GrokIntegrationConfiguration.configURL()
        XCTAssertTrue(url.path.hasSuffix(".grok/config.toml"), "unexpected path: \(url.path)")
    }

    func testMergedContentOnEmptyAddsRepoPromptSection() {
        let merged = GrokIntegrationConfiguration.mergedContent(existingContent: nil)
        XCTAssertFalse(merged.wasMCPServerAlreadyPresent)
        XCTAssertTrue(merged.content.contains(GrokIntegrationConfiguration.sectionHeader))
        XCTAssertTrue(merged.content.contains("command ="))
        XCTAssertTrue(merged.content.contains("enabled = true"))
        XCTAssertTrue(merged.content.contains("startup_timeout_sec = \(GrokIntegrationConfiguration.startupTimeoutSeconds)"))
    }

    func testMergedContentPreservesOtherServersAndContent() {
        let existing = """
        [cli]
        installer = "internal"

        [mcp_servers.other]
        command = "/usr/bin/other"
        enabled = true
        """
        let merged = GrokIntegrationConfiguration.mergedContent(existingContent: existing)
        XCTAssertFalse(merged.wasMCPServerAlreadyPresent)
        XCTAssertTrue(merged.content.contains("[mcp_servers.other]"), "other server dropped")
        XCTAssertTrue(merged.content.contains("[cli]"), "unrelated section dropped")
        XCTAssertTrue(merged.content.contains(GrokIntegrationConfiguration.sectionHeader))
    }

    func testMergedContentIsIdempotentAndReportsAlreadyPresent() {
        let first = GrokIntegrationConfiguration.mergedContent(existingContent: nil)
        let second = GrokIntegrationConfiguration.mergedContent(existingContent: first.content)
        XCTAssertTrue(second.wasMCPServerAlreadyPresent)
        XCTAssertEqual(first.content, second.content, "re-merge must be stable (no duplicate section)")
        // Exactly one RepoPrompt section header.
        let occurrences = second.content.components(separatedBy: GrokIntegrationConfiguration.sectionHeader).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testContentRemovingRepoPromptStripsOurSectionAndPreservesRest() throws {
        let existing = """
        [mcp_servers.other]
        command = "/usr/bin/other"
        enabled = true

        """ + GrokIntegrationConfiguration.mcpSectionString(for: .repoPrompt) + "\n"
        let removed = GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: existing)
        XCTAssertNotNil(removed)
        XCTAssertTrue(try XCTUnwrap(removed?.wasMCPServerPresent))
        XCTAssertFalse(try XCTUnwrap(removed?.content.contains(GrokIntegrationConfiguration.sectionHeader)))
        XCTAssertTrue(try XCTUnwrap(removed?.content.contains("[mcp_servers.other]")), "unrelated server must survive removal")
    }

    func testContentRemovingRepoPromptNilOnEmpty() {
        XCTAssertNil(GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: nil))
        XCTAssertNil(GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: ""))
    }

    func testMergeThenRemoveRoundTrips() throws {
        let merged = GrokIntegrationConfiguration.mergedContent(existingContent: nil)
        let removed = GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: merged.content)
        XCTAssertNotNil(removed)
        XCTAssertFalse(try XCTUnwrap(removed?.content.contains(GrokIntegrationConfiguration.sectionHeader)))
    }

    func testRemoveStripsDescendantTables() throws {
        let existing = """
        [mcp_servers.other]
        command = "/usr/bin/other"

        """ + GrokIntegrationConfiguration.mcpSectionString(for: .repoPrompt) + "\n" + """
        [mcp_servers.RepoPromptCE.env]
        FOO = "bar"

        [mcp_servers.keep]
        command = "/usr/bin/keep"
        """
        let removed = GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: existing)
        XCTAssertNotNil(removed)
        XCTAssertTrue(try XCTUnwrap(removed?.wasMCPServerPresent))
        XCTAssertFalse(try XCTUnwrap(removed?.content.contains(GrokIntegrationConfiguration.sectionHeader)))
        XCTAssertFalse(try XCTUnwrap(removed?.content.contains("[mcp_servers.RepoPromptCE.env]")), "descendant table must be removed with its parent")
        XCTAssertFalse(try XCTUnwrap(removed?.content.contains("FOO = \"bar\"")))
        XCTAssertTrue(try XCTUnwrap(removed?.content.contains("[mcp_servers.keep]")), "unrelated server after descendant must survive")
        XCTAssertTrue(try XCTUnwrap(removed?.content.contains("[mcp_servers.other]")))
    }

    // MARK: - Persisted tool catalog cache path

    func testPersistedProjectDirNameMatchesGrokEncoding() {
        // grok stores its per-cwd MCP catalog under projects/<dir>, encoding the absolute cwd by
        // dropping the leading slash and replacing remaining slashes with "-".
        XCTAssertEqual(
            GrokIntegrationConfiguration.persistedProjectDirName(forWorkspacePath: "/Users/dev/Projects/Repos/repoprompt-ce"),
            "Users-dev-Projects-Repos-repoprompt-ce"
        )
    }

    func testPersistedProjectDirNameTrimsTrailingSlashAndWhitespace() {
        XCTAssertEqual(
            GrokIntegrationConfiguration.persistedProjectDirName(forWorkspacePath: "  /Users/dev/proj/  "),
            "Users-dev-proj"
        )
    }

    func testPersistedProjectDirNameNilForEmptyOrSlashOnly() {
        XCTAssertNil(GrokIntegrationConfiguration.persistedProjectDirName(forWorkspacePath: nil))
        XCTAssertNil(GrokIntegrationConfiguration.persistedProjectDirName(forWorkspacePath: ""))
        XCTAssertNil(GrokIntegrationConfiguration.persistedProjectDirName(forWorkspacePath: "///"))
    }
}

/// Regression coverage for the Grok (`grok`) MCP client identity.
///
/// Unlike `agy` (which is Gemini-derived and may announce a `gemini*` clientInfo.name over MCP),
/// `grok` (xAI's Grok CLI) is an independent client. RepoPrompt still does not rely on grok's
/// announced name for routing — it uses PID-based routing keyed on the explicit "grok-client"
/// hint (`AgentProviderKind.grokMCPClientID`, surfaced via `AgentProviderKind.mcpClientNameHint`,
/// and registered by `GrokAgentProvider` via expected-PID routing). These tests lock in that the
/// explicit "grok-client" hint RepoPrompt uses for PID-based routing canonicalizes to the grok
/// family and is recognized as a known headless agent client, independent of whatever name
/// `grok` announces over MCP.
final class GrokMCPClientIdentityTests: XCTestCase {
    /// The hint RepoPrompt registers for grok (`AgentProviderKind.grokMCPClientID`).
    private let grokClientID = "grok-client"

    func testGrokClientCanonicalizesToGrokFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID(grokClientID), "grok-client")
    }

    func testBareGrokNameCanonicalizesToGrokFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok"), "grok-client")
    }

    func testGrokAnnouncedShellNameCanonicalizesToGrokFamily() {
        // Shell announcements retain the historical storage identity while matching the headless hint.
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell-RepoPromptCE"), "grok-shell")
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell-SomeOtherServer"), "grok-shell")
        XCTAssertTrue(MCPClientIdentity.matches("grok-client", "grok-shell-RepoPromptCE"))
    }

    func testNonGrokPrefixIsNotMisclassifiedAsGrok() {
        // A word that merely starts with the letters "grok" but is not a separated leading token
        // must NOT be swallowed into the grok family.
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("grokkenstein"))
    }

    func testGrokMCPClientIDHintMatchesGrokClientID() {
        // The provider kind's MCP client hint is the exact "grok-client" string these tests pin.
        XCTAssertEqual(AgentProviderKind.grokMCPClientID, grokClientID)
        XCTAssertEqual(AgentProviderKind.grok.mcpClientNameHint, grokClientID)
    }

    func testGrokClientIsRecognizedAsHeadlessAgentClient() {
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient(grokClientID))
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("grok-shell"))
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("grok-shell-RepoPromptCE"))
    }

    func testGrokStorageKeysRemainStableAcrossFamilyAliases() {
        for (name, expectedKey) in [
            ("grok-shell", "grok-shell"),
            ("grok-shell-RepoPromptCE", "grok-shell"),
            ("  GROK-SHELL-SomeOtherServer  ", "grok-shell"),
            ("grok", "grok-client"),
            ("grok-client", "grok-client"),
            ("grok v1.0.3", "grok-client"),
            ("grok-client/1.0.3", "grok-client")
        ] {
            XCTAssertEqual(MCPClientIdentity.storageKey(name), expectedKey, name)
        }
    }

    func testGrokShellAndClientAreSymmetricFamilyAliases() {
        for name in ["grok-shell", "grok-shell-RepoPromptCE", "grok-shell-SomeOtherServer"] {
            XCTAssertTrue(MCPClientIdentity.matches(name, grokClientID), name)
            XCTAssertTrue(MCPClientIdentity.matches(grokClientID, name), name)
            XCTAssertTrue(MCPClientIdentity.sameFamily(name, grokClientID), name)
            XCTAssertTrue(MCPClientIdentity.sameFamily(grokClientID, name), name)
            XCTAssertTrue(MCPClientIdentity.sameFamily(name, "grok v1.0.3"), name)
            XCTAssertFalse(MCPClientIdentity.matches(name, "cursor"), name)
            XCTAssertFalse(MCPClientIdentity.sameFamily(name, "antigravity-client"), name)
        }
    }

    func testGrokClientIsNotMisclassifiedAsAnotherFamily() {
        // The explicit "grok-client" hint must resolve to its own grok family and must never be
        // swallowed by another known client family (e.g. the gemini-cli branch).
        XCTAssertNotEqual(MCPClientIdentity.canonicalFamilyID(grokClientID), "gemini-cli-mcp-client")
        XCTAssertNotEqual(MCPClientIdentity.canonicalFamilyID(grokClientID), "antigravity-client")
    }

    func testGrokClientMatchesItselfAndBareGrok() {
        XCTAssertTrue(MCPClientIdentity.matches(grokClientID, grokClientID))
        XCTAssertTrue(MCPClientIdentity.matches(grokClientID, "grok"))
        XCTAssertTrue(MCPClientIdentity.sameFamily(grokClientID, "grok"))
    }
}

final class GrokModelRegistryTests: XCTestCase {
    func testMultilineOutputBecomesTrimmedLabels() {
        // `grok models` prints each model on its own line, indented and prefixed with a `* `
        // (default) or `- ` marker, with a trailing `(default)` annotation on the default. The
        // surrounding `Available models:` / `Default model: …` status lines are dropped, and the
        // bare id remains as both the `--model` value and the picker label.
        let output = """
        Available models:
          * grok-build (default)
          - grok-composer-2.5-fast
          - grok-code-fast-1
          - grok-4-fast-reasoning
          - grok-4-fast-non-reasoning
          - grok-4-0709
        Default model: grok-build
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, [
            "grok-build",
            "grok-composer-2.5-fast",
            "grok-code-fast-1",
            "grok-4-fast-reasoning",
            "grok-4-fast-non-reasoning",
            "grok-4-0709"
        ])
    }

    func testBareIdsWithoutMarkersOrStatusLinesPassThrough() {
        // Defensive: if a build of `grok models` emits bare ids with no marker/annotation, they
        // are still parsed verbatim and trimmed.
        let output = """
        grok-build
        grok-composer-2.5-fast
        grok-code-fast-1
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-build", "grok-composer-2.5-fast", "grok-code-fast-1"])
    }

    func testStatusLinesAreDroppedCaseInsensitively() {
        // The `Available models:`, `Default model: …`, and `You are not authenticated.` status
        // lines must never become picker entries, regardless of case. The `Default model:` line
        // carries a bare id value that must not leak back into the list.
        let output = """
        AVAILABLE MODELS:
          * grok-build (default)
        DEFAULT MODEL: grok-build
        You Are Not Authenticated.
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-build"])
    }

    func testSignedInGreetingIsDropped() {
        // Live `grok models` output for a signed-in session leads with a greeting line; parsing it
        // as a model would put "You are logged in with grok.com." in the picker and send it as
        // `--model`.
        let output = """
        You are logged in with grok.com.

        Default model: grok-4.6

        Available models:
          * grok-4.6 (default)
          - grok-4.5
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-4.6", "grok-4.5"])
    }

    func testTrailingDefaultAnnotationIsStripped() {
        // The `(default)` annotation (case-insensitive, plus any whitespace before it) is removed
        // so the default model collapses onto the same bare id as a non-default entry.
        let output = """
          * grok-build (DEFAULT)
          - grok-build
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-build"])
    }

    func testBlankAndWhitespaceLinesAreIgnored() {
        let output = "\n  - grok-code-fast-1  \n\n\t\n  \n  * grok-build (default)\n\n"
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-code-fast-1", "grok-build"])
    }

    func testEmptyOutputYieldsNoLabels() {
        XCTAssertTrue(GrokModelRegistry.parseModels(from: "").isEmpty)
        XCTAssertTrue(GrokModelRegistry.parseModels(from: "   \n \t \n").isEmpty)
    }

    func testDuplicateLabelsAreCollapsedPreservingFirstOrder() {
        let output = """
          - grok-code-fast-1
          * grok-build (default)
          - grok-code-fast-1
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-code-fast-1", "grok-build"])
    }

    func testTrailingCarriageReturnsAreTrimmed() {
        // `grok models` output captured on some terminals may include CRLF line endings.
        let output = "  - grok-code-fast-1\r\n  * grok-build (default)\r\n"
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-code-fast-1", "grok-build"])
    }

    @MainActor
    func testCatalogOptionsIncludeDefaultPlusLiveLabels() {
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setLabels(["grok-code-fast-1", "grok-build"])

        let availability = AgentModelCatalog.AvailabilityContext(grokAvailable: true)
        let options = AgentModelCatalog.options(for: .grok, availability: availability)
        let raws = options.map(\.rawValue)

        XCTAssertEqual(options.first?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertTrue(options.first?.isPlaceholderDefault == true)
        XCTAssertTrue(raws.contains("grok-code-fast-1"))
        XCTAssertTrue(raws.contains("grok-build"))
        // The live labels are exposed verbatim as both raw value and display name.
        XCTAssertEqual(
            options.first(where: { $0.rawValue == "grok-code-fast-1" })?.displayName,
            "grok-code-fast-1"
        )
    }

    @MainActor
    func testClearCacheEmptiesLabelsAndPostsChange() {
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setLabels(["grok-code-fast-1"])
        XCTAssertFalse(registry.currentModelLabels().isEmpty)
        XCTAssertNotNil(registry.lastRefresh())

        let expectation = expectation(forNotification: .grokModelsChanged, object: nil)
        registry.clearCache()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(registry.currentModelLabels().isEmpty)
        XCTAssertNil(registry.lastRefresh())
    }

    @MainActor
    func testClearCacheOnEmptyCacheDoesNotPostChange() {
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        registry.clearCache()
        // Reset already empties; clearCache on an empty cache must not regress labels.
        XCTAssertTrue(registry.currentModelLabels().isEmpty)
    }

    func testRefreshBacksOffAndDoesNotImmediatelyRespawnWithinStalenessWindow() async {
        // A refresh ATTEMPT (success or failure) must record the attempt timestamp so a subsequent
        // `refreshIfStale()` within the staleness window is a no-op and does NOT spawn another
        // process. This is the failure-churn fix: previously a failing `grok models` left the cache
        // empty and re-kicked a background refresh on every picker render. This test is
        // environment-independent — it asserts the no-respawn-within-window property whether or not
        // a `grok` binary is present (a failed run leaves the cache empty; a successful run fills
        // it), since the gate is keyed on the attempt time, not on success.
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }

        // First refresh: empty cache => stale => exactly one spawn attempt.
        await registry.refreshIfStale()
        let countAfterFirst = registry.test_refreshAttemptCount()
        XCTAssertEqual(countAfterFirst, 1, "First refreshIfStale should perform exactly one attempt")

        // Second refresh immediately after: the recorded attempt timestamp must gate it within the
        // staleness window, so no additional spawn happens regardless of the first result.
        await registry.refreshIfStale()
        XCTAssertEqual(
            registry.test_refreshAttemptCount(),
            countAfterFirst,
            "A refresh must back off for the staleness window and not re-spawn on the next render"
        )
    }

    func testFailedRefreshRecordsAttemptWithoutSuccessTimestamp() async {
        // Directly exercises the failure path via the DEBUG seam: simulate a failed attempt and
        // confirm it gates `refreshIfStale()` (no respawn) while leaving the success timestamp and
        // cache untouched — the precise behavior that stops failure churn.
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }

        registry.test_simulateFailedRefreshAttempt()
        XCTAssertTrue(registry.currentModelLabels().isEmpty, "Failed attempt must not populate cache")
        XCTAssertNil(registry.lastRefresh(), "Failed attempt must not set the success timestamp")

        // Now a render-triggered refreshIfStale must back off (attempt time is fresh).
        let before = registry.test_refreshAttemptCount()
        await registry.refreshIfStale()
        XCTAssertEqual(
            registry.test_refreshAttemptCount(),
            before,
            "A recorded failed attempt must back off refreshIfStale within the staleness window"
        )
    }

    func testConcurrentRefreshCoalescesWithoutCrashing() async {
        // Single-flight smoke test: many concurrent refreshes must share one run and complete
        // cleanly even when `grok` is absent (each underlying run returns nil and leaves the
        // cache untouched). Asserts no crash/hang from the atomic in-flight claim.
        let registry = GrokModelRegistry.shared
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await registry.refresh() }
            }
        }
    }
}

final class GrokStreamParserTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testPlainTextBecomesSingleContent() {
        let results = GrokStreamParser.parseFinalOutput(data("pong\n"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "pong")
    }

    func testEmptyOrWhitespaceYieldsNoResults() {
        XCTAssertTrue(GrokStreamParser.parseFinalOutput(Data()).isEmpty)
        XCTAssertTrue(GrokStreamParser.parseFinalOutput(data("   \n  ")).isEmpty)
    }

    func testWholeJSONObjectWithTextKey() {
        let results = GrokStreamParser.parseFinalOutput(data("{\"text\": \"hi there\", \"stopReason\": \"EndTurn\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "hi there")
    }

    func testWholeJSONObjectWithStopReasonStillEmitsContent() {
        // grok's `--output-format json` final object carries `text` plus metadata such as
        // `stopReason`/`sessionId`/`requestId`; only `text` is surfaced, as a content result.
        let json = "{\"text\": \"done\", \"stopReason\": \"EndTurn\", \"sessionId\": \"s1\", \"requestId\": \"r1\"}"
        let results = GrokStreamParser.parseFinalOutput(data(json))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "done")
    }

    func testErrorObjectBecomesErrorResult() {
        // grok failure shape: `{"type": "error", "message": "..."}` surfaces as an error result.
        let results = GrokStreamParser.parseFinalOutput(data("{\"type\": \"error\", \"message\": \"boom\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "error")
        XCTAssertEqual(results.first?.text, "boom")
    }

    func testErrorObjectWithoutMessageFallsBackToDefault() {
        let results = GrokStreamParser.parseFinalOutput(data("{\"type\": \"error\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "error")
        XCTAssertEqual(results.first?.text, "Grok CLI reported an error.")
    }

    func testJSONLinesEachBecomeContent() {
        let jsonl = "{\"text\": \"a\"}\n{\"text\": \"b\"}"
        let results = GrokStreamParser.parseFinalOutput(data(jsonl))
        XCTAssertEqual(results.map(\.text), ["a", "b"])
    }

    func testCRLFJSONLinesEachBecomeContent() {
        // CRLF-delimited JSONL: a trailing \r must not defeat the `hasSuffix("}")` check that
        // selects the JSONL branch. Mirrors `testJSONLinesEachBecomeContent` expectations.
        let jsonl = "{\"text\": \"a\"}\r\n{\"text\": \"b\"}\r\n"
        let results = GrokStreamParser.parseFinalOutput(data(jsonl))
        XCTAssertEqual(results.map(\.text), ["a", "b"])
    }

    func testMultilinePlainTextStaysSingleContent() {
        let results = GrokStreamParser.parseFinalOutput(data("line one\nline two"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "line one\nline two")
    }

    func testGarbageJSONFallsBackToPlainText() {
        let results = GrokStreamParser.parseFinalOutput(data("{not valid json"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "{not valid json")
    }

    func testMixedJSONLAndPlainFallsBackToSinglePlainContent() {
        // First line is a content-bearing JSON object, second is a JSON object without a
        // known text key. Since not every line yields content, the JSONL branch must be
        // skipped and the whole output treated as a single plain-text block.
        let mixed = "{\"text\": \"a\"}\n{\"unrelated\": 1}"
        let results = GrokStreamParser.parseFinalOutput(data(mixed))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, mixed)
    }

    // MARK: - Streaming events (`--output-format streaming-json`)

    func testStreamingThoughtBecomesReasoning() {
        let result = GrokStreamParser.parseStreamingEvent(data("{\"type\":\"thought\",\"data\":\"hmm\"}"))
        XCTAssertEqual(result?.type, "reasoning")
        XCTAssertEqual(result?.reasoning, "hmm")
        XCTAssertNil(result?.text)
    }

    func testStreamingTextBecomesContent() {
        let result = GrokStreamParser.parseStreamingEvent(data("{\"type\":\"text\",\"data\":\"hi\"}"))
        XCTAssertEqual(result?.type, "content")
        XCTAssertEqual(result?.text, "hi")
    }

    func testStreamingEndBecomesMessageStop() {
        let json = "{\"type\":\"end\",\"stopReason\":\"EndTurn\",\"sessionId\":\"s1\",\"requestId\":\"r1\"}"
        let result = GrokStreamParser.parseStreamingEvent(data(json))
        XCTAssertEqual(result?.type, "message_stop")
        XCTAssertEqual(result?.stopReason, "EndTurn")
        XCTAssertEqual(result?.providerSessionID, "s1")
    }

    func testStreamingErrorBecomesError() {
        let result = GrokStreamParser.parseStreamingEvent(data("{\"type\":\"error\",\"message\":\"boom\"}"))
        XCTAssertEqual(result?.type, "error")
        XCTAssertEqual(result?.text, "boom")
    }

    func testStreamingEmptyThoughtIsIgnored() {
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(data("{\"type\":\"thought\",\"data\":\"\"}")))
    }

    func testStreamingUnknownTypeIsIgnored() {
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(data("{\"type\":\"heartbeat\"}")))
    }

    func testStreamingNonJSONLineIsIgnored() {
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(data("not json")))
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(Data()))
    }
}

final class GrokToolEventParserTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testToolCallCarriesNameAndArgs() {
        let parser = GrokToolEventParser()
        let line = #"{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read","rawInput":{"path":"/a/b.swift","limit":80}}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "tool_call")
        XCTAssertEqual(result?.toolName, "Read")
        XCTAssertEqual(result?.toolArgs, "/a/b.swift (lines 1–80)")
        XCTAssertNotNil(result?.toolInvocationID)
    }

    func testCommandArgPreferredForShell() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c2","title":"Shell","rawInput":{"command":"git diff --stat","description":"d"}}}}"#
        XCTAssertEqual(parser.parse(data(line))?.toolArgs, "git diff --stat")
    }

    func testTerminalUpdateBecomesToolResultWithSummary() {
        let parser = GrokToolEventParser()
        _ = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Grep","rawInput":{"pattern":"x"}}}}"#))
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"found 19 matches"}}]}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "tool_result")
        XCTAssertEqual(result?.toolName, "Grep") // carried from the opening tool_call (terminal update has no title)
        XCTAssertEqual(result?.toolOutput, "found 19 matches")
        XCTAssertEqual(result?.toolIsError, false)
    }

    func testStartAndResultShareInvocationID() {
        let parser = GrokToolEventParser()
        let start = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read","rawInput":{"path":"/a"}}}}"#))
        let done = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}}}"#))
        XCTAssertNotNil(start?.toolInvocationID)
        XCTAssertEqual(start?.toolInvocationID, done?.toolInvocationID)
    }

    func testFailedStatusIsError() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"failed","content":[{"type":"content","content":{"type":"text","text":"boom"}}]}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.toolIsError, true)
        XCTAssertEqual(result?.toolOutput, "boom")
    }

    func testReadArgIncludesLineRange() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read","rawInput":{"path":"/a.swift","limit":80}}}}"#
        XCTAssertEqual(parser.parse(data(line))?.toolArgs, "/a.swift (lines 1–80)")
    }

    func testBashResultIncludesExitCodeAndMarksNonZeroError() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"nope"}}],"rawOutput":{"type":"Bash","exit_code":2}}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.toolOutput, "exit 2 · nope")
        XCTAssertEqual(result?.toolIsError, true) // non-zero exit overrides the "completed" status
    }

    func testKindUsedAsNameFallbackWhenNoTitle() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","kind":"search","rawInput":{"pattern":"x"}}}}"#
        XCTAssertEqual(parser.parse(data(line))?.toolName, "Search")
    }

    func testThoughtChunkBecomesStatus() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"I'll read the file"}}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "status")
        XCTAssertEqual(result?.text, "I'll read the file")
    }

    func testThoughtChunksAccumulate() {
        let parser = GrokToolEventParser()
        _ = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"Read"}}}}"#))
        let result = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"ing X"}}}}"#))
        XCTAssertEqual(result?.text, "Reading X")
    }

    func testBashInProgressWithExitCodeCompletes() {
        // grok-composer reports shell results under status:in_progress with rawOutput+exit_code.
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"in_progress","rawOutput":{"type":"Bash","exit_code":0},"content":[{"type":"content","content":{"type":"text","text":"diff stats"}}]}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "tool_result")
        XCTAssertEqual(result?.toolIsError, false)
        XCTAssertEqual(result?.toolOutput, "exit 0 · diff stats")
    }

    func testResultEmittedOncePerCall() {
        let parser = GrokToolEventParser()
        let first = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"in_progress","rawOutput":{"exit_code":0}}}}"#))
        let second = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}}}"#))
        XCTAssertEqual(first?.type, "tool_result")
        XCTAssertNil(second) // dedup — second completion ignored
    }

    func testIntermediateAndNonToolLinesIgnored() {
        let parser = GrokToolEventParser()
        // Refinement update with no terminal status → ignored (no duplicate card).
        XCTAssertNil(parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","title":"Skill x"}}}"#)))
        // Non-tool session updates → ignored.
        XCTAssertNil(parser.parse(data(#"{"params":{"update":{"sessionUpdate":"agent_message_chunk","content":"hi"}}}"#)))
        XCTAssertNil(parser.parse(data("not json")))
    }
}
