import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    @MainActor
    final class OneWindowFocusTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var originalGraphPolicy = OrchestrationGraphWindowPolicy.production
        private var originalOpenerPolicy = OrchestrationGraphWindowPolicy.production
        private var originalApprovalSettings: WorkspaceApprovalSettings?
        private var originalStoragePath: String?
        private var storageRoot: URL?
        private var runtime: MCPDomainRuntime?
        private var window: WindowState?
        private var connectionIDs: [UUID] = []
        private var openerCount = 0
        private var runStateChangeCount = 0

        override func setUp() async throws {
            try await super.setUp()
            originalWindows = WindowStatesManager.shared.allWindows
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            originalGraphPolicy = ServerNetworkManager.shared.graphPolicy
            originalOpenerPolicy = AppWindowOpener.shared.policy
            originalApprovalSettings = WorkspaceApprovalManager.shared.settings
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            WorkspaceApprovalManager.shared.setAutoApproveOperation(.createWorkspace, enabled: true)
        }

        override func tearDown() async throws {
            await disposeFixture()
            WindowStatesManager.shared.allWindows = originalWindows
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = originalOpenerPolicy
            ServerNetworkManager.shared.graphPolicy = originalGraphPolicy
            if let originalApprovalSettings {
                WorkspaceApprovalManager.shared.setAutoApproveOperation(
                    .createWorkspace,
                    enabled: originalApprovalSettings.autoApproveOperations.contains(.createWorkspace)
                )
            }
            WorkspaceApprovalManager.shared.cancelAllPending()
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            try await super.tearDown()
        }

        private struct Fixture {
            let service: WindowRoutingService
            let window: WindowState
            let workspaceOne: WorkspaceModel
            let workspaceTwo: WorkspaceModel
            let connectionID: UUID
            let tabT: UUID
            let idleTabU: UUID?
            let sessionS: AgentTabSession
            let sessionX: AgentTabSession
            let provider: CountingWorkspaceSwitchSessionProvider
        }

        private func withFixture(
            graphEnabled: Bool,
            idleTab: Bool = false,
            body: (Fixture) async throws -> Void
        ) async throws {
            let fixture = try await makeFixture(graphEnabled: graphEnabled, idleTab: idleTab)
            do {
                try await body(fixture)
                await disposeFixture()
            } catch {
                await disposeFixture()
                throw error
            }
        }

        private func makeFixture(graphEnabled: Bool, idleTab: Bool) async throws -> Fixture {
            WindowStatesManager.shared.allWindows = []
            AppWindowOpener.shared.resetForTesting()
            await ServerNetworkManager.shared.debugClearPersistedRoutingState()
            openerCount = 0
            runStateChangeCount = 0
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneWindowFocusTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storageRoot = root
            UserDefaults.standard.set(root.path, forKey: "GlobalCustomStorageURL")
            let agentRoot = root.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatRoot = root.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatRoot)

            let workspaceOne = try makeWorkspace("Focus W1", ordinal: 1, in: root)
            var workspaceTwo = try makeWorkspace("Focus W2", ordinal: 2, in: root)
            let idleTabU = idleTab ? UUID() : nil
            if let idleTabU {
                workspaceTwo.composeTabs.append(ComposeTabState(id: idleTabU, name: "Idle U"))
            }
            try writeWorkspace(workspaceOne)
            try writeWorkspace(workspaceTwo)
            let index = [workspaceOne, workspaceTwo].map {
                WorkspaceIndexEntry(
                    id: $0.id,
                    name: $0.name,
                    customStoragePath: $0.customStoragePath,
                    isSystemWorkspace: $0.isSystemWorkspace,
                    isHiddenInMenus: $0.isHiddenInMenus
                )
            }
            try JSONEncoder().encode(index).write(to: root.appendingPathComponent("workspacesIndex.json"), options: .atomic)
            let domainRuntime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "one-window-focus-\(UUID().uuidString)",
                storageDirectory: root.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: root,
                eventDirectory: root.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            runtime = domainRuntime
            try await domainRuntime.start()
            let host = WindowState(domainRuntime: domainRuntime)
            window = host
            WindowStatesManager.shared.registerWindowState(host)
            await host.workspaceManager.awaitInitialized()
            let switchResult = await host.workspaceManager.requestWorkspaceSwitch(to: workspaceOne, saveState: false)
            XCTAssertTrue(switchResult.didSwitch, switchResult.message ?? "setup switch failed")
            let loadedOne = try XCTUnwrap(host.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
            let loadedTwo = try XCTUnwrap(host.workspaceManager.workspaces.first { $0.id == workspaceTwo.id })
            let tabS = try XCTUnwrap(loadedOne.activeComposeTabID)
            let tabT = try XCTUnwrap(loadedTwo.activeComposeTabID)
            let provider = CountingWorkspaceSwitchSessionProvider()
            host.workspaceManager.registerSwitchSessionProvider(provider)
            let sessionS = installLiveSession(on: host, tabID: tabS)
            let sessionX = installLiveSession(on: host, tabID: tabT)
            sessionX.testInstallPersistentSessionBinding(sessionID: UUID())
            let sessionXID = try XCTUnwrap(sessionX.activeAgentSessionID)
            XCTAssertTrue(host.workspaceManager.compareAndSetActiveAgentSessionID(
                expected: nil,
                replacement: sessionXID,
                forTabID: tabT,
                inWorkspaceID: loadedTwo.id
            ))
            XCTAssertEqual(host.workspaceManager.composeTab(with: tabT)?.activeAgentSessionID, sessionXID)
            let policy = OrchestrationGraphWindowPolicy(isGraphEnabled: { graphEnabled })
            let service = WindowRoutingService(windowStates: WindowStatesManager.shared, networkMgr: ServerNetworkManager.shared)
            service.policy = policy
            ServerNetworkManager.shared.graphPolicy = policy
            AppWindowOpener.shared.policy = policy
            AppWindowOpener.shared.install(openMainWindow: { [weak self] in self?.openerCount += 1 })
            await service.prepareDomainTools()
            let connectionID = UUID()
            connectionIDs.append(connectionID)
            return Fixture(
                service: service, window: host, workspaceOne: loadedOne, workspaceTwo: loadedTwo,
                connectionID: connectionID, tabT: tabT, idleTabU: idleTabU,
                sessionS: sessionS, sessionX: sessionX, provider: provider
            )
        }

        private func disposeFixture() async {
            if let window {
                WindowStatesManager.shared.unregisterWindowState(window)
                await window.tearDown()
                self.window = nil
            }
            for connectionID in connectionIDs {
                await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
            }
            connectionIDs = []
            if let runtime { _ = await runtime.shutdown() }
            runtime = nil
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
            storageRoot = nil
            AppWindowOpener.shared.resetForTesting()
            WindowStatesManager.shared.allWindows = []
        }

        private func makeWorkspace(_ name: String, ordinal: Int, in root: URL) throws -> WorkspaceModel {
            let id = UUID()
            let repo = root.appendingPathComponent("repo-\(ordinal)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            return WorkspaceModel(
                id: id, dateModified: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                name: name, repoPaths: [repo.path], lastUsed: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                customStoragePath: root.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: name, id: id), isDirectory: true)
            )
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let directory = try XCTUnwrap(workspace.customStoragePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
        }

        private func installLiveSession(on window: WindowState, tabID: UUID) -> AgentTabSession {
            let session = AgentTabSession(tabID: tabID)
            window.agentModeViewModel.test_installLiveSession(session)
            window.agentModeViewModel.setAgentRunActive(session, isActive: true)
            session.runState = .running
            session.onRunStateChanged = { [weak self] _ in self?.runStateChangeCount += 1 }
            return session
        }

        private func bind(_ fixture: Fixture) async throws -> BindContextResponse {
            let value = try await ServerNetworkManager.$currentConnectionID.withValue(fixture.connectionID) {
                try await fixture.service.call(tool: MCPGlobalToolName.bindContext, with: [
                    "op": .string("bind"),
                    "workspace": .string(fixture.workspaceTwo.id.uuidString),
                    "_rawJSON": .bool(true)
                ])
            }
            return try JSONDecoder().decode(BindContextResponse.self, from: JSONEncoder().encode(XCTUnwrap(value)))
        }

        private func switchWorkspace(_ fixture: Fixture, legacy: Bool = false, focus: Bool = false) async throws -> ManageWorkspacesResponse {
            var arguments: [String: Value] = [
                "action": .string("switch"),
                "workspace": .string(fixture.workspaceTwo.id.uuidString),
                "_rawJSON": .bool(true)
            ]
            if legacy { arguments["open_in_new_window"] = .bool(true) }
            if focus { arguments.merge(["focus": .bool(true)]) { _, new in new } }
            let value = try await ServerNetworkManager.$currentConnectionID.withValue(fixture.connectionID) {
                try await fixture.service.call(tool: MCPGlobalToolName.manageWorkspaces, with: arguments)
            }
            return try JSONDecoder().decode(ManageWorkspacesResponse.self, from: JSONEncoder().encode(XCTUnwrap(value)))
        }

        private func assertRunningSessions(_ fixture: Fixture) {
            XCTAssertEqual(fixture.provider.queryCount, 0)
            XCTAssertEqual(fixture.provider.cancelCount, 0)
            XCTAssertEqual(runStateChangeCount, 0)
            XCTAssertEqual(fixture.sessionS.runState, .running)
            XCTAssertEqual(fixture.sessionX.runState, .running)
            XCTAssertNotNil(fixture.sessionX.activeAgentSessionID)
            XCTAssertEqual(fixture.window.workspaceManager.composeTab(with: fixture.tabT)?.activeAgentSessionID, fixture.sessionX.activeAgentSessionID)
        }

        private func assertBoundToNewIdleTab(_ fixture: Fixture, originalCount: Int, remainsFocusedOnW1: Bool) throws {
            let manager = fixture.window.workspaceManager
            let workspace = try XCTUnwrap(manager.workspaces.first { $0.id == fixture.workspaceTwo.id })
            let binding = fixture.window.mcpServer.connectionBindingSnapshot(forConnection: fixture.connectionID)
            XCTAssertEqual(binding.windowID, fixture.window.windowID)
            XCTAssertEqual(binding.workspaceID, fixture.workspaceTwo.id)
            XCTAssertNotEqual(binding.tabID, fixture.tabT)
            XCTAssertEqual(workspace.composeTabs.count, originalCount + 1)
            XCTAssertNil(workspace.composeTabs.first { $0.id == binding.tabID }?.activeAgentSessionID)
            XCTAssertEqual(manager.activeWorkspaceID, remainsFocusedOnW1 ? fixture.workspaceOne.id : fixture.workspaceTwo.id)
            XCTAssertEqual(openerCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            assertRunningSessions(fixture)
        }

        func testOccupiedTabBindKeepsThatSessionRunning() async throws {
            for graphEnabled in [true, false] {
                try await withFixture(graphEnabled: graphEnabled) { fixture in
                    let count = fixture.workspaceTwo.composeTabs.count
                    let response = try await bind(fixture)
                    XCTAssertEqual(response.binding.windowID, fixture.window.windowID)
                    XCTAssertEqual(response.binding.workspaceID, fixture.workspaceTwo.id)
                    try assertBoundToNewIdleTab(fixture, originalCount: count, remainsFocusedOnW1: true)
                }
            }
        }

        func testIdleTabBindReusesTheIdleTab() async throws {
            for graphEnabled in [true, false] {
                try await withFixture(graphEnabled: graphEnabled, idleTab: true) { fixture in
                    let idleTabU = try XCTUnwrap(fixture.idleTabU)
                    XCTAssertNil(fixture.window.workspaceManager.composeTab(with: idleTabU)?.activeAgentSessionID)
                    let count = fixture.workspaceTwo.composeTabs.count
                    let response = try await bind(fixture)
                    XCTAssertEqual(response.binding.contextID, idleTabU)
                    XCTAssertEqual(response.binding.windowID, fixture.window.windowID)
                    XCTAssertEqual(fixture.window.workspaceManager.workspaces.first { $0.id == fixture.workspaceTwo.id }?.composeTabs.count, count)
                    XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, fixture.workspaceOne.id)
                    XCTAssertEqual(openerCount, 0)
                    XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                    assertRunningSessions(fixture)
                }
            }
        }

        func testOccupiedTabSwitchDoesNotThrow() async throws {
            for graphEnabled in [true, false] {
                for legacy in [false, true] {
                    try await withFixture(graphEnabled: graphEnabled) { fixture in
                        let count = fixture.workspaceTwo.composeTabs.count
                        let response = try await switchWorkspace(fixture, legacy: legacy)
                        XCTAssertEqual(response.status, "ok")
                        XCTAssertEqual(response.windowID, fixture.window.windowID)
                        if legacy { XCTAssertEqual(response.deprecatedArguments, ["open_in_new_window"]) }
                        try assertBoundToNewIdleTab(fixture, originalCount: count, remainsFocusedOnW1: true)
                    }
                }
            }
        }

        func testFocusChangeDoesNotTerminateTheOtherWorkspace() async throws {
            for graphEnabled in [true, false] {
                try await withFixture(graphEnabled: graphEnabled) { fixture in
                    let count = fixture.workspaceTwo.composeTabs.count
                    let response = try await switchWorkspace(fixture, focus: true)
                    XCTAssertEqual(response.status, "ok")
                    XCTAssertEqual(response.windowID, fixture.window.windowID)
                    try assertBoundToNewIdleTab(fixture, originalCount: count, remainsFocusedOnW1: false)
                    let visiblePaths = Set(fixture.window.workspaceManager.fileManager.rootFolders.map(\.standardizedFullPath))
                    XCTAssertTrue(visiblePaths.contains(fixture.workspaceTwo.repoPaths[0]))
                    XCTAssertFalse(visiblePaths.contains(fixture.workspaceOne.repoPaths[0]))
                    let graphRoots = await fixture.window.workspaceFileContextStore.rootRecords(forRootFolderPaths: fixture.workspaceTwo.repoPaths)
                    XCTAssertEqual(graphRoots.count, 1)
                    XCTAssertNotEqual(graphRoots.first?.kind, .sessionWorktree)
                    assertRunningSessions(fixture)
                }
            }
        }
    }

    @MainActor
    private final class CountingWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
        private(set) var queryCount = 0
        private(set) var cancelCount = 0

        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            queryCount += 1
            return [WorkspaceSwitchSessionItem(id: "one-window-focus-session", count: 2, singularLabel: "active session", pluralLabel: "active sessions")]
        }

        func cancelSwitchSessions() async {
            cancelCount += 1
        }
    }
#endif
