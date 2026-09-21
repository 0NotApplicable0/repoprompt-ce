import Foundation
@testable import RepoPromptApp
import XCTest

final class OrchestrationGraphLayoutTests: XCTestCase {
    func testClustersByWorkspaceID() {
        let projection = makeProjection(
            workspaces: [
                .init(id: IDs.workspace1, name: "Zulu"),
                .init(id: IDs.workspace2, name: "Alpha")
            ],
            persisted: [
                session(IDs.root, "Root", IDs.workspace1, .completed),
                session(IDs.child, "Child", IDs.workspace1, .completed, parentSessionID: IDs.root),
                session(IDs.historyRoot, "History", IDs.workspace2, .completed),
                session(IDs.historyChild, "History Child", IDs.workspace2, .failed, parentSessionID: IDs.historyRoot)
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace2),
                workspaceID: IDs.workspace2,
                workspaceName: "Alpha",
                sessionIDs: [IDs.historyRoot, IDs.historyChild]
            ),
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Zulu",
                sessionIDs: [IDs.root, IDs.child]
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.historyRoot, clusterKey: .workspace(IDs.workspace2), revealReasons: []),
            .init(sessionID: IDs.historyChild, clusterKey: .workspace(IDs.workspace2), revealReasons: []),
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.workspace1), revealReasons: []),
            .init(sessionID: IDs.child, clusterKey: .workspace(IDs.workspace1), revealReasons: [])
        ])
    }

    func testChildSessionClustersOnItsOwnWorkspaceIDNotOnItsParents() {
        let projection = makeProjection(
            workspaces: [
                .init(id: IDs.workspace1, name: "Alpha"),
                .init(id: IDs.workspace2, name: "Zulu")
            ],
            persisted: [
                session(IDs.root, "Root", IDs.workspace1, .completed),
                session(IDs.child, "Child", IDs.workspace2, .completed, parentSessionID: IDs.root)
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Alpha",
                sessionIDs: [IDs.root]
            ),
            .init(
                key: .workspace(IDs.workspace2),
                workspaceID: IDs.workspace2,
                workspaceName: "Zulu",
                sessionIDs: [IDs.child]
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.workspace1), revealReasons: []),
            .init(sessionID: IDs.child, clusterKey: .workspace(IDs.workspace2), revealReasons: [])
        ])
    }

    func testUnresolvedParentSessionInAKnownWorkspaceStillClustersOnThatWorkspace() {
        let projection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Alpha")],
            persisted: [
                session(
                    IDs.root,
                    "Root",
                    IDs.workspace1,
                    .completed,
                    parentSessionID: IDs.unknownParent
                )
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Alpha",
                sessionIDs: [IDs.root]
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.workspace1), revealReasons: [])
        ])
    }

    func testClusteringIgnoresProjectionEdges() {
        let projection = OrchestrationGraphProjection(
            nodes: [
                .workspace(id: IDs.workspace1, name: "Alpha"),
                .workspace(id: IDs.workspace2, name: "Zulu"),
                .session(
                    .init(
                        sessionID: IDs.child,
                        name: "Child",
                        workspaceID: IDs.workspace1,
                        status: .init(runState: .completed, statusText: nil, isLive: false),
                        unresolvedParentSessionID: nil
                    )
                ),
                .session(
                    .init(
                        sessionID: IDs.root,
                        name: "Root",
                        workspaceID: IDs.workspace1,
                        status: .init(runState: .completed, statusText: nil, isLive: false),
                        unresolvedParentSessionID: nil
                    )
                )
            ],
            edges: [
                .init(
                    source: .workspace(IDs.workspace2),
                    target: .session(IDs.root),
                    kind: .membership
                )
            ],
            isHistoryScanIncomplete: false
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Alpha",
                sessionIDs: [IDs.child, IDs.root]
            ),
            .init(
                key: .workspace(IDs.workspace2),
                workspaceID: IDs.workspace2,
                workspaceName: "Zulu",
                sessionIDs: []
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.child, clusterKey: .workspace(IDs.workspace1), revealReasons: []),
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.workspace1), revealReasons: [])
        ])
    }

    func testRunningSessionIsExpandedByDefault() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Root", nil, .running)]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.defaultExpanded])
        ])
    }

    func testCompletedAndFailedHistoricalAreCollapsedByDefault() {
        let projection = makeProjection(
            persisted: [
                session(IDs.root, "Completed", nil, .completed),
                session(IDs.child, "Failed", nil, .failed)
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: []),
            .init(sessionID: IDs.child, clusterKey: .unassigned, revealReasons: [])
        ])
    }

    func testEachWaitingStateIsExpandedByDefault() {
        let projection = makeProjection(
            persisted: [
                session(IDs.root, "User", nil, .waitingForUser),
                session(IDs.child, "Question", nil, .waitingForQuestion),
                session(IDs.historyRoot, "Approval", nil, .waitingForApproval)
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.defaultExpanded]),
            .init(sessionID: IDs.child, clusterKey: .unassigned, revealReasons: [.defaultExpanded]),
            .init(sessionID: IDs.historyRoot, clusterKey: .unassigned, revealReasons: [.defaultExpanded])
        ])
    }

    func testDefaultRevealMatrixIsTotalOverEveryRunStateAndIsLive() {
        let cases: [(String, OrchestrationGraphProjection.SessionRunState, OrchestrationGraphLayout.RevealReason, OrchestrationGraphLayout.RevealReason)] = [
            ("idle", .idle, [], [.defaultExpanded]),
            ("running", .running, [.defaultExpanded], [.defaultExpanded]),
            ("waitingForUser", .waitingForUser, [.defaultExpanded], [.defaultExpanded]),
            ("waitingForQuestion", .waitingForQuestion, [.defaultExpanded], [.defaultExpanded]),
            ("waitingForApproval", .waitingForApproval, [.defaultExpanded], [.defaultExpanded]),
            ("completed", .completed, [], []),
            ("failed", .failed, [], []),
            ("cancelled", .cancelled, [], []),
            ("expired", .expired, [], []),
            ("unknown", .unknown("future"), [], [.defaultExpanded]),
            ("unspecified", .unspecified, [], [.defaultExpanded])
        ]

        for (name, runState, historicalExpected, liveExpected) in cases {
            XCTAssertEqual(
                OrchestrationGraphLayout.defaultRevealReasons(
                    for: .init(runState: runState, statusText: nil, isLive: false)
                ),
                historicalExpected,
                "runState=\(name), isLive=false"
            )
            XCTAssertEqual(
                OrchestrationGraphLayout.defaultRevealReasons(
                    for: .init(runState: runState, statusText: nil, isLive: true)
                ),
                liveExpected,
                "runState=\(name), isLive=true"
            )
        }
    }

    func testLiveTerminalSessionsAreStillCollapsedByDefault() {
        let projection = makeProjection(
            live: [
                liveSession(IDs.root, "Completed", nil, .completed),
                liveSession(IDs.child, "Failed", nil, .failed),
                liveSession(IDs.historyRoot, "Cancelled", nil, .cancelled),
                liveSession(IDs.historyChild, "Expired", nil, .expired)
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: []),
            .init(sessionID: IDs.child, clusterKey: .unassigned, revealReasons: []),
            .init(sessionID: IDs.historyRoot, clusterKey: .unassigned, revealReasons: []),
            .init(sessionID: IDs.historyChild, clusterKey: .unassigned, revealReasons: [])
        ])
    }

    func testManualExpandRevealsACollapsedSessionWithTheManualReason() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Root", nil, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            manuallyExpandedSessionIDs: [IDs.root]
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.manualExpansion])
        ])
    }

    func testUnknownManuallyExpandedIDProducesNoPlacement() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Root", nil, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            manuallyExpandedSessionIDs: [IDs.unknownParent]
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [])
        ])
    }

    func testMatchingSearchRevealsCollapsedSessionCaseInsensitively() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Session 9", nil, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            searchQuery: "sEsSi"
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.searchMatch])
        ])
    }

    func testSearchQueryIsTrimmedBeforeMatching() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Session 9", nil, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            searchQuery: "   sessi   "
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.searchMatch])
        ])
    }

    func testNonMatchingSearchDoesNotReveal() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Session 9", nil, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            searchQuery: "missing"
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [])
        ])
    }

    func testWorkspaceNameIsNotASearchRevealPath() {
        let projection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Alpha")],
            persisted: [session(IDs.root, "Beta", IDs.workspace1, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            searchQuery: "alpha"
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.workspace1), revealReasons: [])
        ])
    }

    func testBlankAndNilSearchRevealNothingAndHideNothing() {
        let projection = makeProjection(
            persisted: [
                session(IDs.root, "Historical", nil, .completed),
                session(IDs.child, "Running", nil, .running)
            ]
        )
        let expected: [OrchestrationGraphLayout.SessionPlacement] = [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: []),
            .init(sessionID: IDs.child, clusterKey: .unassigned, revealReasons: [.defaultExpanded])
        ]

        for query in [nil, "", "   "] as [String?] {
            let layout = OrchestrationGraphLayout.make(
                projection: projection,
                searchQuery: query
            )

            XCTAssertEqual(layout.placements, expected, "query=\(String(describing: query))")
            XCTAssertTrue(layout.placements[1].isRevealed)
        }
    }

    func testNonMatchingSearchDoesNotCollapseADefaultExpandedSession() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Running", nil, .running)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            searchQuery: "missing"
        )

        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.defaultExpanded])
        ])
    }

    func testZoomAtAndAboveThresholdRevealsEveryCollapsedSession() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Historical", nil, .completed)]
        )

        for zoom in [
            OrchestrationGraphLayout.revealZoomThreshold,
            OrchestrationGraphLayout.revealZoomThreshold + 0.5
        ] {
            let layout = OrchestrationGraphLayout.make(projection: projection, zoom: zoom)

            XCTAssertEqual(layout.placements, [
                .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [.zoom])
            ], "zoom=\(zoom)")
        }
    }

    func testZoomBelowThresholdDoesNotReveal() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Historical", nil, .completed)]
        )

        for zoom in [OrchestrationGraphLayout.revealZoomThreshold - 0.01, 0] {
            let layout = OrchestrationGraphLayout.make(projection: projection, zoom: zoom)

            XCTAssertEqual(layout.placements, [
                .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [])
            ], "zoom=\(zoom)")
        }
    }

    func testNonFiniteZoomDoesNotReveal() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Historical", nil, .completed)]
        )

        for zoom in [Double.nan, .infinity, -.infinity] {
            let layout = OrchestrationGraphLayout.make(projection: projection, zoom: zoom)

            XCTAssertEqual(layout.placements, [
                .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [])
            ], "zoom=\(zoom)")
        }
    }

    func testRevealReasonsAccumulateOnACollapsedSession() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Historical", nil, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            manuallyExpandedSessionIDs: [IDs.root],
            searchQuery: "historical",
            zoom: OrchestrationGraphLayout.revealZoomThreshold
        )

        XCTAssertEqual(layout.placements, [
            .init(
                sessionID: IDs.root,
                clusterKey: .unassigned,
                revealReasons: [.manualExpansion, .searchMatch, .zoom]
            )
        ])
    }

    func testRevealReasonsAccumulateOnADefaultExpandedSession() {
        let projection = makeProjection(
            persisted: [session(IDs.root, "Running", nil, .running)]
        )

        let layout = OrchestrationGraphLayout.make(
            projection: projection,
            manuallyExpandedSessionIDs: [IDs.root],
            searchQuery: "running",
            zoom: OrchestrationGraphLayout.revealZoomThreshold
        )

        XCTAssertEqual(layout.placements, [
            .init(
                sessionID: IDs.root,
                clusterKey: .unassigned,
                revealReasons: [.defaultExpanded, .manualExpansion, .searchMatch, .zoom]
            )
        ])
    }

    func testLookupsReturnNilOrFalseForUnknownIDs() {
        let projection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Alpha")],
            persisted: [
                session(IDs.root, "Running", IDs.workspace1, .running),
                session(IDs.child, "Completed", IDs.workspace1, .completed)
            ]
        )
        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(
            layout.placement(forSessionID: IDs.root),
            .init(
                sessionID: IDs.root,
                clusterKey: .workspace(IDs.workspace1),
                revealReasons: [.defaultExpanded]
            )
        )
        XCTAssertEqual(
            layout.placement(forSessionID: IDs.child),
            .init(sessionID: IDs.child, clusterKey: .workspace(IDs.workspace1), revealReasons: [])
        )
        XCTAssertEqual(
            layout.cluster(for: .workspace(IDs.workspace1)),
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Alpha",
                sessionIDs: [IDs.root, IDs.child]
            )
        )
        XCTAssertTrue(layout.isRevealed(sessionID: IDs.root))
        XCTAssertFalse(layout.isRevealed(sessionID: IDs.child))
        XCTAssertNil(layout.placement(forSessionID: IDs.unknownParent))
        XCTAssertNil(layout.cluster(for: .workspace(IDs.unknownWorkspace)))
        XCTAssertFalse(layout.isRevealed(sessionID: IDs.unknownParent))
    }

    func testClusterAndPlacementOrderIsDeterministic() {
        let projection = makeProjection(
            workspaces: [
                .init(id: IDs.workspace1, name: "Same"),
                .init(id: IDs.workspace2, name: "Same"),
                .init(id: IDs.workspace3, name: "")
            ],
            persisted: [
                session(IDs.root, "Workspace One", IDs.workspace1, .completed),
                session(IDs.child, "Workspace Two", IDs.workspace2, .completed),
                session(IDs.historyRoot, "Empty Name", IDs.workspace3, .completed),
                session(IDs.historyChild, "Unknown", IDs.unknownWorkspace, .completed),
                session(IDs.sibling, "Unassigned", nil, .completed)
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace3),
                workspaceID: IDs.workspace3,
                workspaceName: "",
                sessionIDs: [IDs.historyRoot]
            ),
            .init(
                key: .workspace(IDs.workspace2),
                workspaceID: IDs.workspace2,
                workspaceName: "Same",
                sessionIDs: [IDs.child]
            ),
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Same",
                sessionIDs: [IDs.root]
            ),
            .init(
                key: .workspace(IDs.unknownWorkspace),
                workspaceID: IDs.unknownWorkspace,
                workspaceName: nil,
                sessionIDs: [IDs.historyChild]
            ),
            .init(
                key: .unassigned,
                workspaceID: nil,
                workspaceName: nil,
                sessionIDs: [IDs.sibling]
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.historyRoot, clusterKey: .workspace(IDs.workspace3), revealReasons: []),
            .init(sessionID: IDs.child, clusterKey: .workspace(IDs.workspace2), revealReasons: []),
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.workspace1), revealReasons: []),
            .init(
                sessionID: IDs.historyChild,
                clusterKey: .workspace(IDs.unknownWorkspace),
                revealReasons: []
            ),
            .init(sessionID: IDs.sibling, clusterKey: .unassigned, revealReasons: [])
        ])
    }

    func testLayoutIsPureAndRepeatable() {
        let projection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Alpha")],
            persisted: [session(IDs.root, "Root", IDs.workspace1, .completed)]
        )
        let originalProjection = projection

        let first = OrchestrationGraphLayout.make(
            projection: projection,
            manuallyExpandedSessionIDs: [IDs.root],
            searchQuery: "root",
            zoom: OrchestrationGraphLayout.revealZoomThreshold
        )
        let second = OrchestrationGraphLayout.make(
            projection: projection,
            manuallyExpandedSessionIDs: [IDs.root],
            searchQuery: "root",
            zoom: OrchestrationGraphLayout.revealZoomThreshold
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(projection, originalProjection)
    }

    func testSessionInAWorkspaceAbsentFromTheProjectionGetsItsOwnNamelessCluster() {
        let projection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Zulu")],
            persisted: [session(IDs.root, "Root", IDs.unknownWorkspace, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Zulu",
                sessionIDs: []
            ),
            .init(
                key: .workspace(IDs.unknownWorkspace),
                workspaceID: IDs.unknownWorkspace,
                workspaceName: nil,
                sessionIDs: [IDs.root]
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .workspace(IDs.unknownWorkspace), revealReasons: [])
        ])
    }

    func testSessionWithNilWorkspaceIDLandsInTheUnassignedCluster() {
        let projection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Zulu")],
            persisted: [session(IDs.root, "Root", nil, .completed)]
        )
        let assignedProjection = makeProjection(
            workspaces: [.init(id: IDs.workspace1, name: "Zulu")],
            persisted: [session(IDs.child, "Child", IDs.workspace1, .completed)]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)
        let assignedLayout = OrchestrationGraphLayout.make(projection: assignedProjection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Zulu",
                sessionIDs: []
            ),
            .init(
                key: .unassigned,
                workspaceID: nil,
                workspaceName: nil,
                sessionIDs: [IDs.root]
            )
        ])
        XCTAssertEqual(layout.placements, [
            .init(sessionID: IDs.root, clusterKey: .unassigned, revealReasons: [])
        ])
        XCTAssertEqual(assignedLayout.clusters, [
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Zulu",
                sessionIDs: [IDs.child]
            )
        ])
    }

    func testWorkspaceWithNoSessionsStillProducesACluster() {
        let projection = makeProjection(
            workspaces: [
                .init(id: IDs.workspace1, name: "Zulu"),
                .init(id: IDs.workspace2, name: "Alpha")
            ]
        )

        let layout = OrchestrationGraphLayout.make(projection: projection)

        XCTAssertEqual(layout.clusters, [
            .init(
                key: .workspace(IDs.workspace2),
                workspaceID: IDs.workspace2,
                workspaceName: "Alpha",
                sessionIDs: []
            ),
            .init(
                key: .workspace(IDs.workspace1),
                workspaceID: IDs.workspace1,
                workspaceName: "Zulu",
                sessionIDs: []
            )
        ])
        XCTAssertEqual(layout.placements, [])
    }

    private enum IDs {
        static let workspace1 = uuid("00000000-0000-0000-0000-000000000002")
        static let workspace2 = uuid("00000000-0000-0000-0000-000000000001")
        static let workspace3 = uuid("00000000-0000-0000-0000-000000000003")
        static let unknownWorkspace = uuid("00000000-0000-0000-0000-000000000009")
        static let root = uuid("00000000-0000-0000-0000-000000000101")
        static let child = uuid("00000000-0000-0000-0000-000000000102")
        static let historyRoot = uuid("00000000-0000-0000-0000-000000000201")
        static let historyChild = uuid("00000000-0000-0000-0000-000000000202")
        static let sibling = uuid("00000000-0000-0000-0000-000000000203")
        static let unknownParent = uuid("00000000-0000-0000-0000-000000000999")
    }

    private func makeProjection(
        workspaces: [OrchestrationGraphProjection.WorkspaceInput] = [],
        persisted: [OrchestrationGraphProjection.PersistedSessionInput] = [],
        live: [OrchestrationGraphProjection.LiveSessionInput] = []
    ) -> OrchestrationGraphProjection {
        OrchestrationGraphProjection.make(
            workspaces: workspaces,
            persisted: persisted,
            live: live,
            isHistoryScanIncomplete: false
        )
    }

    private func session(
        _ id: UUID,
        _ name: String,
        _ workspaceID: UUID?,
        _ runState: OrchestrationGraphProjection.SessionRunState,
        parentSessionID: UUID? = nil
    ) -> OrchestrationGraphProjection.PersistedSessionInput {
        .init(
            sessionID: id,
            workspaceID: workspaceID,
            name: name,
            parentSessionID: parentSessionID,
            runState: runState
        )
    }

    private func liveSession(
        _ id: UUID,
        _ name: String,
        _ workspaceID: UUID?,
        _ runState: OrchestrationGraphProjection.SessionRunState,
        parentSessionID: UUID? = nil
    ) -> OrchestrationGraphProjection.LiveSessionInput {
        .init(
            sessionID: id,
            workspaceID: workspaceID,
            name: name,
            parentSessionID: parentSessionID,
            runState: runState,
            statusText: nil
        )
    }

    private static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
