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

    static func make(
        projection: OrchestrationGraphProjection,
        manuallyExpandedSessionIDs: Set<UUID> = [],
        searchQuery: String? = nil,
        zoom: Double = 1.0
    ) -> OrchestrationGraphLayout {
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
