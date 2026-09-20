import Foundation
import RepoPromptDomainRuntime

/// Every stored property is a value type over `UUID`, `String`, `Bool`, and the nested enums, so this
/// projection and its nested types are implicitly `Sendable` within the module. SwiftFormat's
/// `redundantSendable` rule removes an explicit spelling; `AgentSessionMetadataIndex` is only a
/// factory parameter and is never stored.
struct OrchestrationGraphProjection: Equatable {
    struct WorkspaceInput: Equatable, Hashable {
        let id: UUID
        let name: String
    }

    struct PersistedSessionInput: Equatable, Hashable {
        let sessionID: UUID
        let workspaceID: UUID?
        let name: String
        let parentSessionID: UUID?
        let runState: SessionRunState
    }

    struct LiveSessionInput: Equatable, Hashable {
        let sessionID: UUID
        let workspaceID: UUID?
        let name: String
        let parentSessionID: UUID?
        let runState: SessionRunState
        let statusText: String?
    }

    enum SessionRunState: Equatable, Hashable {
        case idle
        case running
        case waitingForUser
        case waitingForQuestion
        case waitingForApproval
        case completed
        case failed
        case cancelled
        case expired
        case unknown(String)
        case unspecified

        static func fromPersistedRaw(_ raw: String?) -> SessionRunState {
            guard let raw else { return .unspecified }
            return switch raw {
            case AgentSessionRunState.idle.rawValue:
                .idle
            case AgentSessionRunState.running.rawValue:
                .running
            case AgentSessionRunState.waitingForUser.rawValue:
                .waitingForUser
            case AgentSessionRunState.waitingForQuestion.rawValue:
                .waitingForQuestion
            case AgentSessionRunState.waitingForApproval.rawValue:
                .waitingForApproval
            case AgentSessionRunState.completed.rawValue:
                .completed
            case AgentSessionRunState.failed.rawValue:
                .failed
            case AgentSessionRunState.cancelled.rawValue:
                .cancelled
            default:
                .unknown(raw)
            }
        }

        static func fromLive(
            status: DomainAgentRunSnapshot.Status,
            interactionKind: DomainAgentRunSnapshot.Interaction.Kind?
        ) -> SessionRunState {
            switch status {
            case .running:
                .running
            case .waitingForInput:
                switch interactionKind {
                case .some(.approval), .some(.hookApproval):
                    .waitingForApproval
                case .some(.question), .some(.mcpElicitation):
                    .waitingForQuestion
                case .some(.instruction), .some(.userInput), .none:
                    .waitingForUser
                }
            case .completed:
                .completed
            case .failed:
                .failed
            case .cancelled:
                .cancelled
            case .expired:
                .expired
            }
        }
    }

    enum NodeID: Hashable {
        case workspace(UUID)
        case session(UUID)

        var sortIndex: Int {
            switch self {
            case .workspace: 0
            case .session: 1
            }
        }

        var uuid: UUID {
            switch self {
            case let .workspace(id), let .session(id): id
            }
        }
    }

    struct SessionStatus: Equatable, Hashable {
        let runState: SessionRunState
        let statusText: String?
        let isLive: Bool
    }

    enum Node: Equatable, Hashable, Identifiable {
        case workspace(id: UUID, name: String)
        case session(SessionNode)

        var id: NodeID {
            switch self {
            case let .workspace(id, _): .workspace(id)
            case let .session(session): .session(session.sessionID)
            }
        }
    }

    struct SessionNode: Equatable, Hashable {
        let sessionID: UUID
        let name: String
        let workspaceID: UUID?
        let status: SessionStatus
        let unresolvedParentSessionID: UUID?
    }

    enum EdgeKind: Equatable, Hashable {
        case membership
        case dispatch

        var sortIndex: Int {
            switch self {
            case .membership: 0
            case .dispatch: 1
            }
        }
    }

    struct Edge: Equatable, Hashable {
        let source: NodeID
        let target: NodeID
        let kind: EdgeKind
    }

    let nodes: [Node]
    let edges: [Edge]
    let isHistoryScanIncomplete: Bool

    private struct ResolvedSession {
        let sessionID: UUID
        let workspaceID: UUID?
        let name: String
        let parentSessionID: UUID?
        let status: SessionStatus
    }

    static func make(
        workspaces: [WorkspaceInput],
        persisted: [PersistedSessionInput],
        live: [LiveSessionInput],
        isHistoryScanIncomplete: Bool
    ) -> OrchestrationGraphProjection {
        var workspaceByID: [UUID: WorkspaceInput] = [:]
        for workspace in workspaces {
            workspaceByID[workspace.id] = workspace
        }

        var sessionsByID: [UUID: ResolvedSession] = [:]
        for session in persisted {
            sessionsByID[session.sessionID] = ResolvedSession(
                sessionID: session.sessionID,
                workspaceID: session.workspaceID,
                name: session.name,
                parentSessionID: session.parentSessionID,
                status: SessionStatus(runState: session.runState, statusText: nil, isLive: false)
            )
        }

        for session in live {
            sessionsByID[session.sessionID] = ResolvedSession(
                sessionID: session.sessionID,
                workspaceID: session.workspaceID,
                name: session.name,
                parentSessionID: session.parentSessionID,
                status: SessionStatus(runState: session.runState, statusText: session.statusText, isLive: true)
            )
        }

        let workspaceNodes = workspaceByID.values
            .map { Node.workspace(id: $0.id, name: $0.name) }
            .sorted(by: compareWorkspaceNodes)
        let sessionNodes = sessionsByID.values
            .map { session in
                Node.session(
                    SessionNode(
                        sessionID: session.sessionID,
                        name: session.name,
                        workspaceID: session.workspaceID,
                        status: session.status,
                        unresolvedParentSessionID: session.parentSessionID.flatMap { parentSessionID in
                            parentSessionID == session.sessionID || sessionsByID[parentSessionID] == nil
                                ? parentSessionID
                                : nil
                        }
                    )
                )
            }
            .sorted { $0.id.uuid.uuidString < $1.id.uuid.uuidString }

        var edges: [Edge] = []
        for session in sessionsByID.values {
            if let parentSessionID = session.parentSessionID {
                if parentSessionID != session.sessionID, sessionsByID[parentSessionID] != nil {
                    edges.append(
                        Edge(
                            source: .session(parentSessionID),
                            target: .session(session.sessionID),
                            kind: .dispatch
                        )
                    )
                }
            } else if let workspaceID = session.workspaceID, workspaceByID[workspaceID] != nil {
                edges.append(
                    Edge(
                        source: .workspace(workspaceID),
                        target: .session(session.sessionID),
                        kind: .membership
                    )
                )
            }
        }

        return OrchestrationGraphProjection(
            nodes: workspaceNodes + sessionNodes,
            edges: edges.sorted(by: compareEdges),
            isHistoryScanIncomplete: isHistoryScanIncomplete
        )
    }

    static func make(
        workspaces: [WorkspaceInput],
        persistedIndexesByWorkspaceID: [UUID: AgentSessionMetadataIndex],
        liveSnapshotsByWorkspaceID: [UUID: [DomainAgentRunSnapshot]],
        isHistoryScanIncomplete: Bool
    ) -> OrchestrationGraphProjection {
        let persisted = persistedIndexesByWorkspaceID.keys
            .sorted { $0.uuidString < $1.uuidString }
            .flatMap { workspaceID in
                persistedIndexesByWorkspaceID[workspaceID, default: AgentSessionMetadataIndex()].entries.map { record in
                    PersistedSessionInput(
                        sessionID: record.id,
                        workspaceID: workspaceID,
                        name: record.name,
                        parentSessionID: record.parentSessionID,
                        runState: .fromPersistedRaw(record.lastRunStateRaw)
                    )
                }
            }
        let live = liveSnapshotsByWorkspaceID.keys
            .sorted { $0.uuidString < $1.uuidString }
            .flatMap { workspaceID in
                liveSnapshotsByWorkspaceID[workspaceID, default: []].map { snapshot in
                    LiveSessionInput(
                        sessionID: snapshot.sessionID,
                        workspaceID: workspaceID,
                        name: snapshot.sessionName ?? "",
                        parentSessionID: snapshot.parentSessionID,
                        runState: .fromLive(
                            status: snapshot.status,
                            interactionKind: snapshot.interaction?.kind
                        ),
                        statusText: snapshot.statusText
                    )
                }
            }

        return make(
            workspaces: workspaces,
            persisted: persisted,
            live: live,
            isHistoryScanIncomplete: isHistoryScanIncomplete
        )
    }

    private static func compareWorkspaceNodes(_ lhs: Node, _ rhs: Node) -> Bool {
        guard case let .workspace(lhsID, lhsName) = lhs,
              case let .workspace(rhsID, rhsName) = rhs
        else {
            return lhs.id.sortIndex < rhs.id.sortIndex
        }
        if lhsName != rhsName {
            return lhsName < rhsName
        }
        return lhsID.uuidString < rhsID.uuidString
    }

    private static func compareEdges(_ lhs: Edge, _ rhs: Edge) -> Bool {
        if lhs.kind.sortIndex != rhs.kind.sortIndex {
            return lhs.kind.sortIndex < rhs.kind.sortIndex
        }
        if lhs.source.sortIndex != rhs.source.sortIndex {
            return lhs.source.sortIndex < rhs.source.sortIndex
        }
        if lhs.source.uuid != rhs.source.uuid {
            return lhs.source.uuid.uuidString < rhs.source.uuid.uuidString
        }
        if lhs.target.sortIndex != rhs.target.sortIndex {
            return lhs.target.sortIndex < rhs.target.sortIndex
        }
        return lhs.target.uuid.uuidString < rhs.target.uuid.uuidString
    }
}
