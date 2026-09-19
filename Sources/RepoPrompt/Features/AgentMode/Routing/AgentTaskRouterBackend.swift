import Foundation

protocol AgentTaskRouterBackend: Sendable {
    var id: AgentTaskRouterBackendID { get }
    var displayName: String { get }
    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness
    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome
}

struct AgentTaskRouterBackendRegistration {
    let id: AgentTaskRouterBackendID
    let displayName: String
    let backend: any AgentTaskRouterBackend

    init(backend: any AgentTaskRouterBackend) {
        id = backend.id
        displayName = backend.displayName
        self.backend = backend
    }
}

enum AgentTaskRouterRegistryError: Error, Equatable {
    case invalidBackendID
    case duplicateBackendID(AgentTaskRouterBackendID)
}
