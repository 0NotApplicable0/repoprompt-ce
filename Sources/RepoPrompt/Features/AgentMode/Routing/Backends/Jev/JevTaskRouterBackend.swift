import Foundation

struct JevTaskRouterBackend: AgentTaskRouterBackend {
    let id = AgentTaskRouterBackendID.jev
    let displayName = "Jev"
    let credentialService: JevRouterCredentialService

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        await credentialService.readinessSnapshot()
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        // Deliberately fail closed. The wire adapter and strict fixtures may be exercised,
        // but no selection is accepted until a reviewed calibration policy is committed.
        .failed(category: .policyUnavailable, retryable: false, evidence: .init(
            policyVersion: JevRouterCredentialService.unavailablePolicyVersion,
            confidence: nil,
            scores: nil,
            inputTokens: nil,
            outputTokens: nil,
            reasonCode: "calibration_required"
        ))
    }
}
