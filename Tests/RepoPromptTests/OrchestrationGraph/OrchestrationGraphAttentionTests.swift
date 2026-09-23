@testable import RepoPromptApp
import XCTest

@MainActor
final class OrchestrationGraphAttentionTests: XCTestCase {
    func testAttentionListsOnlyWaitingSessionsInWorkspaceThenTitleOrder() {
        let alpha = UUID()
        let beta = UUID()
        let running = UUID()
        let completed = UUID()
        let failed = UUID()
        let projection = projection(
            sessions: [
                (beta, "Beta", "Waiting b", .waitingForQuestion),
                (alpha, "Alpha", "Waiting a", .waitingForUser),
                (running, "Alpha", "Running", .running),
                (completed, "Alpha", "Done", .completed),
                (failed, "Alpha", "Bad", .failed)
            ]
        )
        let rows = OrchestrationGraphAttention.make(projection: projection)
        XCTAssertEqual(rows.map(\.sessionName), ["Waiting a", "Waiting b"])
        XCTAssertEqual(rows.map(\.workspaceName), ["Alpha", "Beta"])
    }

    func testAttentionTieBreaksOnSessionID() throws {
        let first = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let projection = projection(sessions: [
            (second, "W", "Same", .waitingForApproval),
            (first, "W", "Same", .waitingForApproval)
        ])
        let rows = OrchestrationGraphAttention.make(projection: projection)
        XCTAssertEqual(rows.map(\.sessionID), [first, second])
    }

    func testAttentionRowSelectsTheSessionTarget() async {
        let workspaceID = UUID()
        let sessionID = UUID()
        let tabID = UUID()
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: workspaceID, name: "W")],
            persisted: [],
            live: [
                .init(sessionID: sessionID, workspaceID: workspaceID, name: "Ask", parentSessionID: nil, runState: .waitingForUser, statusText: nil, composeTabID: tabID)
            ],
            isHistoryScanIncomplete: false
        )
        let snapshot = OrchestrationGraphSnapshot(
            projection: projection,
            sessionRoutes: [sessionID: .init(workspaceID: workspaceID, tabID: tabID)]
        )
        let row = OrchestrationGraphAttention.make(projection: projection)[0]
        let state = OrchestrationGraphShellGraphState(loader: OrchestrationGraphSnapshotLoader { snapshot })
        await state.loadIfNeeded()
        XCTAssertEqual(state.attentionTarget(for: row), snapshot.target(forSessionID: sessionID))
    }

    private func projection(
        sessions: [(UUID, String, String, OrchestrationGraphProjection.SessionRunState)]
    ) -> OrchestrationGraphProjection {
        var workspaceIDs: [String: UUID] = [:]
        var live: [OrchestrationGraphProjection.LiveSessionInput] = []
        for (sessionID, workspaceName, sessionName, state) in sessions {
            let workspaceID = workspaceIDs[workspaceName] ?? UUID()
            workspaceIDs[workspaceName] = workspaceID
            live.append(.init(
                sessionID: sessionID,
                workspaceID: workspaceID,
                name: sessionName,
                parentSessionID: nil,
                runState: state,
                statusText: nil
            ))
        }
        return OrchestrationGraphProjection.make(
            workspaces: workspaceIDs.map { .init(id: $0.value, name: $0.key) },
            persisted: [],
            live: live,
            isHistoryScanIncomplete: false
        )
    }
}
