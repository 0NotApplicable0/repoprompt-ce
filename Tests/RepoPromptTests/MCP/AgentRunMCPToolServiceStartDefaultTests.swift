import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentRunMCPToolServiceStartDefaultTests: XCTestCase {
    func testInheritedRestrictiveCodexSettingsRemainRestrictive() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.inheritProviderSettings, defaults: defaults)
        CodexAgentToolPreferences.setPermissionLevel(.readOnly, defaults: defaults)
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .userConfigured)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testCustomRestrictiveCodexOverrideWinsOverSafeManagedDefaults() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom, defaults: defaults)
        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .codex(.readOnly),
            for: .codex,
            defaults: defaults
        )
        CodexAgentToolPreferences.setBashToolEnabled(false, defaults: defaults)
        let service = makeBindingService(defaults: defaults)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .providerOverride(.codex(.readOnly)))
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.readOnly.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexSandboxMode, .readOnly)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .user)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, false)
        XCTAssertFalse(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertFalse(profile.codexSuppressesThirdPartyMCPServers)
    }

    func testSubagentPolicyStorageFailureUsesCodexSafeManagedSnapshot() throws {
        let suiteName = "AgentRunMCPToolServiceStartDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let secureStore = AgentPermissionSecureStore(
            secureStrings: AgentRunFailingSecurePlainStringStore(),
            notificationCenter: NotificationCenter()
        )
        let service = makeBindingService(defaults: defaults, secureStore: secureStore)

        let profile = service.permissionProfileForMCPActivation(isSubagent: true, provider: .codex)
        let snapshot = service.controlsBinding(
            selectedAgent: .codexExec,
            permissionProfile: profile,
            isSubagent: true,
            externallyManagedReason: nil
        )

        XCTAssertEqual(profile, .mcpSafeDefaults)
        XCTAssertEqual(snapshot.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(snapshot.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(snapshot.codexTools?.bashToolEnabled, true)
        XCTAssertEqual(snapshot.codexTools?.mcpServerStatesByNormalizedName["external-tools"], false)
        XCTAssertTrue(profile.codexBashToolEnabled(userConfigured: false))
        XCTAssertTrue(profile.codexSuppressesThirdPartyMCPServers)
        XCTAssertEqual(secureStore.diagnostic(for: .subagent)?.kind, .keychainInteractionNotAllowed)
    }

    func testExplicitTargetTabWithOmittedModelIDPreservesCurrentSelection() {
        let targetTabID = UUID()

        XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: targetTabID))
    }

    func testWorkflowDefaultDoesNotOverridePairForUntargetedStart() {
        XCTAssertEqual(AgentWorkflow.oracleExport.defaultTaskLabelKind, .explore)

        let defaultLabel = AgentRunMCPToolService.defaultTaskLabelForStart(
            resolvedTabID: nil,
            workflow: AgentWorkflow.oracleExport.definition
        )

        XCTAssertEqual(defaultLabel, .pair)
    }

    func testRouterOwnedStartKeepsRoleSemanticsWithoutResolvingChildModelPin() {
        XCTAssertEqual(
            AgentRunMCPToolService.taskLabelKindForRouterOwnedStart(
                requestedModelID: nil,
                defaultTaskLabel: .pair
            ),
            .pair
        )
        XCTAssertEqual(
            AgentRunMCPToolService.taskLabelKindForRouterOwnedStart(
                requestedModelID: "explore",
                defaultTaskLabel: .pair
            ),
            .explore
        )
        XCTAssertNil(
            AgentRunMCPToolService.taskLabelKindForRouterOwnedStart(
                requestedModelID: "claudeCode:unavailable-stale-model",
                defaultTaskLabel: .pair
            )
        )
    }

    func testExplicitModelAndParameterPinsBypassModelRouter() {
        XCTAssertTrue(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: nil,
            hasExplicitModelParameters: false
        ))
        XCTAssertTrue(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "engineer",
            hasExplicitModelParameters: false
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "codexExec:gpt-6-sol-xhigh",
            hasExplicitModelParameters: false
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "devin:swe-2",
            hasExplicitModelParameters: false
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: "engineer",
            hasExplicitModelParameters: true
        ))
        XCTAssertFalse(AgentRunMCPToolService.shouldRouteModelForStart(
            requestedModelID: nil,
            hasExplicitModelParameters: true
        ))
    }

    func testRoutedStartLaunchesAntigravityTarget() async throws {
        let fixture = try await RoutedStartFixture.make(testCase: self, modelClass: "gemini-flash", effortRaw: "low")
        let capture = try await fixture.start()

        XCTAssertEqual(capture.agent, .antigravity)
        XCTAssertNotEqual(capture.agent, .claudeCode)
        XCTAssertNotEqual(capture.agent, .codexExec)
        XCTAssertEqual(capture.model, "gemini-3.8-flash-low")
        XCTAssertEqual(capture.parameters, [])
        let stages = await fixture.service.questionNames
        XCTAssertEqual(stages, ["model_route", "effort_route"])
    }

    func testRoutedStartLaunchesGrokTarget() async throws {
        let fixture = try await RoutedStartFixture.make(testCase: self, modelClass: "grok", effortRaw: nil)
        let capture = try await fixture.start()

        XCTAssertEqual(capture.agent, .grok)
        XCTAssertEqual(capture.model, "grok-4.7")
        XCTAssertEqual(capture.parameters, [])
        let stages = await fixture.service.questionNames
        XCTAssertEqual(stages, ["model_route"])
    }

    func testRoutedStartLaunchesCursorTargetWithParameters() async throws {
        let composer = try await RoutedStartFixture.make(testCase: self, modelClass: "composer", effortRaw: nil)
        let composerCapture = try await composer.start()
        XCTAssertEqual(composerCapture.agent, .cursor)
        XCTAssertEqual(composerCapture.model, "composer-2.5")
        XCTAssertEqual(composerCapture.parameters, [])

        let grok = try await RoutedStartFixture.make(
            testCase: self, modelClass: "cursor-grok", effortRaw: "xhigh", grokCLIConnected: false
        )
        let grokCapture = try await grok.start()
        XCTAssertEqual(grokCapture.agent, .cursor)
        XCTAssertEqual(grokCapture.model, "grok-4.7")
        XCTAssertFalse(grokCapture.parameters.isEmpty)
        XCTAssertEqual(grokCapture.parameters, [RoutedStartFixture.cursorGrokThinking("xhigh")])
        let stages = await grok.service.questionNames
        XCTAssertEqual(stages, ["model_route", "effort_route"])
    }

    func testExplicitModelIDStillBypassesRouting() async throws {
        let fixture = try await RoutedStartFixture.make(testCase: self, modelClass: "gemini-flash", effortRaw: "low")
        let modelID = AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: "composer-2.5").rawValue
        let capture = try await fixture.start(modelID: modelID)

        XCTAssertEqual(capture.agent, .cursor)
        XCTAssertEqual(capture.model, "composer-2.5")
        XCTAssertEqual(capture.parameters, [])
        let stages = await fixture.service.questionNames
        XCTAssertTrue(stages.isEmpty)
    }

    private func makeBindingService(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> AgentModeProviderBindingService {
        AgentModeProviderBindingService(
            preferences: AgentProviderPreferenceSnapshotStore(
                defaults: defaults,
                securePermissions: secureStore,
                codexMCPServerEntries: {
                    [
                        MCPIntegrationHelper.CodexServerEntry(
                            rawName: "external-tools",
                            normalizedName: "external-tools",
                            cliPathComponent: "external-tools"
                        )
                    ]
                }
            )
        )
    }
}

@MainActor
final class AgentRunMCPToolServiceDiversityTests: XCTestCase {
    private let pinnedModelID = "cursor:composer-2.5"

    private var reviewArgs: [String: Value] {
        ["workflow_id": .string(AgentWorkflow.review.definition.id)]
    }

    private func makeFixture(routerEnabled: Bool = true, reviewDiversity: Bool = false) async throws -> RoutedStartFixture {
        let fixture = try await RoutedStartFixture.make(
            testCase: self, modelClass: "grok", effortRaw: "low",
            fallbackModelClasses: ["gemini-flash", "composer"], routerEnabled: routerEnabled
        )
        fixture.window.agentModeViewModel.modelRouterSettingsStore.setReviewDiversityEnabled(reviewDiversity)
        return fixture
    }

    private func showReview() {
        let store = AgentWorkflowStore.shared
        let wasHidden = store.isBuiltInHidden(.review)
        store.setBuiltInVisibility(.review, isVisible: true)
        addTeardownBlock { @MainActor in
            store.setBuiltInVisibility(.review, isVisible: !wasHidden)
        }
    }

    private func assertRejected(
        _ fixture: RoutedStartFixture,
        modelID: String? = nil,
        args: [String: Value],
        explore: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sessionsBefore = fixture.sessionCount
        do {
            _ = try await fixture.start(modelID: modelID, additionalArgs: args, explore: explore)
            XCTFail("Expected invalidParams for \(args)", file: file, line: line)
        } catch let error as MCPError {
            guard case .invalidParams = error else {
                return XCTFail("Expected invalidParams, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected invalidParams, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(fixture.sessionCount, sessionsBefore, "Rejection must allocate no session", file: file, line: line)
        XCTAssertTrue(fixture.recorder.headlessStarts.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.recorder.acpRunRequests.isEmpty, file: file, line: line)
        XCTAssertEqual(fixture.recorder.claudeNativeStartCount, 0, file: file, line: line)
        let stages = await fixture.service.questionNames
        XCTAssertTrue(stages.isEmpty, "Invalid input must not reach routing", file: file, line: line)
    }

    private func assertAvoidsXAI(
        _ capture: RoutedStartFixture.Capture,
        fixture: RoutedStartFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        XCTAssertEqual(capture.agent, .antigravity, file: file, line: line)
        XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: capture.agent, modelRaw: capture.model), .google, file: file, line: line)
        let descriptions = await fixture.service.modelChoiceDescriptions
        XCTAssertFalse(descriptions.isEmpty, file: file, line: line)
        XCTAssertFalse(descriptions.contains { $0.contains("Role references: grok") || $0.contains("Role references: cursor-grok") }, file: file, line: line)
    }

    func testExcludeMakersFiltersRoutedStart() async throws {
        let control = try await makeFixture()
        let unfiltered = try await control.start()
        XCTAssertEqual(unfiltered.agent, .grok)

        let fixture = try await makeFixture()
        let capture = try await fixture.start(additionalArgs: ["exclude_makers": .array([.string("xai"), .string("xai")])])
        await assertAvoidsXAI(capture, fixture: fixture)

        let role = try await makeFixture()
        let roleCapture = try await role.start(modelID: "pair", additionalArgs: ["exclude_makers": .array([.string("xai")])])
        await assertAvoidsXAI(roleCapture, fixture: role)
    }

    func testDiverseFromSessionsExcludesThatSessionsMaker() async throws {
        let live = try await makeFixture()
        let liveID = try await live.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let liveCapture = try await live.start(additionalArgs: ["diverse_from_sessions": .array([.string(liveID.uuidString)])])
        await assertAvoidsXAI(liveCapture, fixture: live)

        let cold = try await makeFixture()
        let priorRoot = await AgentSessionDataService.shared.test_workspaceRootURL()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiversityCold-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { @MainActor in
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(priorRoot)
            try? FileManager.default.removeItem(at: root)
        }
        await AgentSessionDataService.shared.test_setWorkspaceRootOverride(root)
        let workspace = try XCTUnwrap(cold.window.workspaceManager.activeWorkspace)
        var session = AgentSession(id: UUID(), name: "Cold Cursor Grok", savedAt: Date())
        session.agentKind = AgentProviderKind.cursor.rawValue
        session.agentModel = "grok-4.7"
        _ = try await AgentSessionDataService.shared.saveAgentSession(session, for: workspace)
        let coldCapture = try await cold.start(additionalArgs: [
            "diverse_from_sessions": .array([.string(session.id.uuidString), .string(session.id.uuidString)])
        ])
        await assertAvoidsXAI(coldCapture, fixture: cold)
    }

    func testUnknownMakerOrSessionIsRejected() async throws {
        let fixture = try await makeFixture()
        let cases: [[String: Value]] = [
            ["exclude_makers": .array([.string("meta")])],
            ["exclude_makers": .array([.string("Anthropic")])],
            ["exclude_makers": .array([.string("xai"), .string("unknown")])],
            ["exclude_makers": .string("xai")],
            ["exclude_makers": .null],
            ["exclude_makers": .array([.int(1)])],
            ["diverse_from_sessions": .array([.string(UUID().uuidString)])],
            ["diverse_from_sessions": .array([.string("not-a-uuid")])],
            ["diverse_from_sessions": .string(UUID().uuidString)],
            ["diverse_from_sessions": .null],
            ["diverse_from_sessions": .array([.null])]
        ]
        for args in cases {
            try await assertRejected(fixture, args: args)
        }
    }

    func testDiversityWithExplicitPinIsRejected() async throws {
        let fixture = try await makeFixture()
        for key in ["exclude_makers", "diverse_from_sessions"] {
            let args: [String: Value] = [key: .array([])]
            try await assertRejected(fixture, modelID: pinnedModelID, args: args)
            for parameters in [Value.array([]), .null] {
                try await assertRejected(fixture, args: args.merging(["model_parameters": parameters]) { $1 })
            }
        }
    }

    func testDiversityWithRouterDisabledIsRejected() async throws {
        let fixture = try await makeFixture(routerEnabled: false)
        for args: [String: Value] in [
            ["exclude_makers": .array([])],
            ["exclude_makers": .array([.string("xai")])],
            ["diverse_from_sessions": .array([])]
        ] {
            try await assertRejected(fixture, args: args)
        }
    }

    func testReviewDiversityExcludesParentMaker() async throws {
        showReview()
        let control = try await makeFixture()
        try await control.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let unfiltered = try await control.start(additionalArgs: reviewArgs)
        XCTAssertEqual(unfiltered.agent, .grok)

        let fixture = try await makeFixture(reviewDiversity: true)
        try await fixture.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let capture = try await fixture.start(additionalArgs: reviewArgs)
        await assertAvoidsXAI(capture, fixture: fixture)

        for explicitArgs: [String: Value] in [[:], ["exclude_makers": .array([])], ["diverse_from_sessions": .array([])]] {
            let parentlessOrExplicit = try await makeFixture(reviewDiversity: true)
            if !explicitArgs.isEmpty {
                try await parentlessOrExplicit.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
            }
            let allowed = try await parentlessOrExplicit.start(additionalArgs: reviewArgs.merging(explicitArgs) { $1 })
            XCTAssertEqual(allowed.agent, .grok)
        }
    }

    func testReviewDiversityWithExplicitPinIsRejected() async throws {
        showReview()
        for parent in [false, true] {
            let fixture = try await makeFixture(reviewDiversity: true)
            if parent { try await fixture.installAuthorizedCaller(agent: .grok, model: "grok-4.7") }
            try await assertRejected(fixture, modelID: pinnedModelID, args: reviewArgs)
            for parameters in [Value.array([]), .null] {
                try await assertRejected(fixture, args: reviewArgs.merging(["model_parameters": parameters]) { $1 })
            }
        }
    }

    func testReviewDiversityIsInertWhenRouterDisabled() async throws {
        showReview()
        let fixture = try await makeFixture(routerEnabled: false, reviewDiversity: true)
        try await fixture.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let capture = try await fixture.start(modelID: pinnedModelID, additionalArgs: reviewArgs)
        XCTAssertEqual(capture.agent, .cursor)
        XCTAssertEqual(capture.model, "composer-2.5")
        let stages = await fixture.service.questionNames
        XCTAssertTrue(stages.isEmpty)
    }

    func testAgentExploreAcceptsDiversityArguments() async throws {
        for key in ["exclude_makers", "diverse_from_sessions"] {
            let fixture = try await makeFixture(reviewDiversity: true)
            let parentID = try await fixture.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
            let value = key == "exclude_makers" ? "xai" : parentID.uuidString
            let capture = try await fixture.start(additionalArgs: [key: .array([.string(value)])], explore: true)
            await assertAvoidsXAI(capture, fixture: fixture)
        }
        let control = try await makeFixture(reviewDiversity: true)
        try await control.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let unfiltered = try await control.start(explore: true)
        XCTAssertEqual(unfiltered.agent, .grok, "Explore must not apply implicit Review diversity")

        let invalid = try await makeFixture()
        try await invalid.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        try await assertRejected(invalid, args: ["exclude_makers": .array([.string("meta")])], explore: true)
        try await assertRejected(invalid, args: ["diverse_from_sessions": .array([.string(UUID().uuidString)])], explore: true)
        let disabled = try await makeFixture(routerEnabled: false)
        try await disabled.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        try await assertRejected(disabled, args: ["exclude_makers": .array([])], explore: true)
    }

    func testAgentRunAndAgentExploreSchemasAdvertiseDiversityArguments() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = WindowState()
        addTeardownBlock { @MainActor in await window.tearDown() }
        let tools = await window.mcpServer.windowMCPTools
        for name in [MCPWindowToolName.agentRun, MCPWindowToolName.agentExplore] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
            let canonical = try XCTUnwrap(definition.inputSchema.objectValue)
            try assertDiversitySchema(canonical, label: "canonical \(name)")
            let tool = try XCTUnwrap(tools.first { $0.name == name })
            let live = try XCTUnwrap(try Value(tool.inputSchema).objectValue)
            try assertDiversitySchema(live, label: "live \(name)")
        }
    }

    private func assertDiversitySchema(_ schema: [String: Value], label: String) throws {
        let properties = try XCTUnwrap(schema["properties"]?.objectValue, label)
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for key in ["exclude_makers", "diverse_from_sessions"] {
            let property = try XCTUnwrap(properties[key]?.objectValue, "\(label) missing \(key)")
            XCTAssertEqual(property["type"], .string("array"), label)
            XCTAssertFalse(required.contains(key), label)
            XCTAssertNil(property["minItems"], label)
            let items = try XCTUnwrap(property["items"]?.objectValue, label)
            XCTAssertEqual(items["type"], .string("string"), label)
            if key == "exclude_makers" {
                XCTAssertEqual(items["enum"]?.arrayValue?.compactMap(\.stringValue), ["anthropic", "openai", "google", "xai", "cursor"], label)
            } else {
                XCTAssertTrue((items["description"]?.stringValue ?? "").contains("UUID"), label)
            }
        }
    }
}

/// Records which provider path a routed start dispatched on, without launching a real CLI.
final class RoutedStartDispatchRecorder: @unchecked Sendable {
    struct HeadlessStart: Equatable {
        let agent: AgentProviderKind
        let model: String?
    }

    struct DeliveredTurn: Equatable {
        let agent: AgentProviderKind
        let model: String?
        let parameters: [ACPModelParameterSelection]
        let message: String
    }

    private let lock = NSLock()
    private let cursorPromptLogURL: URL?
    private var deliveredHeadless: [DeliveredTurn] = []
    private var deliveredACP: [DeliveredTurn] = []
    private var headless: [HeadlessStart] = []
    private var acp: [ACPRunRequest] = []
    private var claudeStarts = 0

    init(cursorPromptLogURL: URL? = nil) {
        self.cursorPromptLogURL = cursorPromptLogURL
    }

    func receivedCursorTurns() throws -> [[String: String]] {
        guard let cursorPromptLogURL,
              FileManager.default.fileExists(atPath: cursorPromptLogURL.path)
        else { return [] }
        return try String(contentsOf: cursorPromptLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
    }

    var headlessTurns: [DeliveredTurn] {
        lock.withLock { deliveredHeadless }
    }

    var acpTurns: [DeliveredTurn] {
        lock.withLock { deliveredACP }
    }

    func recordHeadlessTurn(agent: AgentProviderKind, model: String?, message: AgentMessage) {
        lock.withLock {
            deliveredHeadless.append(.init(agent: agent, model: model, parameters: [], message: message.userMessage))
        }
    }

    func recordACPTurn(request: ACPRunRequest, message: AgentMessage) {
        lock.withLock {
            deliveredACP.append(.init(
                agent: request.agentKind,
                model: request.modelString,
                parameters: request.modelParameterSelections,
                message: message.userMessage
            ))
        }
    }

    var headlessStarts: [HeadlessStart] {
        lock.withLock { headless }
    }

    var acpRunRequests: [ACPRunRequest] {
        lock.withLock { acp }
    }

    var claudeNativeStartCount: Int {
        lock.withLock { claudeStarts }
    }

    func recordHeadless(_ agent: AgentProviderKind, _ model: String?) {
        lock.withLock { headless.append(HeadlessStart(agent: agent, model: model)) }
    }

    func recordACP(_ request: ACPRunRequest) {
        lock.withLock { acp.append(request) }
    }

    func recordClaudeStart() {
        lock.withLock { claudeStarts += 1 }
    }
}

private actor RoutedStartRecordingHeadlessProvider: HeadlessAgentProvider {
    private let base = AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
    private let agent: AgentProviderKind
    private let model: String?
    private let recorder: RoutedStartDispatchRecorder

    init(agent: AgentProviderKind, model: String?, recorder: RoutedStartDispatchRecorder) {
        self.agent = agent
        self.model = model
        self.recorder = recorder
    }

    func streamAgentMessage(_ message: AgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        recorder.recordHeadlessTurn(agent: agent, model: model, message: message)
        return try await base.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await base.dispose()
    }
}

private struct RoutedStartRecordingACPProvider: ACPAgentProvider {
    let base: AgentSessionLinkCapturingACPProvider
    let recorder: RoutedStartDispatchRecorder

    var providerID: ACPProviderID {
        base.providerID
    }

    var supportsParameterizedModelPicker: Bool {
        true
    }

    func modelParameterKind(for input: ACPModelParameterClassificationInput) -> ACPModelParameterKind? {
        input.configID == "reasoning_effort" ? .thinking : nil
    }

    func support(for request: ACPRunRequest) async throws -> ACPSupportResult {
        try await base.support(for: request)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        try base.makeLaunchConfiguration(for: request)
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        try base.makeSessionConfiguration(for: request, mcpServer: mcpServer)
    }

    func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
        recorder.recordACPTurn(request: request, message: message)
        return try base.buildPromptBlocks(for: message, request: request)
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
        base.normalizeSessionUpdate(payload, sessionID: sessionID)
    }

    func normalizeError(_ error: Error) -> Error {
        base.normalizeError(error)
    }
}

/// Selects the one choice whose role reference names the fixture's model class, then its effort.
actor RoutedStartDecisionService: DecisionService {
    nonisolated let id = DecisionServiceID(rawValue: "routed-start")
    nonisolated let displayName = "Routed start"
    nonisolated let capabilities = DecisionServiceCapabilities(
        contextKinds: [.text],
        finiteChoice: .init(
            minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024,
            maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
            maximumAggregateBytes: 128 * 1024
        ),
        evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
    )
    private let modelClass: String
    private let effortRaw: String?
    private let fallbackModelClasses: [String]
    private(set) var questionNames: [String] = []
    private(set) var modelChoiceDescriptions: [String] = []
    private var nextDecisionGate: StartStallGate?

    init(modelClass: String, effortRaw: String?, fallbackModelClasses: [String] = []) {
        self.modelClass = modelClass
        self.effortRaw = effortRaw
        self.fallbackModelClasses = fallbackModelClasses
    }

    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "routed-start-v1")
    }

    fileprivate func suspendNextDecision(on gate: StartStallGate) {
        nextDecisionGate = gate
    }

    func decide(_ request: FiniteChoiceDecisionRequest) async -> DecisionOutcome {
        let gate = nextDecisionGate
        nextDecisionGate = nil
        await gate?.suspend()
        questionNames.append(request.question.name)
        let label: String
        if request.question.name == "effort_route" {
            guard let effortRaw else { return .abstained(reasonCode: "fixture has no effort", evidence: nil) }
            label = "effort:\(effortRaw)"
        } else {
            modelChoiceDescriptions = request.question.choices.map(\.description)
            label = ([modelClass] + fallbackModelClasses).first { candidate in
                request.question.choices.contains { $0.description.contains("Role references: \(candidate)") }
            } ?? modelClass
        }
        let matches = request.question.choices.filter { $0.description.contains("Role references: \(label)") }
        guard matches.count == 1, let match = matches.first else {
            return .abstained(reasonCode: "fixture label \(label) matched \(matches.count) choices", evidence: nil)
        }
        return .selected(opaqueKey: match.opaqueKey, evidence: nil)
    }
}

/// A window with the Model Router on, a stub decision service, and verified Claude Code, Codex,
/// Cursor, Antigravity and (optionally) Grok CLI providers advertising fixed catalogs.
@MainActor
final class RoutedStartFixture {
    struct Capture: Equatable {
        let agent: AgentProviderKind
        let model: String
        let parameters: [ACPModelParameterSelection]
    }

    private struct CapturedBeforeDispatch: Error {}

    let service: RoutedStartDecisionService
    let window: WindowState
    let recorder: RoutedStartDispatchRecorder
    let workspaceRoot: URL
    private var capture: Capture?
    private var caller: (tabID: UUID, sessionID: UUID)?

    var sessionCount: Int {
        window.agentModeViewModel.sessions.count
    }

    private init(service: RoutedStartDecisionService, window: WindowState, recorder: RoutedStartDispatchRecorder, workspaceRoot: URL) {
        self.service = service
        self.window = window
        self.recorder = recorder
        self.workspaceRoot = workspaceRoot
    }

    static func cursorGrokThinking(_ value: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.7",
            kind: .thinking,
            configID: "reasoning_effort",
            valueRaw: value
        )
    }

    static func make(
        testCase: XCTestCase,
        modelClass: String,
        effortRaw: String?,
        grokCLIConnected: Bool = true,
        fallbackModelClasses: [String] = [],
        routerEnabled: Bool = true,
        recordTurnDelivery: Bool = false,
        headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory? = nil,
        prepareRoot: ((URL) throws -> Void)? = nil
    ) async throws -> RoutedStartFixture {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        installProviderCatalogs(testCase: testCase)

        let service = RoutedStartDecisionService(
            modelClass: modelClass, effortRaw: effortRaw, fallbackModelClasses: fallbackModelClasses
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutedStart-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try prepareRoot?(root)
        let suiteName = "RoutedStartFixture.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        testCase.addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        )
        if routerEnabled {
            store.enableModelRouterWithCurrentPolicy(
                backendID: service.id,
                roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
                providers: [.claudeCode, .codexExec, .cursor, .antigravity, .grok]
            )
        }
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(service: service)], demandSource: store)
        testCase.addTeardownBlock { await runtime.teardown() }

        let cursorPromptLogURL = recordTurnDelivery ? root.appendingPathComponent("cursor-prompts.jsonl") : nil
        let cursorCommand = recordTurnDelivery ? try writeCursorServer(to: root) : nil
        let recorder = RoutedStartDispatchRecorder(cursorPromptLogURL: cursorPromptLogURL)
        let workspacePath = root.path
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let viewModel = AgentModeViewModel(
                    testWindowID: windowID,
                    testWorkspacePath: workspacePath,
                    codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("A routed start must not launch Codex") },
                    claudeControllerFactory: { _, _, _, _ in
                        recorder.recordClaudeStart()
                        return MonitorFakeNativeController()
                    },
                    headlessProviderFactory: { agent, model, _, _, _ in
                        recorder.recordHeadless(agent, model)
                        if let headlessProviderFactory {
                            return headlessProviderFactory(agent, model, workspacePath, nil, nil)
                        }
                        if recordTurnDelivery {
                            return RoutedStartRecordingHeadlessProvider(agent: agent, model: model, recorder: recorder)
                        }
                        return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
                    },
                    acpProviderFactory: { agent, _ in
                        guard agent == .cursor else { throw MCPError.internalError("Only Cursor may start over ACP") }
                        let provider = AgentSessionLinkCapturingACPProvider(
                            providerID: .cursor,
                            commandPath: cursorCommand?.path ?? "/usr/bin/true",
                            environment: cursorPromptLogURL.map { ["ROUTED_CURSOR_PROMPT_LOG": $0.path] } ?? [:]
                        )
                        if recordTurnDelivery {
                            return RoutedStartRecordingACPProvider(base: provider, recorder: recorder)
                        }
                        return provider
                    },
                    acpControllerFactory: { provider, request in
                        recorder.recordACP(request)
                        guard recordTurnDelivery else { throw MCPError.internalError("ACP controller recorded") }
                        return try ACPAgentSessionController(
                            provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true
                        )
                    },
                    connectionPolicyInstaller: { client, window, restricted, oneShot, reason, ttl, tab, run, additional, purpose, label, external, expectedPID in
                        guard headlessProviderFactory != nil || recordTurnDelivery else { return }
                        await ServerNetworkManager.shared.installClientConnectionPolicy(
                            for: client, windowID: window, restrictedTools: restricted, oneShot: oneShot,
                            reason: reason, ttl: ttl, tabID: tab, runID: run, additionalTools: additional,
                            purpose: purpose, taskLabelKind: label, allowsAgentExternalControlTools: external,
                            requiresExpectedAgentPID: expectedPID
                        )
                    },
                    mcpRunRoutingCleaner: { _, _, _ in },
                    mcpServerEnabler: { true },
                    testMCPServer: server,
                    testWorkspaceFileContextStore: prompt.workspaceFileContextStore
                )
                viewModel.promptManager = prompt
                viewModel.workspaceManager = manager
                return viewModel
            },
            contextBuilderProviderFactory: { _, _, _, _ in AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1) }
        )
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        testCase.addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        await window.workspaceManager.awaitInitialized()
        window.agentModeViewModel.modelRouterSettingsStore = store
        window.agentModeViewModel.modelRouterRuntime = runtime

        let api = window.apiSettingsViewModel
        api.isClaudeCodeConnected = true
        api.isCodexConnected = true
        api.isCursorConnected = true
        api.isGrokConnected = grokCLIConnected
        try await connectAntigravity(testCase: testCase, api: api)
        api.test_completeContextBuilderProviderValidation(
            verifiedProviders: grokCLIConnected
                ? [.claudeCode, .codexExec, .cursor, .antigravity, .grok]
                : [.claudeCode, .codexExec, .cursor, .antigravity]
        )
        let availability = window.agentModeViewModel.modelRouterAvailabilityContext
        XCTAssertTrue(availability.antigravityAvailable && availability.cursorAvailable)
        XCTAssertEqual(availability.grokAvailable, grokCLIConnected)

        let workspace = window.workspaceManager.createWorkspace(name: "Routed \(UUID())", repoPaths: [root.path], ephemeral: true)
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "routedStartFixture")
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)

        await runtime.reconcileDemand()
        if routerEnabled {
            try await AsyncTestWait.waitUntil("routed-start decision service ready", timeout: 5) {
                runtime.isBackendReady(service.id)
            }
        }
        return RoutedStartFixture(service: service, window: window, recorder: recorder, workspaceRoot: root)
    }

    private static func writeCursorServer(to root: URL) throws -> URL {
        let scriptURL = root.appendingPathComponent("routed_cursor_acp.py")
        let script = #"""
        #!/usr/bin/python3
        import json
        import os
        import sys
        model = "composer-2.5"
        effort = "high"
        mode = "ask"
        def select(config_id, category, current, values):
            return {
                "id": config_id, "name": config_id, "category": category,
                "type": "select", "currentValue": current,
                "options": [{"value": value, "name": value} for value in values]
            }
        def config_options():
            return [
                select("model", "model", model, ["composer-2.5", "grok-4.7"]),
                select("reasoning_effort", "thinking", effort, ["low", "medium", "high", "xhigh"]),
                select("mode", "mode", mode, ["ask", "auto_edit", "repoprompt_acp", "repoprompt_acp_full_access"])
            ]
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            result = {}
            if method == "initialize":
                result = {"agentCapabilities": {}, "authMethods": []}
            elif method == "session/new":
                result = {"sessionId": "routed-cursor-session", "configOptions": config_options()}
            elif method == "cursor/list_available_models":
                result = {"models": [
                    {"value": value, "name": value, "configOptions": config_options()}
                    for value in ["composer-2.5", "grok-4.7"]
                ]}
            elif method == "session/set_config_option":
                config_id = params.get("configId")
                if config_id == "model":
                    model = params["value"]
                elif config_id == "reasoning_effort":
                    effort = params["value"]
                elif config_id == "mode":
                    mode = params["value"]
                result = {"configOptions": config_options()}
            elif method == "session/prompt":
                message = "".join(block["text"] for block in params["prompt"] if block.get("type") == "text")
                with open(os.environ["ROUTED_CURSOR_PROMPT_LOG"], "a") as log:
                    log.write(json.dumps({"model": model, "reasoning_effort": effort, "message": message}) + "\n")
                result = {"stopReason": "end_turn"}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Antigravity and Grok CLI catalogs come from their model registries; Cursor's from ACP discovery.
    /// Teardown restores the prior registry catalogs with fresh timestamps: a reset registry is stale,
    /// and a background refresh would run the real CLI and change a later test's catalog mid-route.
    private static func installProviderCatalogs(testCase: XCTestCase) {
        let priorAntigravityModels = AntigravityModelRegistry.shared.currentModels()
        let priorGrokLabels = GrokModelRegistry.shared.currentModelLabels()
        AntigravityModelRegistry.shared.test_setModels([
            "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low",
            "gemini-3.1-pro-high", "gemini-3.1-pro-low"
        ].map { AntigravityModelRegistry.Model(id: $0, displayName: $0) })
        GrokModelRegistry.shared.test_setLabels(["grok-4.7", "grok-4.6"])
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        let speed = ACPModelParameterDefinition(
            kind: .speed, configID: "fast", displayName: "Speed",
            choices: [.init(rawValue: "false", displayName: "Standard"), .init(rawValue: "true", displayName: "Fast")],
            currentValueRaw: "false"
        )
        let thinking = ACPModelParameterDefinition(
            kind: .thinking, configID: "reasoning_effort", displayName: "Effort",
            choices: ["low", "medium", "high", "xhigh"].map { .init(rawValue: $0, displayName: $0) },
            currentValueRaw: "high"
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    .init(rawValue: "composer-2.5", displayName: "Composer 2.5", description: nil, isDefault: false),
                    .init(rawValue: "grok-4.7", displayName: "Grok 4.7", description: nil, isDefault: false)
                ],
                currentModelRaw: "composer-2.5",
                modelParameterSets: [
                    .init(baseModelRaw: "composer-2.5", parameters: [speed]),
                    .init(baseModelRaw: "grok-4.7", parameters: [thinking, speed])
                ]
            ),
            for: .cursor
        )
        testCase.addTeardownBlock { @MainActor in
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
            GrokModelRegistry.shared.test_setLabels(priorGrokLabels)
            AntigravityModelRegistry.shared.test_setModels(priorAntigravityModels)
        }
    }

    /// The window's settings follow the app-wide Antigravity coordinator; restore its prior state.
    private static func connectAntigravity(testCase: XCTestCase, api: APISettingsViewModel) async throws {
        let coordinator = AntigravityConnectionCoordinator.shared
        let hintKey = "AntigravityCLIConnected"
        let prior = await coordinator.latestProjection()
        let priorHint = UserDefaults.standard.object(forKey: hintKey)
        let generation = await coordinator.beginManualMutation()
        _ = await coordinator.publishIfCurrent(generation: generation, isConnected: true, errorMessage: nil, hasOwnedMCPEntry: true)
        testCase.addTeardownBlock { @MainActor in
            let restoreGeneration = await coordinator.beginManualMutation()
            _ = await coordinator.publishIfCurrent(
                generation: restoreGeneration,
                isConnected: prior?.isConnected ?? false,
                errorMessage: prior?.errorMessage,
                hasOwnedMCPEntry: prior?.hasOwnedMCPEntry ?? false
            )
            if let priorHint {
                UserDefaults.standard.set(priorHint, forKey: hintKey)
            } else {
                UserDefaults.standard.removeObject(forKey: hintKey)
            }
        }
        try await AsyncTestWait.waitUntil("window sees Antigravity connected", timeout: 5) {
            api.isAntigravityConnected
        }
    }

    /// Runs `agent_run start` and captures the session's provider, model and parameters at dispatch.
    func start(modelID: String? = nil, additionalArgs: [String: Value] = [:], explore: Bool = false) async throws -> Capture {
        capture = nil
        var runService = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { [window] in
                MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "routed-start", windowID: window.windowID)
            },
            requireTargetWindow: { [window] in window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in self.caller?.tabID },
            resolveSpawnParentSessionID: { _, _ in self.caller?.sessionID },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, message, metadata, viewModel, agentRaw, modelRaw, effort, taskLabel, workflow, parentID, oracleSource, preserve in
                try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                    target: target, message: message, metadata: metadata, agentModeVM: viewModel,
                    agentRaw: agentRaw, modelRaw: modelRaw, reasoningEffortRaw: effort, taskLabelKind: taskLabel,
                    workflow: workflow, expectedParentSessionID: parentID, oracleReviewSource: oracleSource,
                    preserveRoutedInitialEffort: preserve,
                    dispatchInstruction: { _, tabID, _, _, viewModel in
                        guard let session = viewModel.session(for: tabID, createIfNeeded: false) else {
                            throw MCPError.internalError("Missing configured session")
                        }
                        self.capture = Capture(
                            agent: session.selectedAgent,
                            model: session.selectedModelRaw,
                            parameters: session.acpModelParameterSelections
                        )
                        throw CapturedBeforeDispatch()
                    }
                )
            }
        )
        runService.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let tabID = try self.caller?.tabID ?? XCTUnwrap(workspace.activeComposeTabID)
            let sourceSessionID = self.caller?.sessionID
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: .explicitWindowActiveCompose, windowID: targetWindow.windowID, workspaceID: workspace.id,
                tabID: tabID, selectionRevision: 0, promptText: "", selection: StoredSelection(),
                sourceAgentSessionID: sourceSessionID, routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(), sourceTabID: tabID, workspaceID: workspace.id, sourceAgentSessionID: sourceSessionID,
                    sourceAgentRunID: nil, reason: .sourceCaptureFailed("routed start fixture")
                ))
            )
        }
        var args: [String: Value] = ["op": .string("start"), "message": .string("Route this task"), "detach": .bool(true)]
        if let modelID { args["model_id"] = .string(modelID) }
        args.merge(additionalArgs, uniquingKeysWith: { _, new in new })
        do {
            if explore {
                let exploreService = AgentExploreMCPToolService(
                    toolName: MCPWindowToolName.agentExplore,
                    captureRequestMetadata: runService.captureRequestMetadata,
                    requireTargetWindow: runService.requireTargetWindow,
                    resolveSpawnSourceTabID: { _ in self.caller?.tabID },
                    resolveSpawnParentSessionID: { _, _ in self.caller?.sessionID },
                    withHeartbeat: runService.withHeartbeat,
                    startRun: runService.startRun
                )
                _ = try await exploreService.execute(args: args)
            } else {
                _ = try await runService.execute(args: args)
            }
        } catch {
            if capture == nil { throw error }
        }
        return try XCTUnwrap(capture)
    }

    @discardableResult
    func installAuthorizedCaller(agent: AgentProviderKind, model: String) async throws -> UUID {
        let viewModel = window.agentModeViewModel
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Diversity parent"
        )
        let sessionID = try XCTUnwrap(target.sessionID)
        _ = try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
            target: target,
            message: "Parent task",
            metadata: .init(connectionID: nil, clientName: "routed-start", windowID: window.windowID),
            agentModeVM: viewModel,
            agentRaw: agent.rawValue,
            modelRaw: model,
            reasoningEffortRaw: nil,
            taskLabelKind: .pair,
            dispatchInstruction: { _, _, _, _, _ in .startedRun }
        )
        viewModel.mcpAcceptSessionTarget(target)
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertEqual(session.mcpControlContext?.sessionID, sessionID)
        XCTAssertEqual(session.mcpControlContext?.taskLabelKind, .pair)
        XCTAssertEqual(session.selectedAgent, agent)
        XCTAssertEqual(session.selectedModelRaw, model)
        XCTAssertEqual(
            viewModel.agentSessionLifecycleIdentity(tabID: session.tabID, expectedSessionID: sessionID)?.workspaceID,
            window.workspaceManager.activeWorkspaceID
        )
        caller = (session.tabID, sessionID)
        return sessionID
    }
}

@MainActor
final class AgentRunMCPStartStallTests: XCTestCase {
    func testDeferredPreparationAfterStartupTimeoutDoesNotLaunch() async throws {
        let runtime = try makeRuntimeProbe()
        var providerConstructions = 0
        let clock = StartStallClock()
        let observation = StartStallObservation()
        let (window, service, recorder) = try await makeDeferredPreparationStart(
            runtime: runtime, clock: clock, observation: observation,
            providerConstructed: { providerConstructions += 1 }
        )
        let viewModel = window.agentModeViewModel
        let gate = StartStallGate()
        viewModel.test_afterProviderInputAugmentation = { await gate.suspend() }
        _ = launch(
            service, args: ["model_id": .string("cursor:composer-2.5")],
            observation: observation, gate: gate, clock: clock
        )
        await drainScheduler(until: { gate.hasEntered })
        XCTAssertTrue(gate.hasEntered)
        let target = try XCTUnwrap(observation.target)
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertNil(session.agentTask, "The producer must still be in pre-run preparation")
        XCTAssertEqual(providerConstructions, 0)
        await drainScheduler()
        clock.advance(to: .seconds(60))
        await drainScheduler(until: { session.runState == .failed && session.activeRunOwnership == nil })
        XCTAssertEqual(session.runState, .failed)
        XCTAssertEqual(try viewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))?.failureReason, .timeout)

        gate.release()
        await drainScheduler()
        XCTAssertEqual(providerConstructions, 0, "A timed-out producer must not construct a provider when preparation resumes")
        XCTAssertTrue(recorder.acpRunRequests.isEmpty, "No ACP controller or turn may be dispatched")
        XCTAssertFalse(runtime.processEntered)
        XCTAssertEqual(session.runState, .failed)
        let snapshot = try viewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))
        XCTAssertEqual(snapshot?.status, .failed)
        XCTAssertEqual(snapshot?.failureReason, .timeout)
    }

    func testDeferredPreparationAfterStopDoesNotLaunch() async throws {
        let runtime = try makeRuntimeProbe()
        var providerConstructions = 0
        let clock = StartStallClock()
        let observation = StartStallObservation()
        let (window, service, recorder) = try await makeDeferredPreparationStart(
            runtime: runtime, clock: clock, observation: observation,
            providerConstructed: { providerConstructions += 1 }
        )
        let viewModel = window.agentModeViewModel
        let gate = StartStallGate()
        viewModel.test_afterProviderInputAugmentation = { await gate.suspend() }
        _ = launch(
            service, args: ["model_id": .string("cursor:composer-2.5")],
            observation: observation, gate: gate, clock: clock
        )
        await drainScheduler(until: { gate.hasEntered })
        XCTAssertTrue(gate.hasEntered)
        let target = try XCTUnwrap(observation.target)
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        XCTAssertNil(session.agentTask, "Stop must happen before a runner owns the producer")
        XCTAssertEqual(providerConstructions, 0)
        await viewModel.cancelAgentRun(tabID: target.tabID)
        await drainScheduler(until: { session.runState == .cancelled && session.activeRunOwnership == nil })
        XCTAssertEqual(session.runState, .cancelled)

        gate.release()
        await drainScheduler()
        XCTAssertEqual(providerConstructions, 0, "A stopped producer must not construct a provider when preparation resumes")
        XCTAssertTrue(recorder.acpRunRequests.isEmpty, "No ACP controller or turn may be dispatched")
        XCTAssertFalse(runtime.processEntered)
        XCTAssertEqual(session.runState, .cancelled)
        let snapshot = try viewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))
        XCTAssertEqual(snapshot?.status, .cancelled)
        XCTAssertEqual(snapshot?.failureReason, .cancelled)
    }

    func testNewSubmissionAfterFailedStartupStillStarts() async throws {
        let runtime = try makeRuntimeProbe()
        let clock = StartStallClock()
        let observation = StartStallObservation()
        let (window, service, _) = try await makeDeferredPreparationStart(
            runtime: runtime, clock: clock, observation: observation, providerConstructed: {}
        )
        let viewModel = window.agentModeViewModel
        let gate = StartStallGate()
        viewModel.test_afterProviderInputAugmentation = { await gate.suspend() }
        _ = launch(
            service, args: ["model_id": .string("cursor:composer-2.5")],
            observation: observation, gate: gate, clock: clock
        )
        await drainScheduler(until: { gate.hasEntered })
        XCTAssertTrue(gate.hasEntered)
        let target = try XCTUnwrap(observation.target)
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        await drainScheduler()
        clock.advance(to: .seconds(60))
        await drainScheduler(until: { session.runState == .failed && session.activeRunOwnership == nil })
        XCTAssertEqual(session.runState, .failed)
        gate.release()
        await drainScheduler()
        viewModel.test_afterProviderInputAugmentation = nil
        session.selectedAgent = .antigravity
        session.selectedModelRaw = "gemini-3.8-flash-high"
        runtime.initialization.release()

        let submission = viewModel.submitUserTurn(text: "A genuinely new submission", tabID: target.tabID)
        guard case .submitted = submission else {
            XCTFail("A new submission after startup failure must be admitted: \(submission)")
            return
        }
        await drainScheduler(until: { runtime.processEntered })
        XCTAssertTrue(runtime.processEntered, "A new submission must reach the shipped provider's process dispatch")
        XCTAssertEqual(session.runState, .running)
        XCTAssertNotNil(session.provider)
        XCTAssertEqual(session.activeAgentSessionID, target.sessionID)
        XCTAssertEqual(try viewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))?.status, .running)
    }

    private func makeDeferredPreparationStart(
        runtime: StartRuntimeProbe,
        clock: StartStallClock,
        observation: StartStallObservation,
        providerConstructed: @escaping () -> Void
    ) async throws -> (WindowState, AgentRunMCPToolService, RoutedStartDispatchRecorder) {
        let fixture = try await RoutedStartFixture.make(
            testCase: self, modelClass: "composer", effortRaw: nil, routerEnabled: false
        )
        let root = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.repoPaths.first)
        let recorder = RoutedStartDispatchRecorder()
        let priorAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let viewModel = AgentModeViewModel(
                    testWindowID: windowID,
                    testWorkspacePath: root,
                    codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Deferred preparation must not launch Codex") },
                    headlessProviderFactory: { _, _, _, _, _ in
                        providerConstructed()
                        return runtime.provider
                    },
                    acpProviderFactory: { _, _ in
                        providerConstructed()
                        return AgentSessionLinkCapturingACPProvider(providerID: .cursor, commandPath: "/usr/bin/true")
                    },
                    acpControllerFactory: { _, request in
                        recorder.recordACP(request)
                        throw MCPError.internalError("Unexpected deferred ACP dispatch")
                    },
                    connectionPolicyInstaller: { client, window, restricted, oneShot, reason, ttl, tab, run, additional, purpose, label, external, expectedPID in
                        await ServerNetworkManager.shared.installClientConnectionPolicy(
                            for: client, windowID: window, restrictedTools: restricted, oneShot: oneShot,
                            reason: reason, ttl: ttl, tabID: tab, runID: run, additionalTools: additional,
                            purpose: purpose, taskLabelKind: label, allowsAgentExternalControlTools: external,
                            requiresExpectedAgentPID: expectedPID
                        )
                    },
                    mcpRunRoutingCleaner: { _, _, _ in },
                    mcpServerEnabler: { true },
                    testMCPServer: server,
                    testWorkspaceFileContextStore: prompt.workspaceFileContextStore
                )
                viewModel.promptManager = prompt
                viewModel.workspaceManager = manager
                viewModel.modelRouterSettingsStore = fixture.window.agentModeViewModel.modelRouterSettingsStore
                return viewModel
            },
            contextBuilderProviderFactory: { _, _, _, _ in AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1) }
        )
        GlobalSettingsStore.shared.setMCPAutoStart(priorAutoStart, commit: false)
        WindowStatesManager.shared.registerWindowState(window)
        addTeardownBlock { @MainActor in
            window.agentModeViewModel.test_afterProviderInputAugmentation = nil
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        await window.workspaceManager.awaitInitialized()
        window.apiSettingsViewModel.isCursorConnected = true
        window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.cursor, .antigravity])
        let workspace = window.workspaceManager.createWorkspace(name: "Deferred preparation \(UUID())", repoPaths: [root], ephemeral: true)
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "deferredPreparationStart")
        try window.promptManager.loadComposeTabsFromWorkspace(XCTUnwrap(window.workspaceManager.activeWorkspace), syncPromptText: true)
        await drainScheduler(until: { window.apiSettingsViewModel.isAntigravityConnected })
        XCTAssertTrue(window.apiSettingsViewModel.isAntigravityConnected)

        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { .init(connectionID: nil, clientName: "deferred-preparation-test", windowID: window.windowID) },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, message, metadata, viewModel, agent, model, effort, taskLabel, workflow, parentID, source, preserve in
                try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                    target: target, message: message, metadata: metadata, agentModeVM: viewModel,
                    agentRaw: agent, modelRaw: model, reasoningEffortRaw: effort, taskLabelKind: taskLabel,
                    workflow: workflow, expectedParentSessionID: parentID, oracleReviewSource: source,
                    preserveRoutedInitialEffort: preserve
                )
            }
        )
        service.resolveOracleReviewLaunchSource = makeService(fixture, clock: clock, observation: observation).resolveOracleReviewLaunchSource
        service.testAfterTargetResolution = { observation.target = $0 }
        service.testStartupNow = { clock.now }
        service.testStartupSleep = { try await clock.sleep(for: $0) }
        return (window, service, recorder)
    }

    func testStalledProviderInitializationFailsAndReleasesLease() async throws {
        let runtime = try makeRuntimeProbe()
        let fixture = try await makeRuntimeFixture(runtime)
        let clock = StartStallClock()
        let observation = StartStallObservation()
        let service = makeService(fixture, clock: clock, observation: observation, shippedRuntime: true)
        _ = launch(
            service, args: ["model_id": .string("antigravity:gemini-3.8-flash-high")],
            observation: observation, gate: runtime.initialization, clock: clock
        )
        await drainScheduler(until: { runtime.initialization.hasEntered })
        XCTAssertTrue(runtime.initialization.hasEntered, "The shipped provider must reach prepareContext")
        let target = try XCTUnwrap(observation.target)
        let session = try XCTUnwrap(fixture.window.agentModeViewModel.session(for: target.tabID, createIfNeeded: false))
        let runID = try XCTUnwrap(session.runID)
        await drainScheduler()
        clock.advance(to: .seconds(1))
        await drainScheduler(until: { observation.result != nil })
        XCTAssertNotNil(observation.reply?.objectValue?["session_id"]?.stringValue)
        clock.advance(to: .seconds(60))
        await drainScheduler(until: { session.provider == nil && session.runState == .failed })

        let snapshot = try fixture.window.agentModeViewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))
        XCTAssertEqual(snapshot?.status, .failed)
        XCTAssertEqual(snapshot?.failureReason, .timeout)
        XCTAssertFalse(snapshot?.statusText?.isEmpty ?? true)
        XCTAssertNil(session.provider, "Timeout must detach the initializing provider")
        XCTAssertFalse(runtime.initialization.isOpen, "Lease cleanup must not depend on initializer cooperation")
        let history = await ServerNetworkManager.shared.debugRunRoutingHistoryPayload(runID: runID, limit: 100)
        let events = history["events"] as? [[String: Any]] ?? []
        XCTAssertTrue(events.contains { event in
            guard event["event"] as? String == "lease_cleanup_completed",
                  let fields = event["fields"] as? [String: String] else { return false }
            return fields["policy_cleared"] == "true" && fields["routing_cleaned"] == "true"
        }, "The timed-out startup must revoke its bootstrap policy and routing state")
        runtime.initialization.release()
        await drainScheduler()
        XCTAssertEqual(try fixture.window.agentModeViewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))?.status, .failed)
        XCTAssertFalse(runtime.processEntered, "Late initialization must not start a process")
    }

    func testStalledStartDoesNotQueueLaterHeadlessStart() async throws {
        let firstRuntime = try makeRuntimeProbe()
        let laterRuntime = try makeRuntimeProbe()
        let probes = [firstRuntime, laterRuntime]
        var next = 0
        let fixture = try await RoutedStartFixture.make(
            testCase: self, modelClass: "gemini-flash", effortRaw: nil,
            headlessProviderFactory: { _, _, _, _, _ in
                let probe = probes[min(next, probes.count - 1)]
                next += 1
                return probe.provider
            }
        )
        let clock = StartStallClock()
        let first = StartStallObservation()
        _ = launch(
            makeService(fixture, clock: clock, observation: first, shippedRuntime: true),
            args: ["model_id": .string("antigravity:gemini-3.8-flash-high")],
            observation: first, gate: firstRuntime.initialization, clock: clock
        )
        await drainScheduler(until: { firstRuntime.initialization.hasEntered })
        XCTAssertTrue(firstRuntime.initialization.hasEntered)
        await drainScheduler()
        clock.advance(to: .seconds(60))
        await drainScheduler()
        let firstID = try XCTUnwrap(first.sessionID)
        XCTAssertEqual(fixture.window.agentModeViewModel.mcpSnapshot(sessionID: firstID)?.status, .failed)

        let later = StartStallObservation()
        _ = launch(
            makeService(fixture, clock: clock, observation: later, shippedRuntime: true),
            args: ["model_id": .string("antigravity:gemini-3.8-flash-high")],
            observation: later, gate: laterRuntime.initialization, clock: clock
        )
        await drainScheduler(until: { laterRuntime.initialization.hasEntered })
        XCTAssertTrue(laterRuntime.initialization.hasEntered, "A stalled earlier initializer must not retain startup admission")
        XCTAssertFalse(firstRuntime.initialization.isOpen)
        let gate = await HeadlessAgentConnectionGate.snapshot()
        XCTAssertEqual(gate.queueDepth, 0)
        clock.advance(to: .seconds(61))
        await drainScheduler(until: { later.result != nil })
        XCTAssertNotNil(later.reply?.objectValue?["session_id"]?.stringValue)
    }

    func testStartedRunIsNotCutOffBySupervision() async throws {
        let runtime = try makeRuntimeProbe()
        runtime.initialization.release()
        let fixture = try await makeRuntimeFixture(runtime)
        let clock = StartStallClock()
        let observation = StartStallObservation()
        _ = launch(
            makeService(fixture, clock: clock, observation: observation, shippedRuntime: true),
            args: ["model_id": .string("antigravity:gemini-3.8-flash-high")],
            observation: observation, gate: runtime.initialization, clock: clock
        )
        await drainScheduler(until: { runtime.processEntered })
        XCTAssertTrue(runtime.processEntered)
        let target = try XCTUnwrap(observation.target)
        let session = try XCTUnwrap(fixture.window.agentModeViewModel.session(for: target.tabID, createIfNeeded: false))
        await drainScheduler()
        clock.advance(to: .seconds(120))
        await drainScheduler()
        XCTAssertEqual(session.runState, .running)
        XCTAssertNotNil(session.provider)
        XCTAssertFalse(session.agentTask?.isCancelled ?? true)
        XCTAssertEqual(try fixture.window.agentModeViewModel.mcpSnapshot(sessionID: XCTUnwrap(target.sessionID))?.status, .running)
    }

    func testDetachedRoutedStartRepliesWhileRoutingIsSlow() async throws {
        let fixture = try await makeFixture()
        let gate = StartStallGate()
        await fixture.service.suspendNextDecision(on: gate)
        let clock = StartStallClock()
        let observation = StartStallObservation()
        let service = makeService(fixture, clock: clock, observation: observation)
        let request = launch(service, observation: observation, gate: gate, clock: clock)
        await gate.waitUntilEntered()
        XCTAssertTrue(gate.hasEntered)

        await drainScheduler()
        clock.advance(to: .seconds(1))
        await drainScheduler(until: { observation.result != nil })
        let earlyReply = observation.reply
        XCTAssertNotNil(
            earlyReply?.objectValue?["session_id"]?.stringValue,
            "Detached start must acknowledge a session within 1 virtual second without a routing answer"
        )
        XCTAssertEqual(earlyReply?.objectValue?["status"], .string("running"))
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(observation.dispatchCount, 0)

        if let sessionID = earlyReply?.objectValue?["session_id"]?.stringValue {
            let waitRequest = Task { @MainActor in
                do {
                    observation.waitReply = try await service.execute(args: [
                        "op": .string("wait"), "session_id": .string(sessionID), "timeout": .int(30)
                    ])
                } catch { XCTFail("Pending-start wait failed: \(error)") }
            }
            addTeardownBlock { @MainActor in
                waitRequest.cancel()
                await waitRequest.value
            }
            await drainScheduler()
            XCTAssertNil(observation.waitReply, "A positive wait must not time out immediately before registration")
            gate.release()
            await request.value
            await drainScheduler(until: { observation.waitEntered && observation.dispatchCount == 1 })
            XCTAssertNil(observation.waitReply)
            try await completeRun(fixture, observation: observation)
            await waitRequest.value
            XCTAssertEqual(observation.waitReply?.objectValue?["status"], .string("completed"))
        } else {
            gate.release()
            await request.value
        }
    }

    func testNeverSettlingTargetFailsWithReasonWithinBound() async throws {
        for phase in ["routing", "provider target", "activated provider"] {
            let stallRouting = phase == "routing"
            let stallAfterActivation = phase == "activated provider"
            let fixture = try await makeFixture()
            let gate = StartStallGate()
            if stallRouting { await fixture.service.suspendNextDecision(on: gate) }
            let clock = StartStallClock()
            let observation = StartStallObservation()
            let service = makeService(
                fixture, clock: clock, observation: observation,
                providerGate: stallRouting || stallAfterActivation ? nil : gate,
                dispatchGate: stallAfterActivation ? gate : nil
            )
            let args: [String: Value] = stallRouting ? [:] : ["model_id": .string("cursor:composer-2.5")]
            let request = launch(service, args: args, observation: observation, gate: gate, clock: clock)
            await gate.waitUntilEntered()
            XCTAssertTrue(gate.hasEntered)
            if stallAfterActivation {
                let registration = try XCTUnwrap(observation.sessionID.flatMap(fixture.window.agentModeViewModel.mcpRegistration(sessionID:)))
                let waiter = Task { @MainActor in
                    observation.waitResult = await AgentRunSessionStore.waitUntilInteresting(registration: registration)
                }
                addTeardownBlock { waiter.cancel() }
            }
            await drainScheduler()
            clock.advance(to: .seconds(1))
            await drainScheduler()
            clock.advance(to: .seconds(60))
            await drainScheduler(until: {
                observation.sessionID.flatMap(fixture.window.agentModeViewModel.mcpSnapshot(sessionID:))?.status == .failed
            })

            let snapshot = observation.sessionID.flatMap(fixture.window.agentModeViewModel.mcpSnapshot(sessionID:))
            XCTAssertEqual(snapshot?.status, .failed, "A never-settling \(phase) must fail within 60 virtual seconds")
            XCTAssertEqual(snapshot?.failureReason, .timeout, phase)
            XCTAssertFalse(snapshot?.statusText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, phase)
            XCTAssertFalse(gate.isOpen)

            gate.release()
            await request.value
            await drainScheduler()
            XCTAssertEqual(observation.dispatchCount, 0, "A late \(phase) answer must not dispatch a timed-out start")
            if stallAfterActivation {
                await drainScheduler(until: { observation.waitResult != nil })
                guard case let .snapshotReady(terminal)? = observation.waitResult else {
                    XCTFail("An already-suspended epoch waiter must receive terminal failure, not expire or remain parked")
                    continue
                }
                XCTAssertEqual(terminal.status, .failed)
                XCTAssertEqual(terminal.failureReason, .timeout)
            }
        }
    }

    func testStuckStartCanBeStoppedAndCleanedUp() async throws {
        let fixture = try await makeFixture()
        let gate = StartStallGate()
        let clock = StartStallClock()
        let observation = StartStallObservation()
        let service = makeService(fixture, clock: clock, observation: observation, providerGate: gate)
        let request = launch(
            service, args: ["model_id": .string("cursor:composer-2.5")],
            observation: observation, gate: gate, clock: clock
        )
        await gate.waitUntilEntered()
        await drainScheduler()
        clock.advance(to: .seconds(1))
        await drainScheduler()
        clock.advance(to: .seconds(60))
        await drainScheduler(until: {
            observation.sessionID.flatMap(fixture.window.agentModeViewModel.mcpSnapshot(sessionID:))?.status == .failed
        })
        let sessionID = try XCTUnwrap(observation.sessionID)
        let manage = makeManageService(fixture)
        do {
            let stopped = try await manage.execute(args: ["op": .string("stop_session"), "session_id": .string(sessionID.uuidString)])
            XCTAssertEqual(stopped.objectValue?["session_id"], .string(sessionID.uuidString))
        } catch {
            XCTFail("A timed-out target must not remain forever provisional: \(error)")
            return
        }
        let cleaned = try await manage.execute(args: [
            "op": .string("cleanup_sessions"), "session_ids": .array([.string(sessionID.uuidString)])
        ])
        let deleted = cleaned.objectValue?["deleted_sessions"]?.arrayValue ?? []
        XCTAssertEqual(deleted.compactMap { $0.objectValue?["session_id"]?.stringValue }, [sessionID.uuidString])
        XCTAssertEqual(deleted.first?.objectValue?["durable"], .bool(true))
        XCTAssertFalse(fixture.window.agentModeViewModel.sessions.values.contains { $0.activeAgentSessionID == sessionID })

        gate.release()
        await request.value
        await drainScheduler()
        XCTAssertEqual(observation.dispatchCount, 0)
        XCTAssertFalse(
            fixture.window.agentModeViewModel.sessions.values.contains { $0.activeAgentSessionID == sessionID },
            "Late provider settlement must not resurrect the deleted target"
        )
    }

    func testStuckStartDoesNotBlockLaterWorktreeStart() async throws {
        let (fixture, worktree) = try await makeWorktreeFixture()
        let gate = StartStallGate()
        await fixture.service.suspendNextDecision(on: gate)
        let clock = StartStallClock()
        let first = StartStallObservation()
        _ = launch(makeService(fixture, clock: clock, observation: first), observation: first, gate: gate, clock: clock)
        await gate.waitUntilEntered()
        XCTAssertTrue(gate.hasEntered)
        let later = StartStallObservation()
        let laterService = makeService(fixture, clock: clock, observation: later)
        _ = launch(laterService, args: [
            "model_id": .string("cursor:composer-2.5"), "worktree": .string(worktree.path)
        ], observation: later, gate: gate, clock: clock)
        await drainScheduler(until: { later.result != nil })
        clock.advance(to: .seconds(1))
        await drainScheduler(until: { later.result != nil })

        XCTAssertNotNil(
            later.reply?.objectValue?["session_id"]?.stringValue,
            "The later pinned worktree start must reply within 1 virtual second while routing is suspended"
        )
        XCTAssertFalse(gate.isOpen)
        let sessionID = try XCTUnwrap(later.sessionID)
        try await AsyncTestWait.waitUntil("later pinned worktree binding and provider dispatch", timeout: 10) {
            await MainActor.run {
                let bindings = fixture.window.agentModeViewModel.worktreeBindings(forAgentSessionID: sessionID)
                return bindings.count == 1
                    && bindings.first?.worktreeRootPath == worktree.standardizedFileURL.path
                    && later.dispatchCount == 1
            }
        }
        let bindings = fixture.window.agentModeViewModel.worktreeBindings(forAgentSessionID: sessionID)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings.first?.worktreeRootPath, worktree.standardizedFileURL.path)
        XCTAssertEqual(later.dispatchedWorktreeRoots, [worktree.standardizedFileURL.path])
        XCTAssertEqual(first.dispatchCount, 0)
    }

    func testSettlingStartsUnchanged() async throws {
        let (fixture, worktree) = try await makeWorktreeFixture()
        for routed in [false, true] {
            let clock = StartStallClock()
            let observation = StartStallObservation()
            let service = makeService(fixture, clock: clock, observation: observation)
            var args = startArgs(["worktree": .string(worktree.path)])
            if !routed { args["model_id"] = .string("cursor:composer-2.5") }
            let reply = try await service.execute(args: args)
            await drainScheduler(until: { observation.dispatchCount == 1 })
            let target = try XCTUnwrap(observation.target)
            let sessionID = try XCTUnwrap(target.sessionID)
            XCTAssertEqual(reply.objectValue?["session_id"], .string(sessionID.uuidString))
            let session = try XCTUnwrap(fixture.window.agentModeViewModel.session(for: target.tabID, createIfNeeded: false))
            XCTAssertEqual(session.activeAgentSessionID, sessionID)
            XCTAssertEqual(session.selectedAgent, .cursor)
            XCTAssertEqual(session.selectedModelRaw, "composer-2.5")
            XCTAssertEqual(
                fixture.window.agentModeViewModel.worktreeBindings(forAgentSessionID: sessionID).first?.worktreeRootPath,
                worktree.standardizedFileURL.path
            )
            try await completeRun(fixture, observation: observation)
            clock.cancelAll()
        }

        let clock = StartStallClock()
        let observation = StartStallObservation()
        let gate = StartStallGate()
        let service = makeService(fixture, clock: clock, observation: observation)
        let request = launch(service, args: [
            "model_id": .string("cursor:composer-2.5"), "detach": .bool(false)
        ], observation: observation, gate: gate, clock: clock)
        await drainScheduler(until: { observation.waitEntered })
        XCTAssertTrue(observation.waitEntered, "Non-detached start must enter the shipped run waiter")
        XCTAssertNil(observation.result, "A running non-detached start must not return a pending acknowledgment")
        try await completeRun(fixture, observation: observation)
        await request.value
        XCTAssertEqual(observation.reply?.objectValue?["status"], .string("completed"))
    }
}

private extension AgentRunMCPStartStallTests {
    func makeRuntimeProbe() throws -> StartRuntimeProbe {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StartRuntime-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = StartRuntimeProbe(root: root)
        addTeardownBlock { @MainActor in
            probe.initialization.release()
            probe.process.continuation.finish()
            probe.progressClock.cancelAll()
            await probe.provider.dispose()
            try? FileManager.default.removeItem(at: root)
        }
        return probe
    }

    func makeRuntimeFixture(_ probe: StartRuntimeProbe) async throws -> RoutedStartFixture {
        try await RoutedStartFixture.make(
            testCase: self, modelClass: "gemini-flash", effortRaw: nil,
            headlessProviderFactory: { _, _, _, _, _ in probe.provider }
        )
    }

    func makeFixture(prepareRoot: ((URL) throws -> Void)? = nil) async throws -> RoutedStartFixture {
        try await RoutedStartFixture.make(
            testCase: self, modelClass: "composer", effortRaw: nil, prepareRoot: prepareRoot
        )
    }

    func makeWorktreeFixture() async throws -> (RoutedStartFixture, URL) {
        let git = try ReviewGitRepositoryFixture()
        addTeardownBlock { git.cleanup() }
        let fixture = try await makeFixture { root in
            try git.initializeRepository(at: root)
            try git.write("fixture\n", to: "README.md", at: root)
            try git.stage("README.md", at: root)
            try git.commit("Fixture", at: root)
        }
        let root = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.repoPaths.first)
        let worktree = git.sandbox.appendingPathComponent("bound")
        _ = try git.runGit(["worktree", "add", "--detach", worktree.path, "HEAD"], at: URL(fileURLWithPath: root))
        return (fixture, worktree)
    }

    func makeService(
        _ fixture: RoutedStartFixture,
        clock: StartStallClock,
        observation: StartStallObservation,
        providerGate: StartStallGate? = nil,
        dispatchGate: StartStallGate? = nil,
        shippedRuntime: Bool = false
    ) -> AgentRunMCPToolService {
        let window = fixture.window
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { .init(connectionID: nil, clientName: "start-stall-test", windowID: window.windowID) },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in
                await MainActor.run { observation.waitEntered = true }
                return try await operation()
            },
            startRun: { target, message, metadata, viewModel, agent, model, effort, taskLabel, workflow, parentID, source, preserve in
                await providerGate?.suspend()
                try Task.checkCancellation()
                return try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                    target: target, message: message, metadata: metadata, agentModeVM: viewModel,
                    agentRaw: agent, modelRaw: model, reasoningEffortRaw: effort, taskLabelKind: taskLabel,
                    workflow: workflow, expectedParentSessionID: parentID, oracleReviewSource: source,
                    preserveRoutedInitialEffort: preserve,
                    dispatchInstruction: { _, tabID, message, _, viewModel in
                        if shippedRuntime {
                            _ = await viewModel.startAgentRun(tabID: tabID, initialMessage: message)
                            observation.dispatchCount += 1
                            return .startedRun
                        }
                        let session = try XCTUnwrap(viewModel.session(for: tabID, createIfNeeded: false))
                        await viewModel.prepareMCPWaitTrackingForRunStart(
                            session: session, stopFence: AgentRunStartStopFence(session: session)
                        )
                        await dispatchGate?.suspend()
                        try Task.checkCancellation()
                        observation.dispatchedWorktreeRoots = session.worktreeBindings.map(\.worktreeRootPath)
                        observation.ownership = session.beginRunAttempt(source: "start-stall-fixture")
                        session.runState = .running
                        session.mcpFollowUpRunPending = false
                        observation.dispatchCount += 1
                        return .startedRun
                    }
                )
            }
        )
        service.resolveOracleReviewLaunchSource = { _, window in
            let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(workspace.activeComposeTabID)
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: AgentRunOracleReviewLaunchSnapshot(
                    route: .explicitWindowActiveCompose, windowID: window.windowID, workspaceID: workspace.id,
                    tabID: tabID, selectionRevision: 0, promptText: "", selection: StoredSelection(),
                    sourceAgentSessionID: nil, routedRunID: nil
                ),
                source: .unavailable(.init(
                    delegationID: UUID(), sourceTabID: tabID, workspaceID: workspace.id, sourceAgentSessionID: nil,
                    sourceAgentRunID: nil, reason: .sourceCaptureFailed("start-stall fixture")
                ))
            )
        }
        service.testAfterTargetResolution = { observation.target = $0 }
        service.testStartupNow = { clock.now }
        service.testStartupSleep = { try await clock.sleep(for: $0) }
        return service
    }

    func makeManageService(_ fixture: RoutedStartFixture) -> AgentManageMCPToolService {
        let window = fixture.window
        return AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: { .init(connectionID: nil, clientName: "start-stall-test", windowID: window.windowID) },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in }
        )
    }

    func startArgs(_ extra: [String: Value]) -> [String: Value] {
        var args: [String: Value] = [
            "op": .string("start"), "message": .string("Start this fixture task"), "detach": .bool(true)
        ]
        args.merge(extra, uniquingKeysWith: { _, new in new })
        return args
    }

    func launch(
        _ service: AgentRunMCPToolService,
        args: [String: Value] = [:],
        observation: StartStallObservation,
        gate: StartStallGate,
        clock: StartStallClock
    ) -> Task<Void, Never> {
        let args = startArgs(args)
        let request = Task { @MainActor in
            do {
                let value = try await service.execute(args: args)
                observation.result = .success(value)
            } catch {
                observation.result = .failure(error)
                gate.finishWithoutEntering()
            }
        }
        addTeardownBlock { @MainActor in
            request.cancel()
            gate.release()
            clock.cancelAll()
            await request.value
        }
        return request
    }

    func drainScheduler(until predicate: @MainActor () -> Bool = { false }) async {
        for _ in 0 ..< 20000 {
            if predicate() { return }
            await Task.yield()
        }
    }

    func completeRun(_ fixture: RoutedStartFixture, observation: StartStallObservation) async throws {
        let viewModel = fixture.window.agentModeViewModel
        let target = try XCTUnwrap(observation.target)
        let sessionID = try XCTUnwrap(target.sessionID)
        let session = try XCTUnwrap(viewModel.session(for: target.tabID, createIfNeeded: false))
        let ownership = try XCTUnwrap(observation.ownership)
        let envelope = try XCTUnwrap(viewModel.test_makeTerminalPublicationEnvelope(
            for: session, ownership: ownership, terminalState: .completed
        ))
        let registration = try XCTUnwrap(viewModel.mcpRegistration(sessionID: sessionID))
        session.runState = .completed
        let publication = await AgentRunSessionStore.publishTerminal(
            envelope, registration: registration, commitID: UUID(), successorKind: nil
        )
        XCTAssertEqual(publication, .accepted(successorEpoch: nil))
    }
}

@MainActor
private final class StartRuntimeProbe {
    let initialization = StartStallGate()
    let process = AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>.makeStream()
    let progressClock = StartStallClock()
    private(set) var processEntered = false
    let root: URL

    init(root: URL) {
        self.root = root
    }

    lazy var provider = AntigravityAgentProvider(
        runner: CLIProcessRunner(config: CLIProcessConfiguration(command: "/never-launch-agy", additionalPaths: [])),
        config: AntigravityAgentConfig(maxPrintResumes: 0),
        runtimeOverrides: .init(
            prepareContext: { [self] runID in
                await initialization.suspend()
                try Task.checkCancellation()
                let runID = try XCTUnwrap(runID)
                await MCPRoutingWaiter.notifyRouted(runID: runID)
                return HeadlessAgentContext(runID: runID, configURL: nil, environment: ["HOME": root.path])
            },
            processEvents: { [self] _, _ in
                await MainActor.run { self.processEntered = true }
                return process.stream
            },
            logDirectory: root.appendingPathComponent("logs"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
            now: { 0 },
            waitForProgressCheck: { [progressClock] in try await progressClock.sleep(for: .seconds(3600)) },
            cancelProcess: { [process] in process.continuation.finish() }
        )
    )
}

@MainActor
private final class StartStallObservation {
    var result: Result<Value, Error>?
    var target: AgentModeViewModel.MCPSessionTarget?
    var ownership: AgentRunOwnership?
    var dispatchCount = 0
    var dispatchedWorktreeRoots: [String]?
    var waitEntered = false
    var waitResult: AgentRunSessionStore.WaitDisposition?
    var waitReply: Value?

    var reply: Value? {
        guard let result, case let .success(value) = result else { return nil }
        return value
    }

    var sessionID: UUID? {
        reply?.objectValue?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? target?.sessionID
    }
}

@MainActor
final class StartStallGate {
    private(set) var hasEntered = false
    private(set) var isOpen = false
    private var finished = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        hasEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !hasEntered, !finished else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func finishWithoutEntering() {
        finished = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

final class StartStallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Duration = .zero
    private var closed = false
    private var sleepers: [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]

    var now: Duration {
        lock.withLock { instant }
    }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let installed = lock.withLock {
                    guard !closed, !Task.isCancelled else { return false }
                    sleepers[id] = (instant + duration, continuation)
                    return true
                }
                if !installed { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(to value: Duration) {
        let ready = lock.withLock {
            instant = value
            let ready = sleepers.filter { $0.value.deadline <= instant }
            for id in ready.keys {
                sleepers.removeValue(forKey: id)
            }
            return ready.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    func cancelAll() {
        let pending = lock.withLock {
            closed = true
            let pending = sleepers.values.map(\.continuation)
            sleepers.removeAll()
            return pending
        }
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private final class AgentRunFailingSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_ value: String, for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}

final class MCPToolIdleWaitTests: XCTestCase {
    @MainActor
    func testAlreadyCancelledToolIdleWaitDoesNotTakeIdleFastPath() async {
        let server = makeServerViewModel(service: MCPService(
            hostBootstrapOperation: {}, controllerStartOperation: {}, controllerFullShutdownOperation: {}
        ))
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await server.awaitNoActiveToolExecutions(runID: UUID())
        }
        do {
            try await task.value
            XCTFail("Already-cancelled idle waiter must throw")
        } catch is CancellationError {
            // The same guard also closes cancellation before continuation installation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func makeServerViewModel(service: MCPService) -> MCPServerViewModel {
        let store = WorkspaceFileContextStore()
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: -1)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: -1,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return MCPServerViewModel(
            service: service,
            promptVM: prompt,
            oracleVM: oracle,
            workspaceManager: workspaceManager,
            windowID: -1,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("workspace search is not used by these tests")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("git-data loading is not used by these tests")
            }
        )
    }
}
