import Foundation

/// Stable identity for a bundled routing backend. Router selection is exact and never falls back.
struct AgentTaskRouterBackendID: RawRepresentable, Codable, Hashable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static let jev = AgentTaskRouterBackendID(rawValue: "jev")
}

enum AgentTaskRouterBackendReadiness: Equatable {
    case ready(generation: UInt64, policyVersion: String)
    case needsConfiguration(generation: UInt64, reason: String)
    case validating(generation: UInt64)
    case policyUnavailable(generation: UInt64, reason: String)
    case temporarilyUnavailable(generation: UInt64, reason: String)

    var generation: UInt64 {
        switch self {
        case let .ready(generation, _),
             let .needsConfiguration(generation, _),
             let .validating(generation),
             let .policyUnavailable(generation, _),
             let .temporarilyUnavailable(generation, _):
            generation
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Complete executable identity used for candidate deduplication and commit/rollback.
/// It deliberately retains effort and normalized ACP parameters; provider/model alone is not executable identity.
struct AgentRoutingExecutableTarget: Hashable {
    let agentRaw: String
    let modelRaw: String
    let reasoningEffortRaw: String?
    let modelParameters: [ACPModelParameterSelection]

    init(
        agentRaw: String,
        modelRaw: String,
        reasoningEffortRaw: String?,
        modelParameters: [ACPModelParameterSelection]
    ) {
        self.agentRaw = agentRaw
        self.modelRaw = modelRaw
        self.reasoningEffortRaw = reasoningEffortRaw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.modelParameters = Self.canonicalParameters(modelParameters)
    }

    private static func canonicalParameters(_ parameters: [ACPModelParameterSelection]) -> [ACPModelParameterSelection] {
        ACPModelParameterSelection.normalized(parameters).sorted {
            let lhs = ($0.providerID.rawValue, $0.baseModelRaw, $0.kind.rawValue, $0.configID, $0.valueRaw)
            let rhs = ($1.providerID.rawValue, $1.baseModelRaw, $1.kind.rawValue, $1.configID, $1.valueRaw)
            return lhs < rhs
        }
    }
}

struct AgentTaskRoutingCandidateDescriptor: Codable, Equatable {
    let opaqueKey: String
    let roleLabels: [String]
    let rubricVersion: String
    let rubric: String
}

struct AgentTaskRoutingRequest: Equatable {
    static let currentContractVersion = "rpce.agent-fresh-task-router.v1"

    let requestID: UUID
    let contractVersion: String
    let task: String
    let candidates: [AgentTaskRoutingCandidateDescriptor]
}

struct AgentTaskRoutingDecisionEvidence: Equatable {
    let policyVersion: String?
    let confidence: Double?
    let scores: [String: Double]?
    let inputTokens: Int?
    let outputTokens: Int?
    let reasonCode: String?
}

enum AgentTaskRoutingBackendFailureCategory: String, Equatable {
    case authentication
    case invalidRequest
    case rateLimited
    case overloaded
    case transport
    case timeout
    case invalidResponse
    case policyUnavailable
}

enum AgentTaskRoutingBackendOutcome: Equatable {
    case selected(opaqueKey: String, evidence: AgentTaskRoutingDecisionEvidence?)
    case abstained(reason: String, evidence: AgentTaskRoutingDecisionEvidence?)
    case failed(category: AgentTaskRoutingBackendFailureCategory, retryable: Bool, evidence: AgentTaskRoutingDecisionEvidence?)
    case cancelled
}

struct AgentTaskRouterConfiguration: Equatable {
    enum Validity: Equatable {
        case valid
        case disabled
        case backendMissing
        case fewerThanTwoRoles
    }

    let enabled: Bool
    let selectedBackendID: AgentTaskRouterBackendID?
    let selectedBackendRawValue: String?
    let candidateRoles: [AgentModelCatalog.TaskLabelKind]
    let allowedProviders: Set<AgentProviderKind>
    let unknownRoleRawValues: [String]
    let unknownProviderRawValues: [String]
    let validity: Validity
    let revision: UInt64
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
