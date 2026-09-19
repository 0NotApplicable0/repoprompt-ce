import Foundation

actor AgentFreshTaskRoutingCoordinator {
    private struct InFlight {
        let ownershipID: UUID
        let task: Task<AgentTaskRoutingBackendOutcome, Never>
    }

    private let registry: AgentTaskRouterRegistry
    private var tasksByRequestID: [UUID: InFlight] = [:]

    init(registry: AgentTaskRouterRegistry) {
        self.registry = registry
    }

    func route(
        backendID: AgentTaskRouterBackendID,
        request: AgentTaskRoutingRequest
    ) async -> AgentTaskRoutingBackendOutcome {
        guard tasksByRequestID[request.requestID] == nil,
              let registration = await registry.registration(for: backendID)
        else {
            return .failed(category: .invalidRequest, retryable: false, evidence: nil)
        }
        let capturedReadiness = await registration.backend.readinessSnapshot()
        guard case .ready = capturedReadiness else {
            return .failed(category: .policyUnavailable, retryable: false, evidence: nil)
        }

        let ownershipID = UUID()
        let task = Task { await registration.backend.route(request) }
        tasksByRequestID[request.requestID] = InFlight(ownershipID: ownershipID, task: task)
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard owns(requestID: request.requestID, ownershipID: ownershipID), !Task.isCancelled else {
            removeIfOwned(requestID: request.requestID, ownershipID: ownershipID)?.cancel()
            return .cancelled
        }

        let currentReadiness = await registration.backend.readinessSnapshot()
        guard owns(requestID: request.requestID, ownershipID: ownershipID) else { return .cancelled }
        tasksByRequestID.removeValue(forKey: request.requestID)
        guard currentReadiness == capturedReadiness else {
            return .failed(category: .policyUnavailable, retryable: false, evidence: nil)
        }
        guard case let .ready(_, policyVersion) = capturedReadiness else {
            return .failed(category: .policyUnavailable, retryable: false, evidence: nil)
        }
        return validate(outcome, request: request, policyVersion: policyVersion)
    }

    func cancel(requestID: UUID) {
        tasksByRequestID.removeValue(forKey: requestID)?.task.cancel()
    }

    func cancelAll() {
        let tasks = tasksByRequestID.values.map(\.task)
        tasksByRequestID.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func owns(requestID: UUID, ownershipID: UUID) -> Bool {
        tasksByRequestID[requestID]?.ownershipID == ownershipID
    }

    @discardableResult
    private func removeIfOwned(
        requestID: UUID,
        ownershipID: UUID
    ) -> Task<AgentTaskRoutingBackendOutcome, Never>? {
        guard owns(requestID: requestID, ownershipID: ownershipID) else { return nil }
        return tasksByRequestID.removeValue(forKey: requestID)?.task
    }

    private func validate(
        _ outcome: AgentTaskRoutingBackendOutcome,
        request: AgentTaskRoutingRequest,
        policyVersion: String
    ) -> AgentTaskRoutingBackendOutcome {
        guard case let .selected(key, evidence) = outcome else { return outcome }
        let keys = request.candidates.map(\.opaqueKey)
        guard keys.count(where: { $0 == key }) == 1 else {
            return .failed(category: .invalidResponse, retryable: false, evidence: nil)
        }
        guard let evidence,
              evidence.policyVersion == policyVersion,
              evidence.scores?.allSatisfy({ keys.contains($0.key) && $0.value.isFinite && (0 ... 1).contains($0.value) }) ?? true,
              evidence.confidence.map({ $0.isFinite && (0 ... 1).contains($0) }) ?? true,
              (evidence.inputTokens.map { $0 >= 0 } ?? true),
              (evidence.outputTokens.map { $0 >= 0 } ?? true)
        else {
            return .failed(category: .invalidResponse, retryable: false, evidence: nil)
        }
        return outcome
    }
}
