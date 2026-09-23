import Cocoa
import Combine
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    /// The graph window's live run state wins over a conflicting persisted status the inspector
    /// host would otherwise show.
    @MainActor
    final class OrchestrationGraphLiveStatusTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var graphWindow: WindowState!
        private var hostWindow: WindowState!
        private var models: [OrchestrationGraphInspectorModel] = []

        private var workspaceOne: WorkspaceModel!
        private var workspaceW: WorkspaceModel!
        private let tabT = UUID()
        private let sessionS = UUID()
        private let hostSecondTabID = UUID()
        private var cancellables: Set<AnyCancellable> = []

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrchestrationGraphLiveStatusTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)

            workspaceOne = makeWorkspace(name: "OG07 W1", lastUsed: Date(timeIntervalSince1970: 400), tabID: UUID())
            workspaceW = makeWorkspace(name: "OG07 W", lastUsed: Date(timeIntervalSince1970: 200), tabID: tabT)
            try writeWorkspace(workspaceOne)
            try writeWorkspace(workspaceW)
            try writeLegacyIndex([workspaceOne, workspaceW])

            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "orchestration-graph-live-status-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()

            graphWindow = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(graphWindow)
            await graphWindow.workspaceManager.awaitInitialized()
            if graphWindow.workspaceManager.activeWorkspaceID != workspaceOne.id,
               let target = graphWindow.workspaceManager.workspace(withID: workspaceOne.id)
            {
                await graphWindow.workspaceManager.switchWorkspace(to: target, saveState: false, reason: "test")
            }
            XCTAssertEqual(graphWindow.workspaceManager.activeWorkspaceID, workspaceOne.id)

            // G: the graph window's own live `AgentTabSession` for T — running, bound to S.
            let liveTab = AgentTabSession(tabID: tabT)
            liveTab.runState = .running
            graphWindow.agentModeViewModel.test_installLiveSession(liveTab)
            _ = graphWindow.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionS, on: liveTab)

            // G: a conflicting persisted `sessionIndex` entry for S — "completed".
            let indexOwner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspaceW.id, activationEpoch: 1)
            graphWindow.agentModeViewModel.test_installSessionIndexSnapshot(
                [sessionS: makeIndexEntry(id: sessionS, tabID: tabT, name: "S session", lastRunStateRaw: "completed")],
                owner: indexOwner,
                latestOwner: indexOwner,
                activeWorkspace: workspaceW
            )

            // Inspector host H: built up front, does not auto-switch to Default, active workspace
            // is W1 (not W), and seeded with its own conflicting session state — the residual the
            // resolver must ignore.
            hostWindow = WindowState(inspectorHostDomainRuntime: runtime)
            await hostWindow.workspaceManager.awaitInitialized()
            if let hostWorkspaceOne = hostWindow.workspaceManager.workspace(withID: workspaceOne.id) {
                hostWindow.workspaceManager.activeWorkspace = hostWorkspaceOne
            }

            let hostConflictingTab = AgentTabSession(tabID: tabT)
            hostConflictingTab.runState = .completed
            hostWindow.agentModeViewModel.test_installLiveSession(hostConflictingTab)
            _ = hostWindow.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionS, on: hostConflictingTab)

            let hostRunningTab = AgentTabSession(tabID: hostSecondTabID)
            hostRunningTab.runState = .running
            hostWindow.agentModeViewModel.test_installLiveSession(hostRunningTab)
        }

        override func tearDown() async throws {
            cancellables.removeAll()
            for model in models {
                await model.tearDown()
            }
            models.removeAll()
            if let graphWindow {
                WindowStatesManager.shared.unregisterWindowState(graphWindow)
                await graphWindow.tearDown()
            }
            graphWindow = nil
            hostWindow = nil
            WindowStatesManager.shared.allWindows = originalWindows
            if let runtime {
                _ = await runtime.shutdown()
            }
            runtime = nil
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        // MARK: - 1. Live wins over persisted, host's conflicting status is ignored

        func testWorkspaceSelectionShowsLiveRunningOverPersistedCompleted() async throws {
            let (shell, model) = makeShell()

            shell.select(.workspace(workspaceID: workspaceW.id))

            XCTAssertEqual(model.liveRunStates[sessionS], .running)
            XCTAssertNotEqual(model.liveRunStates[sessionS], .completed)
            let rowBeforeIdle = try XCTUnwrap(model.liveStatusRows.first { $0.sessionID == sessionS })
            XCTAssertEqual(OrchestrationGraphLiveStatusRow.label(for: rowBeforeIdle.runState), "Running")

            await model.waitForIdle()

            XCTAssertEqual(model.liveRunStates[sessionS], .running)
            XCTAssertNotEqual(model.liveRunStates[sessionS], .completed)
            let rowAfterIdle = try XCTUnwrap(model.liveStatusRows.first { $0.sessionID == sessionS })
            XCTAssertEqual(OrchestrationGraphLiveStatusRow.label(for: rowAfterIdle.runState), "Running")
            XCTAssertNotEqual(OrchestrationGraphLiveStatusRow.label(for: rowAfterIdle.runState), "Completed")
        }

        // MARK: - 2. Selecting a workspace never cancels or discards host sessions

        func testWorkspaceSelectionDoesNotCancelRuns() async throws {
            let (shell, model) = makeShell()

            let graphSession = try XCTUnwrap(graphWindow.agentModeViewModel.sessions[tabT])
            let hostCompletedSession = try XCTUnwrap(hostWindow.agentModeViewModel.sessions[tabT])
            let hostRunningSession = try XCTUnwrap(hostWindow.agentModeViewModel.sessions[hostSecondTabID])

            let inverted = XCTestExpectation(description: "host sessions left untouched")
            inverted.isInverted = true

            hostRunningSession.$runState
                .dropFirst()
                .sink { runState in
                    guard runState != .running else { return }
                    inverted.fulfill()
                }
                .store(in: &cancellables)
            hostWindow.agentModeViewModel.$sessions
                .dropFirst()
                .sink { sessions in
                    guard sessions[self.tabT] === hostCompletedSession,
                          sessions[self.hostSecondTabID] === hostRunningSession
                    else {
                        inverted.fulfill()
                        return
                    }
                }
                .store(in: &cancellables)

            shell.select(.workspace(workspaceID: workspaceW.id))
            await model.waitForIdle()

            await fulfillment(of: [inverted], timeout: 2)

            XCTAssertTrue(graphWindow.agentModeViewModel.sessions[tabT] === graphSession)
            XCTAssertEqual(graphSession.runState, .running)
            XCTAssertTrue(hostWindow.agentModeViewModel.sessions[tabT] === hostCompletedSession)
            XCTAssertTrue(hostWindow.agentModeViewModel.sessions[hostSecondTabID] === hostRunningSession)
            XCTAssertEqual(hostRunningSession.runState, .running)
        }

        // MARK: - 3. Cancel clears the published live status

        func testCancelSelectionClearsLiveRunStates() async {
            let (shell, model) = makeShell()

            shell.select(.workspace(workspaceID: workspaceW.id))
            await model.waitForIdle()
            XCTAssertFalse(model.liveRunStates.isEmpty)
            XCTAssertFalse(model.liveStatusRows.isEmpty)

            model.cancelSelection()

            XCTAssertTrue(model.liveRunStates.isEmpty)
            XCTAssertTrue(model.liveStatusRows.isEmpty)
        }

        // MARK: - 4. Every run state has a distinct, non-empty label

        func testLiveStatusLabelCoversEveryRunState() {
            let states: [OrchestrationGraphProjection.SessionRunState] = [
                .idle,
                .running,
                .waitingForUser,
                .waitingForQuestion,
                .waitingForApproval,
                .completed,
                .failed,
                .cancelled,
                .expired,
                .unknown("custom-raw-value"),
                .unspecified
            ]
            var seenLabels = Set<String>()
            for state in states {
                let label = OrchestrationGraphLiveStatusRow.label(for: state)
                XCTAssertFalse(label.isEmpty, "empty label for \(state)")
                XCTAssertTrue(seenLabels.insert(label).inserted, "duplicate label \"\(label)\" for \(state)")
            }
            XCTAssertEqual(OrchestrationGraphLiveStatusRow.label(for: .running), "Running")
            XCTAssertEqual(OrchestrationGraphLiveStatusRow.label(for: .completed), "Completed")
        }

        // MARK: - 5. The chrome renders the live status strip for a workspace surface

        func testDialogChromeRendersLiveStatusStripForWorkspace() async throws {
            let (shell, model) = makeShell()

            shell.select(.workspace(workspaceID: workspaceW.id))
            await model.waitForIdle()

            let chrome = InspectorDialogChrome(title: "Test", model: model, onDone: {}) { EmptyView() }
            let hostingView = NSHostingView(rootView: chrome)
            hostingView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            hostingView.layoutSubtreeIfNeeded()

            let sessionName = try XCTUnwrap(model.liveStatusRows.first { $0.sessionID == sessionS }?.name)
            let labels = model.liveStatusStripRenderRecorderForTesting.labels
            XCTAssertTrue(labels.contains("\(sessionName) — Running"))
            XCTAssertFalse(labels.contains { $0.contains("Completed") })
        }

        // MARK: - Helpers

        private func makeShell() -> (OrchestrationGraphShell, OrchestrationGraphInspectorModel) {
            let host: WindowState = hostWindow
            let model = OrchestrationGraphInspectorModel(hostFactory: { host })
            models.append(model)
            let shell = OrchestrationGraphShell(
                windowState: graphWindow,
                inspectorModel: model,
                snapshotLoader: OrchestrationGraphSnapshotLoader { .empty }
            )
            return (shell, model)
        }

        private func makeWorkspace(name: String, lastUsed: Date, tabID: UUID) -> WorkspaceModel {
            let id = UUID()
            let directory = storageRoot.appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: name, id: id),
                isDirectory: true
            )
            return WorkspaceModel(
                id: id,
                dateModified: lastUsed,
                name: name,
                repoPaths: [storageRoot.appendingPathComponent("\(id.uuidString)-repo").path],
                lastUsed: lastUsed,
                customStoragePath: directory,
                composeTabs: [ComposeTabState(id: tabID, name: "T1", activeAgentSessionID: nil)],
                activeComposeTabID: tabID
            )
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let fileURL = storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(workspace).write(to: fileURL, options: .atomic)
        }

        private func writeLegacyIndex(_ workspaces: [WorkspaceModel]) throws {
            let entries = workspaces.map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
            try JSONEncoder().encode(entries).write(
                to: storageRoot.appendingPathComponent("workspacesIndex.json"),
                options: .atomic
            )
        }

        private func makeIndexEntry(
            id: UUID,
            tabID: UUID,
            name: String,
            lastRunStateRaw: String?
        ) -> AgentSessionIndexEntry {
            AgentSessionIndexEntry(
                id: id,
                tabID: tabID,
                name: name,
                lastUserMessageAt: nil,
                savedAt: Date(timeIntervalSinceReferenceDate: 0),
                lastRunStateRaw: lastRunStateRaw,
                itemCount: 0,
                agentKindRaw: nil,
                agentModelRaw: nil,
                agentReasoningEffortRaw: nil,
                autoEditEnabled: true,
                parentSessionID: nil,
                hasUnknownConversationContent: false,
                isMCPOriginated: false,
                worktreeBindingSummaries: [],
                activeWorktreeMergeSummaries: []
            )
        }
    }
#endif
