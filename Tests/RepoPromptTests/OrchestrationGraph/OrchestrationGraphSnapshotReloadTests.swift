import Cocoa
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class OrchestrationGraphSnapshotReloadTests: XCTestCase {
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var window: WindowState!
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false

        override func setUp() async throws {
            try await super.setUp()
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []
            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrchestrationGraphSnapshotReloadTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)
            let workspace = makeWorkspace(name: "OG08 W")
            try writeWorkspace(workspace)
            try writeLegacyIndex([workspace])
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "orchestration-graph-snapshot-reload-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            window = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(window)
            await window.workspaceManager.awaitInitialized()
        }

        override func tearDown() async throws {
            if let window {
                WindowStatesManager.shared.unregisterWindowState(window)
                await window.tearDown()
            }
            window = nil
            WindowStatesManager.shared.allWindows = originalWindows
            if let runtime { _ = await runtime.shutdown() }
            runtime = nil
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            try await super.tearDown()
        }

        func testSecondReloadWithinTTLDoesNotRescanHistory() async {
            let loader = OrchestrationGraphSnapshotLoader.production(windowState: window)
            _ = await loader.load()
            let afterFirst = await loader.historyScanForTesting?.scannerForTesting?.workspaceInspectionCountForTesting ?? -1
            XCTAssertGreaterThan(afterFirst, 0)
            _ = await loader.load()
            let afterSecond = await loader.historyScanForTesting?.scannerForTesting?.workspaceInspectionCountForTesting ?? -1
            XCTAssertEqual(afterSecond, afterFirst)
        }

        func testLiveRunStateUpdateDoesNotRescanHistory() async {
            let loader = OrchestrationGraphSnapshotLoader.production(windowState: window)
            let state = OrchestrationGraphShellGraphState(loader: loader, windowState: window)
            await state.loadIfNeeded()
            let afterLoad = await loader.historyScanForTesting?.scannerForTesting?.workspaceInspectionCountForTesting ?? 0
            XCTAssertGreaterThan(afterLoad, 0)
            let tab = AgentTabSession(tabID: UUID())
            tab.runState = .running
            window.agentModeViewModel.test_installLiveSession(tab)
            state.applyLiveOverlay()
            let afterOverlay = await loader.historyScanForTesting?.scannerForTesting?.workspaceInspectionCountForTesting ?? 0
            XCTAssertEqual(afterOverlay, afterLoad)
        }

        func testLiveRunStateUpdateDoesNotRebuildHiddenHistory() {
            let workspaceID = UUID()
            let hiddenID = UUID()
            let liveID = UUID()
            let projection = OrchestrationGraphProjection.make(
                workspaces: [.init(id: workspaceID, name: "OG08")],
                persisted: [
                    .init(sessionID: hiddenID, workspaceID: workspaceID, name: "Hidden", parentSessionID: nil, runState: .completed)
                ],
                live: [
                    .init(sessionID: liveID, workspaceID: workspaceID, name: "Live", parentSessionID: nil, runState: .running, statusText: nil)
                ],
                isHistoryScanIncomplete: false
            )
            let previous = OrchestrationGraphLayout.make(projection: projection)
            let updated = projection.applyingLive([
                .init(sessionID: liveID, workspaceID: workspaceID, name: "Live", parentSessionID: nil, runState: .waitingForUser, statusText: nil)
            ])
            let layout = OrchestrationGraphLayout.makeReusingUnchangedHiddenHistory(previous: previous, projection: updated)
            XCTAssertFalse(OrchestrationGraphLayout.lastMakeSessionIDsForTesting.contains(hiddenID))
            XCTAssertTrue(OrchestrationGraphLayout.lastMakeSessionIDsForTesting.contains(liveID))
            XCTAssertEqual(updated.sessionNode(id: liveID)?.status.runState, .waitingForUser)
            let canvas = OrchestrationGraphCanvasLayout.make(
                snapshot: OrchestrationGraphSnapshot(projection: updated, layout: layout)
            )
            let hub = canvas.nodes.first { $0.id == .workspace(workspaceID) }
            XCTAssertEqual(hub?.collapsedCount, 1)
        }

        private func makeWorkspace(name: String) -> WorkspaceModel {
            let id = UUID()
            let directory = storageRoot.appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: name, id: id),
                isDirectory: true
            )
            let tabID = UUID()
            return WorkspaceModel(
                id: id,
                dateModified: Date(timeIntervalSince1970: 300),
                name: name,
                repoPaths: [storageRoot.appendingPathComponent("\(id.uuidString)-repo").path],
                lastUsed: Date(timeIntervalSince1970: 300),
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
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
            try JSONEncoder().encode(entries).write(to: storageRoot.appendingPathComponent("workspacesIndex.json"), options: .atomic)
        }
    }
#endif
