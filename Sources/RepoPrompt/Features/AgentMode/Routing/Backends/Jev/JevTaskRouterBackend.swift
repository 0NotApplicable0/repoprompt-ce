import Foundation

struct JevTaskRouterBackend: AgentTaskRouterBackend {
    let id = AgentTaskRouterBackendID.jev
    let displayName = "Jev"
    let credentialService: JevRouterCredentialService

    static func settingsRegistration(
        controller: JevRouterCredentialService
    ) -> AgentTaskRouterBackendSettingsRegistration {
        AgentTaskRouterBackendSettingsRegistration(
            presentation: .init(
                title: "Jev by TypeSafe",
                configurationDetail: "Validation contacts GET /v1/models. Routing remains unavailable until RepoPrompt ships a reviewed calibration policy. A future enabled route will use one POST /v1/systemone request with a five-second deadline and no RepoPrompt retries.",
                secretFieldLabel: "TypeSafe API key",
                links: [
                    .init(title: "TypeSafe API documentation", url: URL(string: "https://docs.typesafe.ai/api")!),
                    .init(title: "TypeSafe privacy policy", url: URL(string: "https://typesafe.ai/legal/privacy-policy")!)
                ]
            ),
            controller: controller
        )
    }

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
