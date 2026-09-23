import Foundation

/// Sessions that are waiting on a person, in workspace name, session name, then session id order.
enum OrchestrationGraphAttention {
    struct Row: Equatable, Identifiable {
        let sessionID: UUID
        let workspaceName: String
        let sessionName: String

        var id: UUID {
            sessionID
        }
    }

    static func make(projection: OrchestrationGraphProjection) -> [Row] {
        var workspaceNameByID: [UUID: String] = [:]
        for node in projection.nodes {
            if case let .workspace(id, name) = node {
                workspaceNameByID[id] = name
            }
        }
        let rows: [Row] = projection.nodes.compactMap { node in
            guard case let .session(session) = node else { return nil }
            switch session.status.runState {
            case .waitingForUser, .waitingForQuestion, .waitingForApproval:
                break
            default:
                return nil
            }
            let workspaceName = session.workspaceID.flatMap { workspaceNameByID[$0] } ?? ""
            return Row(sessionID: session.sessionID, workspaceName: workspaceName, sessionName: session.name)
        }
        return rows.sorted { lhs, rhs in
            if lhs.workspaceName != rhs.workspaceName { return lhs.workspaceName < rhs.workspaceName }
            if lhs.sessionName != rhs.sessionName { return lhs.sessionName < rhs.sessionName }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }
}

enum OrchestrationGraphFocus: Equatable {
    case none
    case workspace(UUID)
    case session(UUID)
}
