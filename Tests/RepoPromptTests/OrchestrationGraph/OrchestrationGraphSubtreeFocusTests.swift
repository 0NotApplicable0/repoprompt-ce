import Cocoa
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

@MainActor
final class OrchestrationGraphSubtreeFocusTests: XCTestCase {
    func testWorkspaceFocusHidesOtherWorkspaces() async {
        let left = UUID()
        let right = UUID()
        let leftSession = UUID()
        let rightSession = UUID()
        let state = await state(workspaces: [
            (left, "Left", [(leftSession, "L", nil, .running)]),
            (right, "Right", [(rightSession, "R", nil, .running)])
        ])
        state.focusWorkspace(left)
        let ids = canvasIDs(state)
        XCTAssertTrue(ids.contains(.workspace(left)))
        XCTAssertTrue(ids.contains(.session(leftSession)))
        XCTAssertFalse(ids.contains(.workspace(right)))
        XCTAssertFalse(ids.contains(.session(rightSession)))
    }

    func testSessionFocusKeepsDispatchDescendants() async {
        let workspaceID = UUID()
        let root = UUID()
        let child = UUID()
        let grandchild = UUID()
        let other = UUID()
        let state = await state(workspaces: [
            (workspaceID, "W", [
                (root, "Root", nil, .running),
                (child, "Child", root, .running),
                (grandchild, "Grand", child, .running),
                (other, "Other", nil, .running)
            ])
        ])
        state.focusSession(root)
        let ids = canvasIDs(state)
        XCTAssertTrue(ids.contains(.session(root)))
        XCTAssertTrue(ids.contains(.session(child)))
        XCTAssertTrue(ids.contains(.session(grandchild)))
        XCTAssertFalse(ids.contains(.session(other)))
    }

    func testClearingFocusRestoresTheRevealedSet() async {
        let workspaceID = UUID()
        let liveID = UUID()
        let hiddenID = UUID()
        let state = await state(workspaces: [
            (workspaceID, "W", [
                (liveID, "Live", nil, .running),
                (hiddenID, "Done", nil, .completed)
            ])
        ])
        let before = canvasIDs(state)
        state.focusSession(liveID)
        state.clearFocus()
        XCTAssertEqual(canvasIDs(state), before)
        XCTAssertTrue(before.contains(.session(liveID)))
        XCTAssertFalse(before.contains(.session(hiddenID)))
    }

    func testShellFocusActionsEnterAndClearFocus() async {
        let workspaceID = UUID()
        let sessionID = UUID()
        let state = await state(workspaces: [
            (workspaceID, "W", [(sessionID, "S", nil, .running)])
        ])
        state.focusWorkspace(workspaceID)
        XCTAssertEqual(state.focus, .workspace(workspaceID))
        state.focusSession(sessionID)
        XCTAssertEqual(state.focus, .session(sessionID))
        state.clearFocus()
        XCTAssertEqual(state.focus, .none)
    }

    func testFocusAndExpandUseTheNodeAfterInspectorDismiss() async throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestrationGraphFocusControls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "graph-focus-controls-\(UUID().uuidString)",
            storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
            workspaceStorageDirectory: storageRoot,
            eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        let windowState = WindowState(domainRuntime: runtime)
        let workspaceID = UUID()
        let sessionID = UUID()
        let tabID = UUID()
        let outsiderWorkspaceID = UUID()
        let outsiderSessionID = UUID()
        let outsiderTabID = UUID()
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: [
                    .init(id: workspaceID, name: "Hub"),
                    .init(id: outsiderWorkspaceID, name: "Other")
                ],
                persisted: [],
                live: [
                    .init(
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        name: "Shown session",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: nil,
                        composeTabID: tabID
                    ),
                    .init(
                        sessionID: outsiderSessionID,
                        workspaceID: outsiderWorkspaceID,
                        name: "Outsider session",
                        parentSessionID: nil,
                        runState: .running,
                        statusText: nil,
                        composeTabID: outsiderTabID
                    )
                ],
                isHistoryScanIncomplete: false
            ),
            sessionRoutes: [
                sessionID: OrchestrationGraphSnapshot.SessionRoute(workspaceID: workspaceID, tabID: tabID),
                outsiderSessionID: OrchestrationGraphSnapshot.SessionRoute(
                    workspaceID: outsiderWorkspaceID,
                    tabID: outsiderTabID
                )
            ]
        )
        let graph = OrchestrationGraphShellGraphState(
            loader: OrchestrationGraphSnapshotLoader { snapshot },
            windowState: windowState
        )
        let shell = OrchestrationGraphShell(
            windowState: windowState,
            inspectorModel: OrchestrationGraphInspectorModel(hostFactory: { windowState }),
            snapshotLoader: OrchestrationGraphSnapshotLoader { snapshot },
            graphState: graph
        )
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = NSHostingView(rootView: shell)
        hostWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(
            graph.presentation.displayed.layout.clusters.isEmpty,
            "installed shell did not publish the loaded graph"
        )
        let root = try XCTUnwrap(hostWindow.contentView)
        let rings = focusRingViews(in: root)
        try await click(rings, in: hostWindow, until: {
            if case .session = graph.presentation.retainedSelection { return true }
            return false
        })
        guard case let .session(_, _, selectedSessionID) = graph.presentation.retainedSelection else {
            return XCTFail("canvas click did not select a session")
        }
        let otherSessionID = selectedSessionID == sessionID ? outsiderSessionID : sessionID
        try await pressButton("Focus session", in: root)
        let focusedIDs = publishedCanvasIDs(graph)
        XCTAssertTrue(focusedIDs.contains(.session(selectedSessionID)))
        XCTAssertFalse(focusedIDs.contains(.session(otherSessionID)))
        try await pressButton("Clear focus", in: root)
        let restoredIDs = publishedCanvasIDs(graph)
        XCTAssertTrue(restoredIDs.contains(.session(sessionID)))
        XCTAssertTrue(restoredIDs.contains(.session(outsiderSessionID)))
        hostWindow.close()
        await windowState.tearDown()
        _ = await runtime.shutdown()
        try? FileManager.default.removeItem(at: storageRoot)
    }

    func testHiddenCompletedDescendantStaysHidden() async {
        let workspaceID = UUID()
        let root = UUID()
        let done = UUID()
        let state = await state(workspaces: [
            (workspaceID, "W", [
                (root, "Root", nil, .running),
                (done, "Done", root, .completed)
            ])
        ])
        state.focusSession(root)
        XCTAssertFalse(canvasIDs(state).contains(.session(done)))
        XCTAssertFalse(state.displayedSnapshot().layout.isRevealed(sessionID: done))
    }

    private func pressButton(_ title: String, in root: NSView) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let button = findButton(title, in: root) {
                button.performClick(nil)
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("missing button \(title)")
    }

    private func findButton(_ title: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.title == title {
            return button
        }
        for subview in root.subviews {
            if let match = findButton(title, in: subview) {
                return match
            }
        }
        return nil
    }

    private func focusRingViews(in root: NSView) -> [NSView] {
        var views: [NSView] = []
        var stack = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            if String(describing: type(of: view)).contains("FocusRing") {
                views.append(view)
            }
        }
        return views
    }

    private func click(_ views: [NSView], in window: NSWindow, until condition: () -> Bool) async {
        for view in views where !condition() {
            sendClick(to: view, in: window)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func sendClick(to view: NSView, in window: NSWindow) {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return }
        NSApp.sendEvent(down)
        NSApp.sendEvent(up)
    }

    private func publishedCanvasIDs(
        _ state: OrchestrationGraphShellGraphState
    ) -> Set<OrchestrationGraphProjection.NodeID> {
        Set(OrchestrationGraphCanvasLayout.make(snapshot: state.presentation.displayed).nodes.map(\.id))
    }

    private func canvasIDs(_ state: OrchestrationGraphShellGraphState) -> Set<OrchestrationGraphProjection.NodeID> {
        Set(OrchestrationGraphCanvasLayout.make(snapshot: state.displayedSnapshot()).nodes.map(\.id))
    }

    private func state(
        workspaces: [(UUID, String, [(UUID, String, UUID?, OrchestrationGraphProjection.SessionRunState)])]
    ) async -> OrchestrationGraphShellGraphState {
        var inputs: [OrchestrationGraphProjection.LiveSessionInput] = []
        var workspaceInputs: [OrchestrationGraphProjection.WorkspaceInput] = []
        for (workspaceID, name, sessions) in workspaces {
            workspaceInputs.append(.init(id: workspaceID, name: name))
            for (sessionID, sessionName, parent, runState) in sessions {
                inputs.append(.init(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    name: sessionName,
                    parentSessionID: parent,
                    runState: runState,
                    statusText: nil
                ))
            }
        }
        let snapshot = OrchestrationGraphSnapshot(
            projection: OrchestrationGraphProjection.make(
                workspaces: workspaceInputs,
                persisted: [],
                live: inputs,
                isHistoryScanIncomplete: false
            )
        )
        let state = OrchestrationGraphShellGraphState(loader: OrchestrationGraphSnapshotLoader { snapshot })
        await state.loadIfNeeded()
        return state
    }
}
