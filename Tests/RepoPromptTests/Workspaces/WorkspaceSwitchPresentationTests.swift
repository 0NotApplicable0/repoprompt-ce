import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

@MainActor
final class WorkspaceSwitchPresentationTests: XCTestCase {
    func testBlockedResultsPublishSharedNoticeAndStaleDismissalCannotClearReplacement() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()

        manager.isRefreshing = true
        let firstTarget = manager.createWorkspace(
            name: "Blocked Notice First Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let firstResult = await manager.requestWorkspaceSwitch(to: firstTarget, reason: "blockedNoticeFirst")
        guard case let .blocked(firstMessage) = firstResult else {
            return XCTFail("Expected refresh-state request to be blocked")
        }
        let firstNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertEqual(firstNotice.message, firstMessage)
        let staleBinding = WorkspaceSwitchConfirmationModifier.blockedNoticePresentationBinding(
            manager: manager,
            noticeID: firstNotice.id
        )

        let target = manager.createWorkspace(
            name: "Blocked Notice Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        let secondResult = await manager.requestWorkspaceSwitch(to: target, reason: "blockedNoticeSecond")
        guard case let .blocked(secondMessage) = secondResult else {
            return XCTFail("Expected refresh-state request to be blocked")
        }
        let secondNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertEqual(secondNotice.message, secondMessage)
        XCTAssertNotEqual(firstNotice.id, secondNotice.id)

        staleBinding.wrappedValue = false

        XCTAssertEqual(manager.pendingWorkspaceSwitchBlockedNotice?.id, secondNotice.id)
        let currentBinding = WorkspaceSwitchConfirmationModifier.blockedNoticePresentationBinding(
            manager: manager,
            noticeID: secondNotice.id
        )
        currentBinding.wrappedValue = false
        XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
        manager.isRefreshing = false
    }

    func testActiveWorkspaceRequestIsBlockedWithoutPublishingNotice() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()
        let active = try XCTUnwrap(manager.activeWorkspace)

        let result = await manager.requestWorkspaceSwitch(to: active, reason: "sameWorkspaceNoOp")

        guard case let .blocked(message) = result else {
            return XCTFail("Expected active-workspace request to be blocked")
        }
        XCTAssertEqual(message, "Already on workspace \"\(active.name)\".")
        XCTAssertNil(
            manager.pendingWorkspaceSwitchBlockedNotice,
            "Benign same-workspace requests (launch restore, save-and-exit on the fallback, MCP switch to current) must not raise the blocked alert"
        )
    }

    func testSuccessfulSwitchDoesNotClearUnrelatedBlockedNotice() async throws {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()

        manager.isRefreshing = true
        let blockedTarget = manager.createWorkspace(
            name: "Unrelated Blocked Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )
        guard case .blocked = await manager.requestWorkspaceSwitch(
            to: blockedTarget,
            reason: "unrelatedNotice"
        ) else {
            return XCTFail("Expected refresh-state request to publish a blocked notice")
        }
        manager.isRefreshing = false
        let unrelatedNotice = try XCTUnwrap(manager.pendingWorkspaceSwitchBlockedNotice)
        XCTAssertNil(unrelatedNotice.blockingOperationID)
        let target = manager.createWorkspace(
            name: "Unrelated Notice Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )

        let switchResult = await manager.requestWorkspaceSwitch(
            to: target,
            saveState: false,
            reason: "successfulSwitchWithUnrelatedNotice"
        )
        XCTAssertEqual(switchResult, .switched)
        XCTAssertEqual(manager.pendingWorkspaceSwitchBlockedNotice?.id, unrelatedNotice.id)
    }

    func testBlockedNoticeOwnershipDoesNotMatchNewerUnrelatedNotice() {
        let owningOperationID = UUID()
        let relatedNotice = WorkspaceSwitchBlockedNotice(
            message: "related",
            blockingOperationID: owningOperationID
        )
        let newerUnrelatedNotice = WorkspaceSwitchBlockedNotice(
            message: "newer unrelated",
            blockingOperationID: UUID()
        )

        XCTAssertTrue(relatedNotice.isBlocked(by: owningOperationID))
        XCTAssertFalse(newerUnrelatedNotice.isBlocked(by: owningOperationID))
    }

    func testProgrammaticBlockedSwitchReturnsBlockageWithoutNotice() async throws {
        try await HeldFirstSwitch.run(makeComposition().workspaceManager) { held in
            let result = await held.manager.requestWorkspaceSwitch(
                to: held.other,
                saveState: false,
                origin: .programmatic
            )

            guard case let .blocked(message) = result else {
                return XCTFail("Expected programmatic request to be blocked")
            }
            XCTAssertTrue(message.contains("is blocked by a active switch to \"\(held.target.name)\""), message)
            XCTAssertNotNil(held.manager.lastWorkspaceSwitchBlockageReport)
            XCTAssertNil(held.manager.pendingWorkspaceSwitchBlockedNotice)
        }
    }

    func testPersonBlockedSwitchStillPublishesNoticeDuringActiveSwitch() async throws {
        try await HeldFirstSwitch.run(makeComposition().workspaceManager) { held in
            let result = await held.manager.requestWorkspaceSwitch(to: held.other, saveState: false)

            guard case let .blocked(message) = result else {
                return XCTFail("Expected person request to be blocked")
            }
            XCTAssertEqual(held.manager.pendingWorkspaceSwitchBlockedNotice?.message, message)
        }
    }

    func testProgrammaticBlockedRequestReturnsWhileFirstSwitchIsHeld() async throws {
        try await HeldFirstSwitch.run(makeComposition().workspaceManager) { held in
            let secondReturned = await awaitBounded(label: "programmatic request returns while first switch held") {
                _ = await held.manager.requestWorkspaceSwitch(to: held.other, saveState: false, origin: .programmatic)
            }
            XCTAssertTrue(secondReturned)
            held.gate.release()
            let firstResult = await awaitBoundedResult(label: "first switch completes") { await held.first.value }
            XCTAssertEqual(try firstResult.get(), .switched)
        }
    }

    func testProgrammaticRefreshBlockPublishesNoNotice() async {
        let manager = makeComposition().workspaceManager
        await manager.awaitInitialized()
        manager.isRefreshing = true
        defer { manager.isRefreshing = false }
        let target = manager.createWorkspace(
            name: "Programmatic Refresh Target \(UUID().uuidString.prefix(8))",
            repoPaths: [],
            ephemeral: true
        )

        let result = await manager.requestWorkspaceSwitch(to: target, origin: .programmatic)

        guard case .blocked = result else {
            return XCTFail("Expected refresh-state request to be blocked")
        }
        XCTAssertNil(manager.pendingWorkspaceSwitchBlockedNotice)
    }

    @MainActor
    private final class HeldFirstSwitch {
        let manager: WorkspaceManagerViewModel
        let target: WorkspaceModel
        let other: WorkspaceModel
        let gate = BoundedGate()
        var first: Task<WorkspaceSwitchResult, Never>!

        private init(manager: WorkspaceManagerViewModel, target: WorkspaceModel, other: WorkspaceModel) {
            self.manager = manager
            self.target = target
            self.other = other
        }

        static func begin(_ manager: WorkspaceManagerViewModel) async throws -> HeldFirstSwitch {
            await manager.awaitInitialized()
            let target = manager.createWorkspace(
                name: "Held Switch Target \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let other = manager.createWorkspace(
                name: "Blocked Switch Target \(UUID().uuidString.prefix(8))",
                repoPaths: [],
                ephemeral: true
            )
            let held = HeldFirstSwitch(manager: manager, target: target, other: other)
            manager.setWorkspaceSwitchDidBeginHandlerForTesting { [gate = held.gate] id in
                if id == target.id { await gate.hold() }
            }
            held.first = Task { @MainActor in
                await manager.requestWorkspaceSwitch(to: target, saveState: false)
            }
            let entered = await held.gate.waitUntilEntered()
            if !entered {
                await held.join()
                throw BoundedWaitTimeout(label: "first switch entered hold")
            }
            return held
        }

        static func run(
            _ manager: WorkspaceManagerViewModel,
            _ body: @MainActor (HeldFirstSwitch) async throws -> Void
        ) async throws {
            let held = try await begin(manager)
            defer { held.finish() }
            do {
                try await body(held)
            } catch {
                await held.join()
                throw error
            }
            await held.join()
        }

        func join() async {
            finish()
            _ = await awaitBounded(label: "first switch joined") { [first] in
                _ = await first?.value
            }
        }

        func finish() {
            gate.release()
            manager.setWorkspaceSwitchDidBeginHandlerForTesting(nil)
        }
    }

    private func makeComposition() -> WindowStateComposition {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        return WindowStateCompositionFactory.make(
            windowID: -1000 - Int.random(in: 1 ... 99),
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
    }
}

@MainActor
private final class PresentationWorkspaceSwitchSessionProvider: WorkspaceSwitchSessionProvider {
    func switchSessionItems() -> [WorkspaceSwitchSessionItem] {
        [WorkspaceSwitchSessionItem(
            id: "presentation",
            count: 1,
            singularLabel: "presentation session",
            pluralLabel: "presentation sessions"
        )]
    }

    func cancelSwitchSessions() async {}
}
