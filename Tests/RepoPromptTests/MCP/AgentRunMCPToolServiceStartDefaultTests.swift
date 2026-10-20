import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
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

    private let lock = NSLock()
    private var headless: [HeadlessStart] = []
    private var acp: [ACPRunRequest] = []
    private var claudeStarts = 0

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

    init(modelClass: String, effortRaw: String?, fallbackModelClasses: [String] = []) {
        self.modelClass = modelClass
        self.effortRaw = effortRaw
        self.fallbackModelClasses = fallbackModelClasses
    }

    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: "routed-start-v1")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) -> DecisionOutcome {
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
    private var capture: Capture?
    private var caller: (tabID: UUID, sessionID: UUID)?

    var sessionCount: Int {
        window.agentModeViewModel.sessions.count
    }

    private init(service: RoutedStartDecisionService, window: WindowState, recorder: RoutedStartDispatchRecorder) {
        self.service = service
        self.window = window
        self.recorder = recorder
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
        routerEnabled: Bool = true
    ) async throws -> RoutedStartFixture {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        installProviderCatalogs(testCase: testCase)

        let service = RoutedStartDecisionService(
            modelClass: modelClass, effortRaw: effortRaw, fallbackModelClasses: fallbackModelClasses
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutedStart-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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

        let recorder = RoutedStartDispatchRecorder()
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
                        return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
                    },
                    acpProviderFactory: { agent, _ in
                        guard agent == .cursor else { throw MCPError.internalError("Only Cursor may start over ACP") }
                        return AgentSessionLinkCapturingACPProvider(providerID: .cursor, commandPath: "/usr/bin/true")
                    },
                    acpControllerFactory: { _, request in
                        recorder.recordACP(request)
                        throw MCPError.internalError("ACP controller recorded")
                    },
                    connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
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
        return RoutedStartFixture(service: service, window: window, recorder: recorder)
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
