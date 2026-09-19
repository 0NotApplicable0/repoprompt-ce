import Combine
import Foundation

/// App-global composition owner for bundled router adapters and their credential/readiness state.
final class AgentTaskRouterRuntime: ObservableObject {
    let registry: AgentTaskRouterRegistry
    let coordinator: AgentFreshTaskRoutingCoordinator
    let objectWillChange = ObservableObjectPublisher()

    private let readinessLock = NSLock()
    private var readinessByBackendID: [AgentTaskRouterBackendID: AgentTaskRouterBackendReadiness] = [:]

    init(registrations: [AgentTaskRouterBackendRegistration]) throws {
        let registry = try AgentTaskRouterRegistry(registrations: registrations)
        self.registry = registry
        coordinator = AgentFreshTaskRoutingCoordinator(registry: registry)
        start()
    }

    convenience init(
        secureKeys: SecureKeysService = SecureKeysService(),
        jevClient: any JevRoutingClientProtocol = JevRoutingClient()
    ) {
        let credentials = JevRouterCredentialService(secureKeys: secureKeys, client: jevClient)
        do {
            try self.init(registrations: [
                AgentTaskRouterBackendRegistration(
                    backend: JevTaskRouterBackend(credentialService: credentials),
                    settings: JevTaskRouterBackend.settingsRegistration(controller: credentials)
                )
            ])
        } catch {
            preconditionFailure("Invalid bundled model-router registry: \(error)")
        }
    }

    func isBackendReady(_ id: AgentTaskRouterBackendID) -> Bool {
        readinessLock.lock()
        defer { readinessLock.unlock() }
        return readinessByBackendID[id]?.isReady == true
    }

    func cancelAll() {
        Task {
            await coordinator.cancelAll()
            for registration in await registry.registrations() {
                await registration.settings?.controller.cancelAndAdvanceGeneration()
            }
        }
    }

    func backendSelectionDidChange(selectedID: AgentTaskRouterBackendID?) async {
        await coordinator.cancelAll()
        for registration in await registry.registrations() {
            await registration.settings?.controller.cancelAndAdvanceGeneration()
        }
        if let selectedID,
           let selected = await registry.registration(for: selectedID)
        {
            await selected.settings?.controller.bootstrapStoredConfigurationIfNeeded()
        }
    }

    private func start() {
        Task { [weak self, registry] in
            for registration in await registry.registrations() {
                let initialReadiness = await registration.backend.readinessSnapshot()
                self?.publishReadiness(initialReadiness, backendID: registration.id)
                await registration.settings?.controller.bootstrapStoredConfigurationIfNeeded()
                guard let controller = registration.settings?.controller else { continue }
                Task { [weak self] in
                    for await snapshot in await controller.readinessUpdates() {
                        guard !Task.isCancelled else { return }
                        self?.publishReadiness(snapshot, backendID: registration.id)
                    }
                }
            }
        }
    }

    private func publishReadiness(
        _ readiness: AgentTaskRouterBackendReadiness,
        backendID: AgentTaskRouterBackendID
    ) {
        readinessLock.lock()
        let changed = readinessByBackendID[backendID] != readiness
        readinessByBackendID[backendID] = readiness
        readinessLock.unlock()
        guard changed else { return }
        Task { @MainActor [weak self] in self?.objectWillChange.send() }
    }
}
