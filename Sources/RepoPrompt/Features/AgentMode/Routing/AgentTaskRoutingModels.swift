import Foundation
import RepoPromptSettingsCore

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
    let targetDescription: String
    let rubricVersion: String
    let rubric: String
}

enum AgentTaskRoutingScope: String, Codable, Equatable {
    case primarySession
    case subagent
}

enum AgentTaskRoutingDecisionStage: String, Codable, Equatable {
    case model
    case effort
}

enum AgentTaskRoutingMaker: String, CaseIterable, Codable {
    case anthropic, openai, google, xai, cursor
}

struct AgentTaskRoutingDiversityOptions: Equatable {
    enum ExclusionSource: String, CaseIterable, Codable {
        case excludeMakers = "exclude_makers"
        case diverseFromSessions = "diverse_from_sessions"
        case reviewDiversity = "review_diversity"
    }

    let exclusions: [String: Set<ExclusionSource>]

    static let none = AgentTaskRoutingDiversityOptions(exclusions: [:])

    var canonicalMakerExclusions: [String: [String]] {
        exclusions.mapValues { sources in
            ExclusionSource.allCases.filter(sources.contains).map(\.rawValue)
        }
    }
}

struct AgentTaskRouterConfiguration: Equatable {
    enum Validity: Equatable {
        case valid
        case disabled
        case backendMissing
        case fewerThanTwoRoles
        case noAllowedProviders
    }

    let enabled: Bool
    let selectedBackendID: DecisionServiceID?
    let selectedBackendRawValue: String?
    let candidateRoles: [AgentModelCatalog.TaskLabelKind]
    let allowedProviders: Set<AgentProviderKind>
    let candidateRolesMaterialized: Bool
    let allowedProvidersMaterialized: Bool
    let unknownRoleRawValues: [String]
    let unknownProviderRawValues: [String]
    let primaryProvider: AgentProviderKind?
    let subagentProvider: AgentProviderKind?
    let customInstructions: String
    let validity: Validity
    let revision: UInt64
    var usageBalancing = AgentUsageBalancingConfiguration()
    var allowPaidFastRouting = false
    var randomness: AgentRoutingRandomness = .off
    var reviewDiversityEnabled = false
}

enum AgentRoutingRandomness: String, CaseIterable, Identifiable {
    case off, low, medium, high

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var explanation: String {
        switch self {
        case .off: "No added variety."
        case .low: "Adds a little variety among comparable models."
        case .medium: "Adds moderate variety among comparable models."
        case .high: "Adds the most variety among comparable models."
        }
    }

    static func stored(_ raw: String?) -> Self {
        raw.flatMap(Self.init(rawValue:)) ?? .off
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
