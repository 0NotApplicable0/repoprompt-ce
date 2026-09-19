import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentTaskRouterCoreTests: XCTestCase {
    func testRegistryRejectsDuplicatesAndNeverFallsBackUnknownID() async throws {
        let backend = FakeBackend(id: .init(rawValue: "fake"), readiness: .ready(generation: 1, policyVersion: "v1"))
        XCTAssertThrowsError(try AgentTaskRouterRegistry(registrations: [
            .init(backend: backend), .init(backend: backend)
        ])) { error in
            XCTAssertEqual(error as? AgentTaskRouterRegistryError, .duplicateBackendID(.init(rawValue: "fake")))
        }
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let missing = await registry.registration(for: .init(rawValue: "unknown"))
        XCTAssertNil(missing)
        let registrations = await registry.registrations()
        XCTAssertEqual(registrations.map(\.id), [.init(rawValue: "fake")])
    }

    func testSecondBackendRegistrationOwnsSettingsWithoutGenericJevSwitches() async throws {
        let fake = FakeBackend(id: .init(rawValue: "second"), readiness: .ready(generation: 1, policyVersion: "v1"))
        let settings = FakeBackendSettingsController()
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(
                backend: fake,
                settings: .init(
                    presentation: .init(
                        title: "Second backend",
                        configurationDetail: "Fake settings",
                        secretFieldLabel: nil,
                        links: []
                    ),
                    controller: settings
                )
            )
        ])
        let registration = await runtime.registry.registration(for: fake.id)
        XCTAssertEqual(registration?.settings?.presentation.title, "Second backend")
        let readiness = await registration?.settings?.controller.readinessSnapshot()
        XCTAssertEqual(readiness, .ready(generation: 1, policyVersion: "v1"))
    }

    func testEnvelopeIsExactAndRejectsPrivacyExpansionsOrTruncation() throws {
        let candidates = [descriptor("a"), descriptor("b")]
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "  diagnose this  ", candidates: candidates
        )
        XCTAssertEqual(request.task, "diagnose this")
        XCTAssertEqual(request.contractVersion, AgentTaskRoutingRequest.currentContractVersion)
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: String(repeating: "a", count: 4001), candidates: candidates
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .tooManyCharacters) }
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: candidates, containsAttachments: true
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .unsupportedContent) }
        XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a")]
        )) { XCTAssertEqual($0 as? AgentTaskRoutingEnvelopeBuilder.Rejection, .invalidCandidateCount) }
    }

    func testExecutableIdentityIncludesEffortAndNormalizedACPParameters() {
        let low = AgentRoutingExecutableTarget(
            agentRaw: "grokBuild", modelRaw: "grok", reasoningEffortRaw: "low", modelParameters: []
        )
        let high = AgentRoutingExecutableTarget(
            agentRaw: "grokBuild", modelRaw: "grok", reasoningEffortRaw: "high", modelParameters: []
        )
        XCTAssertNotEqual(low, high)

        let first = ACPModelParameterSelection(
            providerID: .openCode, baseModelRaw: "model", kind: .thinking, configID: "effort", valueRaw: "low"
        )
        let second = ACPModelParameterSelection(
            providerID: .openCode, baseModelRaw: "model", kind: .speed, configID: "tier", valueRaw: "fast"
        )
        let ordered = AgentRoutingExecutableTarget(
            agentRaw: "openCode", modelRaw: "model", reasoningEffortRaw: nil, modelParameters: [first, second]
        )
        let reversed = AgentRoutingExecutableTarget(
            agentRaw: "openCode", modelRaw: "model", reasoningEffortRaw: nil, modelParameters: [second, first]
        )
        XCTAssertEqual(ordered, reversed)
    }

    func testCoordinatorRejectsUnknownSelectionFromReadyBackend() async throws {
        let backend = FakeBackend(
            id: .init(rawValue: "fake"),
            readiness: .ready(generation: 1, policyVersion: "v1"),
            outcome: .selected(opaqueKey: "not-submitted", evidence: nil)
        )
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let result = await coordinator.route(backendID: backend.id, request: request)
        XCTAssertEqual(result, .failed(category: .invalidResponse, retryable: false, evidence: nil))
    }

    func testCoordinatorRejectsSelectionAfterReadinessGenerationChanges() async throws {
        let backend = AdvancingReadinessBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let result = await coordinator.route(backendID: backend.id, request: request)
        XCTAssertEqual(result, .failed(category: .policyUnavailable, retryable: false, evidence: nil))
    }

    func testCoordinatorCancellationRejectsLateBackendSelection() async throws {
        let backend = LateCompletionBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let route = Task { await coordinator.route(backendID: backend.id, request: request) }
        await backend.waitUntilStarted()
        await coordinator.cancel(requestID: request.requestID)
        await backend.completeWithSelection()
        let outcome = await route.value
        XCTAssertEqual(outcome, .cancelled)
    }

    func testCoordinatorReservesBeforeReadinessAndDuplicateCannotPass() async throws {
        let backend = SuspendedReadinessBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let first = Task { await coordinator.route(backendID: backend.id, request: request) }
        await backend.waitUntilReadinessStarted()
        let duplicate = await coordinator.route(backendID: backend.id, request: request)
        XCTAssertEqual(duplicate, .failed(category: .invalidRequest, retryable: false, evidence: nil))
        await coordinator.cancel(requestID: request.requestID)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
    }

    func testCancelPromptlySettlesWhenBackendNeverCompletes() async throws {
        let backend = NeverCompletingRouteBackend()
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
        let coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let route = Task { await coordinator.route(backendID: backend.id, request: request) }
        await backend.waitUntilStarted()
        await coordinator.cancelAll()
        let routeOutcome = await route.value
        XCTAssertEqual(routeOutcome, .cancelled)
    }

    func testOptionalEvidenceIsValidatedUniformly() async throws {
        let invalid = AgentTaskRoutingDecisionEvidence(
            policyVersion: "wrong", confidence: .nan, scores: ["unknown": -1],
            inputTokens: -1, outputTokens: -1, reasonCode: nil
        )
        for outcome in [
            AgentTaskRoutingBackendOutcome.abstained(reason: "test", evidence: invalid),
            .failed(category: .transport, retryable: true, evidence: invalid)
        ] {
            let backend = FakeBackend(
                id: .init(rawValue: UUID().uuidString),
                readiness: .ready(generation: 1, policyVersion: "v1"),
                outcome: outcome
            )
            let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: backend)])
            let request = try AgentTaskRoutingEnvelopeBuilder().build(
                requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
            )
            let outcome = await AgentFreshTaskRoutingCoordinator(registry: registry)
                .route(backendID: backend.id, request: request)
            XCTAssertEqual(outcome, .failed(category: .invalidResponse, retryable: false, evidence: nil))
        }
        let nilEvidenceBackend = FakeBackend(
            id: .init(rawValue: "nil-evidence"),
            readiness: .ready(generation: 1, policyVersion: "v1"),
            outcome: .selected(opaqueKey: "a", evidence: nil)
        )
        let registry = try AgentTaskRouterRegistry(registrations: [.init(backend: nilEvidenceBackend)])
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "task", candidates: [descriptor("a"), descriptor("b")]
        )
        let outcome = await AgentFreshTaskRoutingCoordinator(registry: registry)
            .route(backendID: nilEvidenceBackend.id, request: request)
        XCTAssertEqual(outcome, .selected(opaqueKey: "a", evidence: nil))
    }

    func testJevBackendIsFailClosedUntilReviewedPolicyExists() async {
        let credentials = JevRouterCredentialService()
        let backend = JevTaskRouterBackend(credentialService: credentials)
        let outcome = await backend.route(.init(
            requestID: UUID(), contractVersion: AgentTaskRoutingRequest.currentContractVersion,
            task: "task", candidates: [descriptor("a"), descriptor("b")]
        ))
        guard case let .failed(category, retryable, evidence) = outcome else {
            return XCTFail("Expected policy-unavailable failure")
        }
        XCTAssertEqual(category, .policyUnavailable)
        XCTAssertFalse(retryable)
        XCTAssertEqual(evidence?.reasonCode, "calibration_required")
    }

    private func descriptor(_ key: String) -> AgentTaskRoutingCandidateDescriptor {
        .init(opaqueKey: key, roleLabels: [key], rubricVersion: "v1", rubric: "rubric")
    }
}

private struct FakeBackend: AgentTaskRouterBackend {
    let id: AgentTaskRouterBackendID
    let displayName = "Fake"
    let readiness: AgentTaskRouterBackendReadiness
    var outcome: AgentTaskRoutingBackendOutcome = .abstained(reason: "test", evidence: nil)

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        readiness
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        outcome
    }
}

private actor FakeBackendSettingsController: AgentTaskRouterBackendSettingsController {
    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "v1")
    }

    func readinessUpdates() -> AsyncStream<AgentTaskRouterBackendReadiness> {
        AsyncStream { $0.yield(.ready(generation: 1, policyVersion: "v1"))
            $0.finish()
        }
    }

    func perform(_ action: AgentTaskRouterBackendSettingsAction) -> AgentTaskRouterBackendSettingsActionResult {
        .succeeded("ok")
    }

    func bootstrapStoredConfigurationIfNeeded() {}
    func cancelAndAdvanceGeneration() {}
}

private actor AdvancingReadinessBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "advancing")
    nonisolated let displayName = "Advancing"
    private var readinessCallCount = 0

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        readinessCallCount += 1
        return .ready(generation: UInt64(readinessCallCount), policyVersion: "v1")
    }

    func route(_ request: AgentTaskRoutingRequest) -> AgentTaskRoutingBackendOutcome {
        .selected(
            opaqueKey: request.candidates[0].opaqueKey,
            evidence: .init(
                policyVersion: "v1", confidence: 0.8, scores: nil, inputTokens: 1, outputTokens: 1, reasonCode: nil
            )
        )
    }
}

private actor LateCompletionBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "late")
    nonisolated let displayName = "Late"
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<AgentTaskRoutingBackendOutcome, Never>?

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func completeWithSelection() {
        completion?.resume(returning: .selected(
            opaqueKey: "a",
            evidence: .init(
                policyVersion: "v1", confidence: 0.8, scores: nil, inputTokens: 1, outputTokens: 1, reasonCode: nil
            )
        ))
        completion = nil
    }
}

private actor SuspendedReadinessBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "suspended-readiness")
    nonisolated let displayName = "Suspended readiness"
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withUnsafeContinuation { (_: UnsafeContinuation<AgentTaskRouterBackendReadiness, Never>) in }
    }

    func route(_ request: AgentTaskRoutingRequest) -> AgentTaskRoutingBackendOutcome {
        .cancelled
    }

    func waitUntilReadinessStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor NeverCompletingRouteBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID(rawValue: "never-completing")
    nonisolated let displayName = "Never completing"
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withUnsafeContinuation { (_: UnsafeContinuation<AgentTaskRoutingBackendOutcome, Never>) in }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
final class AgentTaskRoutingCandidateBuilderPolicyTests: XCTestCase {
    func testWorkspaceOverrideIsAuthoritative() throws {
        let workspaceID = UUID()
        let claude = AgentModelSelectionID(
            agentRaw: AgentProviderKind.claudeCode.rawValue,
            modelRaw: AgentModel.claudeSonnet.rawValue
        ).rawValue
        let store = WorkspaceAwareRoleStore(workspaceID: workspaceID, workspaceOverrides: ["explore": claude])
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let workspaceCandidates = try AgentTaskRoutingCandidateBuilder(opaqueKey: { UUID().uuidString }).build(
            workspaceID: workspaceID,
            roles: [.explore, .engineer],
            allowedProviders: [.claudeCode, .codexExec],
            availability: availability,
            settingsStore: store
        )
        let explore = try XCTUnwrap(workspaceCandidates.first(where: { $0.roles.contains(.explore) }))
        XCTAssertEqual(explore.target.agentRaw, AgentProviderKind.claudeCode.rawValue)
    }

    func testEmptyProviderAndDuplicateTargetsFailClosed() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: true,
            openCodeAvailable: false
        )
        XCTAssertThrowsError(try AgentTaskRoutingCandidateBuilder().build(
            workspaceID: nil,
            roles: [.explore, .engineer],
            allowedProviders: [],
            availability: availability
        ))

        let same = AgentModelSelectionID(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt56SolMedium.rawValue
        ).rawValue
        let store = WorkspaceAwareRoleStore(
            workspaceID: UUID(),
            workspaceOverrides: ["explore": same, "engineer": same]
        )
        XCTAssertThrowsError(try AgentTaskRoutingCandidateBuilder().build(
            workspaceID: store.workspaceID,
            roles: [.explore, .engineer],
            allowedProviders: [.codexExec],
            availability: availability,
            settingsStore: store
        )) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .insufficientDistinctTargets)
        }
    }
}

@MainActor
private final class WorkspaceAwareRoleStore: MCPAgentRoleDefaultsStoring {
    let workspaceID: UUID
    private var workspaceOverrides: [String: String]?

    init(workspaceID: UUID, workspaceOverrides: [String: String]?) {
        self.workspaceID = workspaceID
        self.workspaceOverrides = workspaceOverrides
    }

    func mcpAgentRoleOverrides(workspaceID: UUID?) -> [String: String]? {
        workspaceID == self.workspaceID ? workspaceOverrides : nil
    }

    func mcpAgentRoleOverrides(scope: AgentModelsEditingScope) -> [String: String]? {
        if case let .workspace(id) = scope, id == workspaceID { return workspaceOverrides }
        return nil
    }

    func updateMCPAgentRoleOverrides(
        _ overrides: [String: String]?,
        scope: AgentModelsEditingScope,
        commit: Bool
    ) {
        if case let .workspace(id) = scope, id == workspaceID { workspaceOverrides = overrides }
    }

    func mcpAgentRoleModelParameters(scope: AgentModelsEditingScope) -> [String: [ACPModelParameterSelection]]? {
        nil
    }

    func mcpAgentRoleModelParameters(workspaceID: UUID?) -> [String: [ACPModelParameterSelection]]? {
        nil
    }
}
