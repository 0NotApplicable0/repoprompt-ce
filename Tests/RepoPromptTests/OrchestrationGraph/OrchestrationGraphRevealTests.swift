@testable import RepoPromptApp
import XCTest

@MainActor
final class OrchestrationGraphRevealTests: XCTestCase {
    func testCompletedSessionIsOmittedUntilSearch() async {
        let workspaceID = UUID()
        let hiddenID = UUID()
        let snapshot = makeSnapshot(workspaceID: workspaceID, hiddenID: hiddenID, hiddenName: "Finished review", hiddenState: .completed, isLive: false)
        let hidden = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        XCTAssertFalse(hidden.nodes.contains { $0.id == .session(hiddenID) })

        let state = graphState(snapshot)
        await state.loadIfNeeded()
        state.setSearchQuery("finished")
        let revealed = OrchestrationGraphCanvasLayout.make(snapshot: state.displayedSnapshot())
        XCTAssertTrue(revealed.nodes.contains { $0.id == .session(hiddenID) })
    }

    func testWorkspaceHubCarriesCollapsedCount() {
        let workspaceID = UUID()
        let snapshot = makeSnapshot(workspaceID: workspaceID, hiddenID: UUID(), hiddenName: "done", hiddenState: .completed, isLive: false)
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        let hub = canvas.nodes.first { $0.id == .workspace(workspaceID) }
        XCTAssertEqual(hub?.collapsedCount, 1)
    }

    func testZoomAtThresholdRevealsHiddenSessions() async {
        let workspaceID = UUID()
        let hiddenID = UUID()
        let snapshot = makeSnapshot(workspaceID: workspaceID, hiddenID: hiddenID, hiddenName: "done", hiddenState: .failed, isLive: false)
        let state = graphState(snapshot)
        await state.loadIfNeeded()
        state.setCanvasZoom(OrchestrationGraphLayout.revealZoomThreshold)
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: state.displayedSnapshot())
        XCTAssertTrue(canvas.nodes.contains { $0.id == .session(hiddenID) })
        XCTAssertTrue(state.snapshot.layout.isRevealed(sessionID: hiddenID))
    }

    func testLiveExpiredSessionStaysHidden() {
        let workspaceID = UUID()
        let hiddenID = UUID()
        let snapshot = makeSnapshot(workspaceID: workspaceID, hiddenID: hiddenID, hiddenName: "stale", hiddenState: .expired, isLive: true)
        XCTAssertFalse(snapshot.layout.isRevealed(sessionID: hiddenID))
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        XCTAssertFalse(canvas.nodes.contains { $0.id == .session(hiddenID) })
    }

    func testShellSearchManualExpandAndZoomReachTheCanvas() async {
        let workspaceID = UUID()
        let searchID = UUID()
        let expandID = UUID()
        let zoomID = UUID()
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: workspaceID, name: "W")],
            persisted: [
                .init(sessionID: searchID, workspaceID: workspaceID, name: "Alpha done", parentSessionID: nil, runState: .completed),
                .init(sessionID: expandID, workspaceID: workspaceID, name: "Beta done", parentSessionID: nil, runState: .cancelled),
                .init(sessionID: zoomID, workspaceID: workspaceID, name: "Gamma done", parentSessionID: nil, runState: .failed)
            ],
            live: [],
            isHistoryScanIncomplete: false
        )
        let state = graphState(OrchestrationGraphSnapshot(projection: projection))
        await state.loadIfNeeded()

        state.setSearchQuery("alpha")
        XCTAssertTrue(canvasIDs(state).contains(.session(searchID)))
        state.setSearchQuery("")
        XCTAssertFalse(canvasIDs(state).contains(.session(searchID)))

        state.expandSession(expandID)
        XCTAssertTrue(canvasIDs(state).contains(.session(expandID)))

        state.setCanvasZoom(OrchestrationGraphLayout.revealZoomThreshold)
        XCTAssertTrue(canvasIDs(state).contains(.session(zoomID)))
    }

    private func canvasIDs(_ state: OrchestrationGraphShellGraphState) -> Set<OrchestrationGraphProjection.NodeID> {
        Set(OrchestrationGraphCanvasLayout.make(snapshot: state.displayedSnapshot()).nodes.map(\.id))
    }

    private func graphState(_ snapshot: OrchestrationGraphSnapshot) -> OrchestrationGraphShellGraphState {
        OrchestrationGraphShellGraphState(loader: OrchestrationGraphSnapshotLoader { snapshot })
    }

    private func makeSnapshot(
        workspaceID: UUID,
        hiddenID: UUID,
        hiddenName: String,
        hiddenState: OrchestrationGraphProjection.SessionRunState,
        isLive: Bool
    ) -> OrchestrationGraphSnapshot {
        let persisted: [OrchestrationGraphProjection.PersistedSessionInput] = isLive ? [] : [
            .init(sessionID: hiddenID, workspaceID: workspaceID, name: hiddenName, parentSessionID: nil, runState: hiddenState)
        ]
        let live: [OrchestrationGraphProjection.LiveSessionInput] = isLive ? [
            .init(sessionID: hiddenID, workspaceID: workspaceID, name: hiddenName, parentSessionID: nil, runState: hiddenState, statusText: nil)
        ] : []
        return OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: persisted,
                live: live,
                isHistoryScanIncomplete: false
            )
        )
    }
}
