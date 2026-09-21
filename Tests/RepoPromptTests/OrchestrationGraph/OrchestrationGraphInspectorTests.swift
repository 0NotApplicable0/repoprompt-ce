import Cocoa
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    /// OG-05 / DW-5: `OrchestrationGraphShell` mounts one production `OrchestrationGraphInspector`.
    /// Selecting a workspace or a session through the shell drives a single inspector-owned host
    /// `WindowState`; the graph window's own `WindowState` stays on W1 and the projection stays whole.
    /// All storage lives under a temporary root with a temporary domain runtime.
    @MainActor
    final class OrchestrationGraphInspectorTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var graphWindow: WindowState!
        private var models: [OrchestrationGraphInspectorModel] = []

        private var workspaceOne: WorkspaceModel!
        private var workspaceTwo: WorkspaceModel!
        private let workspaceOneTabID = UUID()
        private let workspaceTwoTabID = UUID()
        private let workspaceOneSessionID = UUID()
        private let workspaceTwoSessionID = UUID()
        private let orphanedSessionID = UUID()
        private let orphanedTabID = UUID()
        private var hostFactoryCallCount = 0

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            hostFactoryCallCount = 0

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrchestrationGraphInspectorTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)

            workspaceOne = makeWorkspace(
                name: "OG05 W1",
                lastUsed: Date(timeIntervalSince1970: 400),
                tabID: workspaceOneTabID,
                boundSessionID: nil
            )
            workspaceTwo = makeWorkspace(
                name: "OG05 W2",
                lastUsed: Date(timeIntervalSince1970: 200),
                tabID: workspaceTwoTabID,
                boundSessionID: workspaceTwoSessionID
            )
            try writeWorkspace(workspaceOne)
            try writeWorkspace(workspaceTwo)
            try writeLegacyIndex([workspaceOne, workspaceTwo])
            try await saveSession(id: workspaceTwoSessionID, workspace: workspaceTwo, tabID: workspaceTwoTabID)
            try await saveSession(id: orphanedSessionID, workspace: workspaceTwo, tabID: orphanedTabID)

            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "orchestration-graph-inspector-\(UUID().uuidString)",
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
        }

        override func tearDown() async throws {
            for model in models {
                await model.tearDown()
            }
            models.removeAll()
            if let graphWindow {
                WindowStatesManager.shared.unregisterWindowState(graphWindow)
                await graphWindow.tearDown()
            }
            graphWindow = nil
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

        // MARK: - 1. Workspace selection

        func testSelectingWorkspaceThroughShellMountsItInInspectorHostOnly() async throws {
            let (shell, model) = makeShell()
            XCTAssertEqual(graphWindow.workspaceManager.activeWorkspaceID, workspaceOne.id)

            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()

            XCTAssertEqual(model.surface, .workspace(workspaceTwo.id))
            let host = try XCTUnwrap(model.hostWindowState)
            XCTAssertEqual(host.workspaceManager.activeWorkspaceID, workspaceTwo.id)
            XCTAssertEqual(graphWindow.workspaceManager.activeWorkspaceID, workspaceOne.id)
            XCTAssertEqual(model.mcpBindTargetWorkspaceID, workspaceTwo.id)
            XCTAssertFalse(host === graphWindow)
        }

        // MARK: - 2. Session selection

        func testSelectingSessionThroughShellBindsSessionOnHostTab() async throws {
            let (shell, model) = makeShell()

            shell.select(.session(
                workspaceID: workspaceTwo.id,
                tabID: workspaceTwoTabID,
                sessionID: workspaceTwoSessionID
            ))
            await model.waitForIdle()

            XCTAssertEqual(
                model.surface,
                .session(workspaceID: workspaceTwo.id, tabID: workspaceTwoTabID, sessionID: workspaceTwoSessionID)
            )
            let host = try XCTUnwrap(model.hostWindowState)
            XCTAssertEqual(host.agentModeViewModel.sessions[workspaceTwoTabID]?.activeAgentSessionID, workspaceTwoSessionID)
            XCTAssertEqual(host.promptManager.activeComposeTabID, workspaceTwoTabID)
            XCTAssertEqual(host.workspaceManager.activeWorkspaceID, workspaceTwo.id)
            XCTAssertEqual(graphWindow.workspaceManager.activeWorkspaceID, workspaceOne.id)
            XCTAssertEqual(model.mcpBindTargetWorkspaceID, workspaceTwo.id)
        }

        // MARK: - 2b. Session whose tab is gone

        func testSessionWithMissingTabFailsWithoutMutatingWorkspace() async throws {
            let (shell, model) = makeShell()
            let before = try storedTabIDs(of: workspaceTwo.id)

            let target = OrchestrationGraphInspectorTarget.session(
                workspaceID: workspaceTwo.id,
                tabID: orphanedTabID,
                sessionID: orphanedSessionID
            )
            shell.select(target)
            await model.waitForIdle()

            XCTAssertEqual(model.surface, .failure(target, .sessionTabUnavailable))
            let host = try XCTUnwrap(model.hostWindowState)
            let hostWorkspace = try XCTUnwrap(host.workspaceManager.workspace(withID: workspaceTwo.id))
            XCTAssertEqual(hostWorkspace.composeTabs.map(\.id), before.composeTabs)
            XCTAssertEqual(hostWorkspace.stashedTabs.map(\.tab.id), before.stashedTabs)
            XCTAssertEqual(try storedTabIDs(of: workspaceTwo.id).composeTabs, before.composeTabs)
            XCTAssertEqual(try storedTabIDs(of: workspaceTwo.id).stashedTabs, before.stashedTabs)
            XCTAssertNotEqual(model.mcpBindTargetWorkspaceID, workspaceTwo.id)
            XCTAssertEqual(graphWindow.workspaceManager.activeWorkspaceID, workspaceOne.id)
        }

        // MARK: - 3. Exactly one inspector and one host

        func testOneInspectorAndOneHostAcrossSelections() async throws {
            let (shell, model) = makeShell()
            let instanceID = model.instanceID

            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()
            let firstHost = try XCTUnwrap(model.hostWindowState)

            shell.select(.session(
                workspaceID: workspaceTwo.id,
                tabID: workspaceTwoTabID,
                sessionID: workspaceTwoSessionID
            ))
            await model.waitForIdle()

            XCTAssertEqual(model.instanceID, instanceID)
            XCTAssertTrue(model.hostWindowState === firstHost)
            XCTAssertTrue(shell.inspectorModelForTesting === model)
            XCTAssertFalse(WindowStatesManager.shared.allWindows.contains { $0 === firstHost })
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
        }

        // MARK: - 4. Projection stays whole

        func testWorkspaceOneSessionStaysInProjectionAfterSelectingWorkspaceTwo() async {
            let (shell, model) = makeShell()
            await shell.loadSnapshotIfNeeded()
            XCTAssertTrue(shell.snapshotForTesting.projection.nodes.contains { $0.id == .session(workspaceOneSessionID) })

            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()

            let nodes = shell.snapshotForTesting.projection.nodes
            XCTAssertTrue(nodes.contains { $0.id == .session(workspaceOneSessionID) })
            XCTAssertTrue(nodes.contains { $0.id == .workspace(workspaceOne.id) })
            XCTAssertEqual(shell.snapshotForTesting, makeSnapshot())
        }

        // MARK: - 5. Failure

        func testUnknownWorkspaceFailsAndKeepsGraphWindowOnWorkspaceOne() async {
            let (shell, model) = makeShell()
            let target = OrchestrationGraphInspectorTarget.workspace(workspaceID: UUID())

            shell.select(target)
            await model.waitForIdle()

            XCTAssertEqual(model.surface, .failure(target, .workspaceUnavailable))
            XCTAssertEqual(graphWindow.workspaceManager.activeWorkspaceID, workspaceOne.id)
            XCTAssertNotEqual(model.mcpBindTargetWorkspaceID, workspaceTwo.id)
        }

        func testLatestSelectionWins() async {
            let (shell, model) = makeShell()
            let stale = OrchestrationGraphInspectorTarget.workspace(workspaceID: UUID())

            shell.select(stale)
            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()

            XCTAssertEqual(model.surface, .workspace(workspaceTwo.id))
            XCTAssertEqual(model.mcpBindTargetWorkspaceID, workspaceTwo.id)
        }

        // MARK: - 6. Flag false

        func testFlagOffRootSurfaceIsContentView() {
            let policy = OrchestrationGraphWindowPolicy(isGraphEnabled: { false })
            XCTAssertEqual(WindowContentView.rootSurface(policy: policy), .contentView)
        }

        // MARK: - 7. Mounted shell keeps the graph while the inspector changes

        func testMountedShellRendersGraphAndInspectorAcrossSelection() async {
            let (shell, model) = makeShell()
            let hosting = NSHostingView(rootView: shell)
            hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            hosting.layoutSubtreeIfNeeded()
            await shell.loadSnapshotIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
            let clustersBefore = shell.snapshotForTesting.layout.clusters
            XCTAssertFalse(clustersBefore.isEmpty)

            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()
            hosting.layoutSubtreeIfNeeded()

            XCTAssertEqual(model.surface, .workspace(workspaceTwo.id))
            XCTAssertNotNil(model.hostWindowState)
            XCTAssertGreaterThan(hosting.fittingSize.height, 0)
            XCTAssertEqual(shell.snapshotForTesting.layout.clusters, clustersBefore)
            XCTAssertTrue(shell.inspectorModelForTesting === model)
        }

        // MARK: - 8. Lazy single host

        func testHostFactoryIsLazyAndCalledOnce() async {
            let (shell, model) = makeShell()
            let hosting = NSHostingView(rootView: shell)
            hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            hosting.layoutSubtreeIfNeeded()

            XCTAssertEqual(hostFactoryCallCount, 0)
            XCTAssertNil(model.hostWindowState)

            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()
            shell.select(.workspace(workspaceID: workspaceOne.id))
            await model.waitForIdle()

            XCTAssertEqual(hostFactoryCallCount, 1)
            XCTAssertEqual(model.surface, .workspace(workspaceOne.id))
        }

        func testTearDownIsIdempotentAndIgnoresLaterSelections() async {
            let (shell, model) = makeShell()
            shell.select(.workspace(workspaceID: workspaceTwo.id))
            await model.waitForIdle()

            await model.tearDown()
            await model.tearDown()
            shell.select(.workspace(workspaceID: workspaceOne.id))
            await model.waitForIdle()

            XCTAssertNil(model.hostWindowState)
            XCTAssertEqual(hostFactoryCallCount, 1)
        }

        // MARK: - Helpers

        private func makeShell() -> (OrchestrationGraphShell, OrchestrationGraphInspectorModel) {
            let runtime: MCPDomainRuntime = runtime
            let model = OrchestrationGraphInspectorModel(hostFactory: { [weak self] in
                self?.hostFactoryCallCount += 1
                return WindowState(domainRuntime: runtime)
            })
            models.append(model)
            let snapshot = makeSnapshot()
            let shell = OrchestrationGraphShell(
                windowState: graphWindow,
                inspectorModel: model,
                snapshotLoader: OrchestrationGraphSnapshotLoader { snapshot }
            )
            return (shell, model)
        }

        private func makeSnapshot() -> OrchestrationGraphSnapshot {
            OrchestrationGraphSnapshot(
                projection: OrchestrationGraphProjection.make(
                    workspaces: [
                        .init(id: workspaceOne.id, name: workspaceOne.name),
                        .init(id: workspaceTwo.id, name: workspaceTwo.name)
                    ],
                    persisted: [
                        .init(
                            sessionID: workspaceOneSessionID,
                            workspaceID: workspaceOne.id,
                            name: "W1 session",
                            parentSessionID: nil,
                            runState: .completed
                        ),
                        .init(
                            sessionID: workspaceTwoSessionID,
                            workspaceID: workspaceTwo.id,
                            name: "W2 session",
                            parentSessionID: nil,
                            runState: .completed
                        )
                    ],
                    live: [],
                    isHistoryScanIncomplete: false
                ),
                sessionRoutes: [
                    workspaceOneSessionID: .init(workspaceID: workspaceOne.id, tabID: workspaceOneTabID),
                    workspaceTwoSessionID: .init(workspaceID: workspaceTwo.id, tabID: workspaceTwoTabID)
                ]
            )
        }

        private func makeWorkspace(
            name: String,
            lastUsed: Date,
            tabID: UUID,
            boundSessionID: UUID?
        ) -> WorkspaceModel {
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
                composeTabs: [ComposeTabState(id: tabID, name: "T1", activeAgentSessionID: boundSessionID)],
                activeComposeTabID: tabID
            )
        }

        private func saveSession(id: UUID, workspace: WorkspaceModel, tabID: UUID) async throws {
            let session = AgentSession(
                id: id,
                workspaceID: workspace.id,
                composeTabID: tabID,
                name: "Session \(id.uuidString.prefix(8))",
                savedAt: Date(timeIntervalSinceReferenceDate: 42),
                itemCount: 0,
                agentKind: AgentProviderKind.codexExec.rawValue,
                lastRunState: AgentSessionRunState.completed.rawValue,
                autoEditEnabled: true
            )
            try await AgentSessionDataService.shared.saveAgentSession(
                session,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 0
            )
        }

        private func storedTabIDs(of workspaceID: UUID) throws -> (composeTabs: [UUID], stashedTabs: [UUID]) {
            let workspace = try XCTUnwrap([workspaceOne, workspaceTwo].compactMap(\.self).first { $0.id == workspaceID })
            let fileURL = storageRoot
                .appendingPathComponent(
                    DomainWorkspaceStoragePath.directoryName(name: workspace.name, id: workspace.id),
                    isDirectory: true
                )
                .appendingPathComponent("workspace.json")
            let stored = try JSONDecoder().decode(WorkspaceModel.self, from: Data(contentsOf: fileURL))
            return (stored.composeTabs.map(\.id), stored.stashedTabs.map(\.tab.id))
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
    }
#endif
