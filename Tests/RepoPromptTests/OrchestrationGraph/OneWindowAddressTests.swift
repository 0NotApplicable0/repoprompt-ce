import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    @MainActor
    final class OneWindowAddressTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var originalGraphPolicy = OrchestrationGraphWindowPolicy.production
        private var originalOpenerPolicy = OrchestrationGraphWindowPolicy.production
        private var originalApprovalSettings: WorkspaceApprovalSettings?
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var workspaceOne: WorkspaceModel!
        private var workspaceTwo: WorkspaceModel!
        private var windowA: WindowState!
        private var addedWindows: [WindowState] = []
        private var connectionIDs: [UUID] = []
        private var openerCount = 0
        private var runStateChangeCount = 0
        private var originalStoragePath: String?

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
            WindowStatesManager.shared.allWindows = []
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
            ServerNetworkManager.shared.graphPolicy = .production
            await ServerNetworkManager.shared.debugClearPersistedRoutingState()

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneWindowAddressTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            let agentRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatRoot)
            workspaceOne = try makeWorkspace("OW W1", ordinal: 1)
            workspaceTwo = try makeWorkspace("OW W2", ordinal: 2)
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
            try JSONEncoder().encode(index).write(to: storageRoot.appendingPathComponent("workspacesIndex.json"), options: .atomic)
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "one-window-address-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()
            windowA = registerWindow()
            await windowA.workspaceManager.awaitInitialized()
            let result = await windowA.workspaceManager.requestWorkspaceSwitch(to: workspaceOne, saveState: false)
            XCTAssertTrue(result.didSwitch, result.message ?? "setup switch failed")
            workspaceOne = try XCTUnwrap(windowA.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
            workspaceTwo = try XCTUnwrap(windowA.workspaceManager.workspaces.first { $0.id == workspaceTwo.id })
        }

        override func tearDown() async throws {
            for window in addedWindows.reversed() {
                WindowStatesManager.shared.unregisterWindowState(window)
                await window.tearDown()
            }
            for connectionID in connectionIDs {
                await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
            }
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
            if let runtime { _ = await runtime.shutdown() }
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            try await super.tearDown()
        }

        private func configure(graphEnabled: Bool) -> WindowRoutingService {
            let policy = OrchestrationGraphWindowPolicy(isGraphEnabled: { graphEnabled })
            let service = WindowRoutingService(windowStates: WindowStatesManager.shared, networkMgr: ServerNetworkManager.shared)
            service.policy = policy
            ServerNetworkManager.shared.graphPolicy = policy
            AppWindowOpener.shared.policy = policy
            AppWindowOpener.shared.install(openMainWindow: { [weak self] in self?.openerCount += 1 })
            return service
        }

        private func connection(for service: WindowRoutingService) async -> UUID {
            await service.prepareDomainTools()
            let id = UUID()
            connectionIDs.append(id)
            return id
        }

        @discardableResult
        private func registerWindow() -> WindowState {
            let window = WindowState(domainRuntime: runtime)
            WindowStatesManager.shared.registerWindowState(window)
            addedWindows.append(window)
            return window
        }

        private func makeWorkspace(_ name: String, ordinal: Int) throws -> WorkspaceModel {
            let id = UUID()
            let root = storageRoot.appendingPathComponent("repo-\(ordinal)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return WorkspaceModel(
                id: id, dateModified: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                name: name, repoPaths: [root.path], lastUsed: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                customStoragePath: storageRoot.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: name, id: id), isDirectory: true)
            )
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let directory = try XCTUnwrap(workspace.customStoragePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
        }

        private func installLiveSession(
            on window: WindowState,
            workspace: WorkspaceModel
        ) throws -> (AgentTabSession, CountingWorkspaceSwitchSessionProvider) {
            let provider = CountingWorkspaceSwitchSessionProvider()
            window.workspaceManager.registerSwitchSessionProvider(provider)
            let resolved = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == workspace.id })
            let tabID = try XCTUnwrap(resolved.activeComposeTabID)
            let session = AgentTabSession(tabID: tabID)
            window.agentModeViewModel.test_installLiveSession(session)
            window.agentModeViewModel.setAgentRunActive(session, isActive: true)
            session.runState = .running
            runStateChangeCount = 0
            session.onRunStateChanged = { [weak self] _ in self?.runStateChangeCount += 1 }
            return (session, provider)
        }

        private func assertSessionUnchanged(
            _ session: AgentTabSession,
            provider: CountingWorkspaceSwitchSessionProvider
        ) {
            XCTAssertEqual(provider.cancelCount, 0)
            XCTAssertEqual(runStateChangeCount, 0)
            XCTAssertEqual(session.runState, .running)
        }

        private func bind(
            service: WindowRoutingService,
            connectionID: UUID,
            arguments: [String: Value]
        ) async throws -> BindContextResponse {
            let value = try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                guard let raw = try await service.call(tool: MCPGlobalToolName.bindContext, with: arguments) else {
                    throw URLError(.badServerResponse)
                }
                return raw
            }
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(BindContextResponse.self, from: data)
        }

        private func listWorkspaces(
            service: WindowRoutingService,
            connectionID: UUID
        ) async throws -> ManageWorkspacesResponse {
            let value = try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                guard let raw = try await service.call(
                    tool: MCPGlobalToolName.manageWorkspaces,
                    with: ["action": .string("list"), "_rawJSON": .bool(true)]
                ) else {
                    throw URLError(.badServerResponse)
                }
                return raw
            }
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(ManageWorkspacesResponse.self, from: data)
        }

        func testBindByNameSelectsNamedWorkspaceWhileFocusStays() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let (session, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: ["op": .string("bind"), "workspace": .string("OW W2"), "_rawJSON": .bool(true)]
                )
                XCTAssertEqual(response.binding.workspaceID, workspaceTwo.id)
                XCTAssertEqual(windowA.workspaceManager.activeWorkspace?.id, workspaceOne.id)
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            }
        }

        func testBindByIDSelectsNamedWorkspaceWhileFocusStays() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let (session, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string(workspaceTwo.id.uuidString),
                        "_rawJSON": .bool(true)
                    ]
                )
                XCTAssertEqual(response.binding.workspaceID, workspaceTwo.id)
                XCTAssertEqual(windowA.workspaceManager.activeWorkspace?.id, workspaceOne.id)
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            }
        }

        func testTwoConnectionsBindTwoWorkspacesOnOneWindow() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionA = await connection(for: service)
                let connectionB = await connection(for: service)
                let (_, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                _ = try await bind(
                    service: service,
                    connectionID: connectionA,
                    arguments: ["op": .string("bind"), "workspace": .string("OW W1"), "_rawJSON": .bool(true)]
                )
                _ = try await bind(
                    service: service,
                    connectionID: connectionB,
                    arguments: ["op": .string("bind"), "workspace": .string("OW W2"), "_rawJSON": .bool(true)]
                )
                let bindA = windowA.mcpServer.connectionBindingSnapshot(forConnection: connectionA)
                let bindB = windowA.mcpServer.connectionBindingSnapshot(forConnection: connectionB)
                XCTAssertEqual(bindA.workspaceID, workspaceOne.id)
                XCTAssertEqual(bindB.workspaceID, workspaceTwo.id)
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            }
        }

        func testListReportsBothWorkspacesOnWindowOne() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionA = await connection(for: service)
                let connectionB = await connection(for: service)
                _ = try await bind(
                    service: service,
                    connectionID: connectionA,
                    arguments: ["op": .string("bind"), "workspace": .string("OW W1"), "_rawJSON": .bool(true)]
                )
                _ = try await bind(
                    service: service,
                    connectionID: connectionB,
                    arguments: ["op": .string("bind"), "workspace": .string("OW W2"), "_rawJSON": .bool(true)]
                )
                let list = try await listWorkspaces(service: service, connectionID: connectionA)
                let ws1 = list.workspaces?.first { $0.id == workspaceOne.id }
                let ws2 = list.workspaces?.first { $0.id == workspaceTwo.id }
                XCTAssertEqual(ws1?.showingWindowIDs, [windowA.windowID])
                XCTAssertEqual(ws2?.showingWindowIDs, [windowA.windowID])
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWorkspaceSelectorIsExclusive() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let exclusiveRequests: [[String: Value]] = [
                    ["op": .string("bind"), "workspace": .string("OW W2"), "context_id": .string(UUID().uuidString)],
                    ["op": .string("bind"), "workspace": .string("OW W2"), "working_dirs": .string(workspaceTwo.repoPaths[0])],
                    ["op": .string("bind"), "workspace": .string("OW W2"), "create_if_missing": .bool(true)],
                    ["op": .string("bind"), "workspace": .string("OW W2"), "tab_name": .string("tab")]
                ]
                for arguments in exclusiveRequests {
                    do {
                        _ = try await bind(service: service, connectionID: connectionID, arguments: arguments)
                        XCTFail("expected exclusive workspace selector refusal")
                    } catch let error as MCPError {
                        XCTAssertTrue(error.localizedDescription.contains("workspace"))
                    }
                }
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWorkspaceWithWindowIDSelectsHost() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string("OW W2"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                XCTAssertEqual(response.binding.windowID, windowB.windowID)
                XCTAssertEqual(response.binding.workspaceID, workspaceTwo.id)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testBoundWindowAndOtherWindowIDBindIsRefused() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                _ = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string("OW W1"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                do {
                    _ = try await bind(
                        service: service,
                        connectionID: connectionID,
                        arguments: [
                            "op": .string("bind"),
                            "workspace": .string("OW W2"),
                            "window_id": .int(windowA.windowID),
                            "_rawJSON": .bool(true)
                        ]
                    )
                    XCTFail("expected bind refusal when window_id conflicts with bound window")
                } catch {}
                let bind = windowB.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
                XCTAssertEqual(bind.workspaceID, workspaceOne.id)
                XCTAssertEqual(bind.windowID, windowB.windowID)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testUnboundBindWithTwoWindowsAndNoSelectorIsRefused() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                _ = registerWindow()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                do {
                    _ = try await bind(
                        service: service,
                        connectionID: connectionID,
                        arguments: ["op": .string("bind"), "workspace": .string("OW W2"), "_rawJSON": .bool(true)]
                    )
                    XCTFail("expected refusal with ambiguous host")
                } catch {}
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWorkingDirsBindStaysOnHostWindow() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let (session, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .string(workspaceTwo.repoPaths[0]),
                        "_rawJSON": .bool(true)
                    ]
                )
                XCTAssertEqual(response.binding.workspaceID, workspaceTwo.id)
                XCTAssertEqual(response.binding.windowID, windowA.windowID)
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            }
        }

        func testWorkingDirsCreateIfMissingStaysOnHostWindow() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let (_, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                let newRoot = storageRoot.appendingPathComponent("ow-w3-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .string(newRoot.path),
                        "create_if_missing": .bool(true),
                        "_rawJSON": .bool(true)
                    ]
                )
                XCTAssertEqual(response.binding.windowID, windowA.windowID)
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            }
        }

        func testWorkingDirsTwoWindowsHostsOnBoundWindow() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                _ = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string("OW W1"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                let (_, provider) = try installLiveSession(on: windowB, workspace: workspaceOne)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .string(workspaceTwo.repoPaths[0]),
                        "_rawJSON": .bool(true)
                    ]
                )
                XCTAssertEqual(response.binding.windowID, windowB.windowID)
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWorkingDirsTwoWindowsWithoutSelectorIsRefused() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                _ = registerWindow()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let (_, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                do {
                    _ = try await bind(
                        service: service,
                        connectionID: connectionID,
                        arguments: [
                            "op": .string("bind"),
                            "working_dirs": .string(workspaceTwo.repoPaths[0]),
                            "_rawJSON": .bool(true)
                        ]
                    )
                    XCTFail("expected refusal without host selector")
                } catch {}
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testContextIDOnOtherWindowIsRefused() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                _ = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string("OW W1"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                let (session, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                let ws1 = try XCTUnwrap(windowA.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
                let tabID = try XCTUnwrap(ws1.activeComposeTabID)
                do {
                    _ = try await bind(
                        service: service,
                        connectionID: connectionID,
                        arguments: [
                            "op": .string("bind"),
                            "context_id": .string(tabID.uuidString),
                            "_rawJSON": .bool(true)
                        ]
                    )
                    XCTFail("expected context_id refusal on non-host window")
                } catch let error as MCPError {
                    XCTAssertTrue(
                        error.localizedDescription.contains("does not actively show context_id"),
                        error.localizedDescription
                    )
                }
                let status = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: ["op": .string("status"), "_rawJSON": .bool(true)]
                )
                XCTAssertEqual(status.binding.windowID, windowB.windowID)
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testContextIDTwoWindowsWithoutSelectorIsRefused() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                _ = registerWindow()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let (session, provider) = try installLiveSession(on: windowA, workspace: workspaceOne)
                let ws1 = try XCTUnwrap(windowA.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
                let tabID = try XCTUnwrap(ws1.activeComposeTabID)
                do {
                    _ = try await bind(
                        service: service,
                        connectionID: connectionID,
                        arguments: [
                            "op": .string("bind"),
                            "context_id": .string(tabID.uuidString),
                            "_rawJSON": .bool(true)
                        ]
                    )
                    XCTFail("expected context_id refusal without host selector")
                } catch let error as MCPError {
                    XCTAssertTrue(
                        error.localizedDescription.contains("Multiple windows open. Supply 'window_id' or call 'bind_context' first."),
                        error.localizedDescription
                    )
                }
                let status = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: ["op": .string("status"), "_rawJSON": .bool(true)]
                )
                XCTAssertFalse(status.binding.explicit)
                XCTAssertNil(status.binding.windowID)
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWindowIDOnlyBindSelectsThatWindowsCurrentTab() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                XCTAssertEqual(response.binding.windowID, windowB.windowID)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWindowIDOnlyBindToOtherWindowIsRefused() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                _ = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string("OW W1"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                do {
                    _ = try await bind(
                        service: service,
                        connectionID: connectionID,
                        arguments: [
                            "op": .string("bind"),
                            "window_id": .int(windowA.windowID),
                            "_rawJSON": .bool(true)
                        ]
                    )
                    XCTFail("expected window_id-only bind refusal")
                } catch {}
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testWorkspaceTwoWindowsHostsOnBoundWindow() async throws {
            for graphEnabled in [true, false] {
                openerCount = 0
                let windowB = registerWindow()
                await windowB.workspaceManager.awaitInitialized()
                let service = configure(graphEnabled: graphEnabled)
                let connectionID = await connection(for: service)
                _ = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: [
                        "op": .string("bind"),
                        "workspace": .string("OW W1"),
                        "window_id": .int(windowB.windowID),
                        "_rawJSON": .bool(true)
                    ]
                )
                let (session, provider) = try installLiveSession(on: windowB, workspace: workspaceOne)
                let response = try await bind(
                    service: service,
                    connectionID: connectionID,
                    arguments: ["op": .string("bind"), "workspace": .string("OW W2"), "_rawJSON": .bool(true)]
                )
                XCTAssertEqual(response.binding.windowID, windowB.windowID)
                XCTAssertEqual(response.binding.workspaceID, workspaceTwo.id)
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(openerCount, 0)
            }
        }

        private final class CountingWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
            private(set) var queryCount = 0
            private(set) var cancelCount = 0

            func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
                queryCount += 1
                return [WorkspaceSwitchSessionItem(
                    id: "one-window-address-session",
                    count: 1,
                    singularLabel: "active session",
                    pluralLabel: "active sessions"
                )]
            }

            func cancelSwitchSessions() async {
                cancelCount += 1
            }
        }
    }
#endif
