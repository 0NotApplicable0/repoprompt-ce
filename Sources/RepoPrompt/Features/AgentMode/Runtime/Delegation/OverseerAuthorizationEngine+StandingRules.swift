import Foundation
import RepoPromptDomainRuntime

enum StandingRuleRefusal: Equatable {
    case ruleNotActive(StandingRuleEffectiveState)
    case otherKind
    case otherWorkspace
    case otherStarter
    case starterNotLive
    case excluded
    case deleted
    case capabilityOutsideSet
    case thresholdAboveCeiling
    case noExpiry
    case expiryPastRuleEnd
    case teamLeadCountFull
}

enum StandingRuleDecision: Equatable {
    case settle
    case refuse(StandingRuleRefusal)
}

extension OverseerAuthorizationEngine {
    static func standingRuleDecision(
        rule: DelegationStandingRule,
        request: DelegationScopeRequest,
        facts: StandingRuleFacts,
        now: Date,
        isStarterLive: Bool,
        isExcluded: Bool,
        isDeleted: Bool
    ) -> StandingRuleDecision {
        let state = rule.effectiveState(now: now)
        guard state == .active else { return .refuse(.ruleNotActive(state)) }
        guard case let .directChildren(_, requestWorkspaceID) = request.kind else { return .refuse(.otherKind) }
        guard requestWorkspaceID == rule.workspaceID, facts.workspaceID == rule.workspaceID else {
            return .refuse(.otherWorkspace)
        }
        guard facts.starter == rule.starter else { return .refuse(.otherStarter) }
        guard isStarterLive else { return .refuse(.starterNotLive) }
        guard !isExcluded else { return .refuse(.excluded) }
        guard !isDeleted else { return .refuse(.deleted) }
        guard request.capabilities.isSubset(of: DomainDelegationScopeCapability.directChildrenPermitted) else {
            return .refuse(.capabilityOutsideSet)
        }
        guard request.guardrails.bulkConfirmationThreshold <= rule.bulkThresholdCeiling else {
            return .refuse(.thresholdAboveCeiling)
        }
        guard let expiresInSeconds = request.expiresInSeconds else { return .refuse(.noExpiry) }
        guard now.addingTimeInterval(TimeInterval(expiresInSeconds)) <= rule.expiresAt else {
            return .refuse(.expiryPastRuleEnd)
        }
        guard rule.countedTLs.contains(request.requesterSessionID)
            || rule.countedTLs.count < rule.maxTeamLeads
        else { return .refuse(.teamLeadCountFull) }
        return .settle
    }
}
