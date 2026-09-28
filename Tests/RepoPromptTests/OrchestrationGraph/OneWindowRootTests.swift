import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    @MainActor
    final class OneWindowRootTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var originalMCPAutoStart = false
        private var originalFileSystemFlags = (repo: true, cursor: true, symlinks: true, hierarchical: true)
        private var originalGraphPolicy = OrchestrationGraphWindowPolicy.production
        private var originalOpenerPolicy = OrchestrationGraphWindowPolicy.production
        private var originalStoragePath: String?
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var window: WindowState!
        private var workspaceOne: WorkspaceModel!
        private var workspaceTwo: WorkspaceModel!
        private var rootPath: String!
        private var connectionIDs: [UUID] = []
        private var sessionRootOwnerIDs: [UUID] = []
        private var openerCount = 0
        private var runStateChangeCount = 0
        private var liveFSEventBaseline = 0

        override func setUp() async throws {
            try await super.setUp()
            liveFSEventBaseline = FileSystemService.liveFSEventStreamCountForTesting()
            originalWindows = WindowStatesManager.shared.allWindows
            originalMCPAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            let settings = GlobalSettingsStore.shared
            originalFileSystemFlags = (settings.respectRepoIgnore(), settings.respectCursorignore(), settings.skipSymlinks(), settings.enableHierarchicalIgnores())
            setFileSystemFlags(repo: true, cursor: true, symlinks: true, hierarchical: true)
            originalGraphPolicy = ServerNetworkManager.shared.graphPolicy
            originalOpenerPolicy = AppWindowOpener.shared.policy
            originalStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            WindowStatesManager.shared.allWindows = []
            AppWindowOpener.shared.resetForTesting()
            await ServerNetworkManager.shared.debugClearPersistedRoutingState()

            storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("OneWindowRootTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
            let agentRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatRoot)
            rootPath = storageRoot.appendingPathComponent("shared-repo", isDirectory: true).path
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            workspaceOne = try makeWorkspace("OW Root W1", ordinal: 1)
            workspaceTwo = try makeWorkspace("OW Root W2", ordinal: 2)
            try writeWorkspace(workspaceOne)
            try writeWorkspace(workspaceTwo)
            let index = [workspaceOne, workspaceTwo].map {
                WorkspaceIndexEntry(id: $0.id, name: $0.name, customStoragePath: $0.customStoragePath, isSystemWorkspace: $0.isSystemWorkspace, isHiddenInMenus: $0.isHiddenInMenus)
            }
            try JSONEncoder().encode(index).write(to: storageRoot.appendingPathComponent("workspacesIndex.json"), options: .atomic)
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "one-window-roots-\(UUID().uuidString)",
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
            workspaceOne = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
            workspaceTwo = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == workspaceTwo.id })
        }

        override func tearDown() async throws {
            if let window {
                for ownerID in sessionRootOwnerIDs {
                    await window.workspaceFileContextStore.releaseSessionWorktreeOwnership(ownerID: ownerID)
                }
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
            if let runtime { _ = await runtime.shutdown() }
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
            GlobalSettingsStore.shared.setMCPAutoStart(originalMCPAutoStart, commit: false)
            setFileSystemFlags(
                repo: originalFileSystemFlags.repo,
                cursor: originalFileSystemFlags.cursor,
                symlinks: originalFileSystemFlags.symlinks,
                hierarchical: originalFileSystemFlags.hierarchical
            )
            await awaitFileSystemFlags(originalFileSystemFlags)
            if let originalStoragePath {
                UserDefaults.standard.set(originalStoragePath, forKey: "GlobalCustomStorageURL")
            } else {
                UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
            }
            try await super.tearDown()
            FileSystemService.drainQueuedFSEventTeardownsForTesting()
            let live = FileSystemService.liveFSEventStreamCountForTesting()
            XCTAssertEqual(live, liveFSEventBaseline, "\(name): FSEvents baseline=\(liveFSEventBaseline) live=\(live) delta=\(live - liveFSEventBaseline)")
        }

        private func makeWorkspace(_ name: String, ordinal: Int) throws -> WorkspaceModel {
            let id = UUID()
            return WorkspaceModel(
                id: id, dateModified: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                name: name, repoPaths: [rootPath], lastUsed: Date(timeIntervalSince1970: TimeInterval(ordinal)),
                customStoragePath: storageRoot.appendingPathComponent(DomainWorkspaceStoragePath.directoryName(name: name, id: id), isDirectory: true)
            )
        }

        private func writeWorkspace(_ workspace: WorkspaceModel) throws {
            let directory = try XCTUnwrap(workspace.customStoragePath)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(workspace).write(to: directory.appendingPathComponent("workspace.json"), options: .atomic)
        }

        private func setFileSystemFlags(repo: Bool, cursor: Bool, symlinks: Bool, hierarchical: Bool) {
            let settings = GlobalSettingsStore.shared
            settings.setRespectRepoIgnore(repo, commit: false)
            settings.setRespectCursorignore(cursor, commit: false)
            settings.setSkipSymlinks(symlinks, commit: false)
            settings.setEnableHierarchicalIgnores(hierarchical, commit: false)
            settings.postFileSystemPreferencesDidChange(key: "file_system.respect_repo_ignore")
        }

        private func awaitRepoIgnore(_ expected: Bool) async {
            for _ in 0 ..< 1000 where window?.workspaceManager.fileManager.respectRepoIgnore != expected {
                await Task.yield()
            }
            XCTAssertEqual(window?.workspaceManager.fileManager.respectRepoIgnore, expected)
        }

        private func awaitFileSystemFlags(_ expected: (repo: Bool, cursor: Bool, symlinks: Bool, hierarchical: Bool)) async {
            for _ in 0 ..< 1000 {
                let fileManager = window?.workspaceManager.fileManager
                if fileManager?.respectRepoIgnore == expected.repo,
                   fileManager?.respectCursorignore == expected.cursor,
                   fileManager?.skipSymlinks == expected.symlinks,
                   fileManager?.enableHierarchicalIgnores == expected.hierarchical
                {
                    break
                }
                await Task.yield()
            }
            let fileManager = window?.workspaceManager.fileManager
            XCTAssertEqual(fileManager?.respectRepoIgnore, expected.repo)
            XCTAssertEqual(fileManager?.respectCursorignore, expected.cursor)
            XCTAssertEqual(fileManager?.skipSymlinks, expected.symlinks)
            XCTAssertEqual(fileManager?.enableHierarchicalIgnores, expected.hierarchical)
        }

        private func focusWorkspaceOne() async {
            let switched = await window.workspaceManager.requestWorkspaceSwitch(to: workspaceOne, saveState: false)
            XCTAssertEqual(window.workspaceManager.activeWorkspace?.id, workspaceOne.id, switched.message ?? "setup switch failed")
        }

        private func extraRoot(_ name: String) throws -> String {
            let path = storageRoot.appendingPathComponent(name, isDirectory: true).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
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

        private func bindValue(service: WindowRoutingService, connectionID: UUID, workspace: String) async throws -> Value {
            try await ServerNetworkManager.$currentConnectionID.withValue(connectionID) {
                guard let raw = try await service.call(
                    tool: MCPGlobalToolName.bindContext,
                    with: ["op": .string("bind"), "workspace": .string(workspace), "_rawJSON": .bool(true)]
                ) else { throw URLError(.badServerResponse) }
                return raw
            }
        }

        private func bind(service: WindowRoutingService, connectionID: UUID, workspace: String) async throws -> BindContextResponse {
            let value = try await bindValue(service: service, connectionID: connectionID, workspace: workspace)
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(BindContextResponse.self, from: data)
        }

        private func renderedBind(_ value: Value) -> String {
            ToolOutputFormatter.formatBindContext(args: ["op": .string("bind")], value: value)
                .map(String.init(describing:)).joined(separator: "\n")
        }

        private func installLiveSession() throws -> (AgentTabSession, CountingWorkspaceSwitchSessionProvider) {
            let provider = CountingWorkspaceSwitchSessionProvider()
            window.workspaceManager.registerSwitchSessionProvider(provider)
            let resolved = try XCTUnwrap(window.workspaceManager.workspaces.first { $0.id == workspaceOne.id })
            let tabID = try XCTUnwrap(resolved.activeComposeTabID)
            let session = AgentTabSession(tabID: tabID)
            window.agentModeViewModel.test_installLiveSession(session)
            window.agentModeViewModel.setAgentRunActive(session, isActive: true)
            session.runState = .running
            runStateChangeCount = 0
            session.onRunStateChanged = { [weak self] _ in self?.runStateChangeCount += 1 }
            return (session, provider)
        }

        func testSameIgnorePolicySharesOneRoot() async throws {
            await focusWorkspaceOne()
            for graphEnabled in [true, false] {
                let service = configure(graphEnabled: graphEnabled)
                let connectionA = await connection(for: service)
                let connectionB = await connection(for: service)
                let (session, provider) = try installLiveSession()
                let beforeRoots = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                let rootBefore = try XCTUnwrap(beforeRoots.first)
                let responseA = try await bind(service: service, connectionID: connectionA, workspace: workspaceOne.name)
                let responseB = try await bind(service: service, connectionID: connectionB, workspace: workspaceTwo.name)
                let roots = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                XCTAssertEqual(roots.count, 1)
                XCTAssertEqual(roots.first?.id, rootBefore.id)
                XCTAssertNotEqual(roots.first?.kind, .sessionWorktree)
                XCTAssertEqual(responseA.binding.workspaceID, workspaceOne.id)
                XCTAssertEqual(responseB.binding.workspaceID, workspaceTwo.id)
                XCTAssertEqual(responseA.binding.repoPaths, [rootPath])
                XCTAssertEqual(responseB.binding.repoPaths, [rootPath])
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(runStateChangeCount, 0)
                XCTAssertEqual(session.runState, .running)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            }
        }

        func testDifferentIgnorePolicyFailsTheBind() async throws {
            for graphEnabled in [true, false] {
                let service = configure(graphEnabled: graphEnabled)
                let connectionA = await connection(for: service)
                let connectionB = await connection(for: service)
                _ = try await bind(service: service, connectionID: connectionA, workspace: workspaceOne.name)
                await focusWorkspaceOne()
                let prior = try await bind(service: service, connectionID: connectionB, workspace: workspaceOne.name)
                let (session, provider) = try installLiveSession()
                let rootsBefore = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                let rootBefore = try XCTUnwrap(rootsBefore.first)
                GlobalSettingsStore.shared.setRespectRepoIgnore(false, commit: false)
                GlobalSettingsStore.shared.postFileSystemPreferencesDidChange(key: "file_system.respect_repo_ignore")
                await awaitRepoIgnore(false)
                do {
                    _ = try await window.workspaceFileContextStore.loadRoot(
                        path: rootPath,
                        kind: .primaryWorkspace,
                        respectRepoIgnore: false
                    )
                    XCTFail("expected store policy conflict")
                } catch let WorkspaceFileContextStoreError.rootAlreadyLoadedWithDifferentConfiguration(conflict) {
                    XCTAssertEqual(conflict.path, rootPath)
                    XCTAssertEqual(conflict.holder, .workspace)
                    XCTAssertEqual(conflict.loadedPolicy.respectRepoIgnore, true)
                    XCTAssertEqual(conflict.requestedPolicy.respectRepoIgnore, false)
                }
                let value = try await bindValue(service: service, connectionID: connectionB, workspace: workspaceTwo.name)
                let response = try JSONDecoder().decode(BindContextResponse.self, from: JSONEncoder().encode(value))
                let body = try XCTUnwrap(value.objectValue)
                let conflict = try XCTUnwrap(body["conflict"]?.objectValue)
                XCTAssertEqual(body["status"]?.stringValue, "conflict")
                let rawJSON = try XCTUnwrap(String(data: JSONEncoder().encode(value), encoding: .utf8))
                XCTAssertTrue(rawJSON.replacingOccurrences(of: "\":\"", with: "\": \"").contains(#""status": "conflict""#))
                XCTAssertEqual(response.conflict?.path, rootPath)
                XCTAssertEqual(response.conflict?.holder, "workspace")
                XCTAssertEqual(conflict["path"]?.stringValue, rootPath)
                XCTAssertEqual(conflict["holder"]?.stringValue, "workspace")
                XCTAssertEqual(conflict["loadedPolicy"]?.objectValue?["respectRepoIgnore"]?.boolValue, true)
                XCTAssertEqual(conflict["requestedPolicy"]?.objectValue?["respectRepoIgnore"]?.boolValue, false)
                for key in ["respectCursorignore", "skipSymlinks", "enableHierarchicalIgnores"] {
                    XCTAssertEqual(conflict["loadedPolicy"]?.objectValue?[key]?.boolValue, true)
                    XCTAssertEqual(conflict["requestedPolicy"]?.objectValue?[key]?.boolValue, true)
                }
                XCTAssertEqual(response.binding.workspaceID, prior.binding.workspaceID)
                XCTAssertEqual(response.binding.contextID, prior.binding.contextID)
                let rootsAfter = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                XCTAssertEqual(rootsAfter.first?.id, rootBefore.id)
                let formattedValue = try await ServerNetworkManager.$currentConnectionID.withValue(connectionB) {
                    guard let output = try await service.call(
                        tool: MCPGlobalToolName.bindContext,
                        with: ["op": .string("bind"), "workspace": .string(workspaceTwo.name)]
                    ) else { throw URLError(.badServerResponse) }
                    return output
                }
                let formatted = renderedBind(formattedValue)
                XCTAssertTrue(formatted.contains(rootPath))
                XCTAssertTrue(formatted.contains("workspace"))
                XCTAssertTrue(formatted.contains("respectRepoIgnore"))
                XCTAssertTrue(formatted.contains("true"))
                XCTAssertTrue(formatted.contains("false"))
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(runStateChangeCount, 0)
                XCTAssertEqual(session.runState, .running)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                GlobalSettingsStore.shared.setRespectRepoIgnore(true, commit: false)
                GlobalSettingsStore.shared.postFileSystemPreferencesDidChange(key: "file_system.respect_repo_ignore")
                await awaitRepoIgnore(true)
            }
        }

        func testMatchingPolicyAfterConflictResolvesThePath() async throws {
            for graphEnabled in [true, false] {
                let service = configure(graphEnabled: graphEnabled)
                let connectionA = await connection(for: service)
                let connectionB = await connection(for: service)
                _ = try await bind(service: service, connectionID: connectionA, workspace: workspaceOne.name)
                await focusWorkspaceOne()
                let (session, provider) = try installLiveSession()
                let originalRoots = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                let originalRoot = try XCTUnwrap(originalRoots.first)
                GlobalSettingsStore.shared.setRespectRepoIgnore(false, commit: false)
                GlobalSettingsStore.shared.postFileSystemPreferencesDidChange(key: "file_system.respect_repo_ignore")
                await awaitRepoIgnore(false)
                let conflict = try await bindValue(service: service, connectionID: connectionB, workspace: workspaceTwo.name)
                XCTAssertEqual(conflict.objectValue?["status"]?.stringValue, "conflict")
                GlobalSettingsStore.shared.setRespectRepoIgnore(true, commit: false)
                GlobalSettingsStore.shared.postFileSystemPreferencesDidChange(key: "file_system.respect_repo_ignore")
                await awaitRepoIgnore(true)
                let resolved = try await bind(service: service, connectionID: connectionB, workspace: workspaceTwo.name)
                XCTAssertEqual(resolved.binding.workspaceID, workspaceTwo.id)
                let rootsAfter = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                XCTAssertEqual(rootsAfter.first?.id, originalRoot.id)
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(runStateChangeCount, 0)
                XCTAssertEqual(session.runState, .running)
            }
        }

        func testSessionWorktreeHeldPathFailsTheBind() async throws {
            for graphEnabled in [true, false] {
                let service = configure(graphEnabled: graphEnabled)
                let connectionB = await connection(for: service)
                let (session, provider) = try installLiveSession()
                let ownerID = UUID()
                session.testInstallPersistentSessionBinding(sessionID: ownerID)
                XCTAssertEqual(session.activeAgentSessionID, ownerID)
                sessionRootOwnerIDs.append(ownerID)
                let preparation = try await window.workspaceFileContextStore.prepareSessionWorktreeOwnership(
                    ownerID: ownerID,
                    bindingFingerprint: "one-window-root-session-\(ownerID)",
                    physicalRootPaths: [rootPath]
                )
                try await window.workspaceFileContextStore.commitSessionWorktreeOwnership(preparation)
                let rootsBefore = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                let rootBefore = try XCTUnwrap(rootsBefore.first)
                XCTAssertEqual(rootBefore.kind, .sessionWorktree)
                let value = try await bindValue(service: service, connectionID: connectionB, workspace: workspaceTwo.name)
                let response = try JSONDecoder().decode(BindContextResponse.self, from: JSONEncoder().encode(value))
                let conflict = try XCTUnwrap(value.objectValue?["conflict"]?.objectValue)
                XCTAssertEqual(value.objectValue?["status"]?.stringValue, "conflict")
                XCTAssertEqual(response.conflict?.path, rootPath)
                XCTAssertEqual(response.conflict?.holder, "session_worktree")
                XCTAssertEqual(conflict["path"]?.stringValue, rootPath)
                XCTAssertEqual(conflict["holder"]?.stringValue, "session_worktree")
                for key in ["respectRepoIgnore", "respectCursorignore", "skipSymlinks", "enableHierarchicalIgnores"] {
                    XCTAssertEqual(conflict["loadedPolicy"]?.objectValue?[key]?.boolValue, true)
                    XCTAssertEqual(conflict["requestedPolicy"]?.objectValue?[key]?.boolValue, true)
                }
                XCTAssertEqual(response.binding.bindingKind, "unbound")
                let rootsAfter = await window.workspaceFileContextStore.rootRecords(forRootFolderPaths: [rootPath])
                XCTAssertEqual(rootsAfter.first?.id, rootBefore.id)
                XCTAssertTrue(renderedBind(value).contains("session_worktree"))
                XCTAssertEqual(provider.cancelCount, 0)
                XCTAssertEqual(runStateChangeCount, 0)
                XCTAssertEqual(session.runState, .running)
                XCTAssertEqual(openerCount, 0)
                XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
                await window.workspaceFileContextStore.releaseSessionWorktreeOwnership(ownerID: ownerID)
                sessionRootOwnerIDs.removeAll { $0 == ownerID }
            }
        }

        func testGraphOnlyRootStaysOutsideVisibleWorkspaceUntilUIClaimsIt() async throws {
            await focusWorkspaceOne()
            let path = try extraRoot("w2-graph-only")
            let store = window.workspaceFileContextStore
            let focusedRoots = await store.rootRefs(scope: .visibleWorkspace)
            XCTAssertTrue(focusedRoots.contains { $0.fullPath == rootPath })
            let policy = WorkspaceRootIgnorePolicy(respectRepoIgnore: true, respectCursorignore: true, skipSymlinks: true, enableHierarchicalIgnores: true)
            let graph = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: workspaceTwo.id, physicalRootPaths: [path], policy: policy)
            let graphRoot = try XCTUnwrap(graph.roots.first)
            let loadedRoots = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertEqual(loadedRoots.first?.id, graphRoot.id)
            let graphOnlyVisibleRoots = await store.rootRefs(scope: .visibleWorkspace)
            XCTAssertFalse(graphOnlyVisibleRoots.contains { $0.id == graphRoot.id })
            let graphOnlyVisibleWithGitData = await store.rootRefs(scope: .visibleWorkspacePlusGitData)
            XCTAssertFalse(graphOnlyVisibleWithGitData.contains { $0.id == graphRoot.id })
            let graphOnlyGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)

            let uiRoot = try await store.loadRoot(path: path, kind: .primaryWorkspace)
            XCTAssertEqual(uiRoot.id, graphRoot.id)
            let uiVisibleRoots = await store.rootRefs(scope: .visibleWorkspace)
            XCTAssertTrue(uiVisibleRoots.contains { $0.id == graphRoot.id })
            let uiVisibleWithGitData = await store.rootRefs(scope: .visibleWorkspacePlusGitData)
            XCTAssertTrue(uiVisibleWithGitData.contains { $0.id == graphRoot.id })
            let uiGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
            XCTAssertNotEqual(uiGeneration, graphOnlyGeneration)

            await store.unloadRoot(id: uiRoot.id)
            let graphOnlyAgain = await store.rootRefs(scope: .visibleWorkspace)
            XCTAssertFalse(graphOnlyAgain.contains { $0.id == graphRoot.id })
            let graphOnlyAgainWithGitData = await store.rootRefs(scope: .visibleWorkspacePlusGitData)
            XCTAssertFalse(graphOnlyAgainWithGitData.contains { $0.id == graphRoot.id })
            let afterUIUnloadGeneration = await store.catalogGeneration(rootScope: .visibleWorkspace)
            XCTAssertNotEqual(afterUIUnloadGeneration, uiGeneration)
            let retainedRoots = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertEqual(retainedRoots.first?.id, graphRoot.id)
            await store.releaseOrdinaryWorkspaceRootAcquisition(token: graph.token)
            let afterRelease = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertTrue(afterRelease.isEmpty)
        }

        func testUIFirstGraphThenUIUnloadKeepsRoot() async throws {
            let path = try extraRoot("ui-first")
            let store = window.workspaceFileContextStore
            let uiRoot = try await store.loadRoot(path: path, kind: .primaryWorkspace)
            let policy = WorkspaceRootIgnorePolicy(respectRepoIgnore: true, respectCursorignore: true, skipSymlinks: true, enableHierarchicalIgnores: true)
            let graph = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: UUID(), physicalRootPaths: [path], policy: policy)
            XCTAssertEqual(graph.roots.first?.id, uiRoot.id)
            await store.unloadRoot(id: uiRoot.id)
            let whileGraphOwns = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertEqual(whileGraphOwns.first?.id, uiRoot.id)
            await store.releaseOrdinaryWorkspaceRootAcquisition(token: graph.token)
            let afterRelease = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertTrue(afterRelease.isEmpty)
        }

        func testGraphFirstUIThenDisconnectKeepsRoot() async throws {
            let path = try extraRoot("graph-first")
            let store = window.workspaceFileContextStore
            let policy = WorkspaceRootIgnorePolicy(respectRepoIgnore: true, respectCursorignore: true, skipSymlinks: true, enableHierarchicalIgnores: true)
            let graph = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: UUID(), physicalRootPaths: [path], policy: policy)
            let uiRoot = try await store.loadRoot(path: path, kind: .primaryWorkspace)
            XCTAssertEqual(graph.roots.first?.id, uiRoot.id)
            await store.releaseOrdinaryWorkspaceRootAcquisition(token: graph.token)
            let whileUIOwns = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertEqual(whileUIOwns.first?.id, uiRoot.id)
            await store.unloadRoot(id: uiRoot.id)
            let afterUnload = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertTrue(afterUnload.isEmpty)
        }

        func testSameAndDifferentOwnerReplacementRetainsRoot() async throws {
            let path = try extraRoot("replacement")
            let store = window.workspaceFileContextStore
            let policy = WorkspaceRootIgnorePolicy(respectRepoIgnore: true, respectCursorignore: true, skipSymlinks: true, enableHierarchicalIgnores: true)
            let ownerA = UUID()
            let first = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: ownerA, physicalRootPaths: [path], policy: policy)
            let replacement = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: ownerA, physicalRootPaths: [path], policy: policy)
            let other = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: UUID(), physicalRootPaths: [path], policy: policy)
            XCTAssertEqual(first.roots.first?.id, replacement.roots.first?.id)
            XCTAssertEqual(first.roots.first?.id, other.roots.first?.id)
            await store.releaseOrdinaryWorkspaceRootAcquisition(token: first.token)
            await store.releaseOrdinaryWorkspaceRootAcquisition(token: replacement.token)
            let whileOtherOwns = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertEqual(whileOtherOwns.first?.id, other.roots.first?.id)
            await store.releaseOrdinaryWorkspaceRootAcquisition(token: other.token)
            let afterRelease = await store.rootRecords(forRootFolderPaths: [path])
            XCTAssertTrue(afterRelease.isEmpty)
        }

        func testPartialOrdinaryPreparationRollsBack() async throws {
            let availablePath = try extraRoot("a-available")
            let heldPath = try extraRoot("z-held")
            let store = window.workspaceFileContextStore
            let ownerID = UUID()
            sessionRootOwnerIDs.append(ownerID)
            let held = try await store.prepareSessionWorktreeOwnership(
                ownerID: ownerID,
                bindingFingerprint: "partial-rollback-\(ownerID)",
                physicalRootPaths: [heldPath]
            )
            try await store.commitSessionWorktreeOwnership(held)
            let heldRoots = await store.rootRecords(forRootFolderPaths: [heldPath])
            let heldRoot = try XCTUnwrap(heldRoots.first)
            let policy = WorkspaceRootIgnorePolicy(respectRepoIgnore: true, respectCursorignore: true, skipSymlinks: true, enableHierarchicalIgnores: true)
            do {
                _ = try await store.prepareOrdinaryWorkspaceRootAcquisition(ownerID: UUID(), physicalRootPaths: [availablePath, heldPath], policy: policy)
                XCTFail("expected the session-worktree holder to reject the second path")
            } catch let WorkspaceFileContextStoreError.rootAlreadyLoadedWithDifferentConfiguration(conflict) {
                XCTAssertEqual(conflict.path, heldPath)
                XCTAssertEqual(conflict.holder, .sessionWorktree)
            }
            let availableRoots = await store.rootRecords(forRootFolderPaths: [availablePath])
            let heldRootsAfter = await store.rootRecords(forRootFolderPaths: [heldPath])
            XCTAssertTrue(availableRoots.isEmpty)
            XCTAssertEqual(heldRootsAfter.first?.id, heldRoot.id)
        }

        private final class CountingWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
            private(set) var cancelCount = 0

            func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
                [WorkspaceSwitchSessionItem(
                    id: "one-window-root-session",
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
