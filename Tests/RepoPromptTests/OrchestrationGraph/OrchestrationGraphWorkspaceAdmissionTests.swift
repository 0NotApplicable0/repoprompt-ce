import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
@testable import RepoPromptShared
import SwiftUI
import XCTest

#if DEBUG
    /// With the orchestration graph flag on, one main window admits a saved but inactive
    /// workspace's stored compose tab — and exact root authority over its roots — without
    /// switching the window's `activeWorkspace` or entering the workspace-switch confirmation /
    /// cancellation lifecycle. Flag off keeps today's behaviour (active-only matching, a second main
    /// window on `open_in_new_window`).
    @MainActor
    final class OrchestrationGraphWorkspaceAdmissionTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var originalGraphPolicy = OrchestrationGraphWindowPolicy.production
        private var originalApprovalSettings: WorkspaceApprovalSettings?
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var workspaceOne: WorkspaceModel!
        private var workspaceTwo: WorkspaceModel!
        private var repoRootOne: URL!
        private var repoRootTwo: URL!
        private var windowX: WindowState!
        private var addedWindows: [WindowState] = []
        private var connectionIDs: [UUID] = []
        private var fakeSessionProvider: CountingWorkspaceSwitchSessionProvider!
        private var pendingConfirmationLatch: PendingConfirmationLatch!
        private var switchPhaseEvents: [WorkspaceSwitchPhase] = []

        override func setUp() async throws {
            try await super.setUp()
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            originalGraphPolicy = ServerNetworkManager.shared.graphPolicy
            originalApprovalSettings = WorkspaceApprovalManager.shared.settings
            WorkspaceApprovalManager.shared.setAutoApproveOperation(.createWorkspace, enabled: true)
            originalWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrchestrationGraphWorkspaceAdmissionTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)

            repoRootOne = storageRoot.appendingPathComponent("r1-repo", isDirectory: true)
            repoRootTwo = storageRoot.appendingPathComponent("r2-repo", isDirectory: true)
            try FileManager.default.createDirectory(at: repoRootOne, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: repoRootTwo, withIntermediateDirectories: true)
            try "r1-only".write(to: repoRootOne.appendingPathComponent("only-r1.txt"), atomically: true, encoding: .utf8)
            try "r2-only".write(to: repoRootTwo.appendingPathComponent("only-r2.txt"), atomically: true, encoding: .utf8)
            try "r1-same".write(to: repoRootOne.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            try "r2-same".write(to: repoRootTwo.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)

            workspaceOne = makeWorkspace(name: "OG06 W1", repoRoot: repoRootOne, lastUsed: Date(timeIntervalSince1970: 100))
            workspaceTwo = makeWorkspace(name: "OG06 W2", repoRoot: repoRootTwo, lastUsed: Date(timeIntervalSince1970: 200))
            try writeWorkspace(workspaceOne)
            try writeWorkspace(workspaceTwo)
            try writeLegacyIndex([workspaceOne, workspaceTwo])

            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "orchestration-graph-workspace-admission-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()

            windowX = WindowState(domainRuntime: runtime)
            addedWindows.append(windowX)
            WindowStatesManager.shared.registerWindowState(windowX)
            await windowX.workspaceManager.awaitInitialized()

            let activationResult = await windowX.workspaceManager.requestWorkspaceSwitch(to: workspaceOne, saveState: false)
            XCTAssertTrue(activationResult.didSwitch, activationResult.message ?? "setup: W1 activation failed")
            // Capture the persisted saved active tab actually stored by the manager, per design § 5.
            workspaceOne = try XCTUnwrap(windowX.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
            workspaceTwo = try XCTUnwrap(windowX.workspaceManager.workspaces.first { $0.id == workspaceTwo.id })

            fakeSessionProvider = CountingWorkspaceSwitchSessionProvider()
            pendingConfirmationLatch = PendingConfirmationLatch()
            switchPhaseEvents = []
            windowX.workspaceManager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { [weak self] phase in
                self?.switchPhaseEvents.append(phase)
            }
        }

        override func tearDown() async throws {
            windowX?.workspaceManager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting(nil)
            for window in addedWindows.reversed() {
                WindowStatesManager.shared.unregisterWindowState(window)
                await window.tearDown()
            }
            addedWindows.removeAll()
            windowX = nil
            for connectionID in connectionIDs {
                await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
            }
            connectionIDs.removeAll()
            WindowStatesManager.shared.allWindows = originalWindows
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
            ServerNetworkManager.shared.graphPolicy = originalGraphPolicy
            if let originalApprovalSettings {
                WorkspaceApprovalManager.shared.setAutoApproveOperation(
                    .createWorkspace,
                    enabled: originalApprovalSettings.autoApproveOperations.contains(.createWorkspace)
                )
            }
            WorkspaceApprovalManager.shared.cancelAllPending()
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

        // MARK: - working_dirs bind (graph-on)

        func testWorkingDirsBindMatchesSavedWorkspaceThatIsNotActive() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)

            let value = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.bindContext,
                arguments: [
                    "op": .string("bind"),
                    "working_dirs": .array([.string(repoRootTwo.path)]),
                    "_rawJSON": .bool(true)
                ],
                connectionID: connectionID
            )
            let response = try decode(BindContextResponse.self, from: value)

            XCTAssertEqual(response.binding.windowID, windowX.windowID)
            XCTAssertEqual(response.binding.workspaceID, workspaceTwo.id)
            XCTAssertEqual(response.binding.contextID, workspaceTwo.activeComposeTabID)

            try await assertGraphOnPostconditions(connectionID: connectionID)
        }

        // MARK: - impl-r1 regression fixes (findings 1-5)

        func testActiveAgentSessionOnStoredTabFailsGraphAdmissionClosed() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)
            let tabID = try XCTUnwrap(workspaceTwo.activeComposeTabID)
            XCTAssertTrue(windowX.workspaceManager.compareAndSetActiveAgentSessionID(
                expected: nil,
                replacement: UUID(),
                forTabID: tabID,
                inWorkspaceID: workspaceTwo.id
            ))

            do {
                _ = try await callBoundedTool(
                    service: service,
                    tool: MCPGlobalToolName.bindContext,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .array([.string(repoRootTwo.path)]),
                        "_rawJSON": .bool(true)
                    ],
                    connectionID: connectionID
                )
                XCTFail("expected graph admission to fail closed for a stored tab with an active Agent session")
            } catch {
                // expected
            }

            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertEqual(windowX.workspaceManager.activeWorkspaceID, workspaceOne.id)
            let binding = windowX.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
            XCTAssertNotEqual(binding.workspaceID, workspaceTwo.id)
        }

        func testAgentSessionStartedAfterPrepareButBeforeInstallFailsAdmissionClosed() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)
            let tabID = try XCTUnwrap(workspaceTwo.activeComposeTabID)
            let priorBinding = windowX.mcpServer.connectionBindingSnapshot(forConnection: connectionID)

            service.debugGraphAdmissionInterleaveHook = { [windowX, workspaceTwo] in
                guard let windowX, let workspaceTwo else { return }
                _ = windowX.workspaceManager.compareAndSetActiveAgentSessionID(
                    expected: nil,
                    replacement: UUID(),
                    forTabID: tabID,
                    inWorkspaceID: workspaceTwo.id
                )
            }
            defer { service.debugGraphAdmissionInterleaveHook = nil }

            do {
                _ = try await callBoundedTool(
                    service: service,
                    tool: MCPGlobalToolName.bindContext,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .array([.string(repoRootTwo.path)]),
                        "_rawJSON": .bool(true)
                    ],
                    connectionID: connectionID
                )
                XCTFail("expected admission to fail closed for an Agent session started between prepare and install")
            } catch {
                // expected
            }

            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertEqual(windowX.workspaceManager.activeWorkspaceID, workspaceOne.id)
            let binding = windowX.mcpServer.connectionBindingSnapshot(forConnection: connectionID)
            XCTAssertEqual(binding.workspaceID, priorBinding.workspaceID)
            XCTAssertEqual(binding.tabID, priorBinding.tabID)
            XCTAssertNotEqual(binding.workspaceID, workspaceTwo.id)
            let hasLease = await ServerNetworkManager.shared.debugHasGraphAdmissionLease(connectionID: connectionID)
            XCTAssertFalse(hasLease, "expected the provisional admission ticket to be aborted, leaving no graph lease")
        }

        func testGraphAdmissionVerifiesDomainRoutingAuthorityForCreatedWorkspace() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let repoRootFour = try makeRepoRoot(named: "r4-repo", sentinel: "only-r4.txt", sentinelContent: "r4-only", sameContent: "r4-same")
            let connectionID = await makeConnection(service)

            let value = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.bindContext,
                arguments: [
                    "op": .string("bind"),
                    "working_dirs": .array([.string(repoRootFour.path)]),
                    "create_if_missing": .bool(true),
                    "_rawJSON": .bool(true)
                ],
                connectionID: connectionID
            )
            let response = try decode(BindContextResponse.self, from: value)

            let coordinator = try XCTUnwrap(windowX.mcpServer.domainRoutingCoordinator, "expected a domain routing coordinator in this fixture")
            let snapshot = await coordinator.snapshot()
            let binding = snapshot.connections.first { $0.registration.connectionID == connectionID }?.binding
            guard case let .context(identity, explicit) = binding else {
                XCTFail("expected an accepted context binding, got \(String(describing: binding))")
                return
            }
            XCTAssertTrue(explicit)
            XCTAssertEqual(identity.workspaceID, response.binding.workspaceID)
            XCTAssertEqual(identity.contextID, response.binding.contextID)
        }

        func testFailedNonGraphRebindPreservesGraphAdmissionRootAuthority() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)

            _ = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.bindContext,
                arguments: [
                    "op": .string("bind"),
                    "working_dirs": .array([.string(repoRootTwo.path)]),
                    "_rawJSON": .bool(true)
                ],
                connectionID: connectionID
            )

            // A second window drops the single-graph-window invariant, so the next working_dirs
            // bind on this connection falls through to the ordinary explicit-rebind path
            // (`bindTarget`) instead of `admitStoredWorkspace`.
            let windowY = WindowState(domainRuntime: runtime)
            addedWindows.append(windowY)
            WindowStatesManager.shared.registerWindowState(windowY)
            await windowY.workspaceManager.awaitInitialized()

            let w1TabID = try XCTUnwrap(workspaceOne.activeComposeTabID)
            windowX.mcpServer.setAfterFileToolLookupContextRootValidationForTesting { [windowX, workspaceOne] in
                guard let windowX, let workspaceOne else { return }
                _ = windowX.workspaceManager.compareAndSetActiveAgentSessionID(
                    expected: nil,
                    replacement: UUID(),
                    forTabID: w1TabID,
                    inWorkspaceID: workspaceOne.id
                )
            }
            defer { windowX.mcpServer.setAfterFileToolLookupContextRootValidationForTesting(nil) }

            do {
                _ = try await callBoundedTool(
                    service: service,
                    tool: MCPGlobalToolName.bindContext,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .array([.string(repoRootOne.path)]),
                        "_rawJSON": .bool(true)
                    ],
                    connectionID: connectionID
                )
                XCTFail("expected the rebind to detect a stale target and fail")
            } catch {
                // expected: the rebind target went stale mid-resolution
            }

            try await assertRootAuthority(
                connectionID: connectionID,
                expectedRoot: repoRootTwo,
                unexpectedRoot: repoRootOne,
                file: #filePath,
                line: #line
            )
        }

        func testWindowCloseReleasesGraphAdmissionRootAuthority() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)

            _ = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.bindContext,
                arguments: [
                    "op": .string("bind"),
                    "working_dirs": .array([.string(repoRootTwo.path)]),
                    "_rawJSON": .bool(true)
                ],
                connectionID: connectionID
            )

            let store = windowX.workspaceFileContextStore
            let boundMetadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: nil,
                windowID: nil,
                runPurpose: nil,
                tabContextHint: nil,
                explicitWindowRoutingHint: nil
            )
            let boundContext = await windowX.mcpServer.resolveFileToolLookupContext(from: boundMetadata)
            let rootScope = boundContext.rootScope
            let initialAvailability = await store.rootScopeAvailability(rootScope)
            XCTAssertEqual(initialAvailability, .available)

            let closingWindow = try XCTUnwrap(windowX)
            WindowStatesManager.shared.unregisterWindowState(closingWindow)
            addedWindows.removeAll { $0 === closingWindow }
            windowX = nil
            await closingWindow.tearDown()

            var released = false
            for _ in 0 ..< 100 {
                let availability = await store.rootScopeAvailability(rootScope)
                if availability != .available {
                    released = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(released, "expected the graph admission lease to be released when its window closed")
        }

        func testGraphAdmissionFailsClosedWhenDeclaredRootIsMissing() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)
            let missingRoot = storageRoot.appendingPathComponent("missing-r5-repo", isDirectory: true)

            do {
                _ = try await callBoundedTool(
                    service: service,
                    tool: MCPGlobalToolName.bindContext,
                    arguments: [
                        "op": .string("bind"),
                        "working_dirs": .array([.string(repoRootTwo.path), .string(missingRoot.path)]),
                        "create_if_missing": .bool(true),
                        "_rawJSON": .bool(true)
                    ],
                    connectionID: connectionID
                )
                XCTFail("expected admission to fail closed when a declared root is missing on disk")
            } catch {
                // expected
            }

            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertEqual(windowX.workspaceManager.activeWorkspaceID, workspaceOne.id)
        }

        // MARK: - manage_workspaces switch open_in_new_window (graph-on)

        func testFlagOnSwitchInNewWindowKeepsActiveWorkspace() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let connectionID = await makeConnection(service)

            let value = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.manageWorkspaces,
                arguments: switchArguments(workspace: workspaceTwo, openInNewWindow: true),
                connectionID: connectionID
            )
            let response = try decode(ManageWorkspacesResponse.self, from: value)

            XCTAssertEqual(response.windowID, windowX.windowID)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertTrue(WindowStatesManager.shared.allWindows.first === windowX)

            try await assertGraphOnPostconditions(connectionID: connectionID)
        }

        func testFlagOnSwitchDoesNotArmWorkspaceSwitchConfirmation() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            windowX.workspaceManager.registerSwitchSessionProvider(fakeSessionProvider)
            let connectionID = await makeConnection(service)

            // On the pre-fix tree this call can be denied at confirmation and throw
            // "Workspace switch cancelled"; only the arming/cancellation evidence below matters.
            do {
                _ = try await callBoundedTool(
                    service: service,
                    tool: MCPGlobalToolName.manageWorkspaces,
                    arguments: switchArguments(workspace: workspaceTwo, openInNewWindow: true),
                    connectionID: connectionID,
                    approveConfirmation: false
                )
            } catch {
                // Denied confirmation surfaces as a thrown tool error pre-fix; fall through to assert.
            }

            XCTAssertFalse(pendingConfirmationLatch.observedNonNil)
            XCTAssertNil(windowX.workspaceManager.pendingSwitchConfirmation)
            XCTAssertEqual(fakeSessionProvider.cancelCount, 0)
        }

        func testFlagOnSwitchLeavesInstalledRunRunning() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let agentProvider = AgentModeWorkspaceSwitchSessionProvider(agentModeViewModel: windowX.agentModeViewModel)
            windowX.workspaceManager.registerSwitchSessionProvider(agentProvider)

            let tabID = try XCTUnwrap(workspaceOne.activeComposeTabID)
            let session = AgentTabSession(tabID: tabID)
            windowX.agentModeViewModel.test_installLiveSession(session)
            windowX.agentModeViewModel.setAgentRunActive(session, isActive: true)
            session.runState = .running
            var runStateChangeCount = 0
            session.onRunStateChanged = { _ in runStateChangeCount += 1 }

            let connectionID = await makeConnection(service)
            _ = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.manageWorkspaces,
                arguments: switchArguments(workspace: workspaceTwo, openInNewWindow: true),
                connectionID: connectionID,
                // Pre-fix code can reach a real confirmation; approve it so a pre-fix run reaches
                // the real AgentModeViewModel.cancelAgentRun path instead of hanging on approval.
                approveConfirmation: true
            )

            XCTAssertEqual(session.runState, .running)
            XCTAssertEqual(runStateChangeCount, 0)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
        }

        // MARK: - manage_workspaces / bind_context create (graph-on)

        func testFlagOnCreateInNewWindowKeepsActiveWorkspace() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let repoRootThree = try makeRepoRoot(named: "r3-repo", sentinel: "only-r3.txt", sentinelContent: "r3-only", sameContent: "r3-same")
            let connectionID = await makeConnection(service)

            let value = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.manageWorkspaces,
                arguments: [
                    "action": .string("create"),
                    "name": .string("OG06 W3"),
                    "folder_path": .string(repoRootThree.path),
                    "open_in_new_window": .bool(true),
                    "_rawJSON": .bool(true)
                ],
                connectionID: connectionID
            )
            let response = try decode(ManageWorkspacesResponse.self, from: value)

            XCTAssertEqual(response.windowID, windowX.windowID)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)

            try await assertGraphOnPostconditions(
                connectionID: connectionID,
                expectedRoot: repoRootThree,
                unexpectedRoot: repoRootOne
            )
        }

        func testFlagOnWorkingDirsCreateIfMissingKeepsActiveWorkspace() async throws {
            let service = makeRoutingService(graphEnabled: true)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: true)
            let repoRootThree = try makeRepoRoot(named: "r3b-repo", sentinel: "only-r3.txt", sentinelContent: "r3-only", sameContent: "r3-same")
            let connectionID = await makeConnection(service)

            let value = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.bindContext,
                arguments: [
                    "op": .string("bind"),
                    "working_dirs": .array([.string(repoRootThree.path)]),
                    "create_if_missing": .bool(true),
                    "_rawJSON": .bool(true)
                ],
                connectionID: connectionID
            )
            let response = try decode(BindContextResponse.self, from: value)

            XCTAssertEqual(response.binding.windowID, windowX.windowID)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)

            try await assertGraphOnPostconditions(
                connectionID: connectionID,
                expectedRoot: repoRootThree,
                unexpectedRoot: repoRootOne
            )
        }

        // MARK: - flag off controls

        func testFlagOffWorkingDirsStayActiveWorkspaceOnly() async {
            // Y is a second window, active on W2, so the production collector must resolve each
            // repo root to only the window actively displaying it — never X's stored W2.
            let windowY = WindowState(domainRuntime: runtime)
            addedWindows.append(windowY)
            WindowStatesManager.shared.registerWindowState(windowY)
            await windowY.workspaceManager.awaitInitialized()
            let ySwitch = await windowY.workspaceManager.requestWorkspaceSwitch(to: workspaceTwo, saveState: false)
            XCTAssertTrue(ySwitch.didSwitch, ySwitch.message ?? "setup: Y activation failed")

            let windows = WindowStatesManager.shared.allWindows

            let matchesForR2 = await ServerNetworkManager.test_collectWorkingDirectoryMatches(
                workingDirs: [repoRootTwo.path],
                windows: windows,
                admitsStoredGraphWorkspaces: false
            )
            XCTAssertEqual(matchesForR2.map(\.windowID), [windowY.windowID])
            XCTAssertEqual(matchesForR2.map(\.workspaceID), [workspaceTwo.id])

            let matchesForR1 = await ServerNetworkManager.test_collectWorkingDirectoryMatches(
                workingDirs: [repoRootOne.path],
                windows: windows,
                admitsStoredGraphWorkspaces: false
            )
            XCTAssertEqual(matchesForR1.map(\.windowID), [windowX.windowID])
            XCTAssertEqual(matchesForR1.map(\.workspaceID), [workspaceOne.id])
        }

        /// One-window flag-off negative: X is active on W1 and holds W2 only as a stored (inactive)
        /// tab. With the flag off, the collector must never surface a stored inactive workspace —
        /// only the two-window case above exercises the flag-off branch directly.
        func testFlagOffWorkingDirsDoesNotCollectStoredInactiveWorkspace() async {
            let matchesForR2 = await ServerNetworkManager.test_collectWorkingDirectoryMatches(
                workingDirs: [repoRootTwo.path],
                windows: [windowX],
                admitsStoredGraphWorkspaces: false
            )
            XCTAssertTrue(matchesForR2.isEmpty)
        }

        func testFlagOffSwitchInNewWindowStillOpensASecondWindow() async throws {
            let service = makeRoutingService(graphEnabled: false)
            ServerNetworkManager.shared.graphPolicy = policy(graphEnabled: false)
            installProductionOpener()
            let connectionID = await makeConnection(service)

            let value = try await callBoundedTool(
                service: service,
                tool: MCPGlobalToolName.manageWorkspaces,
                arguments: switchArguments(workspace: workspaceTwo, openInNewWindow: true),
                connectionID: connectionID
            )
            let response = try decode(ManageWorkspacesResponse.self, from: value)

            let openedWindowID = try XCTUnwrap(response.windowID)
            XCTAssertNotEqual(openedWindowID, windowX.windowID)
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 2)
            XCTAssertEqual(windowX.workspaceManager.activeWorkspaceID, workspaceOne.id)
            let opened = try XCTUnwrap(WindowStatesManager.shared.allWindows.first { $0.windowID == openedWindowID })
            XCTAssertEqual(opened.workspaceManager.activeWorkspaceID, workspaceTwo.id)
        }

        // MARK: - workflow prompt

        func testWorkflowPromptMatchesFlag() {
            let block = RepoPromptWorkflowPrompts.workspaceVerificationBlock(variant: .mcp)

            XCTAssertTrue(
                block.localizedCaseInsensitiveContains("orchestration graph"),
                "graph-on guidance marker missing: \(block)"
            )
            XCTAssertTrue(
                block.contains("do not open another main window") || block.localizedCaseInsensitiveContains("existing graph window"),
                "graph-on 'bind the existing window' guidance missing: \(block)"
            )
            XCTAssertTrue(
                block.contains("open_in_new_window:true") || block.contains("open_in_new_window\":true"),
                "graph-off 'open a new window' guidance missing: \(block)"
            )

            XCTAssertEqual(RepoPromptWorkflowPrompts.workspaceVerificationBlock(variant: .agent), "")
        }

        // MARK: - Postcondition helper (§ 5)

        /// Asserts every graph-on postcondition named in design.md § 5 after a graph-on tool call:
        /// root authority through the bound connection (with and without `_windowID`), the response
        /// window equals X, one window total, W1 (or the pre-call active workspace) stays active, the
        /// switch-confirmation latch never armed, and the fake provider never cancelled.
        private func assertGraphOnPostconditions(
            connectionID: UUID,
            expectedRoot: URL? = nil,
            unexpectedRoot: URL? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let expected = expectedRoot ?? repoRootTwo!
            let unexpected = unexpectedRoot ?? repoRootOne!

            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1, file: file, line: line)
            XCTAssertEqual(windowX.workspaceManager.activeWorkspaceID, workspaceOne.id, file: file, line: line)
            XCTAssertFalse(pendingConfirmationLatch.observedNonNil, file: file, line: line)
            XCTAssertNil(windowX.workspaceManager.pendingSwitchConfirmation, file: file, line: line)

            try await assertRootAuthority(
                connectionID: connectionID,
                expectedRoot: expected,
                unexpectedRoot: unexpected,
                file: file,
                line: line
            )
        }

        private func assertRootAuthority(
            connectionID: UUID,
            expectedRoot: URL,
            unexpectedRoot: URL,
            file: StaticString,
            line: UInt
        ) async throws {
            let expectedPath = (expectedRoot.path as NSString).standardizingPath
            let unexpectedPath = (unexpectedRoot.path as NSString).standardizingPath

            // (a) via the connection's normal (sticky) binding — no `_windowID` hint.
            let boundMetadata = MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: nil,
                windowID: nil,
                runPurpose: nil,
                tabContextHint: nil,
                explicitWindowRoutingHint: nil
            )
            let boundContext = await windowX.mcpServer.resolveFileToolLookupContext(from: boundMetadata)
            await assertRootScope(
                boundContext.rootScope,
                expectedPath: expectedPath,
                unexpectedPath: unexpectedPath,
                context: "bound connection",
                file: file,
                line: line
            )

            // (b) via `_windowID` with no `context_id`/`_tabID` — the extracted § 3.3 item 4
            // production pre-resolution decision, through the same DEBUG entry `tools/call` uses.
            let probe = await ServerNetworkManager.shared.test_resolveLogicalContextPreResolutionAndDispatchFileTool(
                connectionID: connectionID,
                extractedWindowID: windowX.windowID
            )
            XCTAssertNil(probe.errorResult, file: file, line: line)
            let probeContext = try XCTUnwrap(probe.lookupContext, "no lookup context resolved for _windowID probe", file: file, line: line)
            await assertRootScope(
                probeContext.rootScope,
                expectedPath: expectedPath,
                unexpectedPath: unexpectedPath,
                context: "_windowID probe",
                file: file,
                line: line
            )
        }

        private func assertRootScope(
            _ scope: WorkspaceLookupRootScope,
            expectedPath: String,
            unexpectedPath: String,
            context: String,
            file: StaticString,
            line: UInt
        ) async {
            let refs = await windowX.workspaceFileContextStore.rootRefs(scope: scope)
            let paths = Set(refs.map(\.standardizedFullPath))
            XCTAssertTrue(
                paths.contains(expectedPath),
                "\(context): expected root \(expectedPath) not in scoped roots \(paths)",
                file: file,
                line: line
            )
            XCTAssertFalse(
                paths.contains(unexpectedPath),
                "\(context): unexpected root \(unexpectedPath) leaked into scoped roots \(paths)",
                file: file,
                line: line
            )
        }

        // MARK: - Bounded call helper

        private enum BoundedCallError: Error, CustomStringConvertible {
            case timedOut(phase: WorkspaceSwitchPhase?, confirmationArmed: Bool)
            case noResult

            var description: String {
                switch self {
                case let .timedOut(phase, confirmationArmed):
                    "callBoundedTool timed out: phase=\(String(describing: phase)) confirmationArmed=\(confirmationArmed)"
                case .noResult:
                    "callBoundedTool received no result"
                }
            }
        }

        private actor CallOutcomeBox {
            private var outcome: Result<Value, Error>?

            func set(_ value: Result<Value, Error>) {
                guard outcome == nil else { return }
                outcome = value
            }

            func get() -> Result<Value, Error>? {
                outcome
            }
        }

        /// Runs a `WindowRoutingService.call` that could enter workspace-switch confirmation under a
        /// real 30s deadline, as two unstructured tasks polled from this function rather than a
        /// throwing task group: a group's implicit scope-exit wait for cancelled children would hang
        /// on a cancellation-insensitive `service.call`, exactly the regression this bound exists to
        /// diagnose. A concurrent watcher latches whether `pendingSwitchConfirmation` was ever non-nil
        /// and resolves any confirmation immediately (deny by default; `approveConfirmation` lets a
        /// pre-fix run reach the real cancellation path instead of hanging on approval). On timeout the
        /// call task is cancelled and abandoned — never awaited — any still-armed confirmation is
        /// denied, and the helper fails naming phase/confirmation state rather than hanging.
        private func callBoundedTool(
            service: WindowRoutingService,
            tool: String,
            arguments: [String: Value],
            connectionID: UUID,
            approveConfirmation: Bool = false,
            timeout: Duration = .seconds(30)
        ) async throws -> Value {
            let manager = windowX.workspaceManager
            let latch = pendingConfirmationLatch!
            let box = CallOutcomeBox()

            let callTask = Task {
                do {
                    let value = try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                        guard let value = try await service.call(tool: tool, with: arguments) else {
                            throw BoundedCallError.noResult
                        }
                        return value
                    }
                    await box.set(.success(value))
                } catch {
                    await box.set(.failure(error))
                }
            }
            let watcherTask = Task { @MainActor in
                while !Task.isCancelled {
                    if let confirmation = manager.pendingSwitchConfirmation {
                        latch.observedNonNil = true
                        manager.resolveSwitchConfirmation(id: confirmation.id, allow: approveConfirmation)
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            defer { watcherTask.cancel() }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if let outcome = await box.get() {
                    return try outcome.get()
                }
                try? await Task.sleep(for: .milliseconds(10))
            }

            // Timed out: cancel the call task but do not await it — a cancellation-insensitive
            // `service.call` must not be able to wedge this helper.
            callTask.cancel()
            if let confirmation = manager.pendingSwitchConfirmation {
                latch.observedNonNil = true
                manager.resolveSwitchConfirmation(id: confirmation.id, allow: approveConfirmation)
            }
            try? await Task.sleep(for: .milliseconds(200))
            throw BoundedCallError.timedOut(
                phase: switchPhaseEvents.last,
                confirmationArmed: manager.pendingSwitchConfirmation != nil
            )
        }

        // MARK: - Helpers

        private func makeConnection(_ service: WindowRoutingService) async -> UUID {
            await service.prepareDomainTools()
            let connectionID = UUID()
            connectionIDs.append(connectionID)
            return connectionID
        }

        private func switchArguments(workspace: WorkspaceModel, openInNewWindow: Bool) -> [String: Value] {
            [
                "action": .string("switch"),
                "workspace": .string(workspace.id.uuidString),
                "open_in_new_window": .bool(openInNewWindow),
                "_rawJSON": .bool(true)
            ]
        }

        private func decode<T: Decodable>(_ type: T.Type, from value: Value) throws -> T {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(T.self, from: data)
        }

        private func makeWorkspace(name: String, repoRoot: URL, lastUsed: Date) -> WorkspaceModel {
            let id = UUID()
            let directory = storageRoot.appendingPathComponent(
                DomainWorkspaceStoragePath.directoryName(name: name, id: id),
                isDirectory: true
            )
            return WorkspaceModel(
                id: id,
                dateModified: lastUsed,
                name: name,
                repoPaths: [repoRoot.path],
                lastUsed: lastUsed,
                customStoragePath: directory
            )
        }

        private func makeRepoRoot(
            named name: String,
            sentinel: String,
            sentinelContent: String,
            sameContent: String
        ) throws -> URL {
            let root = storageRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try sentinelContent.write(to: root.appendingPathComponent(sentinel), atomically: true, encoding: .utf8)
            try sameContent.write(to: root.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            return root
        }

        private func policy(graphEnabled: Bool) -> OrchestrationGraphWindowPolicy {
            OrchestrationGraphWindowPolicy(isGraphEnabled: { graphEnabled })
        }

        private func makeRoutingService(graphEnabled: Bool) -> WindowRoutingService {
            let service = WindowRoutingService(
                windowStates: WindowStatesManager.shared,
                networkMgr: ServerNetworkManager.shared
            )
            service.policy = policy(graphEnabled: graphEnabled)
            return service
        }

        private func installProductionOpener(onOpen: (() -> Void)? = nil) {
            AppWindowOpener.shared.install(openMainWindow: { [weak self] in
                onOpen?()
                guard let self else { return }
                let window = WindowState(domainRuntime: runtime)
                addedWindows.append(window)
                WindowStatesManager.shared.registerWindowState(window)
            })
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

    @MainActor
    private final class PendingConfirmationLatch {
        var observedNonNil = false
    }

    @MainActor
    private final class CountingWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
        private(set) var cancelCount = 0

        func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
            [WorkspaceSwitchSessionItem(
                id: "og06-admission-fake",
                count: 1,
                singularLabel: "active session",
                pluralLabel: "active sessions"
            )]
        }

        func cancelSwitchSessions() async {
            cancelCount += 1
        }
    }
#endif
