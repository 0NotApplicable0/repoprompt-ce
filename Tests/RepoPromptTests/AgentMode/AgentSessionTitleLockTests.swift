import Cocoa
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AgentSessionTitleLockTests: XCTestCase {
    private var storageRoot: URL!
    private var runtime: MCPDomainRuntime!
    private var window: WindowState!

    override func setUp() async throws {
        try await super.setUp()
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionTitleLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        runtime = MCPDomainRuntime(configuration: .init(
            mode: .app,
            profileIdentifier: "title-lock-\(UUID().uuidString)",
            storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
            workspaceStorageDirectory: storageRoot,
            eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
        try await runtime.start()
        window = WindowState(domainRuntime: runtime)
        await window.workspaceManager.awaitInitialized()
    }

    override func tearDown() async throws {
        if let window { await window.tearDown() }
        window = nil
        if let runtime { _ = await runtime.shutdown() }
        runtime = nil
        if let storageRoot { try? FileManager.default.removeItem(at: storageRoot) }
        try await super.tearDown()
    }

    func testPromptDoesNotAskATitledSessionToRename() {
        let kinds: [AgentProviderKind?] = [nil, .codexExec]
        for kind in kinds {
            XCTAssertTrue(
                AgentModePrompts.Fragments.setStatusStartSentence(agentKind: kind).contains("do not call `set_status`")
            )
            XCTAssertTrue(
                AgentModePrompts.Fragments.setStatusStartupBullet(agentKind: kind).contains("do not call `set_status`")
            )
            XCTAssertFalse(
                AgentModePrompts.Fragments.setStatusToolListItem(agentKind: kind).contains("call once at session start")
            )
        }
    }

    func testExplicitStartNameSurvivesSetStatus() async throws {
        let viewModel = window.agentModeViewModel
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspaceID)
        let title = "WF - ORCHESTRATE - rpce-graph-ops / OG-14"
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: title,
            expectedWorkspaceID: workspaceID
        )
        XCTAssertTrue(target.dispatcherTitleLocked)
        let sessionID = try XCTUnwrap(target.sessionID)
        let mutation = AgentSessionLifecycleAuthority.MutationTarget(
            tabID: target.tabID,
            identity: target.lifecycleIdentity
        )
        let status = try viewModel.applySetStatusSessionName(target: mutation, proposed: "Helpful title")
        XCTAssertFalse(status.applied)
        XCTAssertEqual(status.message, "The dispatcher title was kept.")
        XCTAssertTrue(viewModel.keepsDispatcherTitle(sessionID: sessionID, proposed: "Helpful title"))
    }

    func testUntitledSessionCanBeNamedBySetStatus() async throws {
        let viewModel = window.agentModeViewModel
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspaceID)
        let target = try await viewModel.mcpResolveOrCreateSessionTarget(
            tabID: nil,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil,
            expectedWorkspaceID: workspaceID
        )
        XCTAssertFalse(target.dispatcherTitleLocked)
        let mutation = AgentSessionLifecycleAuthority.MutationTarget(
            tabID: target.tabID,
            identity: target.lifecycleIdentity
        )
        let status = try viewModel.applySetStatusSessionName(target: mutation, proposed: "Named once")
        XCTAssertTrue(status.applied)
        XCTAssertNil(status.message)
    }
}
