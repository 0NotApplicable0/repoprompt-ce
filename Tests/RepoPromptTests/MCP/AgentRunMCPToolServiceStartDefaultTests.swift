import Foundation
import MCP
@_spi(TestSupport)
@testable import RepoPromptApp
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
        XCTAssertEqual(capture.model, "gemini-3.8-flash-low")
        XCTAssertEqual(capture.parameters, [])
        let stages = await fixture.backend.requestStages()
        XCTAssertEqual(stages, [.model, .effort])
        try await fixture.assertOneAppliedRowMatchesDecision()
    }

    func testRoutedStartLaunchesGrokTarget() async throws {
        let fixture = try await RoutedStartFixture.make(testCase: self, modelClass: "grok", effortRaw: nil)
        let capture = try await fixture.start()

        XCTAssertEqual(capture.agent, .grok)
        XCTAssertEqual(capture.model, "grok-4.7")
        XCTAssertEqual(capture.parameters, [])
        let stages = await fixture.backend.requestStages()
        XCTAssertEqual(stages, [.model])
        try await fixture.assertOneAppliedRowMatchesDecision()
    }

    func testRoutedStartLaunchesCursorTargetWithParameters() async throws {
        let composer = try await RoutedStartFixture.make(testCase: self, modelClass: "composer", effortRaw: nil)
        let composerCapture = try await composer.start()
        XCTAssertEqual(composerCapture.agent, .cursor)
        XCTAssertEqual(composerCapture.model, "composer-2.5")
        XCTAssertEqual(composerCapture.parameters, [])
        try await composer.assertOneAppliedRowMatchesDecision()

        let grok = try await RoutedStartFixture.make(testCase: self, modelClass: "cursor-grok", effortRaw: "xhigh", verifyGrok: false)
        let grokCapture = try await grok.start()
        XCTAssertEqual(grokCapture.agent, .cursor)
        XCTAssertEqual(grokCapture.model, "grok-4.7")
        XCTAssertEqual(grokCapture.parameters, [
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "grok-4.7",
                kind: .thinking,
                configID: "reasoning_effort",
                valueRaw: "xhigh"
            )
        ])
        let stages = await grok.backend.requestStages()
        XCTAssertEqual(stages, [.model, .effort])
        try await grok.assertOneAppliedRowMatchesDecision()
    }

    func testExplicitModelIDStillBypassesRouting() async throws {
        let fixture = try await RoutedStartFixture.make(testCase: self, modelClass: "gemini-flash", effortRaw: "low")
        let capture = try await fixture.start(modelID: "cursor:composer-2.5")

        XCTAssertEqual(capture.agent, .cursor)
        XCTAssertEqual(capture.model, "composer-2.5")
        XCTAssertEqual(capture.parameters, [])
        let stages = await fixture.backend.requestStages()
        XCTAssertTrue(stages.isEmpty)
        try await fixture.assertRouteLogHoldsNoRows()
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
        locked { headless }
    }

    var acpRunRequests: [ACPRunRequest] {
        locked { acp }
    }

    var claudeNativeStartCount: Int {
        locked { claudeStarts }
    }

    func recordHeadless(_ agent: AgentProviderKind, _ model: String?) {
        locked { headless.append(HeadlessStart(agent: agent, model: model)) }
    }

    func recordACP(_ request: ACPRunRequest) {
        locked { acp.append(request) }
    }

    func recordClaudeStart() {
        locked { claudeStarts += 1 }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

actor RoutedStartBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "routed-start")
    nonisolated let displayName = "Routed start"
    private let modelClass: String
    private let effortRaw: String?
    private(set) var requests: [AgentTaskRoutingRequest] = []

    init(modelClass: String, effortRaw: String?) {
        self.modelClass = modelClass
        self.effortRaw = effortRaw
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "routed-start-v1")
    }

    func requestStages() -> [AgentTaskRoutingDecisionStage] {
        requests.map(\.decisionStage)
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        requests.append(request)
        let label: String
        switch request.decisionStage {
        case .model: label = modelClass
        case .effort:
            guard let effortRaw else {
                return .failed(category: .invalidResponse, retryable: false, evidence: nil)
            }
            label = "effort:\(effortRaw)"
        }
        let matches = request.candidates.filter { $0.roleLabels.contains(label) }
        guard matches.count == 1, let match = matches.first else {
            return .failed(category: .invalidResponse, retryable: false, evidence: nil)
        }
        return .selected(opaqueKey: match.opaqueKey, evidence: nil)
    }
}

struct AntigravityGlobalSnapshot: @unchecked Sendable {
    let projection: AntigravityConnectionCoordinator.Projection?
    let hint: Any?
}

@MainActor
final class RoutedStartFixture {
    struct Capture: Equatable {
        let agent: AgentProviderKind
        let model: String
        let parameters: [ACPModelParameterSelection]
    }

    let backend: RoutedStartBackend
    let window: WindowState
    let recorder: RoutedStartDispatchRecorder
    private let log: AgentTaskRoutingDecisionLog
    private let logURL: URL
    private var capture: Capture?

    private init(backend: RoutedStartBackend, window: WindowState, recorder: RoutedStartDispatchRecorder, log: AgentTaskRoutingDecisionLog, logURL: URL) {
        self.backend = backend
        self.window = window
        self.recorder = recorder
        self.log = log
        self.logURL = logURL
    }

    static func make(testCase: XCTestCase, modelClass: String, effortRaw: String?, verifyGrok: Bool = true) async throws -> RoutedStartFixture {
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        let speed = ACPModelParameterDefinition(
            kind: .speed, configID: "fast", displayName: "Speed",
            choices: [.init(rawValue: "false", displayName: "Standard"), .init(rawValue: "true", displayName: "Fast")],
            currentValueRaw: "true"
        )
        let thinking = ACPModelParameterDefinition(
            kind: .thinking, configID: "reasoning_effort", displayName: "Effort",
            choices: ["low", "medium", "high", "xhigh"].map { .init(rawValue: $0, displayName: $0) },
            currentValueRaw: "high"
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [.init(rawValue: "composer-2.5", displayName: "Composer", description: nil, isDefault: false), .init(rawValue: "grok-4.7", displayName: "Grok", description: nil, isDefault: false)],
                currentModelRaw: "grok-4.7",
                modelParameterSets: [.init(baseModelRaw: "composer-2.5", parameters: [speed]), .init(baseModelRaw: "grok-4.7", parameters: [thinking, speed])]
            ),
            for: .cursor
        )
        testCase.addTeardownBlock { @MainActor in
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        }
        let backend = RoutedStartBackend(modelClass: modelClass, effortRaw: effortRaw)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoutedStartFixture.\(UUID())"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        store.enableModelRouterWithCurrentPolicy(
            backendID: backend.id,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec, .cursor, .antigravity, .grok]
        )
        let logURL = root.appendingPathComponent("decision.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: logURL)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(backend: backend)], decisionLog: log)
        runtime.candidateBuilderFactory = {
            AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in modelOptions(for: provider) })
        }
        try await AsyncTestWait.waitUntil("routed backend ready", timeout: 5) {
            runtime.backendReadiness(backend.id) != nil
        }
        let workspacePath = root.path
        let recorder = RoutedStartDispatchRecorder()
        let window = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let viewModel = AgentModeViewModel(
                    testWindowID: windowID,
                    testWorkspacePath: workspacePath,
                    codexControllerFactory: { _, _, _, _, _, _ in preconditionFailure("Codex must not start") },
                    claudeControllerFactory: { _, _, _, _ in
                        recorder.recordClaudeStart()
                        return MonitorFakeNativeController()
                    },
                    headlessProviderFactory: { agent, model, _, _, _ in
                        recorder.recordHeadless(agent, model)
                        return AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
                    },
                    acpProviderFactory: { agent, _ in
                        guard agent == .cursor else { throw MCPError.internalError("ACP must not start") }
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
        WindowStatesManager.shared.registerWindowState(window)
        testCase.addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        await window.workspaceManager.awaitInitialized()
        window.agentModeViewModel.modelRouterSettingsStore = store
        window.agentModeViewModel.modelRouterRuntime = runtime
        window.apiSettingsViewModel.isClaudeCodeConnected = true
        window.apiSettingsViewModel.isCodexConnected = true
        window.apiSettingsViewModel.isCursorConnected = true
        window.apiSettingsViewModel.isGrokConnected = true
        let antigravity = AntigravityConnectionCoordinator.shared
        let antigravityHintKey = "AntigravityCLIConnected"
        let antigravityPrior = await AntigravityGlobalSnapshot(
            projection: antigravity.latestProjection(),
            hint: UserDefaults.standard.object(forKey: antigravityHintKey)
        )
        let generation = await antigravity.beginManualMutation()
        _ = await antigravity.publishIfCurrent(generation: generation, isConnected: true, errorMessage: nil, hasOwnedMCPEntry: true)
        testCase.addTeardownBlock { @MainActor in
            let restoredConnected = antigravityPrior.projection?.isConnected ?? false
            let restoreGeneration = await antigravity.beginManualMutation()
            _ = await antigravity.publishIfCurrent(
                generation: restoreGeneration,
                isConnected: restoredConnected,
                errorMessage: antigravityPrior.projection?.errorMessage,
                hasOwnedMCPEntry: antigravityPrior.projection?.hasOwnedMCPEntry ?? false
            )
            if let hint = antigravityPrior.hint {
                UserDefaults.standard.set(hint, forKey: antigravityHintKey)
            } else {
                UserDefaults.standard.removeObject(forKey: antigravityHintKey)
            }
            try await AsyncTestWait.waitUntil("window converges on restored Antigravity projection", timeout: 5) {
                window.apiSettingsViewModel.isAntigravityConnected == restoredConnected
            }
        }
        let verifiedProviders: Set<AgentProviderKind> = verifyGrok
            ? [.claudeCode, .codexExec, .cursor, .antigravity, .grok]
            : [.claudeCode, .codexExec, .cursor, .antigravity]
        window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(verifiedProviders: verifiedProviders)
        let workspace = window.workspaceManager.createWorkspace(name: "Routed \(UUID())", repoPaths: [root.path], ephemeral: true)
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "routedStart")
        window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        return RoutedStartFixture(backend: backend, window: window, recorder: recorder, log: log, logURL: logURL)
    }

    func routeLogRequestIDs() async throws -> (decision: [String], applied: [String]) {
        await log.flush()
        guard let data = try? Data(contentsOf: logURL) else { return ([], []) }
        var decision: [String] = []
        var applied: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let requestID = try XCTUnwrap(row["requestID"] as? String)
            switch row["event"] as? String {
            case "decision": decision.append(requestID)
            case "applied": applied.append(requestID)
            default: XCTFail("Unexpected log event \(String(describing: row["event"]))")
            }
        }
        return (decision, applied)
    }

    func assertOneAppliedRowMatchesDecision(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await AsyncTestWait.waitUntil("applied row for the route", timeout: 5) {
            await (try? self.routeLogRequestIDs().applied.isEmpty) == false
        }
        let ids = try await routeLogRequestIDs()
        XCTAssertEqual(ids.applied.count, 1, file: file, line: line)
        let appliedID = try XCTUnwrap(ids.applied.first, file: file, line: line)
        XCTAssertTrue(ids.decision.contains(appliedID), file: file, line: line)
    }

    func assertRouteLogHoldsNoRows(file: StaticString = #filePath, line: UInt = #line) async throws {
        let ids = try await routeLogRequestIDs()
        XCTAssertEqual(ids.decision.count, 0, file: file, line: line)
        XCTAssertEqual(ids.applied.count, 0, file: file, line: line)
    }

    func start(modelID: String? = nil) async throws -> Capture {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "routed-start", windowID: self.window.windowID) },
            requireTargetWindow: { self.window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, message, metadata, viewModel, agentRaw, modelRaw, effort, taskLabel, workflow, parentID, oracleSource, preserve in
                try await AgentExternalMCPRunStarter.startPreservingCallerBinding(target: target, message: message, metadata: metadata, agentModeVM: viewModel, agentRaw: agentRaw, modelRaw: modelRaw, reasoningEffortRaw: effort, taskLabelKind: taskLabel, workflow: workflow, expectedParentSessionID: parentID, oracleReviewSource: oracleSource, preserveRoutedInitialEffort: preserve, dispatchInstruction: { sessionID, tabID, _, workflow, viewModel in
                    guard let session = viewModel.session(for: tabID, createIfNeeded: false), let agent = AgentProviderKind(rawValue: session.selectedAgent.rawValue) else { throw MCPError.internalError("Missing configured session") }
                    self.capture = Capture(agent: agent, model: session.selectedModelRaw, parameters: session.acpModelParameterSelections)
                    return try await viewModel.mcpDispatchInstruction(sessionID: sessionID, text: message, allowStartingRun: true, workflow: workflow, preserveRoutedInitialEffort: true)
                })
            }
        )
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(workspace.activeComposeTabID)
            let snapshot = AgentRunOracleReviewLaunchSnapshot(route: .explicitWindowActiveCompose, windowID: targetWindow.windowID, workspaceID: workspace.id, tabID: tabID, selectionRevision: 0, promptText: "", selection: StoredSelection(), sourceAgentSessionID: nil, routedRunID: nil)
            return ResolvedAgentRunOracleReviewLaunchSource(snapshot: snapshot, source: .unavailable(.init(delegationID: UUID(), sourceTabID: tabID, workspaceID: workspace.id, sourceAgentSessionID: nil, sourceAgentRunID: nil, reason: .sourceCaptureFailed("routed start"))))
        }
        var args: [String: Value] = ["op": .string("start"), "message": .string("Route this task"), "detach": .bool(true), "timeout": .int(0)]
        if let modelID { args["model_id"] = .string(modelID) }
        _ = try await service.execute(args: args)
        return try XCTUnwrap(capture)
    }

    private static func modelOptions(for provider: AgentProviderKind) -> [AgentModelOption] {
        func option(_ raw: String, _ variant: AgentModelEffortVariant? = nil) -> AgentModelOption {
            AgentModelOption(rawValue: raw, displayName: raw, description: nil, isPlaceholderDefault: false, isProviderDefault: false, effortVariant: variant)
        }
        switch provider {
        case .antigravity: return [option("gemini-3.8-flash-high", .init(baseModelRaw: "gemini-3.8-flash", reasoningEffort: .high)), option("gemini-3.8-flash-medium", .init(baseModelRaw: "gemini-3.8-flash", reasoningEffort: .medium)), option("gemini-3.8-flash-low", .init(baseModelRaw: "gemini-3.8-flash", reasoningEffort: .low)), option("gemini-3.1-pro-high", .init(baseModelRaw: "gemini-3.1-pro", reasoningEffort: .high)), option("gemini-3.1-pro-low", .init(baseModelRaw: "gemini-3.1-pro", reasoningEffort: .low))]
        case .grok: return [option("grok-4.7"), option("grok-4.6")]
        case .cursor: return [option("composer-2.5"), option("grok-4.7")]
        default: return []
        }
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
