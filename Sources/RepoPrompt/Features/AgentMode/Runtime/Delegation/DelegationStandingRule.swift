import Foundation
import RepoPromptDomainRuntime

struct DelegationStandingRule: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let starter: StarterConnectionStamp
    let workspaceID: UUID
    var countedTLs: Set<UUID>
    var ruleGrants: Set<UUID>
    var stoppedAt: Date?
    var replacedBy: UUID?
    var closedAt: Date?
    var maxTeamLeads: Int = StandingRuleOptions.defaultTeamLeads
    var bulkThresholdCeiling: Int = StandingRuleOptions.maximumBulkThresholdCeiling
    var clientLabel: String?

    func effectiveState(now: Date) -> StandingRuleEffectiveState {
        if stoppedAt != nil { return .stopped }
        if replacedBy != nil { return .replaced }
        if now >= expiresAt { return .expired }
        if closedAt != nil { return .connectionClosed }
        return .active
    }
}

enum StandingRuleEffectiveState: Equatable {
    case active
    case stopped
    case replaced
    case expired
    case connectionClosed
}

struct StandingRuleOptions: Equatable {
    static let minimumDuration: TimeInterval = 4 * 60 * 60
    static let defaultDuration: TimeInterval = 8 * 60 * 60
    static let maximumDuration: TimeInterval = 24 * 60 * 60
    static let minimumTeamLeads = 5
    static let defaultTeamLeads = 10
    static let maximumTeamLeads = 50
    static let maximumBulkThresholdCeiling = 25

    var duration: TimeInterval = Self.defaultDuration
    var maxTeamLeads: Int = Self.defaultTeamLeads
}

struct StandingRuleFacts: Equatable {
    let starter: StarterConnectionStamp
    let workspaceID: UUID
    let clientLabel: String?

    init(starter: StarterConnectionStamp, workspaceID: UUID, clientLabel: String? = nil) {
        self.starter = starter
        self.workspaceID = workspaceID
        self.clientLabel = clientLabel
    }
}

struct StandingRuleOffer: Equatable {
    let ruleID: UUID?
    let clientLabel: String?
    let connectionPrefix: String
    let replacesExisting: Bool
}

struct StandingRuleNotice: Identifiable, Equatable {
    enum Cause: Equatable { case connectionClosed, noStamp, requestChanged }
    let id: UUID
    let cause: Cause
    let sessionID: UUID?
    let tabID: UUID?

    init(id: UUID, cause: Cause, sessionID: UUID? = nil, tabID: UUID? = nil) {
        self.id = id
        self.cause = cause
        self.sessionID = sessionID
        self.tabID = tabID
    }
}

struct DelegationStandingRuleBook: Equatable {
    private(set) var rules: [UUID: DelegationStandingRule] = [:]
    private(set) var notices: [UUID: StandingRuleNotice] = [:]
    private(set) var exclusions: Set<UUID> = []

    mutating func add(_ rule: DelegationStandingRule) {
        rules[rule.id] = rule
    }

    mutating func replace(_ rule: DelegationStandingRule) {
        for (id, existing) in rules
            where id != rule.id
            && existing.starter == rule.starter
            && existing.workspaceID == rule.workspaceID
            && existing.stoppedAt == nil && existing.replacedBy == nil
        {
            rules[id]?.replacedBy = rule.id
        }
        rules[rule.id] = rule
    }

    mutating func remove(id: UUID) {
        rules[id] = nil
    }

    mutating func stop(id: UUID, now: Date) {
        guard rules[id]?.stoppedAt == nil else { return }
        rules[id]?.stoppedAt = now
    }

    mutating func countTeamLead(_ sessionID: UUID, in ruleID: UUID) {
        rules[ruleID]?.countedTLs.insert(sessionID)
    }

    mutating func recordRuleGrant(scopeID: UUID, teamLead sessionID: UUID, in ruleID: UUID) {
        guard rules[ruleID] != nil else { return }
        rules[ruleID]?.countedTLs.insert(sessionID)
        rules[ruleID]?.ruleGrants.insert(scopeID)
    }

    mutating func exclude(_ sessionID: UUID) {
        exclusions.insert(sessionID)
    }

    mutating func removeExclusion(_ sessionID: UUID) {
        exclusions.remove(sessionID)
    }

    func isExcluded(_ sessionID: UUID) -> Bool {
        exclusions.contains(sessionID)
    }

    mutating func addNotice(_ notice: StandingRuleNotice) {
        notices[notice.id] = notice
    }

    mutating func dismissNotice(id: UUID) {
        notices[id] = nil
    }

    mutating func pruneNotices(where isEnded: (StandingRuleNotice) -> Bool) {
        notices = notices.filter { !isEnded($0.value) }
    }

    /// A transient not-live sample leaves the generation present, so only a missing or different
    /// generation latches `closedAt`; the latch is monotonic because generations only increase.
    mutating func evaluate(
        now: Date,
        starterGeneration: (UUID) -> UInt64?,
        isGrantLive: (UUID) -> Bool
    ) {
        for (id, rule) in rules where rule.closedAt == nil
            && starterGeneration(rule.starter.connectionID) != rule.starter.lifecycleGeneration
        {
            rules[id]?.closedAt = now
        }
        rules = rules.filter { _, rule in
            rule.effectiveState(now: now) == .active || rule.ruleGrants.contains(where: isGrantLive)
        }
    }
}
