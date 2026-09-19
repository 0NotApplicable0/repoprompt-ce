import Foundation

/// App-global composition owner for bundled router adapters and their credential/readiness state.
final class AgentTaskRouterRuntime {
    let jevCredentialService: JevRouterCredentialService
    let registry: AgentTaskRouterRegistry
    let coordinator: AgentFreshTaskRoutingCoordinator

    init(
        secureKeys: SecureKeysService = SecureKeysService(),
        jevClient: any JevRoutingClientProtocol = JevRoutingClient()
    ) {
        let credentials = JevRouterCredentialService(secureKeys: secureKeys, client: jevClient)
        jevCredentialService = credentials
        do {
            let registry = try AgentTaskRouterRegistry(registrations: [
                AgentTaskRouterBackendRegistration(backend: JevTaskRouterBackend(credentialService: credentials))
            ])
            self.registry = registry
            coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        } catch {
            preconditionFailure("Invalid bundled model-router registry: \(error)")
        }
    }

    func cancelAll() {
        Task {
            await coordinator.cancelAll()
            await jevCredentialService.cancelValidation()
        }
    }
}
