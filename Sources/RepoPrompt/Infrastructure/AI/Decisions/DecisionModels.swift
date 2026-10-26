import Foundation

/// Stable exact service identity; unknown persisted IDs remain distinct and never fall back.
struct DecisionServiceID: RawRepresentable, Codable, Hashable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static let jev = Self(rawValue: "jev")
    static let openAIDecisions = Self(rawValue: "openai-decisions")
}

struct DecisionConsumerID: RawRepresentable, Codable, Hashable {
    let rawValue: String

    static let modelRouter = Self(rawValue: "model-router")
    static let autoEffort = Self(rawValue: "auto-effort")
}

struct DecisionChoice: Equatable {
    let opaqueKey: String
    let description: String
}

struct FiniteChoiceQuestion: Equatable {
    let name: String
    let instructions: String
    let choices: [DecisionChoice]
}

struct DecisionPolicyIdentity: Equatable {
    let id: String
    let version: String
}

struct FiniteChoiceDecisionRequest: Equatable {
    static let currentContractVersion = "rpce.finite-choice.v1"

    let requestID: UUID
    let consumerID: DecisionConsumerID
    let contractVersion: String
    let policy: DecisionPolicyIdentity
    let textContext: String
    /// V1 deliberately has one text question, not a batch or an image payload.
    let question: FiniteChoiceQuestion
}

struct DecisionChoiceValue: Equatable {
    let opaqueKey: String
    let value: Double
}

enum DecisionValueSemantics: String, Equatable {
    case independentScore
    case probability
}

struct DecisionUsage: Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
}

struct DecisionEvidence: Equatable {
    let acceptancePolicyVersion: String
    let confidence: Double?
    /// Arrays retain duplicate wire entries until validation; dictionaries would silently erase them.
    let scores: [DecisionChoiceValue]?
    let scoreSemantics: DecisionValueSemantics?
    let probabilities: [DecisionChoiceValue]?
    let probabilitySemantics: DecisionValueSemantics?
    let usage: DecisionUsage?
}

enum DecisionFailureCategory: String, Equatable {
    case authentication
    case invalidRequest
    case rateLimited
    case overloaded
    case transport
    case timeout
    case invalidResponse
    case policyUnavailable
}

enum DecisionOutcome: Equatable {
    case selected(opaqueKey: String, evidence: DecisionEvidence?)
    case abstained(reasonCode: String, evidence: DecisionEvidence?)
    case failed(category: DecisionFailureCategory, retryable: Bool, evidence: DecisionEvidence?)
    case cancelled

    static let invalidRequest: Self = .failed(category: .invalidRequest, retryable: false, evidence: nil)
    static let invalidResponse: Self = .failed(category: .invalidResponse, retryable: false, evidence: nil)
    static let unavailable: Self = .failed(category: .policyUnavailable, retryable: false, evidence: nil)
}

/// Route evidence that is not part of the wire outcome: which service answered and how long it took.
/// Used only by the decision log; it never changes decision selection or error semantics.
struct DecisionTrace: Equatable {
    let serviceID: DecisionServiceID
    /// The pinned service evaluator model when the service answered with validated evidence.
    let jevModel: String?
    /// Monotonic milliseconds from just before the service call through the validated terminal result.
    /// Nil when no service call was made (invalid request, unavailable policy, cancellation before start).
    let latencyMs: Double?

    var backendID: DecisionServiceID {
        serviceID
    }
}

struct DecisionTracedOutcome: Equatable {
    let outcome: DecisionOutcome
    let trace: DecisionTrace
}

enum DecisionReadiness: Equatable {
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

    var settingsSymbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .validating: "hourglass"
        case .needsConfiguration: "key.fill"
        case .policyUnavailable: "info.circle"
        case .temporarilyUnavailable: "exclamationmark.triangle.fill"
        }
    }
}
