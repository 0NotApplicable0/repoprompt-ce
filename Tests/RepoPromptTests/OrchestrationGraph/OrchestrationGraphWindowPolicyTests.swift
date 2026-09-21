import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    /// OG-04 / DW-4: with the orchestration graph flag on, the Dock, File → New Window (⌘N) and MCP
    /// `open_in_new_window` routes never attach a second main `WindowState`; with it off they keep
    /// today's behaviour. The flag is always injected through `OrchestrationGraphWindowPolicy`; the
    /// shared settings flag is never written.
    @MainActor
    final class OrchestrationGraphWindowPolicyTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var targetWorkspace: WorkspaceModel!
        private var windowA: WindowState!
        private var addedWindows: [WindowState] = []
        private var connectionIDs: [UUID] = []

        override func setUp() async throws {
            try await super.setUp()
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrchestrationGraphWindowPolicyTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)
            targetWorkspace = makeTargetWorkspace()
            try writeWorkspace(targetWorkspace)
            try writeLegacyIndex([targetWorkspace])
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "orchestration-graph-window-policy-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()

            windowA = makeRegisteredWindow()
        }

        override func tearDown() async throws {
            for window in addedWindows.reversed() {
                WindowStatesManager.shared.unregisterWindowState(window)
                await window.tearDown()
            }
            addedWindows.removeAll()
            windowA = nil
            for connectionID in connectionIDs {
                await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
            }
            connectionIDs.removeAll()
            WindowStatesManager.shared.allWindows = originalWindows
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
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

        // MARK: - Dock → New Window

        func testFlagOffDockNewWindowAttachesSecondWindow() throws {
            AppWindowOpener.shared.policy = policy(graphEnabled: false)
            installProductionOpener()

            try sendDockNewWindow()

            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
            XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === windowA })
        }

        func testFlagOnDockNewWindowDoesNotAttachSecondWindow() throws {
            AppWindowOpener.shared.policy = policy(graphEnabled: true)
            var openCount = 0
            installProductionOpener { openCount += 1 }

            try sendDockNewWindow()

            XCTAssertEqual(openCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertTrue(WindowStatesManager.shared.allWindows.first === windowA)
        }

        func testFlagOnDockNewWindowBeforeInstallDoesNotFlushOnInstall() throws {
            AppWindowOpener.shared.policy = policy(graphEnabled: true)
            XCTAssertFalse(AppWindowOpener.shared.isAvailable)

            try sendDockNewWindow()
            try sendDockNewWindow()

            var openCount = 0
            installProductionOpener { openCount += 1 }
            XCTAssertEqual(openCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)

            try sendDockNewWindow()
            XCTAssertEqual(openCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
        }

        func testFlagOnInstallReplaysAtMostOneQueuedDockRequestWhenNoWindowExists() async throws {
            let closedWindow: WindowState = windowA
            WindowStatesManager.shared.unregisterWindowState(closedWindow)
            addedWindows.removeAll { $0 === closedWindow }
            await closedWindow.tearDown()
            XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty)
            AppWindowOpener.shared.policy = policy(graphEnabled: true)
            XCTAssertFalse(AppWindowOpener.shared.isAvailable)

            try sendDockNewWindow()
            try sendDockNewWindow()
            try sendDockNewWindow()

            var openCount = 0
            installProductionOpener { openCount += 1 }

            XCTAssertEqual(openCount, 1)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertFalse(WindowStatesManager.shared.allWindows.first === closedWindow)
        }

        // MARK: - File → New Window (⌘N)

        func testFlagOffFileNewWindowCommandAttachesSecondWindow() {
            var openCount = 0

            OrchestrationGraphWindowPolicy.performNewWindowCommand(
                policy: policy(graphEnabled: false),
                openWindow: {
                    openCount += 1
                    self.openMainWindowLikeWindowContentView()
                }
            )

            XCTAssertEqual(openCount, 1)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
        }

        func testFlagOnFileNewWindowCommandPerformsNoOpen() {
            var openCount = 0
            var fallbackOpenCount = 0
            AppWindowOpener.shared.policy = policy(graphEnabled: true)
            installProductionOpener { fallbackOpenCount += 1 }

            OrchestrationGraphWindowPolicy.performNewWindowCommand(
                policy: policy(graphEnabled: true),
                openWindow: {
                    openCount += 1
                    self.openMainWindowLikeWindowContentView()
                }
            )

            XCTAssertEqual(openCount, 0)
            XCTAssertEqual(fallbackOpenCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertTrue(WindowStatesManager.shared.allWindows.first === windowA)
        }

        func testFlagOnFileNewWindowCommandOpensFirstWindowWhenNoneExist() async {
            let closedWindow: WindowState = windowA
            WindowStatesManager.shared.unregisterWindowState(closedWindow)
            addedWindows.removeAll { $0 === closedWindow }
            await closedWindow.tearDown()
            XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty)
            var openCount = 0

            OrchestrationGraphWindowPolicy.performNewWindowCommand(
                policy: policy(graphEnabled: true),
                openWindow: {
                    openCount += 1
                    self.openMainWindowLikeWindowContentView()
                }
            )

            XCTAssertEqual(openCount, 1)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertFalse(WindowStatesManager.shared.allWindows.first === closedWindow)
        }

        func testFileNewWindowCommandGroupReplacesNewItemAndCallsHelper() throws {
            let appURL = try RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/App/RepoPromptApp.swift")
            let source = try String(contentsOf: appURL, encoding: .utf8)

            let groupRange = try XCTUnwrap(
                source.range(of: "CommandGroup(replacing: .newItem)"),
                "RepoPromptApp.swift must replace the default .newItem group"
            )
            XCTAssertEqual(source.components(separatedBy: "CommandGroup(replacing: .newItem)").count, 2)

            let groupBody = try commandGroupBody(in: source, startingAt: groupRange.upperBound)
            XCTAssertEqual(groupBody.components(separatedBy: "Button(").count - 1, 1, groupBody)
            XCTAssertTrue(
                groupBody.contains("OrchestrationGraphWindowPolicy.performNewWindowCommand("),
                groupBody
            )
            XCTAssertTrue(groupBody.contains(".keyboardShortcut(\"n\", modifiers: .command)"), groupBody)
            XCTAssertEqual(
                groupBody.components(separatedBy: "openWindow(id: \"main\")").count - 1,
                1,
                "the only scene open in the group is the closure passed to the helper: \(groupBody)"
            )
            XCTAssertFalse(groupBody.contains("openMainWindow"), groupBody)
            XCTAssertFalse(groupBody.contains("requestMainWindowFromDock"), groupBody)

            XCTAssertEqual(
                source.components(separatedBy: "NewWindowCommands()").count - 1,
                1,
                "RepoPromptApp.swift must have exactly one NewWindowCommands() call site"
            )
            let commandsRange = try XCTUnwrap(source.range(of: ".commands {"))
            let commandsBody = try commandGroupBody(in: source, startingAt: commandsRange.lowerBound)
            XCTAssertTrue(commandsBody.contains("NewWindowCommands()"), commandsBody)
        }

        // MARK: - MCP open_in_new_window

        func testFlagOffMCPOpenInNewWindowAttachesSecondWindow() async throws {
            AppWindowOpener.shared.policy = policy(graphEnabled: false)
            installProductionOpener()
            let service = makeRoutingService(graphEnabled: false)

            let response = try await callSwitchInNewWindow(service)

            XCTAssertEqual(response.action, "switch")
            XCTAssertEqual(response.status, "ok")
            let windowID = try XCTUnwrap(response.windowID)
            XCTAssertNotEqual(windowID, windowA.windowID)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
            let opened = try XCTUnwrap(WindowStatesManager.shared.allWindows.first { $0.windowID == windowID })
            XCTAssertEqual(opened.workspaceManager.activeWorkspaceID, targetWorkspace.id)
        }

        func testFlagOnMCPOpenInNewWindowReturnsExistingWindowID() async throws {
            AppWindowOpener.shared.policy = policy(graphEnabled: true)
            var openCount = 0
            installProductionOpener { openCount += 1 }
            let service = makeRoutingService(graphEnabled: true)

            let response = try await callSwitchInNewWindow(service)

            XCTAssertEqual(response.action, "switch")
            XCTAssertEqual(response.status, "ok")
            XCTAssertEqual(response.windowID, windowA.windowID)
            XCTAssertEqual(openCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertTrue(WindowStatesManager.shared.allWindows.first === windowA)
            XCTAssertEqual(windowA.workspaceManager.activeWorkspaceID, targetWorkspace.id)
        }

        // MARK: - Window root surface

        func testFlagOnWindowContentViewMountsOrchestrationGraphShell() {
            XCTAssertEqual(
                WindowContentView.rootSurface(policy: policy(graphEnabled: true)),
                .orchestrationGraphShell
            )
            XCTAssertEqual(
                WindowContentView(policy: policy(graphEnabled: true)).storedRootSurfaceForTesting,
                .orchestrationGraphShell
            )

            let host = NSHostingView(rootView: OrchestrationGraphShell(windowState: windowA))
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
            host.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(host.fittingSize.width, 0)
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }

        func testFlagOffWindowContentViewMountsContentView() {
            XCTAssertEqual(
                WindowContentView.rootSurface(policy: policy(graphEnabled: false)),
                .contentView
            )
            XCTAssertEqual(
                WindowContentView(policy: policy(graphEnabled: false)).storedRootSurfaceForTesting,
                .contentView
            )
        }

        // MARK: - Helpers

        /// The target lives entirely under the temporary storage root: its `customStoragePath` keeps
        /// the manager's Chats / `_git_data` / AgentSessions sidecars out of the live library.
        private func makeTargetWorkspace() -> WorkspaceModel {
            let id = UUID()
            let name = "OG04 Graph Target"
            let directory = storageRoot.appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: name, id: id),
                isDirectory: true
            )
            return WorkspaceModel(
                id: id,
                dateModified: Date(timeIntervalSince1970: 200),
                name: name,
                repoPaths: [storageRoot.appendingPathComponent("og04-graph-target-repo").path],
                lastUsed: Date(timeIntervalSince1970: 200),
                customStoragePath: directory
            )
        }

        private func policy(graphEnabled: Bool) -> OrchestrationGraphWindowPolicy {
            OrchestrationGraphWindowPolicy(isGraphEnabled: { graphEnabled })
        }

        /// Mirrors `WindowContentView.onAppear`: a fresh `WindowState` registered with the shared
        /// manager, which is what resumes `openNewMainWindow`'s waiter. Windows use the temporary
        /// domain runtime so no workspace I/O reaches the live library.
        @discardableResult
        private func makeRegisteredWindow() -> WindowState {
            let window = WindowState(domainRuntime: runtime)
            addedWindows.append(window)
            WindowStatesManager.shared.registerWindowState(window)
            return window
        }

        private func openMainWindowLikeWindowContentView() {
            makeRegisteredWindow()
        }

        private func installProductionOpener(onOpen: (() -> Void)? = nil) {
            AppWindowOpener.shared.install(openMainWindow: { [weak self] in
                onOpen?()
                self?.openMainWindowLikeWindowContentView()
            })
        }

        private func sendDockNewWindow() throws {
            let controller = DockMenuController()
            let item = try XCTUnwrap(controller.makeMenu().items.first)
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        }

        private func makeRoutingService(graphEnabled: Bool) -> WindowRoutingService {
            let service = WindowRoutingService(
                windowStates: WindowStatesManager.shared,
                networkMgr: ServerNetworkManager.shared
            )
            service.policy = policy(graphEnabled: graphEnabled)
            return service
        }

        private func callSwitchInNewWindow(_ service: WindowRoutingService) async throws -> ManageWorkspacesResponse {
            await windowA.workspaceManager.awaitInitialized()
            await service.prepareDomainTools()
            let connectionID = UUID()
            connectionIDs.append(connectionID)
            let arguments: [String: Value] = [
                "action": .string("switch"),
                "workspace": .string(targetWorkspace.id.uuidString),
                "open_in_new_window": .bool(true),
                "_rawJSON": .bool(true)
            ]
            let value = try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                try await service.call(tool: MCPGlobalToolName.manageWorkspaces, with: arguments)
            }
            let data = try JSONEncoder().encode(XCTUnwrap(value))
            return try JSONDecoder().decode(ManageWorkspacesResponse.self, from: data)
        }

        private func commandGroupBody(in source: String, startingAt start: String.Index) throws -> String {
            let open = try XCTUnwrap(source[start...].firstIndex(of: "{"))
            var depth = 0
            var index = open
            while index < source.endIndex {
                switch source[index] {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(source[open ... index])
                    }
                default: break
                }
                index = source.index(after: index)
            }
            throw CommandGroupBodyError.unbalanced
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

    private enum CommandGroupBodyError: Error {
        case unbalanced
    }
#endif
