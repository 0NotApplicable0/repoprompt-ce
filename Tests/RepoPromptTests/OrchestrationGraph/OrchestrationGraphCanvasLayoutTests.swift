@testable import RepoPromptApp
import XCTest

final class OrchestrationGraphCanvasLayoutTests: XCTestCase {
    func testKnowledgeGraphPlacesWorkspaceAndSessionsInTwoDimensions() {
        let workspaceID = UUID()
        let liveID = UUID()
        let doneID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: [
                    .init(
                        sessionID: doneID,
                        workspaceID: workspaceID,
                        name: "done",
                        parentSessionID: nil,
                        runState: .completed
                    )
                ],
                live: [
                    .init(
                        sessionID: liveID,
                        workspaceID: workspaceID,
                        name: "live",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: "working"
                    )
                ],
                isHistoryScanIncomplete: false
            )
        )

        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        XCTAssertEqual(canvas.nodes.count, 3)
        XCTAssertTrue(canvas.nodes.contains { $0.id == .workspace(workspaceID) && $0.isWorkspace })
        XCTAssertTrue(canvas.nodes.contains { $0.id == .session(liveID) })
        XCTAssertTrue(canvas.nodes.contains { $0.id == .session(doneID) })
        XCTAssertTrue(canvas.edges.contains { $0.kind == .membership && $0.source == .workspace(workspaceID) })
        let xs = canvas.nodes.map(\.center.x)
        let ys = canvas.nodes.map(\.center.y)
        let spanX = (xs.max() ?? 0) - (xs.min() ?? 0)
        let spanY = (ys.max() ?? 0) - (ys.min() ?? 0)
        XCTAssertGreaterThan(max(spanX, spanY), 8)
        XCTAssertGreaterThan(canvas.size.width, 120)
        XCTAssertGreaterThan(canvas.size.height, 120)
    }

    func testWorkspaceHubsStayCompactWithoutViewportFloor() {
        let workspaces = (0 ..< 4).map { index in
            OrchestrationGraphProjection.WorkspaceInput(id: UUID(), name: "W\(index)")
        }
        let live: [OrchestrationGraphProjection.LiveSessionInput] = workspaces.map { workspace in
            .init(
                sessionID: UUID(),
                workspaceID: workspace.id,
                name: "s",
                parentSessionID: nil,
                runState: .running,
                statusText: nil
            )
        }
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: workspaces,
                persisted: [],
                live: live,
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(
            snapshot: snapshot,
            containerWidth: 1100,
            containerHeight: 760
        )
        let hubs = canvas.nodes.filter(\.isWorkspace).map(\.center)
        XCTAssertEqual(hubs.count, 4)
        var farthest: CGFloat = 0
        var closest: CGFloat = .greatestFiniteMagnitude
        for i in hubs.indices {
            for j in (i + 1) ..< hubs.count {
                let dist = hypot(hubs[j].x - hubs[i].x, hubs[j].y - hubs[i].y)
                farthest = max(farthest, dist)
                closest = min(closest, dist)
            }
        }
        XCTAssertGreaterThanOrEqual(closest, OrchestrationGraphCanvasLayout.minWorkspaceHubSeparation - 0.5)
        XCTAssertLessThan(farthest, 420)
        XCTAssertLessThan(canvas.size.width, 1100)
        XCTAssertLessThan(canvas.size.height, 1100)
    }

    func testWorkspaceHubsSitOnACenteredRegularPolygon() {
        let workspaces = (0 ..< 4).map { index in
            OrchestrationGraphProjection.WorkspaceInput(id: UUID(), name: "W\(index)")
        }
        let live: [OrchestrationGraphProjection.LiveSessionInput] = workspaces.map { workspace in
            .init(
                sessionID: UUID(),
                workspaceID: workspace.id,
                name: "root",
                parentSessionID: nil,
                runState: .running,
                statusText: nil
            )
        }
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: workspaces,
                persisted: [],
                live: live,
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        let hubs = canvas.nodes.filter(\.isWorkspace)
        XCTAssertEqual(hubs.count, 4)
        let cx = hubs.map(\.center.x).reduce(0, +) / CGFloat(hubs.count)
        let cy = hubs.map(\.center.y).reduce(0, +) / CGFloat(hubs.count)
        let radii = hubs.map { hypot($0.center.x - cx, $0.center.y - cy) }
        XCTAssertEqual(radii.max() ?? 0, radii.min() ?? 0, accuracy: 2)
        XCTAssertGreaterThan(radii.min() ?? 0, 80)
        let angles = hubs.map { atan2($0.center.y - cy, $0.center.x - cx) }.sorted()
        var gaps: [CGFloat] = []
        for index in 1 ..< angles.count {
            gaps.append(angles[index] - angles[index - 1])
        }
        gaps.append(angles[0] + 2 * .pi - angles[angles.count - 1])
        let mean = gaps.reduce(0, +) / CGFloat(gaps.count)
        for gap in gaps {
            XCTAssertEqual(gap, mean, accuracy: 0.12)
        }
    }

    func testSessionsBranchOutwardFromWorkspaceHub() throws {
        let workspaceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: [],
                live: [
                    .init(
                        sessionID: parentID,
                        workspaceID: workspaceID,
                        name: "ORCHESTRATE",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: nil
                    ),
                    .init(
                        sessionID: childID,
                        workspaceID: workspaceID,
                        name: "REVIEW",
                        parentSessionID: parentID,
                        runState: .completed,
                        statusText: nil
                    )
                ],
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        let hub = try XCTUnwrap(canvas.nodes.first { $0.id == .workspace(workspaceID) }?.center)
        let parent = try XCTUnwrap(canvas.nodes.first { $0.id == .session(parentID) }?.center)
        let child = try XCTUnwrap(canvas.nodes.first { $0.id == .session(childID) }?.center)
        let parentDist = hypot(parent.x - hub.x, parent.y - hub.y)
        let childDist = hypot(child.x - hub.x, child.y - hub.y)
        XCTAssertGreaterThan(parentDist, 80)
        XCTAssertGreaterThan(childDist, parentDist)
    }

    func testBusyClustersDoNotOverlapNodesOrForeignHubs() {
        func cluster(name: String, childCount: Int) -> (
            OrchestrationGraphProjection.WorkspaceInput,
            [OrchestrationGraphProjection.LiveSessionInput]
        ) {
            let workspace = OrchestrationGraphProjection.WorkspaceInput(id: UUID(), name: name)
            let parentID = UUID()
            let parent = OrchestrationGraphProjection.LiveSessionInput(
                sessionID: parentID,
                workspaceID: workspace.id,
                name: "ORCHESTRATE",
                parentSessionID: nil,
                runState: .running,
                statusText: nil
            )
            let children = (0 ..< childCount).map { index in
                OrchestrationGraphProjection.LiveSessionInput(
                    sessionID: UUID(),
                    workspaceID: workspace.id,
                    name: "REVIEW \(index)",
                    parentSessionID: parentID,
                    runState: .completed,
                    statusText: nil
                )
            }
            return (workspace, [parent] + children)
        }
        let a = cluster(name: "A", childCount: 8)
        let b = cluster(name: "B", childCount: 8)
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [a.0, b.0],
                persisted: [],
                live: a.1 + b.1,
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        for i in canvas.nodes.indices {
            for j in (i + 1) ..< canvas.nodes.count {
                let left = canvas.nodes[i]
                let right = canvas.nodes[j]
                let dist = hypot(right.center.x - left.center.x, right.center.y - left.center.y)
                XCTAssertGreaterThanOrEqual(
                    dist,
                    OrchestrationGraphCanvasLayout.minimumDistance(between: left, and: right) - 0.75,
                    "\(left.title) overlaps \(right.title)"
                )
            }
        }
    }

    func testWorkspaceContextMenuOmitsDeleteForSystemWorkspaces() {
        XCTAssertEqual(
            OrchestrationGraphWorkspaceNodeMenu.items(isSystemWorkspace: false),
            [.rename, .delete]
        )
        XCTAssertEqual(
            OrchestrationGraphWorkspaceNodeMenu.items(isSystemWorkspace: true),
            [.rename]
        )
    }

    func testPreciseScrollZoomFactorStaysFineGrained() {
        let factor = GraphCanvasZoomMath.scrollZoomFactor(
            verticalDelta: 20,
            hasPreciseScrollingDeltas: true
        )
        XCTAssertGreaterThan(factor, 1.02)
        XCTAssertLessThan(factor, 1.12)
        let wheel = GraphCanvasZoomMath.scrollZoomFactor(
            verticalDelta: 4,
            hasPreciseScrollingDeltas: false
        )
        XCTAssertGreaterThan(wheel, 1.02)
        XCTAssertLessThan(wheel, 1.12)
    }

    func testSiblingSessionsKeepClearance() {
        let workspaceID = UUID()
        let parentID = UUID()
        let childIDs = [UUID(), UUID(), UUID()]
        let live: [OrchestrationGraphProjection.LiveSessionInput] = [
            .init(
                sessionID: parentID,
                workspaceID: workspaceID,
                name: "TL",
                parentSessionID: nil,
                runState: .running,
                statusText: nil
            )
        ] + childIDs.map { id in
            .init(
                sessionID: id,
                workspaceID: workspaceID,
                name: "WORKER",
                parentSessionID: parentID,
                runState: .running,
                statusText: nil
            )
        }
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: [],
                live: live,
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        let children = childIDs.compactMap { id in
            canvas.nodes.first { $0.id == .session(id) }?.center
        }
        XCTAssertEqual(children.count, 3)
        var closest: CGFloat = .greatestFiniteMagnitude
        for i in children.indices {
            for j in (i + 1) ..< children.count {
                closest = min(closest, hypot(children[j].x - children[i].x, children[j].y - children[i].y))
            }
        }
        XCTAssertGreaterThan(closest, 48)
    }

    func testIncomingEdgesStopProgressWhenTargetIsDone() {
        let workspaceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: [],
                live: [
                    .init(
                        sessionID: parentID,
                        workspaceID: workspaceID,
                        name: "TL",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: nil
                    ),
                    .init(
                        sessionID: childID,
                        workspaceID: workspaceID,
                        name: "WORKER",
                        parentSessionID: parentID,
                        runState: .completed,
                        statusText: nil
                    )
                ],
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        let membershipToParent = canvas.edges.first {
            $0.kind == .membership && $0.target == .session(parentID)
        }
        let membershipToChild = canvas.edges.first {
            $0.kind == .membership && $0.target == .session(childID)
        }
        let dispatchToChild = canvas.edges.first {
            $0.kind == .dispatch && $0.source == .session(parentID) && $0.target == .session(childID)
        }
        XCTAssertEqual(membershipToParent.map { canvas.edgeCarriesProgress($0) }, true)
        XCTAssertEqual(dispatchToChild.map { canvas.edgeCarriesProgress($0) }, false)
        if let membershipToChild {
            XCTAssertFalse(canvas.edgeCarriesProgress(membershipToChild))
        }
    }

    func testRunningSessionIsInProgress() {
        let workspaceID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: [],
                live: [
                    .init(
                        sessionID: UUID(),
                        workspaceID: workspaceID,
                        name: "live",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: "working"
                    )
                ],
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        XCTAssertTrue(canvas.nodes.contains { !$0.isWorkspace && $0.isInProgress })
        XCTAssertTrue(canvas.nodes.contains { $0.isWorkspace && !$0.isInProgress })
    }

    func testDispatchAndMembershipEdgesAreBothDrawn() {
        let workspaceID = UUID()
        let parentID = UUID()
        let childID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "W")],
                persisted: [],
                live: [
                    .init(
                        sessionID: parentID,
                        workspaceID: workspaceID,
                        name: "parent",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: nil
                    ),
                    .init(
                        sessionID: childID,
                        workspaceID: workspaceID,
                        name: "child",
                        parentSessionID: parentID,
                        runState: .running,
                        statusText: nil
                    )
                ],
                isHistoryScanIncomplete: false
            )
        )

        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        XCTAssertTrue(canvas.edges.contains {
            $0.kind == .dispatch && $0.source == .session(parentID) && $0.target == .session(childID)
        })
        XCTAssertTrue(canvas.edges.contains {
            $0.kind == .membership && $0.source == .workspace(workspaceID) && $0.target == .session(parentID)
        })
        XCTAssertFalse(canvas.edges.contains { $0.kind == .membership && $0.target == .session(childID) })
    }

    func testEmptyDefaultWorkspacesAreOmitted() {
        let realID = UUID()
        let defaultID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [
                    .init(id: realID, name: "repoprompt-ce"),
                    .init(id: defaultID, name: "Default")
                ],
                persisted: [],
                live: [
                    .init(
                        sessionID: UUID(),
                        workspaceID: realID,
                        name: "live",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: nil
                    )
                ],
                isHistoryScanIncomplete: false
            )
        )
        let canvas = OrchestrationGraphCanvasLayout.make(snapshot: snapshot)
        XCTAssertTrue(canvas.nodes.contains { $0.id == .workspace(realID) })
        XCTAssertFalse(canvas.nodes.contains { $0.id == .workspace(defaultID) })
    }
}
