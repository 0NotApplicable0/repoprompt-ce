import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptInstrumentation
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

@MainActor
final class AgentLifecycleExecutionContractTests: XCTestCase {
    func testAgentRunLifecycleWaitDefaultsAndExplicitOverrides() throws {
        let expected: TimeInterval = 120
        let captured = expected
        XCTAssertEqual(AgentRunMCPToolService.defaultWaitTimeoutSeconds, expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.null, capturedDefaultWaitSeconds: captured), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.int(0), capturedDefaultWaitSeconds: captured), 0)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30), capturedDefaultWaitSeconds: captured), 30)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.double(45.5), capturedDefaultWaitSeconds: captured), 45.5)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(7200), capturedDefaultWaitSeconds: captured), 7200)
    }

    func testAgentRunLifecycleWaitUsesInjectedCapturedDefault() throws {
        let capturedDefault: TimeInterval = 600
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil, capturedDefaultWaitSeconds: capturedDefault),
            capturedDefault
        )
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30), capturedDefaultWaitSeconds: capturedDefault), 30)
    }

    func testCapturedDefaultWaitTimeoutSecondsReadsConfiguredPreferenceOnce() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        XCTAssertEqual(AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store), 120)

        XCTAssertTrue(store.setSubagentDefaultWaitSeconds(1200))
        // Freeze the value an in-flight wait would have captured, then change the preference:
        // the wait must keep resolving against its capture, not the new setting.
        let frozenDefault = AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store)
        XCTAssertEqual(frozenDefault, 1200)

        XCTAssertTrue(store.setSubagentDefaultWaitSeconds(120))
        XCTAssertEqual(
            try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil, capturedDefaultWaitSeconds: frozenDefault),
            frozenDefault
        )
        XCTAssertEqual(AgentRunMCPToolService.capturedDefaultWaitTimeoutSeconds(from: store), 120)
    }

    func testCleanupSessionsRepliesAfterDelete() async throws {
        try await exerciseCleanupTransport(stalled: false, cancelRequest: false)
    }

    func testCleanupSessionsStalledTeardownIsBounded() async throws {
        for cancelRequest in [false, true] {
            try await exerciseCleanupTransport(stalled: true, cancelRequest: cancelRequest)
        }
    }

    private func exerciseCleanupTransport(stalled: Bool, cancelRequest: Bool) async throws {
        try await MCPSharedServerTestLease.shared.withLease { lease in
            let fixture = try await PersistentMCPTestFixture.make(
                lease: lease, domainRuntime: AppDomainRuntimeComposition.shared.runtime
            )
            let manager = fixture.networkManager
            let context = fixture.contextA
            let workspace = try XCTUnwrap(context.window.workspaceManager.workspaces.first { $0.id == context.workspaceID })
            await context.window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "cleanupTransport")
            context.window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
            try await fixture.registerDomainWorkspace(context)
            let endpoint = try fixture.endpointA()
            let clock = StartStallClock()
            let teardown = StartStallGate()
            let observation = CleanupTransportObservation()
            let recorder = CleanupExecutionTraceRecorder()
            var responseTask: Task<Void, Never>?
            let sessionID = UUID()
            let persisted = AgentSession(
                id: sessionID, workspaceID: workspace.id, name: "Cleanup transport",
                savedAt: Date(timeIntervalSinceReferenceDate: 42), itemCount: 0,
                agentKind: AgentProviderKind.codexExec.rawValue,
                lastRunState: AgentSessionRunState.completed.rawValue, autoEditEnabled: true,
                isMCPOriginated: true
            )
            let sessionURL = try await AgentSessionDataService.shared.saveAgentSession(
                persisted, for: workspace, preparation: .alreadyCanonicalTranscript, trustedCanonicalItemCount: 0
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: sessionURL.path))
            let live = AgentManageMCPToolService.CleanupDependencies.live
            let args: [String: Value] = [
                "op": .string("cleanup_sessions"), "session_ids": .array([.string(sessionID.uuidString)])
            ]
            let service = AgentManageMCPToolService(
                toolName: MCPWindowToolName.agentManage,
                captureRequestMetadata: { .init(connectionID: nil, clientName: "cleanup-transport", windowID: context.window.windowID) },
                requireTargetWindow: { context.window }, resolveSpawnSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil }, bindCurrentRequestToTab: { _, _ in },
                cleanupDependencies: .init(
                    loadPersistedMetadata: live.loadPersistedMetadata,
                    loadPersistedSession: { _, _ in nil },
                    deleteOpenSession: live.deleteOpenSession,
                    deletePersistedSession: live.deletePersistedSession,
                    finalizePersistedReferences: { viewModel, id, workspaceID in
                        await teardown.suspend()
                        return await live.finalizePersistedReferences(viewModel, id, workspaceID)
                    },
                    checkCancellation: live.checkCancellation
                )
            )
            MCPToolExecutionTracer.setTestSink { recorder.append($0) }
            await manager.debugSetToolExecutionWatchdogEnvironment(.init(
                now: { clock.now }, sleep: { try await clock.sleep(for: $0) }
            ))
            await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.agentManage) {
                do {
                    let value = try await service.execute(args: args)
                    await MainActor.run { observation.handlerFinished = true }
                    return value
                } catch {
                    await MainActor.run { observation.handlerFinished = true }
                    throw error
                }
            }
            await manager.debugSetDomainPeerIdentityForTesting(
                connectionID: endpoint.connectionID,
                identity: .verified(processID: Int(ProcessInfo.processInfo.processIdentifier), fingerprint: "test:cleanup-transport")
            )
            do {
                _ = try await endpoint.callTool(name: "bind_context", arguments: ["op": "bind", "context_id": context.tabID.uuidString])
                await context.window.mcpServer.domainRoutingPublishTask?.value
                let requestID = endpoint.client.nextRequestIDForTesting()
                let task = Task { @MainActor in
                    do {
                        let response = try await endpoint.callTool(
                            name: MCPWindowToolName.agentManage,
                            arguments: ["op": "cleanup_sessions", "session_ids": [sessionID.uuidString], "_rawJSON": true]
                        )
                        observation.response = .success(response)
                    } catch { observation.response = .failure(error) }
                }
                responseTask = task
                await drainCleanupScheduler(until: { teardown.hasEntered || observation.response != nil })
                XCTAssertTrue(teardown.hasEntered, "The real cleanup handler must reach post-delete reference teardown")
                XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path), "Deletion must be durable before teardown")
                XCTAssertNil(observation.response)
                await drainCleanupScheduler()
                XCTAssertGreaterThan(clock.sleeperCount, 0, "Dispatcher must arm a finite cleanup deadline")
                if stalled {
                    if cancelRequest {
                        try endpoint.client.sendNotification(method: "notifications/cancelled", params: ["requestId": requestID, "reason": "test stalled teardown"])
                        await drainCleanupScheduler(until: { clock.sleeperCount == 0 })
                        XCTAssertEqual(clock.sleeperCount, 0, "Request cancellation must retire the execution deadline")
                        XCTAssertNil(observation.response, "MCP cancellation suppresses the cancelled request's reply")
                        _ = try await endpoint.client.request(method: "tools/list", params: [:])
                        XCTAssertNil(observation.response, "The cancelled request must stay unanswered during a subsequent round trip")
                        task.cancel()
                    } else {
                        clock.advance(to: .seconds(60))
                        await drainCleanupScheduler()
                        clock.advance(to: .seconds(65))
                        await drainCleanupScheduler(until: { observation.response != nil })
                        XCTAssertNotNil(observation.response, "Stalled teardown must settle the transport within deadline plus cleanup grace")
                    }
                    XCTAssertFalse(teardown.isOpen, "Transport settlement must not require a non-cooperative teardown to return")
                } else {
                    clock.advance(to: .seconds(31))
                    await drainCleanupScheduler()
                    XCTAssertNil(observation.response, "The old ordinary-tool deadline must not lose the landed-delete receipt")
                }
                teardown.release()
                await task.value
                await drainCleanupScheduler(until: { observation.handlerFinished })
                XCTAssertTrue(observation.handlerFinished)
                if cancelRequest {
                    if case let .failure(error)? = observation.response {
                        XCTAssertTrue(error is CancellationError, "The client must abandon its own cancelled request, not time out")
                    } else {
                        XCTFail("Expected local cancellation of the client waiter, not a server response")
                    }
                } else {
                    let response = try XCTUnwrap(observation.response).get()
                    if !stalled {
                        XCTAssertFalse(response.rawJSON.contains("\"isError\":true"), response.rawJSON)
                        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.rawJSON.utf8)) as? [String: Any])
                        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
                        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
                        let text = content.compactMap { $0["text"] as? String }.joined()
                        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                        let deleted = try XCTUnwrap(payload["deleted_sessions"] as? [[String: Any]])
                        XCTAssertEqual(deleted.count, 1)
                        XCTAssertEqual(deleted.first?["session_id"] as? String, sessionID.uuidString)
                        XCTAssertEqual(deleted.first?["durable"] as? Bool, true)
                    }
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: sessionURL.path))
                let terminal = await manager.debugIsExecutionWatchdogTerminal(connectionID: endpoint.connectionID)
                XCTAssertFalse(terminal)
                let events = recorder.snapshot().filter { $0.connectionID == endpoint.connectionID && $0.toolName == MCPWindowToolName.agentManage }
                XCTAssertFalse(events.contains { $0.phase == .connectionForceDisconnectRequested })
                if stalled, !cancelRequest {
                    XCTAssertTrue(events.contains { $0.phase == .deadlineExpired })
                }
                if cancelRequest {
                    XCTAssertTrue(events.contains { $0.phase == .cancellationRequested && $0.cancellationOrigin == .requestCancellation })
                }
                _ = try await endpoint.client.request(method: "tools/list", params: [:])
            } catch {
                teardown.release()
                responseTask?.cancel()
                if let responseTask { await responseTask.value }
                await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.agentManage, operation: nil)
                await manager.debugResetToolExecutionWatchdogEnvironment()
                await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
                MCPToolExecutionTracer.setTestSink(nil)
                clock.cancelAll()
                await fixture.cleanup()
                throw error
            }
            await manager.debugSetResolvedToolOperationOverride(toolName: MCPWindowToolName.agentManage, operation: nil)
            await manager.debugResetToolExecutionWatchdogEnvironment()
            await manager.debugSetDomainPeerIdentityForTesting(connectionID: endpoint.connectionID, identity: nil)
            MCPToolExecutionTracer.setTestSink(nil)
            clock.cancelAll()
            await fixture.cleanup()
            try await fixture.assertCleanedUp()
        }
    }

    private func drainCleanupScheduler(until predicate: @MainActor () -> Bool = { false }) async {
        for _ in 0 ..< 20000 {
            if predicate() { return }
            await Task.yield()
        }
    }

    func testAgentExploreStartSharesLifecycleWaitPolicy() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(
                nil,
                capturedDefaultWaitSeconds: MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
            ),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(
                .double(900.5),
                capturedDefaultWaitSeconds: MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
            ),
            900.5
        )
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil, capturedDefaultWaitSeconds: 1800),
            1800
        )
    }
}

private final class CleanupExecutionTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MCPToolExecutionTraceEvent] = []

    func append(_ event: MCPToolExecutionTraceEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [MCPToolExecutionTraceEvent] {
        lock.withLock { events }
    }
}

@MainActor
private final class CleanupTransportObservation {
    var response: Result<PersistentMCPTestRPCResponse, Error>?
    var handlerFinished = false
}

// MARK: - SessionAdminExecutionContractTests regressions

final class SessionAdminExecutionContractTests: XCTestCase {
    func testEverySessionAdminOperationUsesItsOwningLifecycleContract() {
        let workspaceOperations: Set = ["worktree_create", "worktree_bind", "worktree_unbind", "worktree_release", "worktree_inventory", "merge_preview", "merge_apply"]
        let sessionOperations: Set = [
            "rename", "set_pin", "reorder_pins", "set_group", "reorder_groups", "archive", "unarchive",
            "link", "unlink", "reparent", "adopt", "release", "retire", "fork", "set_model", "set_effort", "undo"
        ]
        for operation in MCPDomainSessionAdminToolDefinition.operations {
            let contract = MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin, arguments: ["op": .string(operation)])
            if workspaceOperations.contains(operation) {
                XCTAssertEqual(contract, .workspaceLifecycleCancellable, operation)
            } else if sessionOperations.contains(operation) {
                XCTAssertEqual(contract, .lifecycleManagedCancellable, operation)
            } else {
                XCTAssertEqual(contract, MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin), operation)
                XCTAssertEqual(contract?.cleanupDisposition, .forceDisconnect, operation)
                XCTAssertEqual(contract?.deadline, MCPTimeoutPolicy.boundedToolExecutionDeadline, operation)
            }
        }
    }

    #if DEBUG
        func testDurationDiagnosticsExposeTheArgumentSelectedLifecycleContracts() throws {
            let tools = try XCTUnwrap(MCPToolDurationInventory.debugSnapshot["tools"] as? [[String: Any]])
            let entry = try XCTUnwrap(tools.first { $0["tool"] as? String == MCPWindowToolName.sessionAdmin })
            let overrides = try XCTUnwrap(entry["conditional_execution_overrides"] as? [[String: Any]])
            let byOperation = Dictionary(uniqueKeysWithValues: overrides.compactMap { row -> (String, String)? in
                guard let operation = row["op"] as? String, let kind = row["execution_contract"] as? String else { return nil }
                return (operation, kind)
            })
            XCTAssertEqual(byOperation["rename"], "lifecycle_managed_cancellable")
            XCTAssertEqual(byOperation["merge_preview"], "workspace_lifecycle_cancellable")
            XCTAssertEqual(byOperation["worktree_inventory"], "workspace_lifecycle_cancellable")
            XCTAssertNil(byOperation["inventory"])
            XCTAssertNil(byOperation["get"])
        }
    #endif

    func testInvalidOperationsDoNotReceiveLifecycleExemption() {
        let invalidArguments: [[String: Value]] = [[:], ["op": .int(1)], ["op": .string("unknown")]]
        for arguments in invalidArguments {
            XCTAssertEqual(
                MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin, arguments: arguments),
                MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin)
            )
        }
        XCTAssertEqual(
            MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.sessionAdmin, arguments: ["op": .string("  ARCHIVE  ")]),
            .lifecycleManagedCancellable
        )
    }
}
