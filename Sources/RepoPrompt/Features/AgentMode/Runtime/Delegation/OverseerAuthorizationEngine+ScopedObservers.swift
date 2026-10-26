import Foundation
import RepoPromptDomainRuntime

/// The engine's standing for one controller endpoint under a live `direct_children` grant.
///
/// `awaitingReproof` authorizes nothing: it only tells the endpoint resolver to classify the observer
/// as transiently unavailable so saved link intent is kept while the controller loads or rebinds.
enum ScopedObserverStanding: Equatable {
    case authorized(DomainDelegationScopedObserverEvidence)
    case awaitingReproof(DomainDelegationScopedObserverEvidence)
    case denied
}

struct ScopedObserverControllerFacts {
    let windowMatchesEndpoint: Bool
    let windowIsClosing: Bool
    let hasExactCurrentEndpoint: Bool
    let hasSession: Bool
    let contextSessionMatchesEndpoint: Bool
    let hasMCPControlContext: Bool
    let isMCPOriginated: Bool
    let startedBy: StarterConnectionStamp?
    let parentSessionID: UUID?
    let createdByOverseerSessionID: UUID?
    let taskLabelIsExplore: Bool
    let isDeletionInProgress: Bool
    let isDeletionCommitted: Bool
    let hasLoadedPersistedState: Bool
    let bindingTransitionInProgress: Bool
    let candidateHasLoadedPersistedState: Bool?
    let candidateHasDurableBinding: Bool
    let candidateIsClosing: Bool
    let candidateIsDeletionInProgress: Bool

    init(
        windowMatchesEndpoint: Bool, windowIsClosing: Bool, hasExactCurrentEndpoint: Bool,
        hasSession: Bool, contextSessionMatchesEndpoint: Bool, hasMCPControlContext: Bool,
        isMCPOriginated: Bool, startedBy: StarterConnectionStamp? = nil,
        parentSessionID: UUID?, createdByOverseerSessionID: UUID?, taskLabelIsExplore: Bool,
        isDeletionInProgress: Bool, isDeletionCommitted: Bool, hasLoadedPersistedState: Bool,
        bindingTransitionInProgress: Bool, candidateHasLoadedPersistedState: Bool?,
        candidateHasDurableBinding: Bool, candidateIsClosing: Bool, candidateIsDeletionInProgress: Bool
    ) {
        self.windowMatchesEndpoint = windowMatchesEndpoint
        self.windowIsClosing = windowIsClosing
        self.hasExactCurrentEndpoint = hasExactCurrentEndpoint
        self.hasSession = hasSession
        self.contextSessionMatchesEndpoint = contextSessionMatchesEndpoint
        self.hasMCPControlContext = hasMCPControlContext
        self.isMCPOriginated = isMCPOriginated
        self.startedBy = startedBy
        self.parentSessionID = parentSessionID
        self.createdByOverseerSessionID = createdByOverseerSessionID
        self.taskLabelIsExplore = taskLabelIsExplore
        self.isDeletionInProgress = isDeletionInProgress
        self.isDeletionCommitted = isDeletionCommitted
        self.hasLoadedPersistedState = hasLoadedPersistedState
        self.bindingTransitionInProgress = bindingTransitionInProgress
        self.candidateHasLoadedPersistedState = candidateHasLoadedPersistedState
        self.candidateHasDurableBinding = candidateHasDurableBinding
        self.candidateIsClosing = candidateIsClosing
        self.candidateIsDeletionInProgress = candidateIsDeletionInProgress
    }
}

extension OverseerAuthorizationEngine {
    static func admitsDirectChildrenConsentRequest(
        endpoint: DomainAgentSessionLinkEndpointIdentity, facts: ScopedObserverControllerFacts
    ) -> Bool {
        facts.windowMatchesEndpoint && !facts.windowIsClosing
            && endpoint.hasResolvedPersistentBinding
            && facts.hasExactCurrentEndpoint
            && facts.hasSession
            && facts.contextSessionMatchesEndpoint
            && facts.parentSessionID == nil
            && facts.createdByOverseerSessionID == nil
            && !facts.taskLabelIsExplore
            && !facts.isDeletionInProgress
            && !facts.isDeletionCommitted
    }

    // MARK: - Consent-only route policy

    /// Which calls a supported controller may make while it holds no independent live grant: its own
    /// `direct_children` request, inspection or release of its own grants and request, and `link` /
    /// `unlink` under an explicit full-capability grant. The service projects arguments and receipts;
    /// this decision stays here.
    func admitsScopeLifecycleCall(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        isController: Bool,
        op: String,
        requestsDirectChildren: Bool,
        hasScopeID: Bool,
        requestID: UUID?,
        scopeID: UUID? = nil,
        observerStanding: ScopedObserverStanding = .denied
    ) -> Bool {
        guard let scopes else { return !isController }
        let live = scopes.liveScopes(grantedTo: endpoint.sessionID)
        if !isController {
            return !live.contains { if case .directChildren = $0.grant.kind { return true }
                return false
            }
                || live.contains { if case .directChildren = $0.grant.kind { return false }
                    return true
                }
        }
        if scopes.liveScopes(grantedTo: endpoint.sessionID).contains(where: {
            if case .directChildren = $0.grant.kind { return false }
            return true
        }) { return true }
        let own = live.filter { isOwnDirectChildrenGrant($0, endpoint: endpoint) }
        switch op {
        case "request_scope" where requestsDirectChildren:
            return true
        case "link", "unlink":
            guard hasScopeID, let scopeID, case .authorized = observerStanding else { return false }
            return live.contains { $0.id == scopeID && coversScopedObserver($0, endpoint: endpoint, at: scopes.currentDate) }
        case "scope_status", "release_scope":
            if hasScopeID { return scopeID.map { id in own.contains { $0.id == id } } ?? false }
            if op == "scope_status", requestID == nil { return !own.isEmpty }
            guard let requestID,
                  let request = scopes.request(id: requestID, requesterSessionID: endpoint.sessionID),
                  request.kind == .directChildren(rootSessionID: endpoint.sessionID, workspaceID: endpoint.workspaceID)
            else { return false }
            return true
        default:
            return false
        }
    }

    // MARK: - Qualified controller route

    /// A `direct_children` scope held by a controller with no independent ordinary live grant. Overseer
    /// full access never substitutes for, widens, or waives any gate on it.
    func isQualifiedControllerScope(_ record: DomainDelegationScopeRecord) -> Bool {
        guard let scopes, case .directChildren = record.grant.kind else { return false }
        return !scopes.liveScopes(grantedTo: record.grant.granteeSessionID).contains {
            if case .directChildren = $0.grant.kind { return false }
            return true
        }
    }

    /// The grantee of a `direct_children` scope may observe links under it without being its member.
    func permitsLinkObserver(
        _ sessionID: UUID, ofChainFrom scope: DomainDelegationScopeRecord, projector: any DelegationMembershipProjector
    ) -> Bool {
        if case let .directChildren(root, _) = scope.grant.kind, sessionID == root, root == scope.grant.granteeSessionID,
           let scopes
        {
            let chain = scopes.scopeChain(from: scope.id)
            if !chain.isEmpty, chain.allSatisfy(\.isActive) { return true }
        }
        return permitsMember(sessionID, ofChainFrom: scope, projector: projector)
    }

    /// An existing link sourced by another scope is reported, never re-sourced or upgraded.
    func linkSourceConflicts(existing: UUID?, requested: UUID?) -> Bool {
        existing != requested
    }

    private func isOwnDirectChildrenGrant(_ record: DomainDelegationScopeRecord, endpoint: DomainAgentSessionLinkEndpointIdentity) -> Bool {
        guard case let .directChildren(root, workspaceID) = record.grant.kind else { return false }
        return record.grant.granteeSessionID == endpoint.sessionID && root == endpoint.sessionID && workspaceID == endpoint.workspaceID
    }

    // MARK: - Scoped observer evidence

    /// A live, unexpired, full-capability `direct_children` grant rooted at this exact endpoint.
    private func coversScopedObserver(
        _ record: DomainDelegationScopeRecord, endpoint: DomainAgentSessionLinkEndpointIdentity, at date: Date
    ) -> Bool {
        guard record.isActive, record.grant.granteeSessionID == endpoint.sessionID,
              case let .directChildren(root, workspaceID) = record.grant.kind,
              root == endpoint.sessionID, workspaceID == endpoint.workspaceID,
              record.grant.capabilities.isSuperset(of: DomainDelegationScopeCapability.directChildrenPermitted),
              record.grant.guardrails.expiresAt.map({ $0 > date }) ?? true else { return false }
        return true
    }

    /// The supported-controller shape without its exact-endpoint or readiness proof (those are checked
    /// separately so a loading controller can be told apart from an unsupported one).
    private func hasSupportedControllerShape(
        _ facts: ScopedObserverControllerFacts, endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard endpoint.hasResolvedPersistentBinding,
              facts.hasSession,
              facts.parentSessionID == nil,
              facts.createdByOverseerSessionID == nil,
              !facts.isDeletionCommitted
        else { return false }
        if facts.hasMCPControlContext {
            return facts.contextSessionMatchesEndpoint && !facts.taskLabelIsExplore
        }
        return facts.isMCPOriginated
    }

    /// Fresh scope + current controller + exact endpoint. Issued only here and only from facts the app
    /// owns: no caller-supplied role, title, brief, or root proof is read.
    func scopedObserverAuthorization(
        for endpoint: DomainAgentSessionLinkEndpointIdentity, facts: ScopedObserverControllerFacts
    ) -> ScopedObserverStanding {
        guard let scopes, !facts.windowIsClosing, facts.windowMatchesEndpoint else { return .denied }
        let date = scopes.currentDate
        guard let record = scopes.liveScopes(grantedTo: endpoint.sessionID)
            .filter({ coversScopedObserver($0, endpoint: endpoint, at: date) })
            .max(by: { ($0.grant.grantedAt, $0.id.uuidString) < ($1.grant.grantedAt, $1.id.uuidString) }),
            hasSupportedControllerShape(facts, endpoint: endpoint)
        else { return .denied }
        func evidence(_ status: DomainDelegationScopedObserverEvidence.Status) -> DomainDelegationScopedObserverEvidence {
            DomainDelegationScopedObserverEvidence(
                scopeID: record.id, scopeGeneration: record.generation, observer: endpoint, status: status
            )
        }
        let candidateLoading = facts.candidateHasLoadedPersistedState.map { !$0 } ?? false
        let loading = !facts.hasMCPControlContext || !facts.hasLoadedPersistedState
            || facts.bindingTransitionInProgress || candidateLoading
            || facts.isDeletionInProgress || facts.candidateIsDeletionInProgress
        if loading { return .awaitingReproof(evidence(.awaitingReproof)) }
        guard Self.admitsDirectChildrenConsentRequest(endpoint: endpoint, facts: facts),
              facts.candidateHasDurableBinding,
              !facts.candidateIsClosing
        else { return .denied }
        return .authorized(evidence(.authorized))
    }

    func scopedSourceMatches(_ scopeID: UUID, evidence: DomainDelegationScopedObserverEvidence) -> Bool {
        guard let scopes, let source = scopes.record(id: scopeID),
              let standingSource = scopes.record(id: evidence.scopeID), standingSource.generation == evidence.scopeGeneration,
              coversScopedObserver(standingSource, endpoint: evidence.observer, at: scopes.currentDate) else { return false }
        return coversScopedObserver(source, endpoint: evidence.observer, at: scopes.currentDate)
    }

    /// Whether the host's own read of this target already proves a permanent loss of membership,
    /// independent of the observer's standing: a pending observer must never mask it. Deletion in
    /// progress can still fail, so only a committed deletion is permanent.
    func scopedTargetIsPermanentlyOutside(
        _ scopeID: UUID, target: AgentSessionLinkEndpointCandidate,
        deletionCommitted: Bool? = nil
    ) -> Bool {
        guard let scopes, let record = scopes.record(id: scopeID),
              case let .directChildren(root, workspaceID) = record.grant.kind else { return false }
        return target.workspaceID != workspaceID || target.sessionID == root || target.parentSessionID != root
            || target.isClosing
            || deletionCommitted ?? AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: target.sessionID)
    }

    /// Issues the per-target endorsement for one exact direct child, or `nil`. Membership comes from the
    /// real projector over fresh provenance; the target candidate is the host's own current read of that
    /// exact endpoint, and its parent must agree with the projector.
    func authorizeScopedObserverLink(
        observer: DomainAgentSessionLinkEndpointIdentity,
        observerFacts: ScopedObserverControllerFacts,
        target: AgentSessionLinkEndpointCandidate,
        scopeID: UUID,
        projector: any DelegationMembershipProjector
    ) -> DomainDelegationScopeDirectChildEndorsement? {
        guard let scopes, let record = scopes.record(id: scopeID),
              coversScopedObserver(record, endpoint: observer, at: scopes.currentDate),
              case .authorized = scopedObserverAuthorization(for: observer, facts: observerFacts),
              case let .directChildren(root, workspaceID) = record.grant.kind,
              target.workspaceID == workspaceID, target.sessionID != observer.sessionID,
              target.parentSessionID == root,
              AgentSessionLinkEndpointEligibility.targetResolveFailure(
                  for: target, observerSessionID: observer.sessionID, permitsChildTarget: true
              ) == nil,
              projector.withSynchronousTargets([target.sessionID], { $0.membershipProof(for: target.sessionID, in: record.grant) })?.basis
              == .directChild(rootSessionID: root, workspaceID: workspaceID)
        else { return nil }
        let endorsement = DomainDelegationScopeDirectChildEndorsement(
            scopeID: record.id, scopeGeneration: record.generation, observer: observer, target: target.domainEndpoint
        )
        return scopes.linkConsent.endorse(endorsement, at: scopes.currentDate) ? endorsement : nil
    }
}
