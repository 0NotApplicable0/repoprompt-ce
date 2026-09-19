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
