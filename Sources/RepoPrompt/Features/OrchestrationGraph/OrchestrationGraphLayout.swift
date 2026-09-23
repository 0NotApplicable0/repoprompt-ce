import Foundation

/// Every stored property is a value type, so this layout and its nested types are implicitly
/// `Sendable` within the module. SwiftFormat's `redundantSendable` rule removes an explicit spelling.
struct OrchestrationGraphLayout: Equatable {
    static let revealZoomThreshold: Double = 1.5

    enum ClusterKey: Hashable {
        case workspace(UUID)
        case unassigned
    }

    struct RevealReason: OptionSet, Hashable {
        let rawValue: Int

        static let defaultExpanded = RevealReason(rawValue: 1 << 0)
        static let manualExpansion = RevealReason(rawValue: 1 << 1)
        static let searchMatch = RevealReason(rawValue: 1 << 2)
        static let zoom = RevealReason(rawValue: 1 << 3)
    }

    struct Cluster: Equatable, Hashable {
        let key: ClusterKey
        let workspaceID: UUID?
        let workspaceName: String?
        let sessionIDs: [UUID]
    }

    struct SessionPlacement: Equatable, Hashable {
        let sessionID: UUID
        let clusterKey: ClusterKey
        let revealReasons: RevealReason

        var isRevealed: Bool {
            !revealReasons.isEmpty
        }
    }

    let clusters: [Cluster]
    let placements: [SessionPlacement]

    #if DEBUG
        static var lastMakeSessionIDsForTesting: [UUID] = []
    #endif

    /// Rebuilds layout for sessions that are not unchanged hidden history, and keeps the previous
    /// placements for that hidden set.
    static func makeReusingUnchangedHiddenHistory(
        previous: OrchestrationGraphLayout,
        projection: OrchestrationGraphProjection
    ) -> OrchestrationGraphLayout {
        let hiddenUnchanged = Set(previous.placements.compactMap { placement -> UUID? in
            guard !placement.isRevealed else { return nil }
            guard let session = projection.sessionNode(id: placement.sessionID) else { return placement.sessionID }
            guard isHiddenHistorical(session.status) else { return nil }
            return placement.sessionID
        })
        let filtered = OrchestrationGraphProjection(
            nodes: projection.nodes.filter { node in
                guard case let .session(session) = node else { return true }
                return !hiddenUnchanged.contains(session.sessionID)
            },
            edges: projection.edges.filter { edge in
                if case let .session(id) = edge.target, hiddenUnchanged.contains(id) { return false }
                if case let .session(id) = edge.source, hiddenUnchanged.contains(id) { return false }
                return true
            },
            isHistoryScanIncomplete: projection.isHistoryScanIncomplete
        )
        let rebuilt = make(projection: filtered)
        let reused = previous.placements.filter { hiddenUnchanged.contains($0.sessionID) }
        let placements = rebuilt.placements.filter { !hiddenUnchanged.contains($0.sessionID) } + reused
        let clusters = clustersRestoringHiddenSessions(rebuilt.clusters, reused: reused, previous: previous)
        return OrchestrationGraphLayout(clusters: clusters, placements: placements)
    }

    /// Hidden sessions stay out of `make`, then return to their cluster so the hub count still sees them.
    private static func clustersRestoringHiddenSessions(
        _ rebuilt: [Cluster],
        reused: [SessionPlacement],
        previous: OrchestrationGraphLayout
    ) -> [Cluster] {
        var clusters = rebuilt
        var indexByKey = Dictionary(uniqueKeysWithValues: clusters.enumerated().map { ($1.key, $0) })
        for placement in reused {
            if let index = indexByKey[placement.clusterKey] {
                var ids = clusters[index].sessionIDs
                if !ids.contains(placement.sessionID) {
                    ids.append(placement.sessionID)
                    let cluster = clusters[index]
                    clusters[index] = Cluster(
                        key: cluster.key,
                        workspaceID: cluster.workspaceID,
                        workspaceName: cluster.workspaceName,
                        sessionIDs: ids
                    )
                }
            } else if let prior = previous.clusters.first(where: { $0.key == placement.clusterKey }) {
                clusters.append(Cluster(
                    key: prior.key,
                    workspaceID: prior.workspaceID,
                    workspaceName: prior.workspaceName,
                    sessionIDs: [placement.sessionID]
                ))
                indexByKey[placement.clusterKey] = clusters.count - 1
            }
        }
        return clusters
    }

    private static func isHiddenHistorical(_ status: OrchestrationGraphProjection.SessionStatus) -> Bool {
        switch status.runState {
        case .completed, .failed, .cancelled, .expired:
            true
        default:
            false
        }
    }

    static func make(
        projection: OrchestrationGraphProjection,
        manuallyExpandedSessionIDs: Set<UUID> = [],
        searchQuery: String? = nil,
        zoom: Double = 1.0
    ) -> OrchestrationGraphLayout {
        #if DEBUG
            lastMakeSessionIDsForTesting = projection.nodes.compactMap { node in
                if case let .session(session) = node { return session.sessionID }
                return nil
            }
        #endif
        var workspaceNameByID: [UUID: String] = [:]
        var sessionsByCluster: [ClusterKey: [OrchestrationGraphProjection.SessionNode]] = [:]

        for node in projection.nodes {
            switch node {
            case let .workspace(id, name):
                workspaceNameByID[id] = name
                sessionsByCluster[.workspace(id), default: []] = []
            case let .session(session):
                let key = session.workspaceID.map(ClusterKey.workspace) ?? .unassigned
                sessionsByCluster[key, default: []].append(session)
            }
        }

        let keys = sessionsByCluster.keys.sorted { lhs, rhs in
            compareClusterKeys(lhs, rhs, workspaceNameByID: workspaceNameByID)
        }
        let clusters = keys.map { key in
            let workspaceID: UUID? = switch key {
            case let .workspace(id): id
            case .unassigned: nil
            }
            return Cluster(
                key: key,
                workspaceID: workspaceID,
                workspaceName: workspaceID.flatMap { workspaceNameByID[$0] },
                sessionIDs: sessionsByCluster[key, default: []].map(\.sessionID)
            )
        }
        let trimmedSearchQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placements = keys.flatMap { key in
            sessionsByCluster[key, default: []].map { session in
                var revealReasons = defaultRevealReasons(for: session.status)
                if manuallyExpandedSessionIDs.contains(session.sessionID) {
                    revealReasons.insert(.manualExpansion)
                }
                if !trimmedSearchQuery.isEmpty,
                   session.name.range(of: trimmedSearchQuery, options: .caseInsensitive) != nil
                {
                    revealReasons.insert(.searchMatch)
                }
                if zoom.isFinite, zoom >= revealZoomThreshold {
                    revealReasons.insert(.zoom)
                }
                return SessionPlacement(
                    sessionID: session.sessionID,
                    clusterKey: key,
                    revealReasons: revealReasons
                )
            }
        }

        return OrchestrationGraphLayout(clusters: clusters, placements: placements)
    }

    func placement(forSessionID sessionID: UUID) -> SessionPlacement? {
        placements.first { $0.sessionID == sessionID }
    }

    func cluster(for key: ClusterKey) -> Cluster? {
        clusters.first { $0.key == key }
    }

    func isRevealed(sessionID: UUID) -> Bool {
        placement(forSessionID: sessionID)?.isRevealed ?? false
    }

    static func defaultRevealReasons(
        for status: OrchestrationGraphProjection.SessionStatus
    ) -> RevealReason {
        switch status.runState {
        case .completed, .failed, .cancelled, .expired:
            []
        case .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
            .defaultExpanded
        case .idle, .unknown, .unspecified:
            status.isLive ? .defaultExpanded : []
        }
    }

    private static func compareClusterKeys(
        _ lhs: ClusterKey,
        _ rhs: ClusterKey,
        workspaceNameByID: [UUID: String]
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.workspace(lhsID), .workspace(rhsID)):
            switch (workspaceNameByID[lhsID], workspaceNameByID[rhsID]) {
            case let (.some(lhsName), .some(rhsName)):
                if lhsName != rhsName {
                    return lhsName < rhsName
                }
                return lhsID.uuidString < rhsID.uuidString
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhsID.uuidString < rhsID.uuidString
            }
        case (.workspace, .unassigned):
            return true
        case (.unassigned, .workspace), (.unassigned, .unassigned):
            return false
        }
    }
}
