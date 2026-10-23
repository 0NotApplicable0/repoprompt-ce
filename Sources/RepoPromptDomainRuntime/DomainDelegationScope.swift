import Foundation

// Delegation scopes: durable, user-granted authority for one overseer Agent session to act on many
// sessions without per-item prompts.
//
// A scope sits **beside** oversight links rather than replacing them. Links stay a per-pair transport
// (cursors, passive notices, Auto-wake); a scope is the authority to act across its members. Scope
// authority is an *input* to the existing owners (link authority, passive reducer, claim/receipt,
// wake coordinator); it never takes their ownership. See
// `docs/architecture/agent-session-oversight-auto-wake.md`, "Delegation scopes".
//
// Everything in this file is AppKit-free value vocabulary. Decisions live in
// `DomainDelegationScopeAuthority` and `DomainAgentSessionOperationAuthorizer`.

// MARK: - Capabilities

/// One delegable capability. The set is closed: anything not representable here is human-only.
package enum DomainDelegationScopeCapability: String, CaseIterable, Codable, Hashable {
    /// Inventory, search, poll/wait/read across members.
    case observe
    /// Rename, pin/unpin/reorder, group, archive/unarchive.
    case organize
    /// Send, steer, respond, stop, compact, set model/effort.
    case control
    /// Link/unlink among members, re-parent within scope, release.
    case restructure
    /// Start sessions and lanes, fork, and create nested overseers with attenuated sub-scopes.
    case spawn
    /// Create/bind/unbind/release worktrees for members and merge preview.
    case worktree
    /// **Reserved flag.** No operation requires this capability. Deleting sessions and removing
    /// worktrees are human-only, so nothing grantable is destructive in the deletion sense; the
    /// operations that always force a batch confirmation card (`retire`, `worktree_release`) do so
    /// through `DomainDelegationScopeConfirmationClass.alwaysCarded`, regardless of whether this
    /// flag is held. Kept so presets and persisted grants remain stable.
    case destructive

    /// The only capabilities an `.allSessions` scope may hold (design §6 default 2).
    package static let allSessionsPermitted: Set<Self> = [.observe, .organize, .restructure]
    /// The only capabilities a `.directChildren` scope may hold, with or without `unrestricted`.
    package static let directChildrenPermitted: Set<Self> = [.observe, .control, .restructure]

    /// "Manage this tree": everything except `destructive`.
    package static let manageTreePreset: Set<Self> = Set(allCases).subtracting([.destructive])
    /// "Organize everything" (`.allSessions`).
    package static let organizeEverythingPreset: Set<Self> = allSessionsPermitted
    /// "Full".
    package static let fullPreset: Set<Self> = Set(allCases)
}

/// Actions that are never grantable through any scope, preset, or attenuation.
///
/// None of these maps to a `DomainDelegationScopeCapability`, so no scope can carry them. The
/// operation authorizer additionally refuses the scope basis for the existing operations that
/// perform them (for example `agent_manage.cleanup_sessions`, which deletes sessions).
package enum DomainDelegationScopeHumanOnlyAction: String, CaseIterable, Hashable {
    case deleteSession = "delete_session"
    case removeWorktree = "remove_worktree"
    case pruneWorktree = "prune_worktree"
    case apiKeysAndProviders = "api_keys_and_providers"
    case providerPermissionModes = "provider_permission_modes"
    case mcpClientApprovals = "mcp_client_approvals"
    case mcpServerControl = "mcp_server_control"
    case appSettingsWrites = "app_settings_writes"
    case appQuitOrUpdate = "app_quit_or_update"
    /// The Agent Mode handoff-instructions *setting*. Reading a session's handoff transcript
    /// (`agent_manage.extract_handoff`) is an ordinary `observe` read, not this action.
    case handoffInstructions = "handoff_instructions"

    /// Always false. Present so call sites and tests state the rule rather than imply it.
    package var isGrantable: Bool {
        false
    }
}

/// Read-only, process-local input to link authorization. The app's decision owner publishes its
/// live grants synchronously; storage is never consulted here. Missing/expired consent fails closed.
///
/// `directChildren` is never covered by a UUID: it needs an endpoint-qualified permit backed by an
/// endorsement the app's single authorization owner issued against the current record generation.
package final class DomainDelegationScopeLinkConsent: @unchecked Sendable {
    private static let required: Set<DomainDelegationScopeCapability> = [.observe, .control, .restructure]

    private let lock = NSLock()
    private var grants: [UUID: DomainDelegationScopeGrant] = [:]
    /// Generations of the records last published. Absent for grants installed through `replace`.
    private var generations: [UUID: UInt64] = [:]
    private var endorsements: Set<DomainDelegationScopeDirectChildEndorsement> = []

    package init() {}

    /// Raw grants without generations: legacy `session`/`allSessions` consent only. Drops every endorsement.
    package func replace(_ grants: [DomainDelegationScopeGrant]) {
        lock.withLock {
            self.grants = Dictionary(uniqueKeysWithValues: grants.map { ($0.id, $0) })
            generations = [:]
            endorsements = []
        }
    }

    /// Publishes the current live records. Only active records count; any endorsement whose scope
    /// is absent or whose generation differs is dropped before this returns.
    package func publish(_ records: [DomainDelegationScopeRecord]) {
        lock.withLock {
            let active = records.filter(\.isActive)
            grants = Dictionary(active.map { ($0.id, $0.grant) }, uniquingKeysWith: { _, new in new })
            generations = Dictionary(active.map { ($0.id, $0.generation) }, uniquingKeysWith: { _, new in new })
            endorsements = endorsements.filter { generations[$0.scopeID] == $0.scopeGeneration }
        }
    }

    /// Records an endorsement only if it names the current record and fits its exact kind. The
    /// issuer is the app's authorization engine; membership is its decision, not checked here.
    package func endorse(_ endorsement: DomainDelegationScopeDirectChildEndorsement, at date: Date) -> Bool {
        lock.withLock {
            guard Self.endorsable(endorsement, grants: grants, generations: generations, at: date) else { return false }
            endorsements.insert(endorsement)
            return true
        }
    }

    package func invalidateEndorsements(scopeID: UUID) {
        lock.withLock { endorsements = endorsements.filter { $0.scopeID != scopeID } }
    }

    package func invalidateEndorsements(endpoint: DomainAgentSessionLinkEndpointIdentity) {
        lock.withLock { endorsements = endorsements.filter { $0.observer != endpoint && $0.target != endpoint } }
    }

    package func invalidateEndorsements(sessionID: UUID) {
        lock.withLock {
            endorsements = endorsements.filter { $0.observer.sessionID != sessionID && $0.target.sessionID != sessionID }
        }
    }

    package func invalidateAllEndorsements() {
        lock.withLock { endorsements = [] }
    }

    package func permits(scopeID: UUID, observer: UUID, target: UUID, at date: Date) -> Bool {
        guard let grant = lock.withLock({ grants[scopeID] }), grant.granteeSessionID == observer,
              grant.capabilities.isSuperset(of: Self.required),
              grant.guardrails.expiresAt.map({ $0 > date }) ?? true else { return false }
        switch grant.kind {
        case let .session(approvedTarget): return approvedTarget == target
        case .allSessions: return grant.unrestricted
        case .tree, .workspace, .directChildren: return false
        }
    }

    /// Endpoint-qualified permit. `session`/`allSessions` keep their UUID semantics; `directChildren`
    /// additionally needs the current endorsement for these exact endpoints.
    package func permits(
        scopeID: UUID,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity,
        at date: Date
    ) -> Bool {
        let state = lock.withLock { (grants[scopeID], generations[scopeID], endorsements) }
        guard let grant = state.0, case .directChildren = grant.kind else {
            return permits(scopeID: scopeID, observer: observer.sessionID, target: target.sessionID, at: date)
        }
        guard let generation = state.1 else { return false }
        return state.2.contains(DomainDelegationScopeDirectChildEndorsement(
            scopeID: scopeID, scopeGeneration: generation, observer: observer, target: target
        )) && Self.endorsable(
            DomainDelegationScopeDirectChildEndorsement(scopeID: scopeID, scopeGeneration: generation, observer: observer, target: target),
            grants: [scopeID: grant], generations: [scopeID: generation], at: date
        )
    }

    private static func endorsable(
        _ endorsement: DomainDelegationScopeDirectChildEndorsement,
        grants: [UUID: DomainDelegationScopeGrant],
        generations: [UUID: UInt64],
        at date: Date
    ) -> Bool {
        guard let grant = grants[endorsement.scopeID], generations[endorsement.scopeID] == endorsement.scopeGeneration,
              case let .directChildren(root, workspaceID) = grant.kind,
              root == grant.granteeSessionID, root == endorsement.observer.sessionID,
              endorsement.observer.workspaceID == workspaceID, endorsement.target.workspaceID == workspaceID,
              endorsement.target.sessionID != endorsement.observer.sessionID,
              endorsement.observer.hasResolvedPersistentBinding, endorsement.target.hasResolvedPersistentBinding,
              grant.capabilities.isSuperset(of: required),
              grant.guardrails.expiresAt.map({ $0 > date }) ?? true else { return false }
        return true
    }
}

/// Process-local proof that the app's authorization engine found one exact target a direct child of
/// one exact controller endpoint under one scope generation. Constructed only by that engine (tests
/// build fixtures); never persisted. `DomainDelegationScopeLinkConsent` is the only consumer.
package struct DomainDelegationScopeDirectChildEndorsement: Hashable {
    package let scopeID: UUID
    package let scopeGeneration: UInt64
    package let observer: DomainAgentSessionLinkEndpointIdentity
    package let target: DomainAgentSessionLinkEndpointIdentity

    package init(
        scopeID: UUID, scopeGeneration: UInt64,
        observer: DomainAgentSessionLinkEndpointIdentity, target: DomainAgentSessionLinkEndpointIdentity
    ) {
        self.scopeID = scopeID
        self.scopeGeneration = scopeGeneration
        self.observer = observer
        self.target = target
    }
}

/// Engine-issued, endpoint- and generation-qualified evidence about one scoped observer. It lifts
/// only the MCP-observer role exclusion in the endpoint resolver; `awaitingReproof` authorizes nothing.
package struct DomainDelegationScopedObserverEvidence: Hashable {
    package enum Status: Hashable {
        case authorized
        /// A live matching grant on a supported controller that is transiently loading or rebinding.
        case awaitingReproof
    }

    package let scopeID: UUID
    package let scopeGeneration: UInt64
    package let observer: DomainAgentSessionLinkEndpointIdentity
    package let status: Status

    package init(scopeID: UUID, scopeGeneration: UInt64, observer: DomainAgentSessionLinkEndpointIdentity, status: Status) {
        self.scopeID = scopeID
        self.scopeGeneration = scopeGeneration
        self.observer = observer
        self.status = status
    }
}

// MARK: - Target state

/// App-presented run state of one target, for operations whose requirement depends on it.
///
/// `unknown` is treated exactly like `running`, so an uncertain state can only demand more authority.
package enum DomainDelegationScopeTargetState: String, Hashable {
    /// Idle or finished: nothing to stop.
    case idle
    case running
    case unknown
}

// MARK: - Kind

/// What a scope covers. Membership is never taken from tool arguments; the app presents a
/// `DomainDelegationScopeMembershipProof` computed from persisted provenance.
package enum DomainDelegationScopeKind: Hashable {
    /// The grantee plus exactly one managed target; never its descendants or other workspace sessions.
    case session(targetSessionID: UUID)
    /// The root plus every session whose organizational parent chain reaches it.
    case tree(rootSessionID: UUID)
    /// Sessions the root spawned directly and still parents, in one workspace. Never the root itself.
    case directChildren(rootSessionID: UUID, workspaceID: UUID)
    /// Every session in one workspace.
    case workspace(workspaceID: UUID)
    /// Every session the user owns. Restricted to `allSessionsPermitted` capabilities.
    case allSessions

    package var label: String {
        switch self {
        case .session: "session"
        case .tree: "tree"
        case .directChildren: "direct_children"
        case .workspace: "workspace"
        case .allSessions: "all_sessions"
        }
    }
}

extension DomainDelegationScopeKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case rootSessionID = "root_session_id"
        case targetSessionID = "target_session_id"
        case workspaceID = "workspace_id"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "session":
            self = try .session(targetSessionID: container.decode(UUID.self, forKey: .targetSessionID))
        case "tree":
            self = try .tree(rootSessionID: container.decode(UUID.self, forKey: .rootSessionID))
        case "direct_children":
            self = try .directChildren(
                rootSessionID: container.decode(UUID.self, forKey: .rootSessionID),
                workspaceID: container.decode(UUID.self, forKey: .workspaceID)
            )
        case "workspace":
            self = try .workspace(workspaceID: container.decode(UUID.self, forKey: .workspaceID))
        case "all_sessions":
            self = .allSessions
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown delegation scope kind '\(other)'"
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .type)
        switch self {
        case let .session(targetSessionID):
            try container.encode(targetSessionID, forKey: .targetSessionID)
        case let .tree(rootSessionID):
            try container.encode(rootSessionID, forKey: .rootSessionID)
        case let .directChildren(rootSessionID, workspaceID):
            try container.encode(rootSessionID, forKey: .rootSessionID)
            try container.encode(workspaceID, forKey: .workspaceID)
        case let .workspace(workspaceID):
            try container.encode(workspaceID, forKey: .workspaceID)
        case .allSessions:
            break
        }
    }
}

// MARK: - Guardrails

/// User-chosen limits. `nil` means unlimited for that guardrail.
///
/// Limits count the **whole** subtree: a parent's `maxLiveSessions` includes every live member of
/// every nested overseer's sub-scope.
package struct DomainDelegationScopeGuardrails: Codable, Hashable {
    package static let defaultBulkConfirmationThreshold = 25

    package var maxLiveSessions: Int?
    package var maxDepth: Int?
    package var maxWorktrees: Int?
    package var expiresAt: Date?
    /// Reversible bulk operations affecting more items than this require a batch card.
    package var bulkConfirmationThreshold: Int

    package init(
        maxLiveSessions: Int? = nil,
        maxDepth: Int? = nil,
        maxWorktrees: Int? = nil,
        expiresAt: Date? = nil,
        bulkConfirmationThreshold: Int = DomainDelegationScopeGuardrails.defaultBulkConfirmationThreshold
    ) {
        self.maxLiveSessions = maxLiveSessions
        self.maxDepth = maxDepth
        self.maxWorktrees = maxWorktrees
        self.expiresAt = expiresAt
        self.bulkConfirmationThreshold = bulkConfirmationThreshold
    }

    private enum CodingKeys: String, CodingKey {
        case maxLiveSessions = "max_live_sessions"
        case maxDepth = "max_depth"
        case maxWorktrees = "max_worktrees"
        case expiresAt = "expires_at"
        case bulkConfirmationThreshold = "bulk_confirmation_threshold"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxLiveSessions = try container.decodeIfPresent(Int.self, forKey: .maxLiveSessions)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
        maxWorktrees = try container.decodeIfPresent(Int.self, forKey: .maxWorktrees)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        bulkConfirmationThreshold = try container.decodeIfPresent(Int.self, forKey: .bulkConfirmationThreshold)
            ?? Self.defaultBulkConfirmationThreshold
    }

    /// Structurally valid: every limit is non-negative and the card threshold is at least one.
    package var isWellFormed: Bool {
        [maxLiveSessions, maxDepth, maxWorktrees].allSatisfy { ($0 ?? 0) >= 0 }
            && bulkConfirmationThreshold >= 1
    }

    /// True when every limit is at least as strict as `parent`'s, and expiry is no later.
    ///
    /// An unlimited (`nil`) child limit is looser than any finite parent limit; an absent child
    /// expiry is later than any parent expiry.
    package func isNoLooserThan(_ parent: Self) -> Bool {
        func noLooser(_ child: Int?, _ parent: Int?) -> Bool {
            guard let parent else { return true }
            guard let child else { return false }
            return child <= parent
        }
        let expiryOK: Bool = {
            guard let parentExpiry = parent.expiresAt else { return true }
            guard let expiresAt else { return false }
            return expiresAt <= parentExpiry
        }()
        return noLooser(maxLiveSessions, parent.maxLiveSessions)
            && noLooser(maxDepth, parent.maxDepth)
            && noLooser(maxWorktrees, parent.maxWorktrees)
            && bulkConfirmationThreshold <= parent.bulkConfirmationThreshold
            && expiryOK
    }

    package func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Which guardrail a spawn or worktree operation exceeded.
package enum DomainDelegationScopeGuardrail: String, Codable, Hashable {
    case maxLiveSessions = "max_live_sessions"
    case maxDepth = "max_depth"
    case maxWorktrees = "max_worktrees"
}

// MARK: - Durable grant and live record

/// How a scope came to exist. Scopes are created only by the user or by attenuation.
package enum DomainDelegationScopeOrigin: Hashable {
    case user
    case attenuatedFrom(scopeID: UUID)

    package var parentScopeID: UUID? {
        guard case let .attenuatedFrom(scopeID) = self else { return nil }
        return scopeID
    }
}

extension DomainDelegationScopeOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case scopeID = "scope_id"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "user":
            self = .user
        case "attenuated":
            self = try .attenuatedFrom(scopeID: container.decode(UUID.self, forKey: .scopeID))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown delegation scope origin '\(other)'"
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .type)
        case let .attenuatedFrom(scopeID):
            try container.encode("attenuated", forKey: .type)
            try container.encode(scopeID, forKey: .scopeID)
        }
    }
}

/// The durable intent of one scope. Carries no generation: generations are process-local and a
/// launch reactivates every persisted grant under a fresh one.
package struct DomainDelegationScopeGrant: Codable, Hashable {
    package let id: UUID
    package let granteeSessionID: UUID
    package let kind: DomainDelegationScopeKind
    package let capabilities: Set<DomainDelegationScopeCapability>
    package let guardrails: DomainDelegationScopeGuardrails
    package let origin: DomainDelegationScopeOrigin
    package let grantedAt: Date
    /// Minted only by the user's global auto-approve (Overseer yolo) setting: every capability over
    /// every session, no `.allSessions` capability restriction, and no confirmation cards. Grants
    /// saved before this flag existed decode as restricted.
    package let unrestricted: Bool

    package init(
        id: UUID,
        granteeSessionID: UUID,
        kind: DomainDelegationScopeKind,
        capabilities: Set<DomainDelegationScopeCapability>,
        guardrails: DomainDelegationScopeGuardrails,
        origin: DomainDelegationScopeOrigin,
        grantedAt: Date,
        unrestricted: Bool = false
    ) {
        self.id = id
        self.granteeSessionID = granteeSessionID
        self.kind = kind
        self.capabilities = capabilities
        self.guardrails = guardrails
        self.origin = origin
        self.grantedAt = grantedAt
        self.unrestricted = unrestricted
    }

    package var parentScopeID: UUID? {
        origin.parentScopeID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case granteeSessionID = "grantee_session_id"
        case kind
        case capabilities
        case guardrails
        case origin
        case grantedAt = "granted_at"
        case unrestricted
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        granteeSessionID = try container.decode(UUID.self, forKey: .granteeSessionID)
        kind = try container.decode(DomainDelegationScopeKind.self, forKey: .kind)
        // Unknown capability strings fail the whole row rather than silently narrowing it, so a
        // newer file can never be half-understood into a different grant.
        capabilities = try Set(container.decode([DomainDelegationScopeCapability].self, forKey: .capabilities))
        guardrails = try container.decode(DomainDelegationScopeGuardrails.self, forKey: .guardrails)
        origin = try container.decode(DomainDelegationScopeOrigin.self, forKey: .origin)
        grantedAt = try container.decode(Date.self, forKey: .grantedAt)
        unrestricted = try container.decodeIfPresent(Bool.self, forKey: .unrestricted) ?? false
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(granteeSessionID, forKey: .granteeSessionID)
        try container.encode(kind, forKey: .kind)
        try container.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
        try container.encode(guardrails, forKey: .guardrails)
        try container.encode(origin, forKey: .origin)
        try container.encode(grantedAt, forKey: .grantedAt)
        if unrestricted { try container.encode(true, forKey: .unrestricted) }
    }
}

/// Lifecycle of a live scope record.
package enum DomainDelegationScopeState: String, Hashable {
    case active
    /// Revoked by the user, released by its grantee, or cascaded from a revoked ancestor.
    case revoked
    case expired
}

/// One scope as the authority currently holds it.
package struct DomainDelegationScopeRecord: Hashable {
    package let grant: DomainDelegationScopeGrant
    /// Bumped on every state change. A presented generation that differs is stale.
    package let generation: UInt64
    package let state: DomainDelegationScopeState

    package init(grant: DomainDelegationScopeGrant, generation: UInt64, state: DomainDelegationScopeState) {
        self.grant = grant
        self.generation = generation
        self.state = state
    }

    package var id: UUID {
        grant.id
    }

    package var isActive: Bool {
        state == .active
    }
}

// MARK: - Membership and usage proofs

/// App-presented evidence that one target belongs to one scope.
///
/// The app projects it from persisted provenance (`parentSessionID`, `createdByOverseerSessionID`,
/// and later `organizationalParentID`) exactly as link leases are presented today. It is never
/// constructed from tool arguments.
package struct DomainDelegationScopeMembershipProof: Hashable {
    package enum Basis: Hashable {
        /// A uniquely resolved app-owned identity in an exact-target grant.
        case exactSession
        /// Organizational chain from the target (first) up to the tree root (last), inclusive.
        case treePath([UUID])
        /// Built only by the projector from fresh provenance: spawned by the root, currently placed
        /// under it, and in the workspace.
        case directChild(rootSessionID: UUID, workspaceID: UUID)
        /// The workspace the target currently belongs to.
        case workspace(UUID)
        /// The target is a session the user owns.
        case allSessions
    }

    package let scopeID: UUID
    package let targetSessionID: UUID
    package let basis: Basis

    package init(scopeID: UUID, targetSessionID: UUID, basis: Basis) {
        self.scopeID = scopeID
        self.targetSessionID = targetSessionID
        self.basis = basis
    }

    /// Depth below the tree root (root = 0). `nil` for non-tree bases.
    package var treeDepth: Int? {
        guard case let .treePath(path) = basis, !path.isEmpty else { return nil }
        return path.count - 1
    }
}

/// App-measured usage of one scope (whole subtree), presented for spawn/worktree guardrails.
package struct DomainDelegationScopeUsage: Hashable {
    package let scopeID: UUID
    package let liveSessionCount: Int
    package let worktreeCount: Int
    /// Distinct identities already represented in `worktreeCount`, for in-flight binding deduplication.
    package let countedWorktreeIDs: Set<String>
    /// For session-creating operations: the depth of the new session's organizational parent within
    /// this scope's tree (root = 0). `nil` when the scope is not a tree or the op creates no session.
    package let spawnParentDepth: Int?

    package init(scopeID: UUID, liveSessionCount: Int, worktreeCount: Int, spawnParentDepth: Int? = nil, countedWorktreeIDs: Set<String> = []) {
        self.scopeID = scopeID
        self.liveSessionCount = liveSessionCount
        self.worktreeCount = worktreeCount
        self.countedWorktreeIDs = countedWorktreeIDs
        self.spawnParentDepth = spawnParentDepth
    }
}

/// A user-approved batch card, bound to the exact scope generation, operation, item set, key, and
/// operation arguments.
package struct DomainDelegationScopeConfirmation: Hashable {
    package let confirmationID: UUID
    package let scopeID: UUID
    package let scopeGeneration: UInt64
    package let operation: DomainAgentSessionTargetOperation
    package let idempotencyKey: String
    /// The items the user left ticked. A real call may act on these and nothing else.
    package let approvedSessionIDs: Set<UUID>
    /// `DomainDelegationScopeArgumentsDigest` of the arguments the card was raised for. The applying
    /// call must present the same digest, so changed arguments under the same key apply nothing.
    package let argumentsDigest: String

    package init(
        confirmationID: UUID,
        scopeID: UUID,
        scopeGeneration: UInt64,
        operation: DomainAgentSessionTargetOperation,
        idempotencyKey: String,
        approvedSessionIDs: Set<UUID>,
        argumentsDigest: String = ""
    ) {
        self.confirmationID = confirmationID
        self.scopeID = scopeID
        self.scopeGeneration = scopeGeneration
        self.operation = operation
        self.idempotencyKey = idempotencyKey
        self.approvedSessionIDs = approvedSessionIDs
        self.argumentsDigest = argumentsDigest
    }
}

// MARK: - Lease

/// Proof issued by `DomainDelegationScopeAuthority` that one caller may exercise one capability on
/// one target under one live scope generation. Consumed by `DomainAgentSessionOperationAuthorizer`.
package struct DomainDelegationScopeLease: Hashable {
    package let scopeID: UUID
    package let generation: UInt64
    package let capability: DomainDelegationScopeCapability
    package let granteeSessionID: UUID
    package let targetSessionID: UUID

    package init(
        scopeID: UUID,
        generation: UInt64,
        capability: DomainDelegationScopeCapability,
        granteeSessionID: UUID,
        targetSessionID: UUID
    ) {
        self.scopeID = scopeID
        self.generation = generation
        self.capability = capability
        self.granteeSessionID = granteeSessionID
        self.targetSessionID = targetSessionID
    }
}

// MARK: - Denials

/// Why a scope request or authorization failed.
///
/// The design §2.7 codes (`scope_capability_missing`, `scope_guardrail_exceeded`, `scope_expired`,
/// `confirmation_required`) plus `scope_revoked`, `confirmation_mismatch`, and the per-item
/// `requires_control` are caller-visible. Each is reachable only after grantee identity is
/// established, so it discloses nothing about another session's scopes. Every other case is
/// diagnostic only: callers must render it with the uniform "not found / not available" text so an
/// Agent caller cannot probe whether an unrelated session or scope exists.
package enum DomainDelegationScopeDenial: Error, Hashable {
    /// Caller-visible and recoverable: the scope does not hold this capability.
    case capabilityMissing(DomainDelegationScopeCapability)
    /// Per item, not per batch: the target is running (or its state is unknown) and the operation
    /// would have to stop it, which needs `control`. Reported alongside the authorized items.
    case requiresControl
    case guardrailExceeded(guardrail: DomainDelegationScopeGuardrail, limit: Int, current: Int)
    case expired
    /// The caller's own scope was revoked or released (reported only to its grantee).
    case revoked
    case confirmationRequired(reason: DomainDelegationScopeConfirmationReason)
    /// The presented card does not cover this call (different items, arguments, key, or scope
    /// generation). Reported only to the card's grantee, with the approved items.
    case confirmationMismatch
    /// The caller's live scope covers the target, but no unique session writer is available.
    /// Emit only after membership and capabilities have been authorized, never from a UUID probe.
    case mutationOwnerUnavailable

    // Uniform (diagnostic only).
    case callerNotAgentSession
    case unknownScope
    case granteeMismatch
    case generationStale
    case membershipProofMissing
    case membershipProofInvalid
    case usageProofMissing
    case selfTarget
    case operationNotScopeAuthorizable
    /// A grant or attenuation reused an existing scope ID.
    case duplicateScopeID
    /// The user's approval asked for capabilities the request never did.
    case approvalExceedsRequest

    // Grant-time validation (user or attenuation requests).
    case capabilitiesEmpty
    case capabilityNotPermittedForKind(DomainDelegationScopeCapability)
    case guardrailsMalformed
    case expiryInPast
    case attenuationWidensCapabilities
    case attenuationLoosensGuardrails
    case attenuationRequiresTreeRootedAtGrantee
    case attenuationParentInactive
    case directChildrenRootNotGrantee

    /// Stable public code for the recoverable cases; `nil` means "render the uniform denial".
    package var publicCode: String? {
        switch self {
        case .capabilityMissing: "scope_capability_missing"
        case .requiresControl: "requires_control"
        case .guardrailExceeded: "scope_guardrail_exceeded"
        case .expired: "scope_expired"
        case .revoked: "scope_revoked"
        case .confirmationRequired: "confirmation_required"
        case .confirmationMismatch: "confirmation_mismatch"
        case .mutationOwnerUnavailable: "mutation_owner_unavailable"
        default: nil
        }
    }

    /// Diagnostic label. Never shown to an Agent caller for uniform cases.
    package var diagnosticLabel: String {
        switch self {
        case .capabilityMissing: "capability_missing"
        case .requiresControl: "requires_control"
        case .guardrailExceeded: "guardrail_exceeded"
        case .expired: "expired"
        case .revoked: "revoked"
        case .confirmationRequired: "confirmation_required"
        case .callerNotAgentSession: "caller_not_agent_session"
        case .unknownScope: "unknown_scope"
        case .granteeMismatch: "grantee_mismatch"
        case .generationStale: "generation_stale"
        case .membershipProofMissing: "membership_proof_missing"
        case .membershipProofInvalid: "membership_proof_invalid"
        case .usageProofMissing: "usage_proof_missing"
        case .selfTarget: "self_target"
        case .operationNotScopeAuthorizable: "operation_not_scope_authorizable"
        case .confirmationMismatch: "confirmation_mismatch"
        case .mutationOwnerUnavailable: "mutation_owner_unavailable"
        case .duplicateScopeID: "duplicate_scope_id"
        case .approvalExceedsRequest: "approval_exceeds_request"
        case .capabilitiesEmpty: "capabilities_empty"
        case .capabilityNotPermittedForKind: "capability_not_permitted_for_kind"
        case .guardrailsMalformed: "guardrails_malformed"
        case .expiryInPast: "expiry_in_past"
        case .attenuationWidensCapabilities: "attenuation_widens_capabilities"
        case .attenuationLoosensGuardrails: "attenuation_loosens_guardrails"
        case .attenuationRequiresTreeRootedAtGrantee: "attenuation_requires_tree_rooted_at_grantee"
        case .attenuationParentInactive: "attenuation_parent_inactive"
        case .directChildrenRootNotGrantee: "direct_children_root_not_grantee"
        }
    }
}

/// The items one authorization admitted, and the items it set aside as needing `control`.
package struct DomainDelegationScopeAuthorizedItems: Equatable {
    /// One lease per admitted target, in request order. Empty for scope-level operations.
    package let leases: [DomainDelegationScopeLease]
    package let bases: [DomainAgentSessionAuthorityBasis]
    /// Running (or unknown-state) targets an operation would have to stop without `control`.
    /// They are excluded from the batch and reported as `requires_control`, never failing it.
    package let itemsRequiringControl: [UUID]

    package init(
        leases: [DomainDelegationScopeLease] = [],
        bases: [DomainAgentSessionAuthorityBasis] = [],
        itemsRequiringControl: [UUID] = []
    ) {
        self.leases = leases
        self.bases = bases
        self.itemsRequiringControl = itemsRequiringControl
    }

    package var admittedSessionIDs: [UUID] {
        leases.map(\.targetSessionID)
    }
}

/// Why an operation needs a batch confirmation card.
package enum DomainDelegationScopeConfirmationReason: String, Hashable {
    /// An operation that always forces a card (`retire`, `worktree_release`). The raw value is kept
    /// stable for callers; it does not mean anything is deleted.
    case destructive
    /// Bringing sessions from outside the scope into it always needs the user's consent.
    case adoption
    /// A reversible operation affecting more items than the scope's threshold.
    case bulkThreshold = "bulk_threshold"
}
