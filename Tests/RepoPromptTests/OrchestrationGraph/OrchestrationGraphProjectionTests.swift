import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

final class OrchestrationGraphProjectionTests: XCTestCase {
    func testDW2FixtureThroughProductionInputsProducesExactNodesAndEdges() {
        let fixture = makeDW2Fixture(isHistoryScanIncomplete: true)

        let projection = OrchestrationGraphProjection.make(
            workspaces: fixture.workspaces,
            persistedIndexesByWorkspaceID: fixture.persisted,
            liveSnapshotsByWorkspaceID: fixture.live,
            isHistoryScanIncomplete: fixture.isHistoryScanIncomplete
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            .workspace(id: IDs.workspace2, name: "Workspace Two"),
            .session(
                .init(
                    sessionID: IDs.root,
                    name: "Root Live",
                    workspaceID: IDs.workspace1,
                    status: .init(runState: .running, statusText: "Thinking…", isLive: true),
                    unresolvedParentSessionID: nil
                )
            ),
            .session(
                .init(
                    sessionID: IDs.child,
                    name: "Child",
                    workspaceID: IDs.workspace1,
                    status: .init(runState: .idle, statusText: nil, isLive: false),
                    unresolvedParentSessionID: nil
                )
            ),
            .session(
                .init(
                    sessionID: IDs.historyRoot,
                    name: "History Root",
                    workspaceID: IDs.workspace2,
                    status: .init(runState: .completed, statusText: nil, isLive: false),
                    unresolvedParentSessionID: nil
                )
            ),
            .session(
                .init(
                    sessionID: IDs.historyChild,
                    name: "History Child",
                    workspaceID: IDs.workspace2,
                    status: .init(runState: .completed, statusText: nil, isLive: false),
                    unresolvedParentSessionID: nil
                )
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace2), .session(IDs.historyRoot), .membership),
            edge(.session(IDs.root), .session(IDs.child), .dispatch),
            edge(.session(IDs.historyRoot), .session(IDs.historyChild), .dispatch)
        ]

        assertProjection(projection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(projection.isHistoryScanIncomplete, true)
        XCTAssertEqual(
            projection.nodes.count(where: { $0.id == .session(IDs.root) }),
            1
        )
    }

    func testParentSessionIDCreatesDispatchEvenWhenComposeTabsDiffer() {
        let orchestrateTab = UUID()
        let reviewTab = UUID()
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persisted: [
                .init(
                    sessionID: IDs.root,
                    workspaceID: IDs.workspace1,
                    name: "WF - ORCHESTRATE",
                    parentSessionID: nil,
                    runState: .running,
                    composeTabID: orchestrateTab
                ),
                .init(
                    sessionID: IDs.child,
                    workspaceID: IDs.workspace1,
                    name: "WF - REVIEW",
                    parentSessionID: IDs.root,
                    runState: .running,
                    composeTabID: reviewTab
                )
            ],
            live: [],
            isHistoryScanIncomplete: false
        )
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .membership && $0.source == .workspace(IDs.workspace1) && $0.target == .session(IDs.root)
        })
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .dispatch && $0.source == .session(IDs.root) && $0.target == .session(IDs.child)
        })
        XCTAssertFalse(projection.edges.contains {
            $0.kind == .membership && $0.target == .session(IDs.child)
        })
    }

    func testChildWithoutComposeTabStillDispatchesToParent() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persisted: [
                .init(
                    sessionID: IDs.root,
                    workspaceID: IDs.workspace1,
                    name: "WF - ORCHESTRATE",
                    parentSessionID: nil,
                    runState: .running,
                    composeTabID: UUID()
                ),
                .init(
                    sessionID: IDs.child,
                    workspaceID: IDs.workspace1,
                    name: "WF - REVIEW",
                    parentSessionID: IDs.root,
                    runState: .completed
                )
            ],
            live: [],
            isHistoryScanIncomplete: false
        )
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .dispatch && $0.source == .session(IDs.root) && $0.target == .session(IDs.child)
        })
        XCTAssertFalse(projection.edges.contains {
            $0.kind == .membership && $0.target == .session(IDs.child)
        })
    }

    func testNestedThreadOnSameComposeTabKeepsDispatch() {
        let tab = UUID()
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persisted: [
                .init(
                    sessionID: IDs.root,
                    workspaceID: IDs.workspace1,
                    name: "TL",
                    parentSessionID: nil,
                    runState: .running,
                    composeTabID: tab
                ),
                .init(
                    sessionID: IDs.child,
                    workspaceID: IDs.workspace1,
                    name: "WORKER",
                    parentSessionID: IDs.root,
                    runState: .running,
                    composeTabID: tab
                )
            ],
            live: [],
            isHistoryScanIncomplete: false
        )
        XCTAssertTrue(projection.edges.contains {
            $0.kind == .dispatch && $0.source == .session(IDs.root) && $0.target == .session(IDs.child)
        })
        XCTAssertFalse(projection.edges.contains {
            $0.kind == .membership && $0.target == .session(IDs.child)
        })
    }

    func testLiveEntryReplacesStalePersistedEntryForSameSessionID() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.root,
                        name: "Root Stale",
                        parentSessionID: nil,
                        runState: .completed
                    ),
                    persistedSession(
                        id: IDs.historyRoot,
                        name: "History Root",
                        parentSessionID: nil,
                        runState: .completed
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [
                IDs.workspace1: [
                    liveSession(
                        id: IDs.root,
                        name: "Root Live",
                        parentSessionID: nil,
                        status: .running,
                        statusText: "Thinking…"
                    )
                ]
            ],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            .session(
                .init(
                    sessionID: IDs.root,
                    name: "Root Live",
                    workspaceID: IDs.workspace1,
                    status: .init(runState: .running, statusText: "Thinking…", isLive: true),
                    unresolvedParentSessionID: nil
                )
            ),
            .session(
                .init(
                    sessionID: IDs.historyRoot,
                    name: "History Root",
                    workspaceID: IDs.workspace1,
                    status: .init(runState: .completed, statusText: nil, isLive: false),
                    unresolvedParentSessionID: nil
                )
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.historyRoot), .membership)
        ]

        assertProjection(projection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
        XCTAssertEqual(projection.nodes.count(where: { $0.id == .session(IDs.root) }), 1)
    }

    func testLiveEntryReplacesPersistedParentRatherThanMerging() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.historyRoot,
                        name: "History Root",
                        parentSessionID: nil,
                        runState: .completed
                    ),
                    persistedSession(
                        id: IDs.root,
                        name: "Root Stale",
                        parentSessionID: IDs.historyRoot,
                        runState: .completed
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [
                IDs.workspace1: [
                    liveSession(
                        id: IDs.root,
                        name: "Root Live",
                        parentSessionID: nil,
                        status: .running,
                        statusText: "Thinking…"
                    )
                ]
            ],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            .session(
                .init(
                    sessionID: IDs.root,
                    name: "Root Live",
                    workspaceID: IDs.workspace1,
                    status: .init(runState: .running, statusText: "Thinking…", isLive: true),
                    unresolvedParentSessionID: nil
                )
            ),
            .session(
                .init(
                    sessionID: IDs.historyRoot,
                    name: "History Root",
                    workspaceID: IDs.workspace1,
                    status: .init(runState: .completed, statusText: nil, isLive: false),
                    unresolvedParentSessionID: nil
                )
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.historyRoot), .membership)
        ]

        assertProjection(projection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
        XCTAssertEqual(
            projection.edges.count(where: {
                $0.source == .session(IDs.historyRoot)
                    && $0.target == .session(IDs.root)
                    && $0.kind == .dispatch
            }),
            0
        )
    }

    func testSiblingWithDifferentParentIsNotAnEdgeFromR() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(id: IDs.root, name: "Root", parentSessionID: nil, runState: .running),
                    persistedSession(id: IDs.child, name: "Child", parentSessionID: IDs.root, runState: .running),
                    persistedSession(
                        id: IDs.historyRoot,
                        name: "History Root",
                        parentSessionID: nil,
                        runState: .completed
                    ),
                    persistedSession(
                        id: IDs.sibling,
                        name: "Sibling",
                        parentSessionID: IDs.historyRoot,
                        runState: .completed
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [:],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            sessionNode(
                id: IDs.root,
                name: "Root",
                workspaceID: IDs.workspace1,
                runState: .running
            ),
            sessionNode(
                id: IDs.child,
                name: "Child",
                workspaceID: IDs.workspace1,
                runState: .running
            ),
            sessionNode(
                id: IDs.historyRoot,
                name: "History Root",
                workspaceID: IDs.workspace1,
                runState: .completed
            ),
            sessionNode(
                id: IDs.sibling,
                name: "Sibling",
                workspaceID: IDs.workspace1,
                runState: .completed
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.historyRoot), .membership),
            edge(.session(IDs.root), .session(IDs.child), .dispatch),
            edge(.session(IDs.historyRoot), .session(IDs.sibling), .dispatch)
        ]

        assertProjection(projection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
        XCTAssertEqual(
            projection.edges.count(where: {
                $0.source == .session(IDs.root)
                    && $0.target == .session(IDs.sibling)
                    && $0.kind == .dispatch
            }),
            0
        )
    }

    func testUnknownParentSessionIDCreatesNoPhantomNodeOrEdge() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.child,
                        name: "Child",
                        parentSessionID: IDs.unknownParent,
                        runState: .running
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [:],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            sessionNode(
                id: IDs.child,
                name: "Child",
                workspaceID: IDs.workspace1,
                runState: .running,
                unresolvedParentSessionID: IDs.unknownParent
            )
        ]

        assertProjection(
            projection,
            nodes: expectedNodes,
            edges: [edge(.workspace(IDs.workspace1), .session(IDs.child), .membership)]
        )
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
        XCTAssertEqual(projection.nodes.count(where: { $0.id == .session(IDs.unknownParent) }), 0)
    }

    func testSelfParentIsUnresolvedAndProducesNoSelfLoop() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.root,
                        name: "Root",
                        parentSessionID: IDs.root,
                        runState: .running
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [:],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            sessionNode(
                id: IDs.root,
                name: "Root",
                workspaceID: IDs.workspace1,
                runState: .running,
                unresolvedParentSessionID: IDs.root
            )
        ]

        assertProjection(
            projection,
            nodes: expectedNodes,
            edges: [edge(.workspace(IDs.workspace1), .session(IDs.root), .membership)]
        )
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
        XCTAssertEqual(
            projection.edges.count(where: {
                $0.source == .session(IDs.root)
                    && $0.target == .session(IDs.root)
                    && $0.kind == .dispatch
            }),
            0
        )
    }

    func testSessionWithUnknownWorkspaceKeepsItsNodeWithoutMembershipEdge() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.unknownWorkspace: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.root,
                        name: "Root",
                        parentSessionID: nil,
                        runState: .completed
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [:],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            sessionNode(
                id: IDs.root,
                name: "Root",
                workspaceID: IDs.unknownWorkspace,
                runState: .completed
            )
        ]

        assertProjection(projection, nodes: expectedNodes, edges: [])
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
    }

    func testIncompleteHistoryScanIsAFieldNotOmittedNodes() {
        let incompleteFixture = makeDW2Fixture(isHistoryScanIncomplete: true)
        let completeFixture = makeDW2Fixture(isHistoryScanIncomplete: false)

        let incomplete = OrchestrationGraphProjection.make(
            workspaces: incompleteFixture.workspaces,
            persistedIndexesByWorkspaceID: incompleteFixture.persisted,
            liveSnapshotsByWorkspaceID: incompleteFixture.live,
            isHistoryScanIncomplete: incompleteFixture.isHistoryScanIncomplete
        )
        let complete = OrchestrationGraphProjection.make(
            workspaces: completeFixture.workspaces,
            persistedIndexesByWorkspaceID: completeFixture.persisted,
            liveSnapshotsByWorkspaceID: completeFixture.live,
            isHistoryScanIncomplete: completeFixture.isHistoryScanIncomplete
        )
        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            .workspace(id: IDs.workspace2, name: "Workspace Two"),
            sessionNode(
                id: IDs.root,
                name: "Root Live",
                workspaceID: IDs.workspace1,
                runState: .running,
                statusText: "Thinking…",
                isLive: true
            ),
            sessionNode(
                id: IDs.child,
                name: "Child",
                workspaceID: IDs.workspace1,
                runState: .idle
            ),
            sessionNode(
                id: IDs.historyRoot,
                name: "History Root",
                workspaceID: IDs.workspace2,
                runState: .completed
            ),
            sessionNode(
                id: IDs.historyChild,
                name: "History Child",
                workspaceID: IDs.workspace2,
                runState: .completed
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace2), .session(IDs.historyRoot), .membership),
            edge(.session(IDs.root), .session(IDs.child), .dispatch),
            edge(.session(IDs.historyRoot), .session(IDs.historyChild), .dispatch)
        ]

        assertProjection(incomplete, nodes: expectedNodes, edges: expectedEdges)
        assertProjection(complete, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(incomplete.isHistoryScanIncomplete, true)
        XCTAssertEqual(complete.isHistoryScanIncomplete, false)
        XCTAssertEqual(incomplete.nodes, complete.nodes)
        XCTAssertEqual(incomplete.edges, complete.edges)
    }

    func testProjectionIsOrderIndependentForUniqueIDInputs() {
        let workspaces: [OrchestrationGraphProjection.WorkspaceInput] = [
            .init(id: IDs.workspace1, name: "Workspace One"),
            .init(id: IDs.workspace2, name: "Workspace Two")
        ]
        let persisted: [OrchestrationGraphProjection.PersistedSessionInput] = [
            .init(
                sessionID: IDs.root,
                workspaceID: IDs.workspace1,
                name: "Root",
                parentSessionID: nil,
                runState: .running
            ),
            .init(
                sessionID: IDs.child,
                workspaceID: IDs.workspace1,
                name: "Child",
                parentSessionID: IDs.root,
                runState: .running
            ),
            .init(
                sessionID: IDs.historyRoot,
                workspaceID: IDs.workspace2,
                name: "History Root",
                parentSessionID: nil,
                runState: .completed
            )
        ]
        let live: [OrchestrationGraphProjection.LiveSessionInput] = [
            .init(
                sessionID: IDs.sibling,
                workspaceID: IDs.workspace2,
                name: "Sibling",
                parentSessionID: IDs.historyRoot,
                runState: .running,
                statusText: "Working"
            )
        ]

        let forward = OrchestrationGraphProjection.make(
            workspaces: workspaces,
            persisted: persisted,
            live: live,
            isHistoryScanIncomplete: false
        )
        let reversed = OrchestrationGraphProjection.make(
            workspaces: Array(workspaces.reversed()),
            persisted: Array(persisted.reversed()),
            live: Array(live.reversed()),
            isHistoryScanIncomplete: false
        )
        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            .workspace(id: IDs.workspace2, name: "Workspace Two"),
            sessionNode(
                id: IDs.root,
                name: "Root",
                workspaceID: IDs.workspace1,
                runState: .running
            ),
            sessionNode(
                id: IDs.child,
                name: "Child",
                workspaceID: IDs.workspace1,
                runState: .running
            ),
            sessionNode(
                id: IDs.historyRoot,
                name: "History Root",
                workspaceID: IDs.workspace2,
                runState: .completed
            ),
            sessionNode(
                id: IDs.sibling,
                name: "Sibling",
                workspaceID: IDs.workspace2,
                runState: .running,
                statusText: "Working",
                isLive: true
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace2), .session(IDs.historyRoot), .membership),
            edge(.session(IDs.root), .session(IDs.child), .dispatch),
            edge(.session(IDs.historyRoot), .session(IDs.sibling), .dispatch)
        ]

        assertProjection(forward, nodes: expectedNodes, edges: expectedEdges)
        assertProjection(reversed, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(forward, reversed)
    }

    func testConflictingDuplicateIDsInOneTierResolveLastWins() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [
                .init(id: IDs.workspace1, name: "First Workspace"),
                .init(id: IDs.workspace1, name: "Last Workspace")
            ],
            persisted: [
                .init(
                    sessionID: IDs.root,
                    workspaceID: IDs.workspace1,
                    name: "First Session",
                    parentSessionID: nil,
                    runState: .idle
                ),
                .init(
                    sessionID: IDs.root,
                    workspaceID: IDs.workspace1,
                    name: "Last Session",
                    parentSessionID: nil,
                    runState: .completed
                )
            ],
            live: [],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Last Workspace"),
            sessionNode(
                id: IDs.root,
                name: "Last Session",
                workspaceID: IDs.workspace1,
                runState: .completed
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership)
        ]

        assertProjection(projection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
    }

    func testProductionFactoryFlattensWorkspaceKeysInUUIDOrderLastWins() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [
                .init(id: IDs.workspace1, name: "Workspace One"),
                .init(id: IDs.workspace2, name: "Workspace Two")
            ],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.child,
                        name: "From First Workspace",
                        parentSessionID: nil,
                        runState: .idle
                    )
                ]),
                IDs.workspace2: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.historyRoot,
                        name: "Parent",
                        parentSessionID: nil,
                        runState: .running
                    ),
                    persistedSession(
                        id: IDs.child,
                        name: "From Last Workspace",
                        parentSessionID: IDs.historyRoot,
                        runState: .completed
                    )
                ])
            ],
            liveSnapshotsByWorkspaceID: [:],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            .workspace(id: IDs.workspace2, name: "Workspace Two"),
            sessionNode(
                id: IDs.child,
                name: "From Last Workspace",
                workspaceID: IDs.workspace2,
                runState: .completed
            ),
            sessionNode(
                id: IDs.historyRoot,
                name: "Parent",
                workspaceID: IDs.workspace2,
                runState: .running
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace2), .session(IDs.historyRoot), .membership),
            edge(.session(IDs.historyRoot), .session(IDs.child), .dispatch)
        ]

        assertProjection(projection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
    }

    func testProductionFactoryExcludesQuarantinedFiles() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(
                    entries: [],
                    quarantinedFiles: [
                        AgentSessionMetadataQuarantineRecord(
                            filename: "AgentSession-\(IDs.root.uuidString).json",
                            observedFileSize: 100,
                            observedFileModificationDate: Date(timeIntervalSinceReferenceDate: 2),
                            errorDescription: "Unreadable fixture",
                            lastAttemptedAt: Date(timeIntervalSinceReferenceDate: 3)
                        )
                    ]
                )
            ],
            liveSnapshotsByWorkspaceID: [:],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One")
        ]

        assertProjection(projection, nodes: expectedNodes, edges: [])
        XCTAssertEqual(projection.nodes.count(where: { $0.id == .session(IDs.root) }), 0)
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
    }

    func testWorkspaceOrderingUsesNameThenUUIDString() {
        let projection = OrchestrationGraphProjection.make(
            workspaces: [
                .init(id: IDs.workspace2, name: "Zulu"),
                .init(id: IDs.unknownWorkspace, name: "Alpha"),
                .init(id: IDs.workspace1, name: "Zulu")
            ],
            persisted: [],
            live: [],
            isHistoryScanIncomplete: false
        )

        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.unknownWorkspace, name: "Alpha"),
            .workspace(id: IDs.workspace1, name: "Zulu"),
            .workspace(id: IDs.workspace2, name: "Zulu")
        ]

        assertProjection(projection, nodes: expectedNodes, edges: [])
        XCTAssertEqual(projection.isHistoryScanIncomplete, false)
    }

    func testWaitingStatesStayDistinctAcrossBothVocabularies() {
        let persistedRecords = [
            persistedSession(id: IDs.root, name: "Waiting User", parentSessionID: nil, runState: .waitingForUser),
            persistedSession(
                id: IDs.child,
                name: "Waiting Question",
                parentSessionID: nil,
                runState: .waitingForQuestion
            ),
            persistedSession(
                id: IDs.historyRoot,
                name: "Waiting Approval",
                parentSessionID: nil,
                runState: .waitingForApproval
            ),
            persistedSession(
                id: IDs.historyChild,
                name: "Unknown",
                parentSessionID: nil,
                runState: nil,
                runStateRaw: "futureState"
            ),
            persistedSession(id: IDs.sibling, name: "Unspecified", parentSessionID: nil, runState: nil)
        ]
        let liveSnapshots = [
            liveSession(
                id: IDs.liveUser,
                name: "Live User",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil
            ),
            liveSession(
                id: IDs.liveQuestion,
                name: "Live Question",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil,
                interaction: interaction(kind: .question)
            ),
            liveSession(
                id: IDs.liveApproval,
                name: "Live Approval",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil,
                interaction: interaction(kind: .approval)
            ),
            liveSession(
                id: IDs.liveHookApproval,
                name: "Live Hook Approval",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil,
                interaction: interaction(kind: .hookApproval)
            ),
            liveSession(
                id: IDs.liveMCPElicitation,
                name: "Live MCP Elicitation",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil,
                interaction: interaction(kind: .mcpElicitation)
            ),
            liveSession(
                id: IDs.liveInstruction,
                name: "Live Instruction",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil,
                interaction: interaction(kind: .instruction)
            ),
            liveSession(
                id: IDs.liveInput,
                name: "Live Input",
                parentSessionID: nil,
                status: .waitingForInput,
                statusText: nil,
                interaction: interaction(kind: .userInput)
            )
        ]
        let productionProjection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persistedIndexesByWorkspaceID: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: persistedRecords)
            ],
            liveSnapshotsByWorkspaceID: [IDs.workspace1: liveSnapshots],
            isHistoryScanIncomplete: false
        )
        let dtoProjection = OrchestrationGraphProjection.make(
            workspaces: [.init(id: IDs.workspace1, name: "Workspace One")],
            persisted: [
                .init(
                    sessionID: IDs.root,
                    workspaceID: IDs.workspace1,
                    name: "Waiting User",
                    parentSessionID: nil,
                    runState: .waitingForUser
                ),
                .init(
                    sessionID: IDs.child,
                    workspaceID: IDs.workspace1,
                    name: "Waiting Question",
                    parentSessionID: nil,
                    runState: .waitingForQuestion
                ),
                .init(
                    sessionID: IDs.historyRoot,
                    workspaceID: IDs.workspace1,
                    name: "Waiting Approval",
                    parentSessionID: nil,
                    runState: .waitingForApproval
                ),
                .init(
                    sessionID: IDs.historyChild,
                    workspaceID: IDs.workspace1,
                    name: "Unknown",
                    parentSessionID: nil,
                    runState: .unknown("futureState")
                ),
                .init(
                    sessionID: IDs.sibling,
                    workspaceID: IDs.workspace1,
                    name: "Unspecified",
                    parentSessionID: nil,
                    runState: .unspecified
                )
            ],
            live: [
                .init(
                    sessionID: IDs.liveUser,
                    workspaceID: IDs.workspace1,
                    name: "Live User",
                    parentSessionID: nil,
                    runState: .waitingForUser,
                    statusText: nil
                ),
                .init(
                    sessionID: IDs.liveQuestion,
                    workspaceID: IDs.workspace1,
                    name: "Live Question",
                    parentSessionID: nil,
                    runState: .waitingForQuestion,
                    statusText: nil
                ),
                .init(
                    sessionID: IDs.liveApproval,
                    workspaceID: IDs.workspace1,
                    name: "Live Approval",
                    parentSessionID: nil,
                    runState: .waitingForApproval,
                    statusText: nil
                ),
                .init(
                    sessionID: IDs.liveHookApproval,
                    workspaceID: IDs.workspace1,
                    name: "Live Hook Approval",
                    parentSessionID: nil,
                    runState: .waitingForApproval,
                    statusText: nil
                ),
                .init(
                    sessionID: IDs.liveMCPElicitation,
                    workspaceID: IDs.workspace1,
                    name: "Live MCP Elicitation",
                    parentSessionID: nil,
                    runState: .waitingForQuestion,
                    statusText: nil
                ),
                .init(
                    sessionID: IDs.liveInstruction,
                    workspaceID: IDs.workspace1,
                    name: "Live Instruction",
                    parentSessionID: nil,
                    runState: .waitingForUser,
                    statusText: nil
                ),
                .init(
                    sessionID: IDs.liveInput,
                    workspaceID: IDs.workspace1,
                    name: "Live Input",
                    parentSessionID: nil,
                    runState: .waitingForUser,
                    statusText: nil
                )
            ],
            isHistoryScanIncomplete: false
        )
        let expectedNodes: [OrchestrationGraphProjection.Node] = [
            .workspace(id: IDs.workspace1, name: "Workspace One"),
            sessionNode(
                id: IDs.root,
                name: "Waiting User",
                workspaceID: IDs.workspace1,
                runState: .waitingForUser
            ),
            sessionNode(
                id: IDs.child,
                name: "Waiting Question",
                workspaceID: IDs.workspace1,
                runState: .waitingForQuestion
            ),
            sessionNode(
                id: IDs.historyRoot,
                name: "Waiting Approval",
                workspaceID: IDs.workspace1,
                runState: .waitingForApproval
            ),
            sessionNode(
                id: IDs.historyChild,
                name: "Unknown",
                workspaceID: IDs.workspace1,
                runState: .unknown("futureState")
            ),
            sessionNode(
                id: IDs.sibling,
                name: "Unspecified",
                workspaceID: IDs.workspace1,
                runState: .unspecified
            ),
            sessionNode(
                id: IDs.liveUser,
                name: "Live User",
                workspaceID: IDs.workspace1,
                runState: .waitingForUser,
                isLive: true
            ),
            sessionNode(
                id: IDs.liveQuestion,
                name: "Live Question",
                workspaceID: IDs.workspace1,
                runState: .waitingForQuestion,
                isLive: true
            ),
            sessionNode(
                id: IDs.liveApproval,
                name: "Live Approval",
                workspaceID: IDs.workspace1,
                runState: .waitingForApproval,
                isLive: true
            ),
            sessionNode(
                id: IDs.liveHookApproval,
                name: "Live Hook Approval",
                workspaceID: IDs.workspace1,
                runState: .waitingForApproval,
                isLive: true
            ),
            sessionNode(
                id: IDs.liveMCPElicitation,
                name: "Live MCP Elicitation",
                workspaceID: IDs.workspace1,
                runState: .waitingForQuestion,
                isLive: true
            ),
            sessionNode(
                id: IDs.liveInstruction,
                name: "Live Instruction",
                workspaceID: IDs.workspace1,
                runState: .waitingForUser,
                isLive: true
            ),
            sessionNode(
                id: IDs.liveInput,
                name: "Live Input",
                workspaceID: IDs.workspace1,
                runState: .waitingForUser,
                isLive: true
            )
        ]
        let expectedEdges: [OrchestrationGraphProjection.Edge] = [
            edge(.workspace(IDs.workspace1), .session(IDs.root), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.child), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.historyRoot), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.historyChild), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.sibling), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveUser), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveQuestion), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveApproval), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveHookApproval), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveMCPElicitation), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveInstruction), .membership),
            edge(.workspace(IDs.workspace1), .session(IDs.liveInput), .membership)
        ]

        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.root)?.runState,
            .waitingForUser
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.child)?.runState,
            .waitingForQuestion
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.historyRoot)?.runState,
            .waitingForApproval
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.liveQuestion)?.runState,
            .waitingForQuestion
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.liveApproval)?.runState,
            .waitingForApproval
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.liveHookApproval)?.runState,
            .waitingForApproval
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.liveMCPElicitation)?.runState,
            .waitingForQuestion
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.liveInstruction)?.runState,
            .waitingForUser
        )
        XCTAssertEqual(
            sessionStatus(in: productionProjection, sessionID: IDs.liveInput)?.runState,
            .waitingForUser
        )
        assertProjection(productionProjection, nodes: expectedNodes, edges: expectedEdges)
        assertProjection(dtoProjection, nodes: expectedNodes, edges: expectedEdges)
        XCTAssertEqual(productionProjection, dtoProjection)
    }

    private struct DW2Fixture {
        let workspaces: [OrchestrationGraphProjection.WorkspaceInput]
        let persisted: [UUID: AgentSessionMetadataIndex]
        let live: [UUID: [DomainAgentRunSnapshot]]
        let isHistoryScanIncomplete: Bool
    }

    private enum IDs {
        static let workspace1 = uuid("00000000-0000-0000-0000-000000000001")
        static let workspace2 = uuid("00000000-0000-0000-0000-000000000002")
        static let unknownWorkspace = uuid("00000000-0000-0000-0000-000000000009")
        static let root = uuid("00000000-0000-0000-0000-000000000101")
        static let child = uuid("00000000-0000-0000-0000-000000000102")
        static let historyRoot = uuid("00000000-0000-0000-0000-000000000201")
        static let historyChild = uuid("00000000-0000-0000-0000-000000000202")
        static let sibling = uuid("00000000-0000-0000-0000-000000000203")
        static let unknownParent = uuid("00000000-0000-0000-0000-000000000999")
        static let liveUser = uuid("00000000-0000-0000-0000-000000000301")
        static let liveQuestion = uuid("00000000-0000-0000-0000-000000000302")
        static let liveApproval = uuid("00000000-0000-0000-0000-000000000303")
        static let liveHookApproval = uuid("00000000-0000-0000-0000-000000000304")
        static let liveMCPElicitation = uuid("00000000-0000-0000-0000-000000000305")
        static let liveInstruction = uuid("00000000-0000-0000-0000-000000000306")
        static let liveInput = uuid("00000000-0000-0000-0000-000000000307")
        static let interaction = uuid("00000000-0000-0000-0000-000000000401")
    }

    private func makeDW2Fixture(isHistoryScanIncomplete: Bool) -> DW2Fixture {
        DW2Fixture(
            workspaces: [
                .init(id: IDs.workspace1, name: "Workspace One"),
                .init(id: IDs.workspace2, name: "Workspace Two")
            ],
            persisted: [
                IDs.workspace1: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.root,
                        name: "Root Stale",
                        parentSessionID: nil,
                        runState: .completed
                    ),
                    persistedSession(
                        id: IDs.child,
                        name: "Child",
                        parentSessionID: IDs.root,
                        runState: .idle
                    )
                ]),
                IDs.workspace2: AgentSessionMetadataIndex(entries: [
                    persistedSession(
                        id: IDs.historyRoot,
                        name: "History Root",
                        parentSessionID: nil,
                        runState: .completed
                    ),
                    persistedSession(
                        id: IDs.historyChild,
                        name: "History Child",
                        parentSessionID: IDs.historyRoot,
                        runState: .completed
                    )
                ])
            ],
            live: [
                IDs.workspace1: [
                    liveSession(
                        id: IDs.root,
                        name: "Root Live",
                        parentSessionID: nil,
                        status: .running,
                        statusText: "Thinking…"
                    )
                ]
            ],
            isHistoryScanIncomplete: isHistoryScanIncomplete
        )
    }

    private func persistedSession(
        id: UUID,
        name: String,
        parentSessionID: UUID?,
        runState: AgentSessionRunState?,
        runStateRaw: String? = nil
    ) -> AgentSessionMetadataRecord {
        let timestamp = Date(timeIntervalSinceReferenceDate: 1)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: name,
            savedAt: timestamp,
            lastUserMessageAt: nil,
            itemCount: 0,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: runStateRaw ?? runState?.rawValue,
            autoEditEnabled: true,
            parentSessionID: parentSessionID,
            isMCPOriginated: false,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: nil,
            lastIndexedAt: timestamp
        )
    }

    private func liveSession(
        id: UUID,
        name: String,
        parentSessionID: UUID?,
        status: DomainAgentRunSnapshot.Status,
        statusText: String?,
        interaction: DomainAgentRunSnapshot.Interaction? = nil
    ) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
            sessionID: id,
            tabID: nil,
            sessionName: name,
            agentRaw: nil,
            agentDisplayName: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            status: status,
            statusText: statusText,
            latestAssistantPreview: nil,
            interaction: interaction,
            transcriptItemCount: 0,
            updatedAt: Date(timeIntervalSinceReferenceDate: 2),
            parentSessionID: parentSessionID,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private func interaction(
        kind: DomainAgentRunSnapshot.Interaction.Kind
    ) -> DomainAgentRunSnapshot.Interaction {
        .init(
            id: IDs.interaction,
            kind: kind,
            responseType: .decision,
            title: nil,
            prompt: nil,
            context: nil,
            allowsMultiple: nil,
            options: [],
            fields: [],
            details: []
        )
    }

    private func sessionNode(
        id: UUID,
        name: String,
        workspaceID: UUID?,
        runState: OrchestrationGraphProjection.SessionRunState,
        statusText: String? = nil,
        isLive: Bool = false,
        unresolvedParentSessionID: UUID? = nil
    ) -> OrchestrationGraphProjection.Node {
        .session(
            .init(
                sessionID: id,
                name: name,
                workspaceID: workspaceID,
                status: .init(runState: runState, statusText: statusText, isLive: isLive),
                unresolvedParentSessionID: unresolvedParentSessionID
            )
        )
    }

    private func edge(
        _ source: OrchestrationGraphProjection.NodeID,
        _ target: OrchestrationGraphProjection.NodeID,
        _ kind: OrchestrationGraphProjection.EdgeKind
    ) -> OrchestrationGraphProjection.Edge {
        .init(source: source, target: target, kind: kind)
    }

    private func sessionStatus(
        in projection: OrchestrationGraphProjection,
        sessionID: UUID
    ) -> OrchestrationGraphProjection.SessionStatus? {
        projection.nodes.first { $0.id == .session(sessionID) }.flatMap { node in
            guard case let .session(session) = node else { return nil }
            return session.status
        }
    }

    private func assertProjection(
        _ projection: OrchestrationGraphProjection,
        nodes expectedNodes: [OrchestrationGraphProjection.Node],
        edges expectedEdges: [OrchestrationGraphProjection.Edge],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(projection.nodes.count, expectedNodes.count, file: file, line: line)
        XCTAssertEqual(projection.edges.count, expectedEdges.count, file: file, line: line)
        XCTAssertEqual(projection.nodes, expectedNodes, file: file, line: line)
        XCTAssertEqual(projection.edges, expectedEdges, file: file, line: line)
        for node in expectedNodes {
            XCTAssertEqual(projection.nodes.count(where: { $0 == node }), 1, file: file, line: line)
        }
        for edge in expectedEdges {
            XCTAssertEqual(projection.edges.count(where: { $0 == edge }), 1, file: file, line: line)
        }
        XCTAssertTrue(projection.nodes.allSatisfy(expectedNodes.contains), file: file, line: line)
        XCTAssertTrue(projection.edges.allSatisfy(expectedEdges.contains), file: file, line: line)
    }

    private static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
