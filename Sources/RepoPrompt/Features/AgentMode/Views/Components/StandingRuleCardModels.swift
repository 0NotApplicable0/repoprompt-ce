import Foundation
import RepoPromptDomainRuntime

struct StandingRuleCardModel: Equatable {
    static let durationChoices: [TimeInterval] = [4, 8, 24].map { TimeInterval($0) * 60 * 60 }
    static let teamLeadChoices = [5, 10, 25, 50]
    static let selfDeclaredLabelCharacterLimit = 80
    static let unknownClientLabel = "an MCP client"

    static func displayClientLabel(_ declared: String?) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: (declared ?? "").unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
                && $0.properties.generalCategory != .lineSeparator && $0.properties.generalCategory != .paragraphSeparator
        })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? unknownClientLabel : cleaned).prefix(selfDeclaredLabelCharacterLimit))
    }

    var offer: StandingRuleOffer
    var isSelected = false
    var duration: TimeInterval = StandingRuleOptions.defaultDuration
    var maxTeamLeads = StandingRuleOptions.defaultTeamLeads
    var bulkThreshold: Int

    /// The retained card keeps only the human's choices; offer metadata follows the current offer.
    func presenting(_ current: StandingRuleOffer?) -> StandingRuleCardModel {
        var shown = self
        if let current { shown.offer = current }
        return shown
    }

    var checkboxLabel: String {
        offer.replacesExisting
            ? "Replace the standing rule for this connection"
            : "Also approve direct-child requests from other team leads this MCP connection starts in this workspace"
    }

    var effectiveBulkThreshold: Int {
        min(max(bulkThreshold, 1), StandingRuleOptions.maximumBulkThresholdCeiling)
    }

    static func durationTitle(_ duration: TimeInterval) -> String {
        "\(Int(duration / 3600)) h"
    }

    static func timeText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    func disclosure(now: Date) -> String {
        let label = Self.displayClientLabel(offer.clientLabel)
        let end = Self.timeText(now.addingTimeInterval(duration))
        return "Started by “\(label)” (connection \(offer.connectionPrefix); the name is self-declared). "
            + "Applies only while this connection stays open, until \(end) or \(maxTeamLeads) team leads including this one. "
            + "Bulk changes over \(effectiveBulkThreshold) items still ask you. "
            + "A request is approved automatically only if its whole requested lifetime ends before the rule does. "
            + "Grants it issues behave like grants you approve here, including after restart, until they expire. "
            + "Existing parent-session controls and already-started work are separate."
    }

    enum GrantRoute: Equatable {
        case plain
        case withRule(StandingRuleOptions)
    }

    /// The ticked box is the human's intent and is forwarded even if the offer has since gone, so the
    /// runtime's own fresh checks decide whether a rule is created and name the cause when not.
    static func grantRoute(
        model: StandingRuleCardModel?,
        selectedCapabilities: Set<DomainDelegationScopeCapability>,
        canApproveWithRule: Bool
    ) -> GrantRoute {
        guard canApproveWithRule, let options = model?.options(selectedCapabilities: selectedCapabilities) else {
            return .plain
        }
        return .withRule(options)
    }

    /// Options reach the runtime only for a ticked box over the full permitted capability set.
    func options(selectedCapabilities: Set<DomainDelegationScopeCapability>) -> StandingRuleOptions? {
        guard isSelected, selectedCapabilities == DomainDelegationScopeCapability.directChildrenPermitted else { return nil }
        return StandingRuleOptions(duration: duration, maxTeamLeads: maxTeamLeads)
    }
}

struct ActiveStandingRuleRowModel: Equatable, Identifiable {
    static let settledSuffix = " · settled by standing rule"
    static let fullAccessNote = "Overseer full access does not affect this rule."

    let id: UUID
    let title: String
    let detail: String
    let asOf: String
    let stopTitle = "Stop rule"
    let revokeCount: Int
    let revokeTitle: String?
    let canStop: Bool
    let actions: [Action]

    struct Action: Equatable {
        let title: String
        let revokesIssuedGrants: Bool
    }

    init(
        rule: DelegationStandingRule,
        workspaceName: String?,
        liveGrantIDs: Set<UUID>,
        connectionLive: Bool,
        now: Date
    ) {
        id = rule.id
        let state = rule.effectiveState(now: now)
        let prefix = String(rule.starter.connectionID.uuidString.prefix(8))
        let workspace = workspaceName ?? String(rule.workspaceID.uuidString.prefix(8))
        title = "Standing rule — direct-child delegation for team leads started by “\(StandingRuleCardModel.displayClientLabel(rule.clientLabel))” "
            + "(connection \(prefix)) in “\(workspace)”"
        let capabilities = DomainDelegationScopeCapability.allCases
            .filter(DomainDelegationScopeCapability.directChildrenPermitted.contains)
            .map(\.rawValue)
            .joined(separator: " · ")
        let connection = if rule.closedAt != nil {
            "connection closed"
        } else if connectionLive {
            "connection open"
        } else {
            "connection unavailable"
        }
        detail = "\(capabilities) — grants end no later than \(StandingRuleCardModel.timeText(rule.expiresAt)) — "
            + "\(rule.countedTLs.count) of \(rule.maxTeamLeads) team leads — \(connection) — \(Self.stateText(state))"
        asOf = "as of \(now.formatted(date: .omitted, time: .standard))"
        revokeCount = rule.ruleGrants.intersection(liveGrantIDs).count
        revokeTitle = revokeCount > 0 ? "Stop rule and revoke \(revokeCount) grants" : nil
        canStop = state == .active
        actions = (canStop ? [Action(title: stopTitle, revokesIssuedGrants: false)] : [])
            + (revokeTitle.map { [Action(title: $0, revokesIssuedGrants: true)] } ?? [])
    }

    func perform(_ action: Action, stopRule: (UUID, Bool) -> Void) {
        stopRule(id, action.revokesIssuedGrants)
    }

    static func stateText(_ state: StandingRuleEffectiveState) -> String {
        switch state {
        case .active: "active"
        case .stopped: "stopped"
        case .replaced: "replaced"
        case .expired: "expired"
        case .connectionClosed: "ended: connection closed"
        }
    }

    static func isVisible(rule: DelegationStandingRule, liveGrantIDs: Set<UUID>, now: Date) -> Bool {
        rule.effectiveState(now: now) == .active || !rule.ruleGrants.isDisjoint(with: liveGrantIDs)
    }

    static func grantSuffix(scopeID: UUID, rules: [DelegationStandingRule]) -> String {
        rules.contains { $0.ruleGrants.contains(scopeID) } ? settledSuffix : ""
    }
}

extension StandingRuleNotice {
    var message: String {
        let reason = switch cause {
        case .connectionClosed: "the MCP connection that started this team lead is no longer open"
        case .noStamp: "this team lead was not freshly started by an open MCP connection"
        case .requestChanged: "the request changed before Grant"
        }
        return "The standing rule was not created: \(reason). The team lead's own request was approved."
    }
}
