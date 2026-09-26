import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    @MainActor
    final class OneWindowHostTests: XCTestCase {
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

        override func setUp() async throws {
            try await super.setUp()
            originalWindows = WindowStatesManager.shared.allWindows
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            originalGraphPolicy = ServerNetworkManager.shared.graphPolicy
            originalOpenerPolicy = AppWindowOpener.shared.policy
            originalApprovalSettings = WorkspaceApprovalManager.shared.settings
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            WorkspaceApprovalManager.shared.setAutoApproveOperation(.createWorkspace, enabled: true)
            WindowStatesManager.shared.allWindows = []
            AppWindowOpener.shared.resetForTesting()

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OneWindowHostTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
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
                profileIdentifier: "one-window-host-\(UUID().uuidString)",
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
            try await super.tearDown()
        }

        func testBareSwitchKeepsOneWindowAndTheSameWindowID() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                let response = try await call(service, connectionID: connectionID, arguments: switchArguments())
                XCTAssertEqual(response.windowID, windowA.windowID)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                XCTAssertEqual(openerCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testSwitchInNewWindowKeepsOneWindow() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                let args = switchArguments(legacy: true)
                let response = try await call(service, connectionID: connectionID, arguments: args)
                XCTAssertEqual(response.windowID, windowA.windowID)
                XCTAssertEqual(response.deprecatedArguments, ["open_in_new_window"])
                try assertDeprecatedArgumentsJSONKey(response)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                XCTAssertEqual(openerCount, 0)
                let formatted = try formattedResult(response: response, arguments: args)
                XCTAssertTrue(formatted.contains("existing window"))
                XCTAssertFalse(formatted.contains("New Window"))
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testCreateSwitchToCreatedKeepsOneWindow() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                try await assertCreatedAndBound(service, connectionID: connectionID, window: windowA)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testCreateInNewWindowKeepsOneWindowAndBindsW3() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                try await assertCreatedAndBound(service, connectionID: connectionID, window: windowA, legacy: true)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testCreateWithoutSwitchDoesNotBind() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments(workspace: workspaceTwo))
                let prior = binding(on: windowA, connectionID: connectionID)
                let args = createArguments(switchToCreated: false)
                let response = try await call(service, connectionID: connectionID, arguments: args)
                let created = try XCTUnwrap(response.workspaces?.first)
                XCTAssertEqual(response.windowID, windowA.windowID)
                XCTAssertEqual(binding(on: windowA, connectionID: connectionID).workspaceID, prior.workspaceID)
                XCTAssertEqual(created.showingWindowIDs, [])
                let listed = try await listedWorkspace(created.id, service: service, connectionID: connectionID)
                XCTAssertEqual(listed.showingWindowIDs, [])
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                XCTAssertEqual(openerCount, 0)
                let formatted = try formattedResult(response: response, arguments: args)
                XCTAssertTrue(formatted.contains("binding unchanged"))
                XCTAssertFalse(formatted.contains("New Window"))
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testSwitchLeavesAnotherResidentRunning() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments())
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(windowA.workspaceManager.activeWorkspace?.id, workspaceOne.id)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testSwitchDoesNotCallRequestWorkspaceSwitch() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                let response = try await call(service, connectionID: connectionID, arguments: switchArguments(legacy: true))
                XCTAssertEqual(response.windowID, windowA.windowID)
                XCTAssertEqual(provider.queryCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testTwoWindowsHostOnTheBoundWindow() async throws {
            let windowB = registerWindow()
            await windowB.workspaceManager.awaitInitialized()
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments(workspace: workspaceOne, windowID: windowB.windowID))
                for legacy in [false, true] {
                    let response = try await call(service, connectionID: connectionID, arguments: switchArguments(legacy: legacy))
                    XCTAssertEqual(response.windowID, windowB.windowID)
                    XCTAssertEqual(response.deprecatedArguments, legacy ? ["open_in_new_window"] : nil)
                    try await assertCreatedAndBound(service, connectionID: connectionID, window: windowB, legacy: legacy)
                }
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testTwoWindowsHostOnWindowIDArgument() async throws {
            let windowB = registerWindow()
            await windowB.workspaceManager.awaitInitialized()
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                for legacy in [false, true] {
                    let switchConnectionID = await connection(for: service)
                    let response = try await call(service, connectionID: switchConnectionID, arguments: switchArguments(legacy: legacy, windowID: windowB.windowID))
                    XCTAssertEqual(response.windowID, windowB.windowID)
                    XCTAssertEqual(binding(on: windowB, connectionID: switchConnectionID).workspaceID, workspaceTwo.id)
                    let createConnectionID = await connection(for: service)
                    try await assertCreatedAndBound(service, connectionID: createConnectionID, window: windowB, legacy: legacy, explicitWindowID: true)
                    let noSwitchConnectionID = await connection(for: service)
                    let prior = binding(on: windowB, connectionID: noSwitchConnectionID)
                    let noSwitch = try await call(
                        service,
                        connectionID: noSwitchConnectionID,
                        arguments: createArguments(switchToCreated: false, legacy: legacy, windowID: windowB.windowID)
                    )
                    let created = try XCTUnwrap(noSwitch.workspaces?.first)
                    XCTAssertEqual(noSwitch.windowID, windowB.windowID)
                    XCTAssertEqual(noSwitch.deprecatedArguments, legacy ? ["open_in_new_window"] : nil)
                    XCTAssertEqual(binding(on: windowB, connectionID: noSwitchConnectionID).workspaceID, prior.workspaceID)
                    let listed = try await listedWorkspace(created.id, service: service, connectionID: noSwitchConnectionID)
                    XCTAssertEqual(listed.showingWindowIDs, [])
                }
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testTwoWindowsCreateWithoutSwitchHostsOnBoundWindow() async throws {
            let windowB = registerWindow()
            await windowB.workspaceManager.awaitInitialized()
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                for legacy in [false, true] {
                    let connectionID = await connection(for: service)
                    _ = try await call(service, connectionID: connectionID, arguments: switchArguments(workspace: workspaceOne, windowID: windowB.windowID))
                    let prior = binding(on: windowB, connectionID: connectionID)
                    let response = try await call(service, connectionID: connectionID, arguments: createArguments(switchToCreated: false, legacy: legacy))
                    let created = try XCTUnwrap(response.workspaces?.first)
                    XCTAssertEqual(response.windowID, windowB.windowID)
                    XCTAssertEqual(response.deprecatedArguments, legacy ? ["open_in_new_window"] : nil)
                    XCTAssertEqual(binding(on: windowB, connectionID: connectionID).workspaceID, prior.workspaceID)
                    let listed = try await listedWorkspace(created.id, service: service, connectionID: connectionID)
                    XCTAssertEqual(listed.showingWindowIDs, [])
                }
                assertSessionUnchanged(session, provider: provider)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
                XCTAssertEqual(openerCount, 0)
            }
        }

        func testTwoWindowsWithoutSelectorRefusesAndOpensNothing() async throws {
            let windowB = registerWindow()
            await windowB.workspaceManager.awaitInitialized()
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                for args in twoWindowRequests() {
                    let connectionID = await connection(for: service)
                    do {
                        _ = try await call(service, connectionID: connectionID, arguments: args)
                        XCTFail("Unbound two-window request must be refused")
                    } catch {}
                    XCTAssertNil(binding(on: windowA, connectionID: connectionID).workspaceID)
                    XCTAssertNil(binding(on: windowB, connectionID: connectionID).workspaceID)
                }
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
                XCTAssertEqual(openerCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testBoundWindowAndOtherWindowIDIsRefused() async throws {
            let windowB = registerWindow()
            await windowB.workspaceManager.awaitInitialized()
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments(workspace: workspaceOne, windowID: windowB.windowID))
                let prior = binding(on: windowB, connectionID: connectionID)
                for var args in twoWindowRequests() {
                    args["window_id"] = .int(windowA.windowID)
                    do {
                        _ = try await call(service, connectionID: connectionID, arguments: args)
                        XCTFail("Conflicting window_id must be refused")
                    } catch {}
                    XCTAssertEqual(binding(on: windowB, connectionID: connectionID).workspaceID, prior.workspaceID)
                }
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
                XCTAssertEqual(openerCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testFlagTrueAndFalseUseTheSameWindow() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                let response = try await call(service, connectionID: connectionID, arguments: switchArguments(legacy: true))
                XCTAssertEqual(response.windowID, windowA.windowID)
                XCTAssertEqual(binding(on: windowA, connectionID: connectionID).workspaceID, workspaceTwo.id)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                XCTAssertEqual(openerCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testHumanNewWindowKeepsFlagOffBehaviour() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                openerCount = 0
                try sendDockNewWindow()
                XCTAssertEqual(openerCount, enabled ? 0 : 1)
                openerCount = 0
                OrchestrationGraphWindowPolicy.performNewWindowCommand(
                    policy: OrchestrationGraphWindowPolicy(isGraphEnabled: { enabled }),
                    openWindow: { self.openerCount += 1 }
                )
                XCTAssertEqual(openerCount, enabled ? 0 : 1)
                openerCount = 0
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments(legacy: true))
                XCTAssertEqual(openerCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testHumanNewWindowKeepsFlagOnBehaviour() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                openerCount = 0
                try sendDockNewWindow()
                XCTAssertEqual(openerCount, enabled ? 0 : 1)
                openerCount = 0
                OrchestrationGraphWindowPolicy.performNewWindowCommand(
                    policy: OrchestrationGraphWindowPolicy(isGraphEnabled: { enabled }),
                    openWindow: { self.openerCount += 1 }
                )
                XCTAssertEqual(openerCount, enabled ? 0 : 1)
                openerCount = 0
                if enabled {
                    XCTAssertThrowsError(try AppWindowOpener.shared.openMainWindow()) { error in
                        guard case WindowOpenError.singleWindowPolicy = error else {
                            return XCTFail("expected singleWindowPolicy, got \(error)")
                        }
                    }
                }
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments(legacy: true))
                XCTAssertEqual(openerCount, 0)
                assertSessionUnchanged(session, provider: provider)
            }
        }

        func testMCPNeverReachesTheOpener() async throws {
            let (session, provider) = try installLiveSession(on: windowA)
            for enabled in [true, false] {
                let service = configure(graphEnabled: enabled)
                let connectionID = await connection(for: service)
                _ = try await call(service, connectionID: connectionID, arguments: switchArguments(legacy: true))
                _ = try await call(service, connectionID: connectionID, arguments: createArguments(legacy: true))
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                assertSessionUnchanged(session, provider: provider)
            }
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

        private func switchArguments(workspace: WorkspaceModel? = nil, legacy: Bool = false, windowID: Int? = nil) -> [String: Value] {
            var args: [String: Value] = [
                "action": .string("switch"),
                "workspace": .string((workspace ?? workspaceTwo).id.uuidString),
                "_rawJSON": .bool(true)
            ]
            if legacy { args["open_in_new_window"] = .bool(true) }
            if let windowID { args["window_id"] = .int(windowID) }
            return args
        }

        private func createArguments(switchToCreated: Bool = true, legacy: Bool = false, windowID: Int? = nil) -> [String: Value] {
            var args: [String: Value] = [
                "action": .string("create"),
                "name": .string("OW W3 \(UUID().uuidString)"),
                "switch_to_created": .bool(switchToCreated),
                "_rawJSON": .bool(true)
            ]
            if legacy { args["open_in_new_window"] = .bool(true) }
            if let windowID { args["window_id"] = .int(windowID) }
            return args
        }

        private func twoWindowRequests() -> [[String: Value]] {
            [
                switchArguments(), switchArguments(legacy: true),
                createArguments(), createArguments(legacy: true),
                createArguments(switchToCreated: false), createArguments(switchToCreated: false, legacy: true)
            ]
        }

        private func assertCreatedAndBound(
            _ service: WindowRoutingService,
            connectionID: UUID,
            window: WindowState,
            legacy: Bool = false,
            explicitWindowID: Bool = false
        ) async throws {
            let args = createArguments(legacy: legacy, windowID: explicitWindowID ? window.windowID : nil)
            let response = try await call(service, connectionID: connectionID, arguments: args)
            let created = try XCTUnwrap(response.workspaces?.first)

            let createdWorkspaceModel = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == created.id })
            XCTAssertEqual(createdWorkspaceModel.isSavedWorkspace, false)
            XCTAssertTrue(createdWorkspaceModel.isTemporaryWorkspace)

            XCTAssertEqual(response.windowID, window.windowID)
            XCTAssertEqual(response.deprecatedArguments, legacy ? ["open_in_new_window"] : nil)
            if legacy { try assertDeprecatedArgumentsJSONKey(response) }
            XCTAssertEqual(created.showingWindowIDs, [window.windowID])
            XCTAssertEqual(binding(on: window, connectionID: connectionID).workspaceID, created.id)
            let listed = try await listedWorkspace(created.id, service: service, connectionID: connectionID)
            XCTAssertEqual(listed.showingWindowIDs, [window.windowID])
            XCTAssertEqual(openerCount, 0)
            if legacy {
                let formatted = try formattedResult(response: response, arguments: args)
                XCTAssertTrue(formatted.contains("existing window"))
                XCTAssertFalse(formatted.contains("New Window"))
                XCTAssertTrue(formatted.contains("open_in_new_window"))
            }
        }

        private func listedWorkspace(_ id: UUID, service: WindowRoutingService, connectionID: UUID) async throws -> MCPWorkspaceSummary {
            let response = try await call(service, connectionID: connectionID, arguments: ["action": .string("list"), "_rawJSON": .bool(true)])
            return try XCTUnwrap(response.workspaces?.first(where: { $0.id == id }))
        }

        private func binding(on window: WindowState, connectionID: UUID) -> MCPServerViewModel.ConnectionBindingSnapshot {
            window.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
        }

        private func assertDeprecatedArgumentsJSONKey(_ response: ManageWorkspacesResponse) throws {
            let json = try String(data: JSONEncoder().encode(response), encoding: .utf8)
            XCTAssertTrue(json?.contains("\"deprecated_arguments\"") == true)
        }

        private func formattedResult(response: ManageWorkspacesResponse, arguments: [String: Value]) throws -> String {
            let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(response))
            return ToolOutputFormatter.formatManageWorkspaces(args: arguments, value: value).compactMap { content -> String? in
                if case let .text(text, _, _) = content { return text }
                return nil
            }.joined(separator: "\n")
        }

        private func installLiveSession(on window: WindowState) throws -> (AgentTabSession, CountingWorkspaceSwitchSessionProvider) {
            let provider = CountingWorkspaceSwitchSessionProvider()
            window.workspaceManager.registerSwitchSessionProvider(provider)
            let workspace = try XCTUnwrap(window.workspaceManager.workspaces.first(where: { $0.id == workspaceOne.id }))
            let tabID = try XCTUnwrap(workspace.activeComposeTabID)
            let session = AgentTabSession(tabID: tabID)
            window.agentModeViewModel.test_installLiveSession(session)
            window.agentModeViewModel.setAgentRunActive(session, isActive: true)
            session.runState = .running
            runStateChangeCount = 0
            session.onRunStateChanged = { [weak self] _ in self?.runStateChangeCount += 1 }
            return (session, provider)
        }

        private func assertSessionUnchanged(_ session: AgentTabSession, provider: CountingWorkspaceSwitchSessionProvider) {
            XCTAssertEqual(provider.cancelCount, 0)
            XCTAssertEqual(runStateChangeCount, 0)
            XCTAssertEqual(session.runState, .running)
        }

        private func sendDockNewWindow() throws {
            let controller = DockMenuController()
            let item = try XCTUnwrap(controller.makeMenu().items.first)
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        }

        private final class CountingWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
            private(set) var queryCount = 0
            private(set) var cancelCount = 0

            func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
                queryCount += 1
                return [WorkspaceSwitchSessionItem(
                    id: "one-window-host-session",
                    count: 1,
                    singularLabel: "active session",
                    pluralLabel: "active sessions"
                )]
            }

            func cancelSwitchSessions() async {
                cancelCount += 1
            }
        }

        private func call(_ service: WindowRoutingService, connectionID: UUID, arguments: [String: Value]) async throws -> ManageWorkspacesResponse {
            let value = try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                try await service.call(tool: MCPGlobalToolName.manageWorkspaces, with: arguments)
            }
            return try JSONDecoder().decode(ManageWorkspacesResponse.self, from: JSONEncoder().encode(XCTUnwrap(value)))
        }

        @discardableResult
        private func registerWindow() -> WindowState {
            let window = WindowState(domainRuntime: runtime)
            addedWindows.append(window)
            WindowStatesManager.shared.registerWindowState(window)
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
    }
#endif
