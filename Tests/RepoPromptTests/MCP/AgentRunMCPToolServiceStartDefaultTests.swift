import Foundation
import JSONSchema
import MCP
@_spi(TestSupport)
@testable import RepoPromptApp
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

@MainActor
final class AgentRunMCPToolServiceDiversityTests: XCTestCase {
    /// Grok is verified in this fixture, so the candidate builder drops "cursor-grok" (AgentTaskRoutingCandidateBuilder eligibility); only "grok" is an xai label in the pool.
    private static let xaiLabels: Set<String> = ["grok"]
    private static let pinnedModelID = "cursor:composer-2.5"
    private static let xaiParent: (agent: AgentProviderKind, model: String) = (.grok, "grok-4.7")
    private static let unclassifiableParent: (agent: AgentProviderKind, model: String) = (.kimiCode, "kimi-k2")

    private var reviewArgs: [String: Value] {
        ["workflow_id": .string(AgentWorkflow.review.definition.id)]
    }

    private func makeFixture(
        modelClass: String = "grok",
        fallbackModelClasses: [String] = ["gemini-flash"],
        effortRaw: String? = "low",
        routerEnabled: Bool = true
    ) async throws -> RoutedStartFixture {
        try await RoutedStartFixture.make(
            testCase: self,
            modelClass: modelClass,
            fallbackModelClasses: fallbackModelClasses,
            effortRaw: effortRaw,
            routerEnabled: routerEnabled
        )
    }

    private func makeReviewFixture(
        parent: (agent: AgentProviderKind, model: String)?,
        classifiable: Bool = true,
        reviewDiversity: Bool = true,
        routerEnabled: Bool = true,
        ownership: RoutedStartFixture.CallerOwnership = .capturedWorkspace
    ) async throws -> RoutedStartFixture {
        let fixture = try await makeFixture(routerEnabled: routerEnabled)
        fixture.setReviewDiversityEnabled(reviewDiversity)
        if let parent {
            _ = try await fixture.installAuthorizedCaller(agent: parent.agent, model: parent.model, classifiable: classifiable, ownership: ownership)
        }
        return fixture
    }

    private func showBuiltIn(_ workflow: AgentWorkflow) {
        let store = AgentWorkflowStore.shared
        let wasHidden = store.isBuiltInHidden(workflow)
        store.setBuiltInVisibility(workflow, isVisible: true)
        addTeardownBlock { @MainActor in
            store.setBuiltInVisibility(workflow, isVisible: !wasHidden)
        }
    }

    private func unfilteredPick() async throws -> (capture: RoutedStartFixture.Capture, labels: Set<String>) {
        let control = try await makeFixture()
        let capture = try await control.start()
        XCTAssertEqual(capture.agent, .grok)
        XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: capture.agent, modelRaw: capture.model), .xai)
        let labels = try await control.modelStageCandidateLabels()
        XCTAssertTrue(labels.isSuperset(of: Self.xaiLabels))
        let controlExclusions = try await control.modelDecisionMakerExclusions()
        XCTAssertNil(controlExclusions)
        return (capture, labels)
    }

    private func assertRejected(
        _ fixture: RoutedStartFixture,
        modelID: String? = nil,
        args: [String: Value],
        containing fragment: String,
        preRoute: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sessionsBefore = fixture.sessionCount
        do {
            _ = try await fixture.start(modelID: modelID, additionalArgs: args)
            XCTFail("Expected MCPError.invalidParams for \(args)", file: file, line: line)
        } catch let error as MCPError {
            guard case let .invalidParams(detail) = error else {
                XCTFail("Expected MCPError.invalidParams, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue((detail ?? "").contains(fragment), "\(detail ?? "nil") does not contain \(fragment)", file: file, line: line)
        } catch {
            XCTFail("Expected MCPError.invalidParams, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(fixture.sessionCount, sessionsBefore, "rejection must allocate no session", file: file, line: line)
        XCTAssertTrue(fixture.recorder.headlessStarts.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.recorder.acpRunRequests.isEmpty, file: file, line: line)
        XCTAssertEqual(fixture.recorder.claudeNativeStartCount, 0, file: file, line: line)
        if preRoute {
            let requests = await fixture.backend.requests
            XCTAssertTrue(requests.isEmpty, "pre-route rejection must not reach the advisor", file: file, line: line)
            try await fixture.assertRouteLogHoldsNoRows(file: file, line: line)
        }
    }

    private func assertPairDefaultDispatched(
        _ capture: RoutedStartFixture.Capture,
        on fixture: RoutedStartFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        XCTAssertEqual(capture.agent, .grok, file: file, line: line)
        XCTAssertEqual(capture.model, "grok-4.7", file: file, line: line)
        XCTAssertEqual(capture.parameters, [], file: file, line: line)
        XCTAssertEqual(fixture.recorder.claudeNativeStartCount, 0, file: file, line: line)
        try await AsyncTestWait.waitUntil("pair default reaches the headless provider", timeout: 5) {
            fixture.recorder.headlessStarts.last == RoutedStartDispatchRecorder.HeadlessStart(agent: .grok, model: "grok-4.7")
        }
    }

    private func assertAdvisorFailedThenPairDefault(
        _ capture: RoutedStartFixture.Capture,
        on fixture: RoutedStartFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let configuration = fixture.window.agentModeViewModel.modelRouterSettingsStore.modelRouterConfiguration()
        XCTAssertTrue(configuration.enabled, file: file, line: line)
        XCTAssertFalse(configuration.usageBalancing.enabled, file: file, line: line)
        let stages = await fixture.backend.requestStages()
        XCTAssertEqual(stages, [.model], "the advisor was consulted once and could not route", file: file, line: line)
        try await assertPairDefaultDispatched(capture, on: fixture, file: file, line: line)
    }

    private func assertRouterOffPairDefault(
        _ capture: RoutedStartFixture.Capture,
        on fixture: RoutedStartFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let configuration = fixture.window.agentModeViewModel.modelRouterSettingsStore.modelRouterConfiguration()
        XCTAssertFalse(configuration.enabled, file: file, line: line)
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty, file: file, line: line)
        try await assertPairDefaultDispatched(capture, on: fixture, file: file, line: line)
    }

    private func installCustomReviewWorkflow(file: StaticString = #filePath, line: UInt = #line) throws -> AgentWorkflowDefinition {
        let store = AgentWorkflowStore.shared
        let custom = try store.createWorkflow(name: "Review")
        addTeardownBlock { @MainActor in
            try store.deleteWorkflow(custom)
        }
        XCTAssertNotNil(custom.customID, file: file, line: line)
        XCTAssertEqual(custom.displayName, "Review", file: file, line: line)
        XCTAssertNil(custom.builtInWorkflow, file: file, line: line)
        XCTAssertNotEqual(custom.id, AgentWorkflow.review.definition.id, file: file, line: line)
        XCTAssertEqual(store.resolveWorkflowReference(custom.id)?.id, custom.id, file: file, line: line)
        return custom
    }

    private func assertNonStartRejected(
        _ fixture: RoutedStartFixture,
        op: String,
        args: [String: Value],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sessionsBefore = fixture.sessionCount
        let activationBefore = fixture.callerControlActivationID
        XCTAssertNotNil(activationBefore, file: file, line: line)
        do {
            _ = try await fixture.executeNonStart(op: op, args: args)
            XCTFail("Expected \(op) to reject diversity arguments", file: file, line: line)
        } catch let error as MCPError {
            guard case let .invalidParams(detail) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue(
                (detail ?? "").contains("diversity arguments are only supported with op=start"),
                "\(op): \(detail ?? "nil")",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected MCPError.invalidParams, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(fixture.sessionCount, sessionsBefore, file: file, line: line)
        XCTAssertEqual(fixture.callerControlActivationID, activationBefore, "\(op) must not touch the control context", file: file, line: line)
        XCTAssertTrue(fixture.recorder.headlessStarts.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.recorder.acpRunRequests.isEmpty, file: file, line: line)
        XCTAssertEqual(fixture.recorder.claudeNativeStartCount, 0, file: file, line: line)
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty, file: file, line: line)
        try await fixture.assertRouteLogHoldsNoRows(file: file, line: line)
    }

    private func assertAvoidsXAI(
        _ capture: RoutedStartFixture.Capture,
        on fixture: RoutedStartFixture,
        unfiltered: Set<String>,
        expectedExclusions: [String: [String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let labels = try await fixture.modelStageCandidateLabels(file: file, line: line)
        XCTAssertTrue(labels.isDisjoint(with: Self.xaiLabels), file: file, line: line)
        XCTAssertEqual(labels, unfiltered.subtracting(Self.xaiLabels), file: file, line: line)
        XCTAssertEqual(capture.agent, .antigravity, file: file, line: line)
        let exclusions = try await fixture.modelDecisionMakerExclusions()
        XCTAssertEqual(exclusions, expectedExclusions, file: file, line: line)
        try await fixture.assertOneAppliedRowMatchesDecision(file: file, line: line)
    }

    private func assertStillPicksXAI(
        _ label: String,
        _ fixture: RoutedStartFixture,
        args: [String: Value],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let capture = try await fixture.start(additionalArgs: args)
        XCTAssertEqual(capture.agent, .grok, label, file: file, line: line)
        let labels = try await fixture.modelStageCandidateLabels(file: file, line: line)
        XCTAssertTrue(labels.isSuperset(of: Self.xaiLabels), label, file: file, line: line)
        let exclusions = try await fixture.modelDecisionMakerExclusions()
        XCTAssertNil(exclusions, label, file: file, line: line)
        try await fixture.assertOneAppliedRowMatchesDecision(file: file, line: line)
    }

    func testExcludeMakersFiltersRoutedStart() async throws {
        let unfiltered = try await unfilteredPick()
        let xai = AgentTaskRoutingMaker.xai.rawValue

        let fixture = try await makeFixture()
        let capture = try await fixture.start(additionalArgs: ["exclude_makers": .array([.string(xai), .string(xai)])])
        try await assertAvoidsXAI(capture, on: fixture, unfiltered: unfiltered.labels, expectedExclusions: [xai: ["exclude_makers"]])
        XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: capture.agent, modelRaw: capture.model), .google)

        let union = try await makeFixture()
        let coldXAI = try await union.seedColdSession(agent: .grok, model: "grok-4.7")
        let survivor = try await union.start(additionalArgs: [
            "exclude_makers": .array([.string(xai), .string("google")]),
            "diverse_from_sessions": .array([.string(coldXAI.uuidString)])
        ])
        XCTAssertEqual(survivor.agent, .cursor)
        XCTAssertEqual(survivor.model, "composer-2.5")
        let unionRequests = await union.backend.requests
        XCTAssertTrue(unionRequests.filter { $0.decisionStage == .model }.isEmpty, "one survivor is selected locally")
        let unionExclusions = try await union.modelDecisionMakerExclusions()
        XCTAssertEqual(unionExclusions, [xai: ["exclude_makers", "diverse_from_sessions"], "google": ["exclude_makers"]])
        try await union.assertOneAppliedRowMatchesDecision()

        let none = try await makeFixture()
        try await assertRejected(
            none,
            args: ["exclude_makers": .array(AgentTaskRoutingMaker.allCases.map { .string($0.rawValue) })],
            containing: "excluded maker",
            preRoute: false
        )

        let baselineControl = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        baselineControl.pinPairDefault(agent: .grok, model: "grok-4.7")
        let baseline = try await baselineControl.start()
        try await assertAdvisorFailedThenPairDefault(baseline, on: baselineControl)
        let baselineMaker = try XCTUnwrap(AgentTaskRoutingMakerCatalog.maker(provider: baseline.agent, modelRaw: baseline.model))
        let blocked = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        blocked.pinPairDefault(agent: .grok, model: "grok-4.7")
        try await assertRejected(
            blocked,
            args: ["exclude_makers": .array([.string(baselineMaker.rawValue)])],
            containing: "fallback",
            preRoute: false
        )
        let blockedStages = await blocked.backend.requestStages()
        XCTAssertEqual(blockedStages, [.model])
        let otherMaker = try XCTUnwrap(AgentTaskRoutingMaker.allCases.first { $0 != baselineMaker })
        let allowed = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        allowed.pinPairDefault(agent: .grok, model: "grok-4.7")
        let frozen = try await allowed.start(additionalArgs: ["exclude_makers": .array([.string(otherMaker.rawValue)])])
        XCTAssertEqual(frozen, baseline)
        try await assertAdvisorFailedThenPairDefault(frozen, on: allowed)

        let targeted = try await makeFixture()
        try targeted.targetActiveComposeTab()
        let targetedCapture = try await targeted.start(additionalArgs: ["exclude_makers": .array([.string(xai)])])
        XCTAssertEqual(targetedCapture.agent, .antigravity)
        let targetedExclusions = try await targeted.modelDecisionMakerExclusions()
        XCTAssertEqual(targetedExclusions, [xai: ["exclude_makers"]])

        let targetedBlocked = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        targetedBlocked.pinPairDefault(agent: .grok, model: "grok-4.7")
        let blockedTab = try targetedBlocked.targetActiveComposeTab()
        XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: blockedTab, workflow: nil))
        XCTAssertNotNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil, workflow: nil))
        let unresolved = try AgentMCPSelectionResolver.resolve(
            modelID: nil,
            defaultTaskLabel: nil,
            availability: targetedBlocked.window.apiSettingsViewModel.agentModeAvailabilityContext,
            workspaceID: targetedBlocked.window.workspaceManager.activeWorkspace?.id
        )
        XCTAssertNil(unresolved.agentRaw)
        XCTAssertNil(unresolved.modelRaw)
        try await assertRejected(
            targetedBlocked,
            args: ["exclude_makers": .array([.string(otherMaker.rawValue)])],
            containing: "fallback",
            preRoute: false
        )
        let targetedStages = await targetedBlocked.backend.requestStages()
        XCTAssertEqual(targetedStages, [.model], "advisory failure, not input validation, forced the fallback")
    }

    func testDiverseFromSessionsExcludesThatSessionsMaker() async throws {
        let unfiltered = try await unfilteredPick()
        let xai = AgentTaskRoutingMaker.xai.rawValue
        let source = "diverse_from_sessions"

        let cold = try await makeFixture()
        let coldGrok = try await cold.seedColdSession(agent: .grok, model: "grok-4.7")
        let coldCursorGrok = try await cold.seedColdSession(agent: .cursor, model: "grok-4.7")
        let coldCapture = try await cold.start(additionalArgs: [
            source: .array([.string(coldGrok.uuidString), .string(coldCursorGrok.uuidString), .string(coldGrok.uuidString)])
        ])
        try await assertAvoidsXAI(coldCapture, on: cold, unfiltered: unfiltered.labels, expectedExclusions: [xai: [source]])

        let live = try await makeFixture()
        let sessionID = UUID()
        _ = try await live.seedColdSession(id: sessionID, agent: .cursor, model: "composer-2.5")
        _ = try await live.installAuthorizedCaller(sessionID: sessionID, agent: .grok, model: "grok-4.7")
        XCTAssertEqual(live.installedCaller?.sessionID, sessionID)
        XCTAssertEqual(live.installedCaller.flatMap { live.lifecycleWorkspaceID(of: $0) }, live.activeWorkspaceID)
        let liveCapture = try await live.start(additionalArgs: [source: .array([.string(sessionID.uuidString)])])
        try await assertAvoidsXAI(liveCapture, on: live, unfiltered: unfiltered.labels, expectedExclusions: [xai: [source]])

        let old = try await makeFixture()
        let oldParent = try await old.installAuthorizedCaller(agent: .grok, model: "grok-4.7", ownership: .otherWorkspace)
        XCTAssertNotEqual(old.lifecycleWorkspaceID(of: oldParent), old.activeWorkspaceID)
        XCTAssertNotNil(old.window.agentModeViewModel.session(for: oldParent.tabID, createIfNeeded: false)?.mcpControlContext)
        try await assertRejected(old, args: [source: .array([.string(oldParent.sessionID.uuidString)])], containing: "could not resolve")

        let stale = try await makeFixture()
        let staleSession = try await stale.seedColdSession(agent: .grok, model: "grok-4.7")
        let viewModel = stale.window.agentModeViewModel
        let workspace = try XCTUnwrap(stale.window.workspaceManager.activeWorkspace)
        let captured = viewModel.modelRouterSettingsStore.modelRouterConfiguration()
        let args: [String: Value] = [source: .array([.string(staleSession.uuidString)])]
        let options = try await AgentRunMCPToolService.resolveDiversityOptions(
            args: args, workspace: workspace, configuration: captured, agentModeVM: viewModel,
            workflow: nil, validatedParentSessionID: nil, hasExplicitModelPin: false, sessionDataService: .shared
        )
        XCTAssertEqual(options.canonicalMakerExclusions, [xai: [source]])
        stale.setReviewDiversityEnabled(true)
        await assertResolverRejects(args: args, workspace: workspace, configuration: captured, viewModel: viewModel, containing: "settings changed")
        let current = viewModel.modelRouterSettingsStore.modelRouterConfiguration()
        let otherWorkspace = stale.window.workspaceManager.createWorkspace(
            name: "Other \(UUID())", repoPaths: [FileManager.default.temporaryDirectory.path], ephemeral: true
        )
        await assertResolverRejects(args: args, workspace: otherWorkspace, configuration: current, viewModel: viewModel, containing: "workspace changed")
    }

    private func assertResolverRejects(
        args: [String: Value],
        workspace: WorkspaceModel,
        configuration: AgentTaskRouterConfiguration,
        viewModel: AgentModeViewModel,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AgentRunMCPToolService.resolveDiversityOptions(
                args: args, workspace: workspace, configuration: configuration, agentModeVM: viewModel,
                workflow: nil, validatedParentSessionID: nil, hasExplicitModelPin: false, sessionDataService: .shared
            )
            XCTFail("Expected stale resolution to be rejected", file: file, line: line)
        } catch let error as MCPError {
            guard case let .invalidParams(detail) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue((detail ?? "").contains(fragment), "\(detail ?? "nil")", file: file, line: line)
        } catch {
            XCTFail("Expected MCPError.invalidParams, got \(error)", file: file, line: line)
        }
    }

    func testUnknownMakerOrSessionIsRejected() async throws {
        let fixture = try await makeFixture()
        let unclassifiable = try await fixture.seedColdSession(agent: .kimiCode, model: "kimi-k2", classifiable: false)
        let unauthorizedLive = await fixture.installUnauthorizedLiveSession(agent: .grok, model: "grok-4.7")
        let uuid = UUID().uuidString
        let shapes: [(String, [String: Value], String)] = [
            ("unknown maker", ["exclude_makers": .array([.string("meta")])], "supported makers"),
            ("wrong case maker", ["exclude_makers": .array([.string("Anthropic")])], "supported makers"),
            ("vendor alias", ["exclude_makers": .array([.string("grok")])], "supported makers"),
            ("non-string maker", ["exclude_makers": .array([.int(1)])], "supported makers"),
            ("null maker", ["exclude_makers": .array([.null])], "supported makers"),
            ("valid then invalid maker", ["exclude_makers": .array([.string("xai"), .string("meta")])], "supported makers"),
            ("string makers", ["exclude_makers": .string("xai")], "exclude_makers must be an array"),
            ("null makers", ["exclude_makers": .null], "exclude_makers must be an array"),
            ("object makers", ["exclude_makers": .object([:])], "exclude_makers must be an array"),
            ("string sessions", ["diverse_from_sessions": .string(uuid)], "diverse_from_sessions must be an array"),
            ("null sessions", ["diverse_from_sessions": .null], "diverse_from_sessions must be an array"),
            ("malformed uuid", ["diverse_from_sessions": .array([.string("not-a-uuid")])], "full UUIDs"),
            ("truncated uuid", ["diverse_from_sessions": .array([.string(String(uuid.prefix(8)))])], "full UUIDs"),
            ("non-string uuid", ["diverse_from_sessions": .array([.int(7)])], "full UUIDs"),
            ("null uuid", ["diverse_from_sessions": .array([.null])], "full UUIDs"),
            ("unknown session", ["diverse_from_sessions": .array([.string(uuid)])], "could not resolve"),
            ("unclassifiable session", ["diverse_from_sessions": .array([.string(unclassifiable.uuidString)])], "could not resolve"),
            ("unauthorized live session", ["diverse_from_sessions": .array([.string(unauthorizedLive.uuidString)])], "could not resolve"),
            ("valid maker with unknown session", ["exclude_makers": .array([.string("xai")]), "diverse_from_sessions": .array([.string(uuid)])], "could not resolve")
        ]
        for (label, args, fragment) in shapes {
            try await assertRejected(fixture, args: args, containing: fragment)
            XCTAssertTrue(fixture.recorder.headlessStarts.isEmpty, label)
        }

        let unbound = try await makeFixture()
        let unboundParent = try await unbound.installAuthorizedCaller(agent: .grok, model: "grok-4.7", ownership: .unbound)
        try await assertRejected(
            unbound,
            args: ["diverse_from_sessions": .array([.string(unboundParent.sessionID.uuidString)])],
            containing: "could not resolve"
        )

        let nonStart = try await makeFixture()
        let nonStartWorkspaceID = try XCTUnwrap(nonStart.activeWorkspaceID)
        XCTAssertNotNil(nonStart.window.workspaceManager.workspace(withID: nonStartWorkspaceID))
        let caller = try await nonStart.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let nonStartKeys: [[String: Value]] = [
            ["exclude_makers": .array([])],
            ["exclude_makers": .array([.string("xai")])],
            ["diverse_from_sessions": .array([])],
            ["diverse_from_sessions": .array([.string(caller.sessionID.uuidString)])]
        ]
        for op in ["poll", "wait", "cancel", "steer", "respond"] {
            for keys in nonStartKeys {
                let args = keys.merging(["session_id": .string(caller.sessionID.uuidString), "message": .string("x"), "timeout": .int(0)]) { $1 }
                try await assertNonStartRejected(nonStart, op: op, args: args)
            }
        }
    }

    func testDiversityWithExplicitPinIsRejected() async throws {
        let fixture = try await makeFixture()
        let fragment = "Diversity cannot be combined"
        let keys: [[String: Value]] = [
            ["exclude_makers": .array([])],
            ["exclude_makers": .array([.string("xai")])],
            ["diverse_from_sessions": .array([])],
            ["exclude_makers": .array([]), "diverse_from_sessions": .array([])]
        ]
        for args in keys {
            try await assertRejected(fixture, modelID: Self.pinnedModelID, args: args, containing: fragment)
            for parameters in [Value.array([]), Value.null] {
                try await assertRejected(fixture, args: args.merging(["model_parameters": parameters]) { $1 }, containing: fragment)
            }
        }

        let unfiltered = try await unfilteredPick()
        let role = try await makeFixture()
        let capture = try await role.start(
            modelID: "pair",
            additionalArgs: ["exclude_makers": .array([.string(AgentTaskRoutingMaker.xai.rawValue)])]
        )
        try await assertAvoidsXAI(capture, on: role, unfiltered: unfiltered.labels, expectedExclusions: ["xai": ["exclude_makers"]])
    }

    func testDiversityWithRouterDisabledIsRejected() async throws {
        let disabled = try await makeFixture(routerEnabled: false)
        let keys: [[String: Value]] = [
            ["exclude_makers": .array([])],
            ["exclude_makers": .array([.string("xai")])],
            ["diverse_from_sessions": .array([])],
            ["exclude_makers": .array([]), "diverse_from_sessions": .array([])]
        ]
        for args in keys {
            try await assertRejected(disabled, args: args, containing: "model router to be enabled")
        }

        let control = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        control.pinPairDefault(agent: .grok, model: "grok-4.7")
        let baseline = try await control.start()
        try await assertAdvisorFailedThenPairDefault(baseline, on: control)
        let enabled = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        enabled.pinPairDefault(agent: .grok, model: "grok-4.7")
        let capture = try await enabled.start(additionalArgs: ["exclude_makers": .array([])])
        XCTAssertEqual(capture, baseline)
        try await assertAdvisorFailedThenPairDefault(capture, on: enabled)
    }

    func testReviewDiversityExcludesParentMaker() async throws {
        showBuiltIn(.review)
        showBuiltIn(.deepPlan)
        let xai = AgentTaskRoutingMaker.xai.rawValue

        let control = try await makeReviewFixture(parent: Self.xaiParent, reviewDiversity: false)
        try await assertStillPicksXAI("setting off", control, args: reviewArgs)
        let unfiltered = try await control.modelStageCandidateLabels()
        XCTAssertTrue(unfiltered.isSuperset(of: Self.xaiLabels))

        let fixture = try await makeReviewFixture(parent: Self.xaiParent)
        let parent = try XCTUnwrap(fixture.installedCaller)
        XCTAssertEqual(fixture.lifecycleWorkspaceID(of: parent), fixture.activeWorkspaceID)
        let current = try XCTUnwrap(fixture.window.agentModeViewModel.session(for: parent.tabID, createIfNeeded: false))
        XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: current.selectedAgent, modelRaw: current.selectedModelRaw), .xai)
        let capture = try await fixture.start(additionalArgs: reviewArgs)
        try await assertAvoidsXAI(capture, on: fixture, unfiltered: unfiltered, expectedExclusions: [xai: ["review_diversity"]])

        let emptyMakers = try await makeReviewFixture(parent: Self.xaiParent)
        try await assertStillPicksXAI("empty exclude_makers", emptyMakers, args: reviewArgs.merging(["exclude_makers": .array([])]) { $1 })
        let emptySessions = try await makeReviewFixture(parent: Self.xaiParent)
        try await assertStillPicksXAI("empty diverse_from_sessions", emptySessions, args: reviewArgs.merging(["diverse_from_sessions": .array([])]) { $1 })

        let parentless = try await makeReviewFixture(parent: nil)
        try await assertStillPicksXAI("parentless", parentless, args: reviewArgs)
        let unclassifiable = try await makeReviewFixture(parent: Self.unclassifiableParent, classifiable: false)
        try await assertStillPicksXAI("unclassifiable parent", unclassifiable, args: reviewArgs)

        let otherWorkflow = try await makeReviewFixture(parent: Self.xaiParent)
        try await assertStillPicksXAI("other workflow", otherWorkflow, args: ["workflow_id": .string(AgentWorkflow.deepPlan.definition.id)])
        let noWorkflow = try await makeReviewFixture(parent: Self.xaiParent)
        try await assertStillPicksXAI("no workflow", noWorkflow, args: [:])
        let oldWorkspace = try await makeReviewFixture(parent: Self.xaiParent, ownership: .otherWorkspace)
        let oldParent = try XCTUnwrap(oldWorkspace.installedCaller)
        XCTAssertNotEqual(oldWorkspace.lifecycleWorkspaceID(of: oldParent), oldWorkspace.activeWorkspaceID)
        XCTAssertNotNil(oldWorkspace.window.agentModeViewModel.session(for: oldParent.tabID, createIfNeeded: false)?.mcpControlContext)
        try await assertStillPicksXAI("old-workspace control parent", oldWorkspace, args: reviewArgs)
        let unboundParent = try await makeReviewFixture(parent: Self.xaiParent, ownership: .unbound)
        try await assertStillPicksXAI("control parent bound to no workspace", unboundParent, args: reviewArgs)
        let custom = try installCustomReviewWorkflow()
        let customReview = try await makeReviewFixture(parent: Self.xaiParent)
        try await assertStillPicksXAI("custom workflow named Review", customReview, args: ["workflow_id": .string(custom.id)])
    }

    func testReviewDiversityWithExplicitPinIsRejected() async throws {
        showBuiltIn(.review)
        let fragment = "Diversity cannot be combined"
        let parents: [(String, (agent: AgentProviderKind, model: String)?, Bool)] = [
            ("xai parent", Self.xaiParent, true),
            ("parentless", nil, true),
            ("unclassifiable parent", Self.unclassifiableParent, false)
        ]
        for (label, parent, classifiable) in parents {
            let fixture = try await makeReviewFixture(parent: parent, classifiable: classifiable)
            try await assertRejected(fixture, modelID: Self.pinnedModelID, args: reviewArgs, containing: fragment)
            try await assertRejected(fixture, args: reviewArgs.merging(["model_parameters": .array([])]) { $1 }, containing: fragment)
            try await assertRejected(fixture, args: reviewArgs.merging(["model_parameters": .null]) { $1 }, containing: fragment)
            XCTAssertTrue(fixture.recorder.headlessStarts.isEmpty, label)
        }
    }

    func testReviewDiversityIsInertWhenRouterDisabled() async throws {
        showBuiltIn(.review)
        let pinned = try await makeReviewFixture(parent: Self.xaiParent, routerEnabled: false)
        let capture = try await pinned.start(modelID: Self.pinnedModelID, additionalArgs: reviewArgs)
        XCTAssertEqual(capture.agent, .cursor)
        XCTAssertEqual(capture.model, "composer-2.5")
        try await pinned.assertRouteLogHoldsNoRows()

        let control = try await makeReviewFixture(parent: Self.xaiParent, reviewDiversity: false, routerEnabled: false)
        control.pinPairDefault(agent: .grok, model: "grok-4.7")
        let defaultCapture = try await control.start(additionalArgs: reviewArgs)
        try await assertRouterOffPairDefault(defaultCapture, on: control)
        let inert = try await makeReviewFixture(parent: Self.xaiParent, routerEnabled: false)
        inert.pinPairDefault(agent: .grok, model: "grok-4.7")
        let inertCapture = try await inert.start(additionalArgs: reviewArgs)
        XCTAssertEqual(inertCapture, defaultCapture)
        try await assertRouterOffPairDefault(inertCapture, on: inert)
        try await inert.assertRouteLogHoldsNoRows()
    }

    func testAgentExploreAcceptsDiversityArguments() async throws {
        let control = try await makeFixture()
        _ = try await control.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let unfiltered = try await assertExploreBatch(control, args: [:], expectedMaker: .xai, expectedExclusions: nil)

        let makers = try await makeFixture()
        _ = try await makers.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        _ = try await assertExploreBatch(
            makers, args: ["exclude_makers": .array([.string("xai"), .string("xai")])],
            expectedMaker: .google, expectedExclusions: ["xai": ["exclude_makers"]], unfiltered: unfiltered
        )

        let cold = try await makeFixture()
        _ = try await cold.installAuthorizedCaller(agent: .cursor, model: "composer-2.5")
        let coldGrok = try await cold.seedColdSession(agent: .cursor, model: "grok-4.7")
        _ = try await assertExploreBatch(
            cold, args: ["diverse_from_sessions": .array([.string(coldGrok.uuidString), .string(coldGrok.uuidString)])],
            expectedMaker: .google, expectedExclusions: ["xai": ["diverse_from_sessions"]], unfiltered: unfiltered
        )

        let live = try await makeFixture()
        let liveID = try await live.seedColdSession(agent: .cursor, model: "composer-2.5")
        let liveCaller = try await live.installAuthorizedCaller(sessionID: liveID, agent: .grok, model: "grok-4.7")
        XCTAssertEqual(live.lifecycleWorkspaceID(of: liveCaller), live.activeWorkspaceID)
        _ = try await assertExploreBatch(
            live, args: ["diverse_from_sessions": .array([.string(liveID.uuidString)])],
            expectedMaker: .google, expectedExclusions: ["xai": ["diverse_from_sessions"]], unfiltered: unfiltered
        )

        let union = try await makeFixture()
        let unionCaller = try await union.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let unionCold = try await union.seedColdSession(agent: .cursor, model: "grok-4.7")
        _ = try await assertExploreBatch(
            union, args: [
                "exclude_makers": .array([.string("xai"), .string("xai")]),
                "diverse_from_sessions": .array([.string(unionCold.uuidString), .string(unionCaller.sessionID.uuidString), .string(unionCold.uuidString)])
            ], expectedMaker: .google, expectedExclusions: ["xai": ["exclude_makers", "diverse_from_sessions"]],
            unfiltered: unfiltered, count: 3
        )

        for args in [[String: Value](), ["exclude_makers": .array([])], ["diverse_from_sessions": .array([])], ["exclude_makers": .array([]), "diverse_from_sessions": .array([])]] {
            let inert = try await makeFixture()
            inert.setReviewDiversityEnabled(true)
            _ = try await inert.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
            _ = try await assertExploreBatch(inert, args: args, expectedMaker: .xai, expectedExclusions: nil)
        }

        let allowedFallback = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        _ = try await allowedFallback.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        allowedFallback.pinExploreDefault(agent: .grok, model: "grok-4.7")
        _ = try await assertExploreBatch(
            allowedFallback, args: ["exclude_makers": .array([.string("google")])],
            expectedMaker: .xai, expectedExclusions: ["google": ["exclude_makers"]]
        )

        let blockedFallback = try await makeFixture(modelClass: "unavailable", fallbackModelClasses: [])
        _ = try await blockedFallback.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        blockedFallback.pinExploreDefault(agent: .grok, model: "grok-4.7")
        try await assertExploreRejected(blockedFallback, args: ["exclude_makers": .array([.string("xai")])], containing: "fallback", preRoute: false)

        let invalid = try await makeFixture()
        _ = try await invalid.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        let unclassifiable = try await invalid.seedColdSession(agent: .kimiCode, model: "kimi-k2", classifiable: false)
        let cases: [([String: Value], String)] = [
            (["exclude_makers": .array([.string("meta")])], "supported makers"),
            (["exclude_makers": .array([.string("mistral")])], "supported makers"),
            (["diverse_from_sessions": .array([.string(UUID().uuidString)])], "could not resolve"),
            (["diverse_from_sessions": .array([.string("not-a-uuid")])], "full UUID"),
            (["diverse_from_sessions": .array([.string(unclassifiable.uuidString)])], "classifiable")
        ]
        for (args, fragment) in cases {
            try await assertExploreRejected(invalid, args: args, containing: fragment)
        }
        for key in ["exclude_makers", "diverse_from_sessions"] {
            for value in [Value.null, .string("xai"), .object([:]), .int(1), .array([.null]), .array([.int(1)])] {
                try await assertExploreRejected(invalid, args: [key: value], containing: key)
            }
        }

        let foreign = try await makeFixture()
        let foreignID = await foreign.installUnauthorizedLiveSession(agent: .grok, model: "grok-4.7")
        _ = try await foreign.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        try await assertExploreRejected(foreign, args: ["diverse_from_sessions": .array([.string(foreignID.uuidString)])], containing: "could not resolve")

        let disabled = try await makeFixture(routerEnabled: false)
        _ = try await disabled.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        for args in [
            ["exclude_makers": Value.array([])], ["diverse_from_sessions": .array([])],
            ["exclude_makers": .array([]), "diverse_from_sessions": .array([])],
            ["exclude_makers": .array([.string("xai")])]
        ] {
            try await assertExploreRejected(disabled, args: args, containing: "enabled")
        }

        let controls = try await makeFixture()
        let controlsCaller = try await controls.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
        for op in ["poll", "wait", "cancel"] {
            for (key, nonempty) in [
                ("exclude_makers", Value.array([.string("xai")])),
                ("diverse_from_sessions", .array([.string(controlsCaller.sessionID.uuidString)]))
            ] {
                for value in [Value.array([]), nonempty] {
                    try await assertExploreRejected(
                        controls, args: ["op": .string(op), "session_id": .string(controlsCaller.sessionID.uuidString), key: value],
                        containing: "does not support '\(key)'"
                    )
                }
            }
        }

        for fence in ["enabled", "review", "revision", "workspace", "cancel"] {
            let fixture = try await makeFixture()
            _ = try await fixture.installAuthorizedCaller(agent: .grok, model: "grok-4.7")
            try await assertExplorePartialFailure(fixture, fence: fence)
        }
    }

    @discardableResult
    private func assertExploreBatch(
        _ fixture: RoutedStartFixture, args: [String: Value], expectedMaker: AgentTaskRoutingMaker,
        expectedExclusions: [String: [String]]?, unfiltered: Set<String>? = nil, count: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Set<String> {
        do {
            let result = try await fixture.executeExplore(args: args, count: count)
            XCTAssertEqual(fixture.exploreCaptures.count, count, file: file, line: line)
            XCTAssertEqual(fixture.exploreAllocationCount, count, file: file, line: line)
            let captures = fixture.exploreCaptures
            XCTAssertEqual(Set(captures.map(\.sessionID)).count, count, file: file, line: line)
            if count > 1 {
                let ids = result.objectValue?["session_ids"]?.arrayValue?.compactMap(\.stringValue).compactMap { UUID(uuidString: $0) }
                XCTAssertEqual(ids, captures.map(\.sessionID), file: file, line: line)
            } else {
                XCTAssertEqual(result.objectValue?["session_id"]?.stringValue, captures.first?.sessionID.uuidString, file: file, line: line)
            }
            for captured in captures {
                XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: captured.selection.agent, modelRaw: captured.selection.model), expectedMaker, file: file, line: line)
                XCTAssertEqual(captured.taskLabel, .explore, file: file, line: line)
                XCTAssertEqual(captured.parentSessionID, fixture.installedCaller?.sessionID, file: file, line: line)
                XCTAssertEqual(captured.selection.parameters, [], file: file, line: line)
            }
            try await AsyncTestWait.waitUntil("Explore admitted headless providers", timeout: 5) {
                fixture.recorder.headlessStarts.count == count
            }
            XCTAssertEqual(fixture.recorder.headlessStarts, captures.map { .init(agent: $0.selection.agent, model: $0.selection.model) }, file: file, line: line)
            XCTAssertTrue(fixture.recorder.acpRunRequests.isEmpty, file: file, line: line)
            XCTAssertEqual(fixture.recorder.claudeNativeStartCount, 0, file: file, line: line)
            let requests = await fixture.backend.requests.filter { $0.decisionStage == .model }
            XCTAssertEqual(requests.count, count, file: file, line: line)
            for request in requests {
                let labels = Set(request.candidates.flatMap(\.roleLabels))
                if let unfiltered {
                    XCTAssertEqual(labels, unfiltered.subtracting(Self.xaiLabels), file: file, line: line)
                }
            }
            try await fixture.assertExploreRouteRows(count: count, exclusions: expectedExclusions, file: file, line: line)
            return Set(requests.flatMap { $0.candidates.flatMap(\.roleLabels) })
        } catch {
            XCTFail("Expected real agent_explore start acceptance, got \(error)", file: file, line: line)
            return []
        }
    }

    private func assertExploreRejected(
        _ fixture: RoutedStartFixture, args: [String: Value], containing fragment: String, preRoute: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let tabsBefore = fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id)
        let sessionsBefore = Set(fixture.window.agentModeViewModel.sessions.keys)
        let activationBefore = fixture.callerControlActivationID
        do {
            _ = try await fixture.executeExplore(args: args, count: 3)
            XCTFail("Expected invalidParams for \(args)", file: file, line: line)
        } catch let error as MCPError {
            guard case let .invalidParams(detail) = error else { return XCTFail("\(error)", file: file, line: line) }
            XCTAssertTrue((detail ?? "").contains(fragment), "\(detail ?? "nil") lacks \(fragment)", file: file, line: line)
        } catch {
            XCTFail("Expected invalidParams, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(Set(fixture.window.agentModeViewModel.sessions.keys), sessionsBefore, file: file, line: line)
        XCTAssertEqual(fixture.window.workspaceManager.activeWorkspace?.composeTabs.map(\.id), tabsBefore, file: file, line: line)
        XCTAssertEqual(fixture.callerControlActivationID, activationBefore, file: file, line: line)
        XCTAssertTrue(fixture.exploreCaptures.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.recorder.headlessStarts.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.recorder.acpRunRequests.isEmpty, file: file, line: line)
        XCTAssertEqual(fixture.recorder.claudeNativeStartCount, 0, file: file, line: line)
        if preRoute {
            XCTAssertEqual(fixture.exploreAllocationCount, 0, file: file, line: line)
            XCTAssertTrue(fixture.exploreAllocatedBindings.isEmpty, file: file, line: line)
            let requests = await fixture.backend.requests
            XCTAssertTrue(requests.isEmpty, file: file, line: line)
            try await fixture.assertRouteLogHoldsNoRows(file: file, line: line)
        }
    }

    private func assertExplorePartialFailure(_ fixture: RoutedStartFixture, fence: String) async throws {
        let workspaceID = try XCTUnwrap(fixture.activeWorkspaceID)
        let captured = fixture.window.agentModeViewModel.modelRouterSettingsStore.modelRouterConfiguration()
        let task = Task { @MainActor in
            try await fixture.executeExplore(args: ["exclude_makers": .array([.string("xai")])], count: 3, beforeChild: { index in
                guard index == 1 else { return }
                let store = fixture.window.agentModeViewModel.modelRouterSettingsStore
                switch fence {
                case "enabled": store.setModelRouterEnabled(false)
                case "review": store.setReviewDiversityEnabled(!captured.reviewDiversityEnabled)
                case "revision": XCTAssertTrue(store.setModelRouterCustomInstructions("Changed after first Explore child"))
                case "workspace":
                    let sessionsBefore = Set(fixture.window.agentModeViewModel.sessions.keys)
                    XCTAssertEqual(fixture.activeWorkspaceID, workspaceID)
                    XCTAssertEqual(fixture.exploreCaptures.count, 1)
                    let other = fixture.window.workspaceManager.createWorkspace(name: "Explore changed workspace \(UUID())", repoPaths: [FileManager.default.temporaryDirectory.path], ephemeral: true)
                    XCTAssertNotEqual(other.id, workspaceID)
                    // ponytail: Change request currency only; a full switch tears down the successful sibling.
                    fixture.window.workspaceManager.activeWorkspace = other
                    XCTAssertEqual(fixture.activeWorkspaceID, other.id)
                    XCTAssertNotEqual(fixture.activeWorkspaceID, workspaceID)
                    XCTAssertEqual(Set(fixture.window.agentModeViewModel.sessions.keys), sessionsBefore)
                    if let first = fixture.exploreCaptures.first {
                        XCTAssertNotNil(fixture.window.agentModeViewModel.mcpRegistration(sessionID: first.sessionID))
                    }
                case "cancel": withUnsafeCurrentTask { $0?.cancel() }
                default: XCTFail("Unknown fence")
                }
            })
        }
        do {
            _ = try await task.value
            XCTFail("Expected \(fence) to stop the second Explore child")
        } catch is CancellationError {
            XCTAssertEqual(fence, "cancel")
        } catch let error as MCPError {
            if case let .internalError(detail) = error {
                XCTAssertNotEqual(fence, "cancel")
                XCTAssertTrue((detail ?? "").contains("starting 1 of 3"))
                XCTAssertTrue((detail ?? "").contains("Failed index: 1"))
                if let first = fixture.exploreCaptures.first {
                    XCTAssertTrue((detail ?? "").contains(first.sessionID.uuidString))
                }
            } else {
                XCTFail("Expected partial-success error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected Explore partial failure: \(error)")
        }
        XCTAssertEqual(fixture.exploreCaptures.count, 1)
        XCTAssertEqual(fixture.exploreAllocatedBindings.count, 3)
        XCTAssertEqual(fixture.exploreAllocationCount, 3)
        let requests = await fixture.backend.requests.filter { $0.decisionStage == .model }
        XCTAssertEqual(requests.count, 1, "no second child advisor admission after \(fence)")
        let firstID = fixture.exploreCaptures.first?.sessionID
        let workspace = fixture.window.workspaceManager.workspaces.first { $0.id == workspaceID }
        for (tabID, sessionID) in fixture.exploreAllocatedBindings {
            XCTAssertEqual(workspace?.composeTabs.contains { $0.id == tabID && $0.activeAgentSessionID == sessionID }, sessionID == firstID)
            if sessionID != firstID {
                XCTAssertNil(fixture.window.agentModeViewModel.mcpRegistration(sessionID: sessionID))
            }
        }
        if let firstID {
            XCTAssertNotNil(fixture.window.agentModeViewModel.mcpRegistration(sessionID: firstID), "successful sibling must not be cancelled or resubmitted")
        }
        do {
            try await AsyncTestWait.waitUntil("first Explore child admitted before fence", timeout: 5) {
                fixture.recorder.headlessStarts.count == 1
            }
            try await fixture.assertExploreRouteRows(count: 1, exclusions: ["xai": ["exclude_makers"]])
        } catch {
            XCTFail("Expected first child's real admission and routing rows before \(fence): \(error)")
        }
        XCTAssertEqual(fixture.recorder.headlessStarts.count, 1)
    }

    func testAgentRunAndAgentExploreSchemasAdvertiseDiversityArguments() async {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = WindowState()
        addTeardownBlock { @MainActor in
            await window.tearDown()
        }

        let liveTools = await window.mcpServer.windowMCPTools
        let catalogError = window.mcpServer.windowMCPToolCatalogService.materializationErrorDescription
        for name in [MCPWindowToolName.agentRun, MCPWindowToolName.agentExplore] {
            if let definition = MCPDomainCanonicalToolDefinitions.definition(named: name) {
                assertDiversityAnnotations(
                    readOnlyHint: definition.annotations.readOnlyHint,
                    destructiveHint: definition.annotations.destructiveHint,
                    openWorldHint: definition.annotations.openWorldHint,
                    idempotentHint: definition.annotations.idempotentHint,
                    title: definition.annotations.title,
                    enabled: definition.isEnabledByDefault,
                    name: name,
                    surface: "canonical"
                )
                if let schema = definition.inputSchema.objectValue {
                    assertDiversitySchema(schema, name: name, surface: "canonical", toolDescription: definition.description)
                } else {
                    XCTFail("canonical \(name) schema is not an object")
                }
            } else {
                XCTFail("canonical \(name) definition is missing")
            }

            if let tool = liveTools.first(where: { $0.name == name }) {
                assertDiversityAnnotations(
                    readOnlyHint: tool.annotations.readOnlyHint,
                    destructiveHint: tool.annotations.destructiveHint,
                    openWorldHint: tool.annotations.openWorldHint,
                    idempotentHint: tool.annotations.idempotentHint,
                    title: tool.annotations.title,
                    enabled: tool.isEnabledByDefault,
                    name: name,
                    surface: "live"
                )
                if let schema = liveSchemaObject(tool) {
                    assertDiversitySchema(schema, name: name, surface: "live", toolDescription: tool.description)
                }
            } else {
                XCTFail("live windowMCPTools missing \(name): \(catalogError ?? "no materialization error")")
            }
        }
    }

    private static let makerEnum = ["anthropic", "openai", "google", "xai", "cursor"]
    private static let diversityCopyMarkers = [
        "start-only",
        "[]",
        "union",
        "current maker",
        "router off",
        "model_parameters",
        "built-in Review"
    ]
    private static let exploreCopyMarkers = [
        "no implicit Review",
        "no model or workflow custom pin"
    ]
    private static let runPreservedProperties = [
        "_worktree_startup_benchmark_token",
        "allow_external_worktree_path",
        "amendment",
        "answers",
        "content",
        "detach",
        "inherit_worktree",
        "interaction_id",
        "message",
        "meta",
        "model_id",
        "model_parameters",
        "op",
        "response",
        "session_id",
        "session_ids",
        "session_name",
        "timeout",
        "timeout_seconds",
        "wait",
        "workflow_id",
        "workflow_name",
        "worktree",
        "worktree_base_ref",
        "worktree_branch",
        "worktree_color",
        "worktree_create",
        "worktree_id",
        "worktree_label",
        "worktree_path",
        "worktree_repo_root"
    ]
    private static let explorePreservedProperties = [
        "allow_external_worktree_path",
        "detach",
        "inherit_worktree",
        "message",
        "messages",
        "op",
        "session_id",
        "session_ids",
        "timeout",
        "worktree",
        "worktree_base_ref",
        "worktree_branch",
        "worktree_color",
        "worktree_create",
        "worktree_id",
        "worktree_label",
        "worktree_path",
        "worktree_repo_root"
    ]
    private static let exploreAbsentPinProperties = ["model_id", "model_parameters", "workflow_id", "workflow_name"]

    private func liveSchemaObject(_ tool: RepoPromptApp.Tool, file: StaticString = #filePath, line: UInt = #line) -> [String: Value]? {
        do {
            guard let object = try Value(tool.inputSchema).objectValue else {
                XCTFail("live \(tool.name) schema is not an object", file: file, line: line)
                return nil
            }
            return object
        } catch {
            XCTFail("live \(tool.name) schema could not be read: \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertDiversityAnnotations(
        readOnlyHint: Bool?,
        destructiveHint: Bool?,
        openWorldHint: Bool?,
        idempotentHint: Bool?,
        title: String?,
        enabled: Bool,
        name: String,
        surface: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(readOnlyHint, false, "\(surface) \(name) readOnlyHint", file: file, line: line)
        XCTAssertEqual(destructiveHint, false, "\(surface) \(name) destructiveHint", file: file, line: line)
        XCTAssertEqual(openWorldHint, false, "\(surface) \(name) openWorldHint", file: file, line: line)
        XCTAssertNil(idempotentHint, "\(surface) \(name) idempotentHint", file: file, line: line)
        XCTAssertNil(title, "\(surface) \(name) title", file: file, line: line)
        XCTAssertTrue(enabled, "\(surface) \(name) default enabled", file: file, line: line)
    }

    private func assertDiversitySchema(
        _ schema: [String: Value],
        name: String,
        surface: String,
        toolDescription: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let label = "\(surface) \(name)"
        if schema["type"] != .string("object") {
            XCTFail("\(label) schema type is not object", file: file, line: line)
        }
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(required, ["op"], "\(label) required", file: file, line: line)
        guard let properties = schema["properties"]?.objectValue else {
            XCTFail("\(label) properties object is missing", file: file, line: line)
            return
        }

        let preserved = name == MCPWindowToolName.agentExplore ? Self.explorePreservedProperties : Self.runPreservedProperties
        for key in preserved where properties[key] == nil {
            XCTFail("\(label) dropped \(key)", file: file, line: line)
        }
        if name == MCPWindowToolName.agentExplore {
            for key in Self.exploreAbsentPinProperties where properties[key] != nil {
                XCTFail("\(label) advertises \(key)", file: file, line: line)
            }
            if !toolDescription.contains("no custom `model_id`") {
                XCTFail("\(label) dropped the no-custom-model pin copy", file: file, line: line)
            }
            if !toolDescription.contains("no implicit Review") {
                XCTFail("\(label) does not say no implicit Review", file: file, line: line)
            }
        } else {
            if !toolDescription.contains("bypasses routing") {
                XCTFail("\(label) dropped explicit pin bypass copy", file: file, line: line)
            }
            if !toolDescription.contains("diversity key") {
                XCTFail("\(label) does not qualify pin bypass against a diversity key", file: file, line: line)
            }
        }
        let schemaDescription = schema["description"]?.stringValue ?? ""
        if !schemaDescription.contains("exclude_makers") || !schemaDescription.contains("diverse_from_sessions") {
            XCTFail("\(label) schema description does not advertise both diversity arguments", file: file, line: line)
        }

        for (key, makers) in [("exclude_makers", true), ("diverse_from_sessions", false)] {
            guard let property = properties[key]?.objectValue else {
                XCTFail("\(label) missing \(key)", file: file, line: line)
                continue
            }
            if required?.contains(key) == true {
                XCTFail("\(label) \(key) is required", file: file, line: line)
            }
            if property["type"] != .string("array") {
                XCTFail("\(label) \(key) is not an array", file: file, line: line)
            }
            if property["minItems"] != nil {
                XCTFail("\(label) \(key) declares minItems", file: file, line: line)
            }
            let description = property["description"]?.stringValue ?? ""
            for marker in Self.diversityCopyMarkers where !description.contains(marker) {
                XCTFail("\(label) \(key) copy missing \(marker)", file: file, line: line)
            }
            if name == MCPWindowToolName.agentExplore {
                for marker in Self.exploreCopyMarkers where !description.contains(marker) {
                    XCTFail("\(label) \(key) copy missing \(marker)", file: file, line: line)
                }
            }
            guard let items = property["items"]?.objectValue else {
                XCTFail("\(label) \(key) items are missing", file: file, line: line)
                continue
            }
            if items["type"] != .string("string") {
                XCTFail("\(label) \(key) items are not strings", file: file, line: line)
            }
            if items["minItems"] != nil {
                XCTFail("\(label) \(key) items declare minItems", file: file, line: line)
            }
            if makers {
                XCTAssertEqual(
                    items["enum"]?.arrayValue?.compactMap(\.stringValue),
                    Self.makerEnum,
                    "\(label) \(key) enum",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertNil(items["enum"], "\(label) \(key) enum", file: file, line: line)
                if !(items["description"]?.stringValue ?? "").contains("UUID") {
                    XCTFail("\(label) \(key) items do not say UUID", file: file, line: line)
                }
            }
        }
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
    private let fallbackModelClasses: [String]
    private(set) var requests: [AgentTaskRoutingRequest] = []

    init(modelClass: String, fallbackModelClasses: [String] = [], effortRaw: String?) {
        self.modelClass = modelClass
        self.fallbackModelClasses = fallbackModelClasses
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
        let labels: [String]
        switch request.decisionStage {
        case .model: labels = [modelClass] + fallbackModelClasses
        case .effort:
            guard let effortRaw else {
                return .failed(category: .invalidResponse, retryable: false, evidence: nil)
            }
            labels = ["effort:\(effortRaw)"]
        }
        for label in labels {
            let matches = request.candidates.filter { $0.roleLabels.contains(label) }
            if matches.count == 1, let match = matches.first {
                return .selected(opaqueKey: match.opaqueKey, evidence: nil)
            }
        }
        return .failed(category: .invalidResponse, retryable: false, evidence: nil)
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
    private let settingsStore: GlobalSettingsStore
    private unowned let testCase: XCTestCase
    private var caller: (tabID: UUID, sessionID: UUID)?
    private var capture: Capture?
    private var requestedTabID: UUID?
    private var coldRoot: URL?
    struct ExploreCapture {
        let sessionID: UUID
        let selection: Capture
        let taskLabel: AgentModelCatalog.TaskLabelKind?
        let parentSessionID: UUID?
    }

    private(set) var exploreCaptures: [ExploreCapture] = []
    private(set) var exploreAllocatedBindings: [UUID: UUID] = [:]
    private(set) var exploreAllocationCount = 0

    private init(backend: RoutedStartBackend, window: WindowState, recorder: RoutedStartDispatchRecorder, log: AgentTaskRoutingDecisionLog, logURL: URL, settingsStore: GlobalSettingsStore, testCase: XCTestCase) {
        self.testCase = testCase
        self.backend = backend
        self.window = window
        self.recorder = recorder
        self.log = log
        self.logURL = logURL
        self.settingsStore = settingsStore
    }

    static func make(testCase: XCTestCase, modelClass: String, fallbackModelClasses: [String] = [], effortRaw: String?, verifyGrok: Bool = true, routerEnabled: Bool = true) async throws -> RoutedStartFixture {
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
        let backend = RoutedStartBackend(modelClass: modelClass, fallbackModelClasses: fallbackModelClasses, effortRaw: effortRaw)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoutedStartFixture.\(UUID())"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        if routerEnabled {
            store.enableModelRouterWithCurrentPolicy(
                backendID: backend.id,
                roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
                providers: [.claudeCode, .codexExec, .cursor, .antigravity, .grok]
            )
        }
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
        return RoutedStartFixture(backend: backend, window: window, recorder: recorder, log: log, logURL: logURL, settingsStore: store, testCase: testCase)
    }

    func setReviewDiversityEnabled(_ enabled: Bool) {
        settingsStore.setReviewDiversityEnabled(enabled)
    }

    var installedCaller: (tabID: UUID, sessionID: UUID)? {
        caller
    }

    var sessionCount: Int {
        window.agentModeViewModel.sessions.count
    }

    @discardableResult
    func targetActiveComposeTab() throws -> UUID {
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        requestedTabID = tabID
        return tabID
    }

    func pinPairDefault(agent: AgentProviderKind, model: String, file: StaticString = #filePath, line: UInt = #line) {
        let store = GlobalSettingsStore.shared
        let prior = store.mcpAgentRoleOverrides(scope: .global)
        testCase.addTeardownBlock { @MainActor in
            store.updateMCPAgentRoleOverrides(prior, scope: .global, commit: true)
        }
        let selection = AgentModelCatalog.NormalizedAgentSelection(agent: agent, modelRaw: model)
        XCTAssertTrue(MCPAgentRoleDefaultsService.setSelection(selection, for: .pair, scope: .global), file: file, line: line)
        let effective = MCPAgentRoleDefaultsService.effectiveSelection(
            for: .pair,
            availability: window.apiSettingsViewModel.agentModeAvailabilityContext,
            workspaceID: window.workspaceManager.activeWorkspace?.id
        )
        XCTAssertEqual(effective?.effective, selection, file: file, line: line)
        XCTAssertEqual(effective?.hasStoredOverride, true, file: file, line: line)
    }

    func installUnauthorizedLiveSession(agent: AgentProviderKind, model: String) async -> UUID {
        let viewModel = window.agentModeViewModel
        let sessionID = UUID()
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        session.selectedAgent = agent
        session.selectedModelRaw = model
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        XCTAssertEqual(session.activeAgentSessionID, sessionID)
        XCTAssertNil(session.mcpControlContext)
        XCTAssertFalse(window.workspaceManager.activeWorkspace?.composeTabs.contains { $0.id == session.tabID } ?? true)
        return sessionID
    }

    enum CallerOwnership {
        case capturedWorkspace
        case otherWorkspace
        case unbound
    }

    var activeWorkspaceID: UUID? {
        window.workspaceManager.activeWorkspaceID
    }

    func lifecycleWorkspaceID(of caller: (tabID: UUID, sessionID: UUID)) -> UUID? {
        window.agentModeViewModel.agentSessionLifecycleIdentity(tabID: caller.tabID, expectedSessionID: caller.sessionID)?.workspaceID
    }

    func installAuthorizedCaller(sessionID: UUID = UUID(), agent: AgentProviderKind, model: String, classifiable: Bool = true, ownership: CallerOwnership = .capturedWorkspace, file: StaticString = #filePath, line: UInt = #line) async throws -> (tabID: UUID, sessionID: UUID) {
        let viewModel = window.agentModeViewModel
        let session = await viewModel.ensureSessionReady(tabID: UUID())
        session.selectedAgent = agent
        session.selectedModelRaw = model
        _ = viewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        let context = try await viewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            taskLabelKind: .pair,
            startPending: false
        )
        XCTAssertTrue(viewModel.session(for: session.tabID, createIfNeeded: false) === session, file: file, line: line)
        XCTAssertEqual(session.activeAgentSessionID, sessionID, file: file, line: line)
        XCTAssertEqual(session.mcpControlContext?.sessionID, sessionID, file: file, line: line)
        XCTAssertEqual(context.sessionID, sessionID, file: file, line: line)
        XCTAssertEqual(session.selectedAgent, agent, file: file, line: line)
        XCTAssertEqual(session.selectedModelRaw, model, file: file, line: line)
        let currentMaker = AgentTaskRoutingMakerCatalog.maker(provider: session.selectedAgent, modelRaw: session.selectedModelRaw)
        XCTAssertEqual(currentMaker != nil, classifiable, file: file, line: line)
        let captured = try XCTUnwrap(activeWorkspaceID, file: file, line: line)
        var ownerID: UUID? = switch ownership {
        case .capturedWorkspace:
            captured
        case .otherWorkspace:
            window.workspaceManager.createWorkspace(
                name: "Old workspace \(UUID())", repoPaths: [FileManager.default.temporaryDirectory.path], ephemeral: true
            ).id
        case .unbound:
            nil
        }
        if let ownerID {
            let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == ownerID }, file: file, line: line)
            window.workspaceManager.workspaces[index].composeTabs.append(
                ComposeTabState(id: session.tabID, name: "Hidden MCP parent", activeAgentSessionID: sessionID)
            )
        }
        let caller = (tabID: session.tabID, sessionID: sessionID)
        XCTAssertEqual(lifecycleWorkspaceID(of: caller), ownerID, file: file, line: line)
        XCTAssertEqual(activeWorkspaceID, captured, file: file, line: line)
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace, file: file, line: line)
        XCTAssertEqual(activeWorkspace.composeTabs.contains { $0.id == session.tabID }, ownership == .capturedWorkspace, file: file, line: line)
        XCTAssertNotEqual(activeWorkspace.activeComposeTabID, session.tabID, file: file, line: line)
        self.caller = caller
        return caller
    }

    func seedColdSession(id: UUID = UUID(), agent: AgentProviderKind, model: String, classifiable: Bool = true) async throws -> UUID {
        if coldRoot == nil {
            let previousRoot = await AgentSessionDataService.shared.test_workspaceRootURL()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Test-lifetime ownership: the override stays installed until XCTest teardown, which awaits the restore before deleting the sandbox.
            testCase.addTeardownBlock { @MainActor in
                await AgentSessionDataService.shared.test_setWorkspaceRootOverride(previousRoot)
                try? FileManager.default.removeItem(at: root)
            }
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(root)
            coldRoot = root
        }
        let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        var session = AgentSession(id: id, name: "Cold metadata", savedAt: Date())
        session.agentKind = agent.rawValue
        session.agentModel = model
        _ = try await AgentSessionDataService.shared.saveAgentSession(session, for: workspace)
        XCTAssertNil(window.agentModeViewModel.sessions.values.first { $0.activeAgentSessionID == session.id })
        let record = try await AgentSessionDataService.shared.metadataRecordForSessionID(session.id, for: workspace)
        XCTAssertEqual(record?.agentKindRaw, agent.rawValue)
        XCTAssertEqual(record?.agentModelRaw, model)
        XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: agent, modelRaw: model) != nil, classifiable)
        return session.id
    }

    func modelStageCandidateLabels(file: StaticString = #filePath, line: UInt = #line) async throws -> Set<String> {
        let requests = await backend.requests
        let first = try XCTUnwrap(requests.first { $0.decisionStage == .model }, "advisor saw no model-stage request", file: file, line: line)
        return Set(first.candidates.flatMap(\.roleLabels))
    }

    func modelDecisionMakerExclusions() async throws -> [String: [String]]? {
        await log.flush()
        guard let data = try? Data(contentsOf: logURL) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if row["event"] as? String == "decision", row["stage"] as? String == "model" {
                return row["makerExclusions"] as? [String: [String]]
            }
        }
        return nil
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

    private func makeService() -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: { MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "routed-start", windowID: self.window.windowID) },
            requireTargetWindow: { self.window },
            resolveRequestedTabID: { _ in self.requestedTabID },
            resolveSpawnParentSourceTabID: { _ in self.caller?.tabID },
            resolveSpawnParentSessionID: { _, _ in self.caller?.sessionID },
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
            // With an installed caller the immutable Oracle packaging identity must be the caller's tab and session; without one keep the active-compose fixture identity.
            let installed = self.caller
            let tabID = try installed?.tabID ?? XCTUnwrap(workspace.activeComposeTabID)
            let sourceSessionID = installed?.sessionID
            let snapshot = AgentRunOracleReviewLaunchSnapshot(route: .explicitWindowActiveCompose, windowID: targetWindow.windowID, workspaceID: workspace.id, tabID: tabID, selectionRevision: 0, promptText: "", selection: StoredSelection(), sourceAgentSessionID: sourceSessionID, routedRunID: nil)
            return ResolvedAgentRunOracleReviewLaunchSource(snapshot: snapshot, source: .unavailable(.init(delegationID: UUID(), sourceTabID: tabID, workspaceID: workspace.id, sourceAgentSessionID: sourceSessionID, sourceAgentRunID: nil, reason: .sourceCaptureFailed("routed start"))))
        }
        return service
    }

    func executeNonStart(op: String, args: [String: Value]) async throws -> Value {
        try await makeService().execute(args: args.merging(["op": .string(op)]) { _, new in new })
    }

    var callerControlActivationID: UUID? {
        caller.flatMap { window.agentModeViewModel.session(for: $0.tabID, createIfNeeded: false)?.mcpControlContext?.activationID }
    }

    func start(
        modelID: String? = nil,
        additionalArgs: [String: Value] = [:]
    ) async throws -> Capture {
        capture = nil
        let service = makeService()
        var args: [String: Value] = ["op": .string("start"), "message": .string("Route this task"), "detach": .bool(true), "timeout": .int(0)]
        if let modelID { args["model_id"] = .string(modelID) }
        args.merge(additionalArgs, uniquingKeysWith: { _, new in new })
        _ = try await service.execute(args: args)
        return try XCTUnwrap(capture)
    }

    func pinExploreDefault(agent: AgentProviderKind, model: String, file: StaticString = #filePath, line: UInt = #line) {
        let store = GlobalSettingsStore.shared
        let prior = store.mcpAgentRoleOverrides(scope: .global)
        testCase.addTeardownBlock { @MainActor in
            store.updateMCPAgentRoleOverrides(prior, scope: .global, commit: true)
        }
        let selection = AgentModelCatalog.NormalizedAgentSelection(agent: agent, modelRaw: model)
        XCTAssertTrue(MCPAgentRoleDefaultsService.setSelection(selection, for: .explore, scope: .global), file: file, line: line)
        let resolved = try? AgentMCPSelectionResolver.resolve(
            modelID: nil, defaultTaskLabel: .explore,
            availability: window.apiSettingsViewModel.agentModeAvailabilityContext,
            workspaceID: activeWorkspaceID, surface: .headless
        )
        XCTAssertEqual(resolved?.agentRaw, agent.rawValue, file: file, line: line)
        XCTAssertEqual(resolved?.modelRaw, model, file: file, line: line)
    }

    func executeExplore(
        args additionalArgs: [String: Value], count: Int = 1,
        beforeChild: ((Int) async -> Void)? = nil
    ) async throws -> Value {
        exploreCaptures = []
        exploreAllocatedBindings = [:]
        exploreAllocationCount = 0
        window.agentModeViewModel.test_setAfterDurableChildTabCreation {
            self.exploreAllocationCount += 1
        }
        defer { window.agentModeViewModel.test_setAfterDurableChildTabCreation(nil) }
        let tabsBefore = Set(window.agentModeViewModel.sessions.keys)
        var service = AgentExploreMCPToolService(
            toolName: MCPWindowToolName.agentExplore,
            captureRequestMetadata: { MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "routed-explore", windowID: self.window.windowID) },
            requireTargetWindow: { self.window },
            resolveSpawnSourceTabID: { _ in self.caller?.tabID },
            resolveSpawnParentSessionID: { _, _ in self.caller?.sessionID },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, message, metadata, viewModel, agentRaw, modelRaw, effort, taskLabel, workflow, parentID, oracleSource, preserve in
                try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                    target: target, message: message, metadata: metadata, agentModeVM: viewModel,
                    agentRaw: agentRaw, modelRaw: modelRaw, reasoningEffortRaw: effort, taskLabelKind: taskLabel,
                    workflow: workflow, expectedParentSessionID: parentID, oracleReviewSource: oracleSource,
                    preserveRoutedInitialEffort: preserve,
                    dispatchInstruction: { sessionID, tabID, _, workflow, viewModel in
                        let session = try XCTUnwrap(viewModel.session(for: tabID, createIfNeeded: false))
                        self.exploreCaptures.append(ExploreCapture(
                            sessionID: sessionID,
                            selection: Capture(agent: session.selectedAgent, model: session.selectedModelRaw, parameters: session.acpModelParameterSelections),
                            taskLabel: taskLabel, parentSessionID: session.parentSessionID
                        ))
                        return try await viewModel.mcpDispatchInstruction(
                            sessionID: sessionID, text: message, allowStartingRun: true,
                            workflow: workflow, preserveRoutedInitialEffort: true
                        )
                    }
                )
            }
        )
        service.testBeforeChildWorktreePreparation = { index, _ in
            if index == 0 {
                for (tabID, session) in self.window.agentModeViewModel.sessions where !tabsBefore.contains(tabID) {
                    if let sessionID = session.activeAgentSessionID {
                        self.exploreAllocatedBindings[tabID] = sessionID
                    }
                }
            }
            await beforeChild?(index)
        }
        if let op = AgentMCPToolHelpers.normalizedString(additionalArgs["op"])?.lowercased(), op != "start" {
            return try await service.execute(args: additionalArgs)
        }
        var args: [String: Value] = ["op": .string("start"), "detach": .bool(true), "timeout": .int(0)]
        if count > 1 {
            args["messages"] = .array((0 ..< count).map { .string("Explore child \($0)") })
        } else {
            args["message"] = .string("Explore task")
        }
        args.merge(additionalArgs, uniquingKeysWith: { _, new in new })
        return try await service.execute(args: args)
    }

    func assertExploreRouteRows(
        count: Int, exclusions: [String: [String]]?, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await AsyncTestWait.waitUntil("Explore applied rows admitted", timeout: 5) {
            await (try? self.routeLogRequestIDs().applied.count) == count
        }
        let ids = try await routeLogRequestIDs()
        XCTAssertEqual(ids.applied.count, count, file: file, line: line)
        XCTAssertEqual(Set(ids.applied).count, count, file: file, line: line)
        XCTAssertTrue(Set(ids.applied).isSubset(of: Set(ids.decision)), file: file, line: line)
        await log.flush()
        let data = try Data(contentsOf: logURL)
        var modelRows = 0
        var modelRequestIDs: Set<String> = []
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            if row["event"] as? String == "decision", row["stage"] as? String == "model" {
                modelRows += 1
                try modelRequestIDs.insert(XCTUnwrap(row["requestID"] as? String))
                XCTAssertEqual(row["makerExclusions"] as? [String: [String]], exclusions, file: file, line: line)
            }
        }
        XCTAssertEqual(modelRows, count, file: file, line: line)
        XCTAssertEqual(modelRequestIDs, Set(ids.applied), file: file, line: line)
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
