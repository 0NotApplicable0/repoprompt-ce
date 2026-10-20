import Combine
import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptSettingsCore
import RepoPromptShared
import SwiftUI
import XCTest

final class FleetRosterModelTests: XCTestCase {
    func testTwoSectionsInRegistryOrderSkippingSystemWorkspace() {
        let roster = derive(fixtureWindows())

        XCTAssertEqual(roster.sections.map(\.workspaceName), ["A", "B"])
        XCTAssertEqual(roster.sections.map(\.windowID), [1, 2])
    }

    func testSectionCountsRunningAndWaiting() throws {
        let section = try XCTUnwrap(derive(fixtureWindows()).sections.first)

        XCTAssertEqual(section.runningCount, 2)
        XCTAssertEqual(section.waitingCount, 2)
    }

    func testSameWindowChildrenNestUnderParent() throws {
        let parent = try XCTUnwrap(row(named: "P", in: derive(fixtureWindows())))

        XCTAssertEqual(parent.children.map(\.name), ["C1", "C2"])
        XCTAssertEqual(parent.children.map(\.parent), [.sameWindow(parent.id), .sameWindow(parent.id)])
    }

    func testParentRollupCountsAcrossWindows() throws {
        let parent = try XCTUnwrap(row(named: "P", in: derive(fixtureWindows())))

        XCTAssertEqual(parent.rollup, FleetRosterRollup(totalSubagents: 3, runningCount: 2, waitingCount: 1, otherWindowCount: 1))
    }

    func testCrossWindowChildStaysInOwnSectionNamingParent() throws {
        let roster = derive(fixtureWindows())
        let section = try XCTUnwrap(roster.sections.last)
        let child = try XCTUnwrap(row(named: "C3", in: roster))

        XCTAssertTrue(section.rows.contains(where: { $0.id == child.id }))
        XCTAssertEqual(child.parent, .otherWindow(windowID: 1, sessionID: ids.p, name: "P"))
    }

    func testIndexOnlyChildNestsUnderParent() throws {
        let roster = derive(fixtureWindows())
        let parent = try XCTUnwrap(row(named: "P", in: roster))
        let indexOnly = try XCTUnwrap(parent.children.first(where: { $0.id == ids.c2 }))

        XCTAssertEqual(indexOnly.parent, .sameWindow(parent.id))
    }

    func testSelfParentIsTopLevelAndNotCounted() throws {
        let selfParent = session(id: ids.p, name: "P", parentSessionID: ids.p)
        let roster = derive([window(id: 1, workspaceName: "A", sessions: [selfParent])])
        let section = try XCTUnwrap(roster.sections.first)
        let row = try XCTUnwrap(section.rows.first)

        XCTAssertEqual(section.rows.count, 1)
        XCTAssertNil(row.parent)
        XCTAssertEqual(row.rollup.totalSubagents, 0)
    }

    func testAmbiguousParentIsTopLevelWithoutLink() throws {
        let duplicateParent = session(id: ids.duplicateParent, name: "Duplicate P")
        let child = session(id: ids.ambiguousChild, name: "Ambiguous", indexParentSessionID: ids.duplicateParent)
        let ambiguousRoster = derive([
            window(id: 1, workspaceName: "A", sessions: [duplicateParent]),
            window(id: 2, workspaceName: "B", sessions: [duplicateParent]),
            window(id: 3, workspaceName: "C", sessions: [child])
        ])
        let ambiguous = try XCTUnwrap(row(named: "Ambiguous", in: ambiguousRoster))
        let ambiguousSection = try XCTUnwrap(ambiguousRoster.sections.last)

        XCTAssertTrue(ambiguousSection.rows.contains(where: { $0.id == ambiguous.id }))
        XCTAssertNil(ambiguous.parent)

        let sameWindowRoster = derive([
            window(id: 1, workspaceName: "A", sessions: [duplicateParent, child]),
            window(id: 2, workspaceName: "B", sessions: [duplicateParent])
        ])
        let sameWindowParent = try XCTUnwrap(row(named: "Duplicate P", in: sameWindowRoster))
        let sameWindowChild = try XCTUnwrap(row(named: "Ambiguous", in: sameWindowRoster))

        XCTAssertEqual(sameWindowChild.parent, .sameWindow(sameWindowParent.id))
        XCTAssertTrue(sameWindowParent.children.contains(where: { $0.id == sameWindowChild.id }))
    }

    func testPendingKindsApprovalAndQuestion() {
        let windows = fixtureWindows() + [window(id: 4, workspaceName: "C", sessions: [session(id: ids.operatorTurn, name: "Operator", runState: .waitingForUser), session(id: ids.none, name: "None", runState: .running)])]
        let roster = derive(windows)

        XCTAssertEqual(row(named: "C2", in: roster)?.pendingKind, .approval)
        XCTAssertEqual(row(named: "Q", in: roster)?.pendingKind, .question)
        XCTAssertEqual(row(named: "Operator", in: roster)?.pendingKind, .operatorTurn)
        XCTAssertNil(row(named: "None", in: roster)?.pendingKind)
    }

    func testSessionRowsCarryNameAgentModelRunStateLastActivity() throws {
        let roster = derive(fixtureWindows())
        let session = try XCTUnwrap(row(named: "P", in: roster))

        XCTAssertEqual(session.name, "P")
        XCTAssertEqual(session.agent, "claudeCode")
        XCTAssertEqual(session.model, "sonnet")
        XCTAssertEqual(session.runState, .running)
        XCTAssertEqual(session.lastActivityAt, timestamp)
    }

    func testClosingWindowRemovesSection() {
        var windows = fixtureWindows()
        windows[0].isClosing = true
        let roster = derive(windows)

        XCTAssertEqual(roster.sections.map(\.workspaceName), ["B"])
        let remote = row(named: "C3", in: roster)
        XCTAssertNotNil(remote)
        XCTAssertNil(remote?.parent)
    }

    func testRowNamePolicyUsesComposeTabNameOverConflictingIndexEntryName() {
        let session = session(id: ids.named, name: "ignored", composeTabName: "Tab Name", indexEntryName: "Entry Name")
        let roster = derive([window(id: 1, workspaceName: "A", sessions: [session])])

        XCTAssertEqual(row(id: ids.named, in: roster)?.name, "Tab Name")
    }

    func testRowNamePolicyFallsBackToIndexEntryNameWhenSessionHasNoComposeTab() {
        let session = session(id: ids.named, name: "ignored", composeTabName: nil, indexEntryName: "Entry Name", hasComposeTab: false)
        let roster = derive([window(id: 1, workspaceName: "A", sessions: [session])])

        XCTAssertEqual(row(id: ids.named, in: roster)?.name, "Entry Name")
    }

    func testRowNamePolicyUsesAgentSessionWhenNoTabNameOrBlank() {
        let missing = session(id: ids.named, name: "ignored", composeTabName: nil, indexEntryName: nil, hasComposeTab: false)
        let blank = session(id: ids.none, name: "ignored", composeTabName: "   ", indexEntryName: "Entry Name")
        let roster = derive([window(id: 1, workspaceName: "A", sessions: [missing, blank])])

        XCTAssertEqual(row(id: ids.named, in: roster)?.name, "Agent Session")
        XCTAssertEqual(row(id: ids.none, in: roster)?.name, "Agent Session")
    }

    func testSectionCarriesWorkspaceNameWindowIDAndParkedFlag() {
        let roster = derive(fixtureWindows(), parked: [2])

        XCTAssertEqual(roster.sections.map(\.workspaceName), ["A", "B"])
        XCTAssertEqual(roster.sections.map(\.windowID), [1, 2])
        XCTAssertEqual(roster.sections.map(\.isParked), [false, true])
    }

    func testSubagentOfSubagentNestsUnderItsParentAndNeverVanishes() throws {
        let grandparent = session(id: ids.p, name: "P")
        let parent = session(id: ids.c1, name: "C1", parentSessionID: ids.p)
        let child = session(id: ids.c2, name: "C2", parentSessionID: ids.c1)
        let roster = derive([window(id: 1, workspaceName: "A", sessions: [grandparent, parent, child])])

        let parentRow = try XCTUnwrap(row(id: ids.c1, in: roster))
        XCTAssertEqual(parentRow.children.map(\.id), [ids.c2])
        XCTAssertEqual(roster.sections.flatMap(\.allRows).map(\.id), [ids.p, ids.c1, ids.c2])
    }

    @MainActor
    func testLastActivityChangeShowsWithinTimerInterval() {
        let source = TestWindowSource(windows: fixtureWindows())
        let ticker = ManualFleetRosterTicker()
        let model = FleetRosterModel(source: source, ticker: ticker)
        model.start()
        let updated = Date(timeIntervalSinceReferenceDate: 2000)

        let published = expectation(description: "timer roster publish")
        let observation = model.$roster.dropFirst().sink { _ in published.fulfill() }
        source.windowsValue[1].sessions[0].lastActivityAt = updated
        XCTAssertNotEqual(row(id: ids.r, in: model.roster)?.lastActivityAt, updated)
        ticker.fire()

        wait(for: [published], timeout: 1)
        XCTAssertEqual(FleetRosterModel.tickInterval, 2)
        XCTAssertEqual(ticker.intervals, [FleetRosterModel.tickInterval])
        XCTAssertEqual(row(id: ids.r, in: model.roster)?.lastActivityAt, updated)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRunStateChangeRepublishesWithBRunningTwo() {
        let source = TestWindowSource(windows: fixtureWindows())
        let ticker = ManualFleetRosterTicker()
        let model = FleetRosterModel(source: source, ticker: ticker)
        let published = expectation(description: "roster publish")
        let observation = model.$roster.dropFirst().sink { _ in published.fulfill() }
        model.start()

        source.windowsValue[1].sessions[0].runState = .running
        source.changesSubject.send(())

        wait(for: [published], timeout: 1)
        XCTAssertEqual(model.roster.sections[1].runningCount, 2)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testModelNeverRegistersInAllWindows() {
        let originalIDs = WindowStatesManager.shared.allWindows.map(\.windowID)
        let model = FleetRosterModel(source: TestWindowSource(windows: fixtureWindows()), ticker: ManualFleetRosterTicker())
        model.start()
        model.stop()

        XCTAssertEqual(WindowStatesManager.shared.allWindows.map(\.windowID), originalIDs)
    }

    @MainActor
    func testStopCancelsTickerAndSubscriptions() {
        let source = TestWindowSource(windows: fixtureWindows())
        let ticker = ManualFleetRosterTicker()
        let model = FleetRosterModel(source: source, ticker: ticker)
        let published = expectation(description: "no publish")
        published.isInverted = true
        let observation = model.$roster.dropFirst().sink { _ in published.fulfill() }
        model.start()
        model.stop()

        source.windowsValue[1].sessions[0].runState = .running
        source.changesSubject.send(())
        ticker.fire()

        wait(for: [published], timeout: 0.1)
        XCTAssertEqual(ticker.stopCount, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testStopPreventsPendingRefreshFromPublishing() async {
        let source = TestWindowSource(windows: fixtureWindows())
        let model = FleetRosterModel(source: source, ticker: ManualFleetRosterTicker())
        var publishCount = 0
        let observation = model.$roster.dropFirst().sink { _ in publishCount += 1 }
        let before = model.roster
        model.start()

        source.windowsValue[1].sessions[0].runState = .running
        source.changesSubject.send(())
        model.stop()
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(model.roster, before)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testLiveSourceUsesSidebarParentRule() async throws {
        try await withLiveWindow { window, workspace in
            let parentID = UUID()
            let parent = window.agentModeViewModel.session(for: UUID())
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: parentID, on: parent)
            parent.hasLoadedPersistedState = true
            let child = window.agentModeViewModel.session(for: UUID())
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: child)
            child.hasLoadedPersistedState = true
            child.parentSessionID = parentID
            let model = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ManualFleetRosterTicker())
            let section = try XCTUnwrap(model.roster.sections.first(where: { $0.workspaceID == workspace.id }))
            XCTAssertEqual(section.allRows.count, 2)
            let parentRow = try XCTUnwrap(section.rows.first(where: { $0.id == parentID }))
            let childID = try XCTUnwrap(child.activeAgentSessionID)
            XCTAssertEqual(parentRow.children.map(\.id), [childID])
            XCTAssertEqual(parentRow.children.first?.parent, .sameWindow(parentID))
        }
    }

    @MainActor
    func testLiveSourceNestsIndexOnlyChildUnderParent() async throws {
        try await withLiveWindow { window, workspace in
            let parentID = UUID()
            let childID = UUID()
            let parent = window.agentModeViewModel.session(for: UUID())
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: parentID, on: parent)
            let child = window.agentModeViewModel.session(for: UUID())
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: childID, on: child)
            child.hasLoadedPersistedState = false
            let owner = AgentModeViewModel.SessionIndexOwner(workspaceID: workspace.id, activationEpoch: 1)
            window.agentModeViewModel.test_installSessionIndexSnapshot(
                [childID: AgentSessionIndexEntry(
                    id: childID,
                    tabID: child.tabID,
                    name: "Index Child",
                    lastUserMessageAt: nil,
                    savedAt: timestamp,
                    lastRunStateRaw: nil,
                    itemCount: 0,
                    agentKindRaw: "claudeCode",
                    agentModelRaw: "sonnet",
                    agentReasoningEffortRaw: nil,
                    autoEditEnabled: false,
                    parentSessionID: parentID,
                    hasUnknownConversationContent: false,
                    isMCPOriginated: false,
                    worktreeBindingSummaries: [],
                    activeWorktreeMergeSummaries: []
                )],
                owner: owner,
                latestOwner: owner,
                activeWorkspace: workspace
            )
            let model = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ManualFleetRosterTicker())
            let section = try XCTUnwrap(model.roster.sections.first(where: { $0.workspaceID == workspace.id }))
            let parentRow = try XCTUnwrap(section.rows.first(where: { $0.id == parentID }))

            XCTAssertEqual(parentRow.children.map(\.id), [childID])
            XCTAssertEqual(parentRow.children.first?.parent, .sameWindow(parentID))
        }
    }

    @MainActor
    func testLiveSourceSkipsSystemWorkspace() async throws {
        try await withLiveWindow { window, workspace in
            let model = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ManualFleetRosterTicker())
            XCTAssertTrue(model.roster.sections.contains(where: { $0.workspaceID == workspace.id }))
            let systemWorkspace = try XCTUnwrap(window.workspaceManager.workspaces.first(where: \.isSystemWorkspace))
            await window.workspaceManager.switchWorkspace(to: systemWorkspace, saveState: false, reason: "fleetRosterTest")
            let systemModel = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ManualFleetRosterTicker())
            XCTAssertFalse(systemModel.roster.sections.contains(where: { $0.windowID == window.windowID }))
        }
    }

    @MainActor
    func testLiveSourceDropsSectionAfterRealBeginClose() async throws {
        try await withLiveWindow { window, workspace in
            let ticker = ManualFleetRosterTicker()
            let model = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ticker)
            model.start()
            XCTAssertTrue(model.roster.sections.contains(where: { $0.workspaceID == workspace.id }))
            let removed = expectation(description: "closing window removed")
            let observation = model.$roster.dropFirst().sink { roster in
                if !roster.sections.contains(where: { $0.workspaceID == workspace.id }) { removed.fulfill() }
            }
            window.beginClose()
            ticker.fire()
            await fulfillment(of: [removed], timeout: 1)
            withExtendedLifetime(observation) {}
        }
    }

    @MainActor
    func testLiveSourceRowNamePolicyUsesComposeTabNameOverIndexEntryName() async throws {
        try await withLiveWindow { window, workspace in
            let id = UUID()
            let tabID = UUID()
            let workspaceIndex = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }))
            window.workspaceManager.workspaces[workspaceIndex].composeTabs.append(ComposeTabState(id: tabID, name: "Tab Name"))
            let session = window.agentModeViewModel.session(for: tabID)
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: id, on: session)
            let model = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ManualFleetRosterTicker())
            XCTAssertEqual(model.roster.sections.first(where: { $0.workspaceID == workspace.id })?.allRows.first(where: { $0.id == id })?.name, "Tab Name")
        }
    }

    @MainActor
    func testLiveSourceKeepsSessionWithoutComposeTabAsRow() async throws {
        try await withLiveWindow { window, workspace in
            let id = UUID()
            let session = window.agentModeViewModel.session(for: UUID())
            _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: id, on: session)
            let model = FleetRosterModel(source: LiveFleetRosterWindowSource(), ticker: ManualFleetRosterTicker())
            XCTAssertTrue(model.roster.sections.contains(where: { $0.workspaceID == workspace.id }))
            XCTAssertNotNil(model.roster.sections.first(where: { $0.workspaceID == workspace.id })?.allRows.first(where: { $0.id == id }))
        }
    }

    @MainActor
    private func withLiveWindow(_ body: (WindowState, WorkspaceModel) async throws -> Void) async throws {
        let previous = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previous, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previous, commit: false) }
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("fleet-roster-\(UUID())")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
        // The shared domain runtime's metadata path policy is fixed at composition, so per-test storage must live under its owned root.
        let ownedStorageParent = AppProfileLocations.current.applicationSupportRoot.appendingPathComponent("FleetRosterStorage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: ownedStorageParent) }
        UserDefaults.standard.set(AppProfileLocations.current.customWorkspaceDirectory(selectedDirectory: ownedStorageParent).path, forKey: "GlobalCustomStorageURL")
        do {
            await window.workspaceManager.awaitInitialized()
            let workspace = window.workspaceManager.createWorkspace(name: "Fleet roster \(UUID())", repoPaths: [repository.path], ephemeral: false)
            try await waitForWorkspace(workspace.id, in: window, stage: "workspace creation")
            let switchResult = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "fleetRosterTest")
            XCTAssertTrue(switchResult.didSwitch, "W\(window.windowID) workspace switch failed: \(switchResult.message ?? "no message")")
            try await body(window, workspace)
        } catch {
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
            restoreStoragePath(previousStoragePath)
            try? FileManager.default.removeItem(at: repository)
            throw error
        }
        window.beginClose()
        await window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(window)
        await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
        restoreStoragePath(previousStoragePath)
        try? FileManager.default.removeItem(at: repository)
    }

    @MainActor
    private func waitForWorkspace(_ workspaceID: UUID, in window: WindowState, stage: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while window.workspaceManager.workspace(withID: workspaceID) == nil {
            guard clock.now < deadline else {
                XCTFail("W\(window.windowID) workspace \(workspaceID) missing after \(stage)")
                throw NSError(domain: "FleetRosterModelTests", code: 1)
            }
            await Task.yield()
        }
    }

    private func restoreStoragePath(_ path: String?) {
        if let path { UserDefaults.standard.set(path, forKey: "GlobalCustomStorageURL") }
        else { UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL") }
    }

    func testDisplayRollupLineForDW3Parent() throws {
        let parent = try XCTUnwrap(row(named: "P", in: derive(fixtureWindows())))

        XCTAssertEqual(
            FleetRosterDisplay.rollupLine(parent.rollup),
            FleetRosterDisplay.RollupLine(
                summary: "3 sub-agents · 2 running",
                waitingText: "1 waiting on you",
                otherWindowText: "1 in another window",
                running: 2,
                waiting: 1,
                rest: 0
            )
        )
    }

    func testDisplayCollapsedParentHidesChildrenButKeepsWaitingSignal() throws {
        let roster = derive(fixtureWindows())
        let parent = try XCTUnwrap(row(named: "P", in: roster))
        let section = try XCTUnwrap(roster.sections.first(where: { $0.rows.contains(where: { $0.id == parent.id }) }))

        XCTAssertEqual(
            FleetRosterDisplay.visibleChildren(of: parent, in: section, collapsed: [FleetRosterDisplay.occurrence(of: parent, in: section)]),
            []
        )
        XCTAssertEqual(FleetRosterDisplay.rollupLine(parent.rollup)?.waitingText, "1 waiting on you")
        XCTAssertEqual(FleetRosterDisplay.visibleChildren(of: parent, in: section, collapsed: []).map(\.name), ["C1", "C2"])
    }

    func testDisplayCollapseIsIndependentForSameSessionInTwoWindows() throws {
        let roster = derive([
            window(id: 1, workspaceName: "A", sessions: [
                session(id: ids.p, name: "P1"),
                session(id: ids.c1, name: "C1", parentSessionID: ids.p)
            ]),
            window(id: 2, workspaceName: "B", sessions: [
                session(id: ids.p, name: "P2"),
                session(id: ids.c2, name: "C2", parentSessionID: ids.p)
            ])
        ])
        let first = try XCTUnwrap(roster.sections.first(where: { $0.windowID == 1 }))
        let second = try XCTUnwrap(roster.sections.first(where: { $0.windowID == 2 }))
        let firstParent = try XCTUnwrap(first.rows.first)
        let secondParent = try XCTUnwrap(second.rows.first)
        let collapsed: Set<FleetRosterDisplay.Occurrence> = [FleetRosterDisplay.occurrence(of: firstParent, in: first)]

        XCTAssertEqual(firstParent.id, secondParent.id)
        XCTAssertEqual(FleetRosterDisplay.visibleChildren(of: firstParent, in: first, collapsed: collapsed), [])
        XCTAssertEqual(FleetRosterDisplay.visibleChildren(of: secondParent, in: second, collapsed: collapsed).map(\.name), ["C2"])
    }

    func testDisplayDisclosureOnlyForRowsWithChildren() throws {
        let roster = derive(fixtureWindows())

        XCTAssertTrue(try FleetRosterDisplay.hasDisclosure(XCTUnwrap(row(named: "P", in: roster))))
        XCTAssertFalse(try FleetRosterDisplay.hasDisclosure(XCTUnwrap(row(named: "C3", in: roster))))
        XCTAssertFalse(try FleetRosterDisplay.hasDisclosure(XCTUnwrap(row(named: "Q", in: roster))))
    }

    func testDisplaySectionCountsAndParkedLabelForDW3() throws {
        let roster = derive(fixtureWindows(), parked: [2])
        let first = try XCTUnwrap(roster.sections.first)
        let last = try XCTUnwrap(roster.sections.last)

        XCTAssertEqual(FleetRosterDisplay.sectionCounts(first).running, "2 running")
        XCTAssertEqual(FleetRosterDisplay.sectionCounts(first).waiting, "2 waiting")
        XCTAssertEqual(FleetRosterDisplay.sectionCounts(last).running, "1 running")
        XCTAssertEqual(FleetRosterDisplay.sectionCounts(last).waiting, "0 waiting")
        XCTAssertEqual(FleetRosterDisplay.parkedLabel(first.isParked), "On screen")
        XCTAssertEqual(FleetRosterDisplay.parkedLabel(last.isParked), "Parked")
    }

    func testDisplaySummaryForDW3Fixture() {
        let open = FleetRosterDisplay.summary(derive(fixtureWindows()).sections)

        XCTAssertEqual(open, FleetRosterDisplay.Summary(agents: 6, subAgents: 3, running: 3, waiting: 2, failed: 0, workspaces: 2, parked: 0, onScreen: 2))

        let parked = FleetRosterDisplay.summary(derive(fixtureWindows(), parked: [2]).sections)

        XCTAssertEqual(parked.parked, 1)
        XCTAssertEqual(parked.onScreen, 1)
        XCTAssertEqual(FleetRosterDisplay.workspaceLine(parked), "2 workspaces · 1 parked · 1 on screen")
    }

    func testDisplaySummaryCountsFailedAndIgnoresUnresolvedParents() {
        let failed = session(id: ids.p, name: "F", runState: .failed)
        let child = session(id: ids.c1, name: "C1", parentSessionID: ids.p, runState: .running)
        let orphan = session(id: ids.named, name: "Orphan", parentSessionID: ids.none, runState: .running)
        let summary = FleetRosterDisplay.summary(derive([window(id: 1, workspaceName: "A", sessions: [failed, child, orphan])]).sections)

        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.subAgents, 1)
        XCTAssertEqual(summary.agents, 3)
    }

    func testDisplaySummaryEmptyRoster() {
        let summary = FleetRosterDisplay.summary([])

        XCTAssertEqual(summary, FleetRosterDisplay.Summary(agents: 0, subAgents: 0, running: 0, waiting: 0, failed: 0, workspaces: 0, parked: 0, onScreen: 0))
        XCTAssertEqual(FleetRosterDisplay.workspaceLine(summary), "0 workspaces · 0 parked · 0 on screen")
    }

    private func derive(_ windows: [FleetRosterWindowSnapshot], parked: Set<Int> = []) -> FleetRoster {
        FleetRosterProjection.derive(windows, parked: parked)
    }

    private func row(named name: String, in roster: FleetRoster) -> FleetRosterRow? {
        roster.sections.lazy.flatMap(\.allRows).first(where: { $0.name == name })
    }

    private func row(id: UUID, in roster: FleetRoster) -> FleetRosterRow? {
        roster.sections.lazy.flatMap(\.allRows).first(where: { $0.id == id })
    }

    private func fixtureWindows() -> [FleetRosterWindowSnapshot] {
        let parent = session(id: ids.p, name: "P", runState: .running)
        let child1 = session(id: ids.c1, name: "C1", parentSessionID: ids.p, runState: .running)
        let child2 = session(id: ids.c2, name: "C2", indexParentSessionID: ids.p, runState: .waitingForApproval)
        let question = session(id: ids.q, name: "Q", runState: .waitingForQuestion)
        let complete = session(id: ids.r, name: "R", runState: .completed)
        let remoteChild = session(id: ids.c3, name: "C3", parentSessionID: ids.p, runState: .running)
        return [
            window(id: 1, workspaceName: "A", sessions: [parent, child1, child2, question]),
            window(id: 2, workspaceName: "B", sessions: [complete, remoteChild]),
            window(id: 3, workspaceName: "System", isSystemWorkspace: true, sessions: [])
        ]
    }

    private func window(id: Int, workspaceName: String, isSystemWorkspace: Bool = false, sessions: [FleetRosterSessionSnapshot]) -> FleetRosterWindowSnapshot {
        FleetRosterWindowSnapshot(
            windowID: id,
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(id)")!,
            workspaceName: workspaceName,
            isSystemWorkspace: isSystemWorkspace,
            isClosing: false,
            sessions: sessions
        )
    }

    private func session(
        id: UUID,
        name: String,
        parentSessionID: UUID? = nil,
        indexParentSessionID: UUID? = nil,
        composeTabName: String? = nil,
        indexEntryName: String? = nil,
        hasComposeTab: Bool = true,
        runState: AgentSessionRunState = .idle
    ) -> FleetRosterSessionSnapshot {
        FleetRosterSessionSnapshot(
            tabID: UUID(),
            sessionID: id,
            parentSessionID: parentSessionID,
            indexParentSessionID: indexParentSessionID,
            composeTabName: hasComposeTab ? (composeTabName ?? name) : nil,
            indexEntryName: indexEntryName,
            agent: "claudeCode",
            model: "sonnet",
            runState: runState,
            lastActivityAt: timestamp
        )
    }

    private var timestamp: Date {
        Date(timeIntervalSinceReferenceDate: 1000)
    }

    @MainActor
    private final class TestWindowSource: FleetRosterWindowSource {
        var windowsValue: [FleetRosterWindowSnapshot]
        let changesSubject = PassthroughSubject<Void, Never>()

        init(windows: [FleetRosterWindowSnapshot]) {
            windowsValue = windows
        }

        func windows() -> [FleetRosterWindowSnapshot] {
            windowsValue
        }

        var changes: AnyPublisher<Void, Never> {
            changesSubject.eraseToAnyPublisher()
        }
    }

    @MainActor
    private final class ManualFleetRosterTicker: FleetRosterTicker {
        var intervals: [TimeInterval] = []
        var stopCount = 0
        private var fireHandler: (@MainActor () -> Void)?

        func start(interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
            intervals.append(interval)
            fireHandler = fire
        }

        func stop() {
            stopCount += 1
            fireHandler = nil
        }

        func fire() {
            fireHandler?()
        }
    }

    private enum ids {
        static let p = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        static let c1 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        static let c2 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        static let q = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        static let r = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        static let c3 = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        static let duplicateParent = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        static let ambiguousChild = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
        static let operatorTurn = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        static let none = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        static let named = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    }
}

final class FleetRosterDisplayTests: XCTestCase {
    private let allStates: [AgentSessionRunState] = [.idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval, .completed, .cancelled, .failed]

    func testStateLabelForEveryRunState() {
        let expected = ["Idle", "Running", "Waiting for you", "Has a question", "Needs approval", "Completed", "Cancelled", "Failed"]

        XCTAssertEqual(allStates.map(FleetRosterDisplay.stateLabel), expected)
        for state in allStates {
            XCTAssertNotEqual(FleetRosterDisplay.stateLabel(state), String(describing: state))
        }
    }

    func testStateToneForEveryRunState() {
        let expected: [FleetRosterDisplay.Tone] = [.neutral, .running, .waiting, .waiting, .waiting, .success, .neutral, .failure]

        XCTAssertEqual(allStates.map(FleetRosterDisplay.tone), expected)
    }

    func testPendingLabelsForEveryKind() {
        XCTAssertEqual(FleetRosterDisplay.pendingLabel(.approval), "Approval")
        XCTAssertEqual(FleetRosterDisplay.pendingLabel(.question), "Question")
        XCTAssertEqual(FleetRosterDisplay.pendingLabel(.operatorTurn), "Your turn")
    }

    func testRelativeTimeBoundaries() {
        let since = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let cases: [(TimeInterval, String)] = [(-5, "0s ago"), (0, "0s ago"), (59, "59s ago"), (60, "1m ago"), (3599, "59m ago"), (3600, "1h ago"), (86399, "23h ago"), (86400, "1d ago")]

        for (offset, expected) in cases {
            XCTAssertEqual(FleetRosterDisplay.relativeTime(since: since, now: since.addingTimeInterval(offset)), expected)
        }
    }

    func testRelativeTimeAdvancesWithInjectedNow() {
        let since = Date(timeIntervalSinceReferenceDate: 1_000_000)

        XCTAssertEqual(FleetRosterDisplay.relativeTime(since: since, now: since.addingTimeInterval(6)), "6s ago")
        XCTAssertEqual(FleetRosterDisplay.relativeTime(since: since, now: since.addingTimeInterval(8)), "8s ago")
        XCTAssertEqual(FleetRosterDisplay.relativeTime(since: since, now: since.addingTimeInterval(62)), "1m ago")
    }

    func testRollupLineSingularZeroAndNil() {
        XCTAssertNil(FleetRosterDisplay.rollupLine(FleetRosterRollup(totalSubagents: 0, runningCount: 0, waitingCount: 0, otherWindowCount: 0)))
        XCTAssertEqual(
            FleetRosterDisplay.rollupLine(FleetRosterRollup(totalSubagents: 1, runningCount: 0, waitingCount: 0, otherWindowCount: 0)),
            FleetRosterDisplay.RollupLine(summary: "1 sub-agent", waitingText: nil, otherWindowText: nil, running: 0, waiting: 0, rest: 1)
        )
        XCTAssertEqual(
            FleetRosterDisplay.rollupLine(FleetRosterRollup(totalSubagents: 5, runningCount: 1, waitingCount: 0, otherWindowCount: 2)),
            FleetRosterDisplay.RollupLine(summary: "5 sub-agents · 1 running", waitingText: nil, otherWindowText: "2 in other windows", running: 1, waiting: 0, rest: 4)
        )
    }

    func testVisibleChildrenWithLiteralRows() {
        let first = literalRow(name: "One")
        let second = literalRow(name: "Two")
        let parent = literalRow(name: "Parent", children: [first, second])

        let section = literalSection(windowID: 1, workspaceID: UUID(), rows: [parent])

        XCTAssertEqual(
            FleetRosterDisplay.visibleChildren(of: parent, in: section, collapsed: [FleetRosterDisplay.occurrence(of: parent, in: section)]),
            []
        )
        XCTAssertEqual(
            FleetRosterDisplay.visibleChildren(of: parent, in: section, collapsed: [FleetRosterDisplay.occurrence(of: first, in: section)]).map(\.name),
            ["One", "Two"]
        )
    }

    func testCollapseSeparatesWorkspacesSharingWindowIDAndSession() {
        let parent = literalRow(name: "Parent", children: [literalRow(name: "One")])
        let firstSection = literalSection(windowID: 1, workspaceID: UUID(), rows: [parent])
        let secondSection = literalSection(windowID: 1, workspaceID: UUID(), rows: [parent])
        let collapsed: Set<FleetRosterDisplay.Occurrence> = [FleetRosterDisplay.occurrence(of: parent, in: firstSection)]

        XCTAssertEqual(FleetRosterDisplay.visibleChildren(of: parent, in: firstSection, collapsed: collapsed), [])
        XCTAssertEqual(FleetRosterDisplay.visibleChildren(of: parent, in: secondSection, collapsed: collapsed).map(\.name), ["One"])
    }

    func testEmptyStateWording() {
        let state = FleetRosterDisplay.emptyState()

        XCTAssertEqual(state.title, "No live workspaces")
        XCTAssertEqual(state.message, "Workspace windows appear here as soon as a project workspace opens.")
    }

    private func literalSection(windowID: Int, workspaceID: UUID, rows: [FleetRosterRow]) -> FleetRosterSection {
        FleetRosterSection(workspaceID: workspaceID, workspaceName: "W", windowID: windowID, isParked: false, runningCount: 0, waitingCount: 0, rows: rows)
    }

    private func literalRow(name: String, children: [FleetRosterRow] = []) -> FleetRosterRow {
        FleetRosterRow(
            id: UUID(),
            name: name,
            agent: "claudeCode",
            model: "sonnet",
            runState: .idle,
            lastActivityAt: Date(timeIntervalSinceReferenceDate: 1000),
            pendingKind: nil,
            parent: nil,
            rollup: FleetRosterRollup(totalSubagents: 0, runningCount: 0, waitingCount: 0, otherWindowCount: 0),
            children: children
        )
    }
}

@MainActor
final class FleetManagerWorkspacesTests: XCTestCase {
    private var previousAutoStart = false
    private var previousStorage: String?
    private var storageRoot: URL?
    private var states: [WindowState] = []
    private var coordinators: [FleetManagerWindowCoordinator] = []

    override func setUp() async throws {
        try await super.setUp()
        let sandbox = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let prefix = URL(fileURLWithPath: sandbox).resolvingSymlinksInPath().path + "/"
        try XCTSkipUnless(AppProfileLocations.current.applicationSupportRoot.resolvingSymlinksInPath().path.hasPrefix(prefix))
        _ = NSApplication.shared
        previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        previousStorage = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
        let root = AppProfileLocations.current.applicationSupportRoot.appendingPathComponent("FleetWorkspaces-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storageRoot = root
        UserDefaults.standard.set(AppProfileLocations.current.customWorkspaceDirectory(selectedDirectory: root).path, forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
    }

    override func tearDown() async throws {
        for coordinator in coordinators {
            coordinator.windowForTesting?.close()
        }
        coordinators.removeAll()
        for state in states {
            state.beginClose()
            await state.tearDown()
        }
        states.removeAll()
        await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
        if let storageRoot {
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            if let previousStorage { UserDefaults.standard.set(previousStorage, forKey: "GlobalCustomStorageURL") }
            else { UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL") }
            try FileManager.default.removeItem(at: storageRoot)
        }
        storageRoot = nil
        try await super.tearDown()
    }

    func testFleetShowsDebugBadgeInDebugBuilds() throws {
        let coordinator = FleetManagerWindowCoordinator(present: { _ in })
        coordinators.append(coordinator)
        coordinator.open()
        let window = try XCTUnwrap(coordinator.windowForTesting)
        XCTAssertEqual(window.title, "Fleet Manager")
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains {
            $0.view is NSHostingView<DebugBuildToolbarBadge>
        }, "Fleet must install the same titlebar badge as workspace windows")

        XCTAssertTrue(
            window.contentViewController is NSHostingController<FleetManagerWindowRoot>,
            "Fleet must host the root that installs the shared DEBUG window-edge rule"
        )
    }

    func testRecentWorkspacesMatchChooserOrderAndLimit() async throws {
        let state = await makeState()
        let manager = state.workspaceManager
        var saved = (1 ... 7).map { index in
            var workspace = WorkspaceModel(name: "Saved \(index)", repoPaths: [], isSavedWorkspace: true)
            workspace.lastUsed = Date(timeIntervalSince1970: TimeInterval(index))
            return workspace
        }
        var hidden = WorkspaceModel(name: "Hidden", repoPaths: [], isHiddenInMenus: true, isSavedWorkspace: true)
        hidden.lastUsed = Date(timeIntervalSince1970: 100)
        var temporary = WorkspaceModel(name: "Temporary", repoPaths: [], isSavedWorkspace: false)
        temporary.lastUsed = Date(timeIntervalSince1970: 101)
        var system = WorkspaceModel(name: "System", repoPaths: [], isSystemWorkspace: true)
        system.lastUsed = Date(timeIntervalSince1970: 102)
        saved.append(contentsOf: [hidden, temporary, system])
        manager.workspaces = saved
        let probe = OpenProbe(destination: state)
        let actions = makeActions(probe)
        var consumed: [WorkspaceChooserConsumption] = []
        manager.setWorkspaceChooserConsumptionHandlerForTesting { consumed.append($0) }
        defer { manager.setWorkspaceChooserConsumptionHandlerForTesting(nil) }
        let chooser = NSHostingView(rootView: WorkspaceLandingView(
            workspaceManager: manager, onOpenWorkspace: { _ in }, onManageWorkspaces: {}, onSelectFolder: {}
        ))
        chooser.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        chooser.layoutSubtreeIfNeeded()
        let chooserRows = try XCTUnwrap(consumed.last)
        consumed.removeAll()
        let fleet = hostSection(manager: manager, actions: actions)
        let fleetRows = try XCTUnwrap(consumed.last)
        let expected = Array(saved[2 ... 6].reversed().map(\.id))

        XCTAssertEqual(fleetRows.kind, .ready)
        XCTAssertEqual(fleetRows.orderedIDs, expected)
        XCTAssertEqual(fleetRows.orderedIDs, chooserRows.orderedIDs)
        XCTAssertEqual(fleetRows.query, chooserRows.query)
        XCTAssertEqual(fleetRows.source, chooserRows.source)
        XCTAssertEqual(fleetRows.orderedIDs.count, 5)
        XCTAssertEqual(probe.openCount, 0)
        withExtendedLifetime((chooser, fleet)) {}
    }

    func testRecentRowFocusesWindowAlreadyShowingWorkspace() async throws {
        let state = await makeState(authorityBacked: true)
        let workspace = try await savedWorkspace(in: state, name: "Already open")
        let switched = await state.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: false)
        XCTAssertTrue(switched.didSwitch)
        let probe = OpenProbe(destination: state)
        probe.windows = [state]
        let actions = makeActions(probe)

        try await actions.openRecentWorkspace(workspace)

        XCTAssertEqual(probe.revealed, [state.windowID])
        XCTAssertEqual(probe.openCount, 0)
        XCTAssertEqual(state.workspaceManager.activeWorkspaceID, workspace.id)
    }

    func testRecentRowOpensNewWindowWhenNoneShowsWorkspace() async throws {
        let destination = await makeState(authorityBacked: true)
        let other = await makeState()
        let workspace = try await savedWorkspace(in: destination, name: "Recent")
        let fallback = destination.workspaceManager.getOrCreateSystemWorkspace()
        let otherWorkspace = other.workspaceManager.activeWorkspaceID
        for hasOtherWindow in [false, true] {
            _ = await destination.workspaceManager.requestWorkspaceSwitch(to: fallback, saveState: false)
            XCTAssertEqual(destination.workspaceManager.activeWorkspaceID, fallback.id)
            let probe = OpenProbe(destination: destination)
            probe.windows = hasOtherWindow ? [other] : []
            let actions = makeActions(probe)

            try await actions.openRecentWorkspace(workspace)

            XCTAssertEqual(probe.openCount, 1)
            XCTAssertTrue(probe.revealed.isEmpty)
            XCTAssertEqual(destination.workspaceManager.activeWorkspaceID, workspace.id)
            XCTAssertEqual(other.workspaceManager.activeWorkspaceID, otherWorkspace)
        }
    }

    func testAddWorkspaceUsesOpenFolderFlow() async throws {
        let destination = await makeState()
        let root = try XCTUnwrap(storageRoot).appendingPathComponent("Chosen Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = OpenProbe(destination: destination)
        probe.selection = root
        let actions = makeActions(probe)

        try await actions.addWorkspace()

        XCTAssertEqual(probe.pickerTitles, ["Open Folder"])
        XCTAssertEqual(probe.pickerMessages, ["Choose a folder to open. If it matches an existing workspace root, that workspace will reopen."])
        XCTAssertEqual(probe.openCount, 1)
        let opened = try XCTUnwrap(destination.workspaceManager.activeWorkspace)
        XCTAssertEqual(opened.repoPaths, [root.path])
        XCTAssertFalse(opened.isSystemWorkspace)
        XCTAssertFalse(opened.isEphemeral)
        let workspaceIDs = destination.workspaceManager.workspaces.map(\.id)
        probe.selection = nil

        try await actions.addWorkspace()

        XCTAssertEqual(probe.pickerTitles.count, 2)
        XCTAssertEqual(probe.openCount, 1, "Cancel must not request another workspace window")
        XCTAssertEqual(destination.workspaceManager.activeWorkspaceID, opened.id)
        XCTAssertEqual(destination.workspaceManager.workspaces.map(\.id), workspaceIDs)
    }

    func testFleetWorkspaceSectionOpensNothingUntilClicked() async {
        let state = await makeState()
        let probe = OpenProbe(destination: state)
        let actions = makeActions(probe)
        let registered = WindowStatesManager.shared.allWindows.map(\.windowID)
        let active = state.workspaceManager.activeWorkspaceID
        let host = hostSection(manager: state.workspaceManager, actions: actions)

        XCTAssertNil(host.window)
        XCTAssertEqual(probe.openCount, 0)
        XCTAssertTrue(probe.revealed.isEmpty)
        XCTAssertTrue(probe.pickerTitles.isEmpty)
        XCTAssertEqual(WindowStatesManager.shared.allWindows.map(\.windowID), registered)
        XCTAssertEqual(state.workspaceManager.activeWorkspaceID, active)
        withExtendedLifetime(host) {}
    }

    private func makeState(authorityBacked: Bool = false) async -> WindowState {
        let state = authorityBacked ? WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime) : WindowState()
        states.append(state)
        await state.workspaceManager.awaitInitialized()
        return state
    }

    private func savedWorkspace(in state: WindowState, name: String) async throws -> WorkspaceModel {
        let root = try XCTUnwrap(storageRoot).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let creation = try state.workspaceManager.createPersistentWorkspace(name: name, repoPaths: [root.path], savedInLibrary: true)
        return try await creation.publishedWorkspace()
    }

    private func hostSection(manager: WorkspaceManagerViewModel, actions: FleetManagerWorkspaceActions) -> NSHostingView<FleetManagerWorkspacesView<WorkspaceManagerViewModel>> {
        let host = NSHostingView(rootView: FleetManagerWorkspacesView(workspaceManager: manager, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func makeActions(_ probe: OpenProbe) -> FleetManagerWorkspaceActions {
        FleetManagerWorkspaceActions(
            windows: { probe.windows },
            openWindow: {
                probe.openCount += 1
                return probe.destination
            },
            revealWindow: { probe.revealed.append($0.windowID) },
            pickFolder: { title, message in
                probe.pickerTitles.append(title)
                probe.pickerMessages.append(message)
                return probe.selection
            }
        )
    }

    private final class OpenProbe {
        let destination: WindowState
        var windows: [WindowState] = []
        var openCount = 0
        var revealed: [Int] = []
        var selection: URL?
        var pickerTitles: [String] = []
        var pickerMessages: [String] = []

        init(destination: WindowState) {
            self.destination = destination
        }
    }
}

@MainActor
final class FleetManagerWindowTests: XCTestCase {
    private var previousAutoStart = false
    private var previousHUDActive: (() -> Bool)?
    private var previousOpenFleetManager: (() -> Void)?
    private var windows: [WindowState] = []
    private var nsWindows: [NSWindow] = []
    private var hudObserver: NSObjectProtocol?
    private var hudWindowIDs: [Int] = []

    override func setUp() async throws {
        try await super.setUp()
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let prefix = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        try XCTSkipUnless(WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path.hasPrefix(prefix))
        _ = NSApplication.shared
        previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        previousHUDActive = GlobalKeyboardShortcutsCoordinator.shared.isApplicationActive
        FleetParkingCoordinator.shared.resetForTesting()
        previousOpenFleetManager = FleetParkingCoordinator.shared.openFleetManager
        FleetParkingCoordinator.shared.setAutomaticBackstopDeliveryEnabledForTesting(false)
    }

    override func tearDown() async throws {
        if let hudObserver {
            NotificationCenter.default.removeObserver(hudObserver)
        }
        hudObserver = nil
        hudWindowIDs.removeAll()
        if let previousHUDActive {
            GlobalKeyboardShortcutsCoordinator.shared.isApplicationActive = previousHUDActive
        }
        FleetParkingCoordinator.shared.resetForTesting()
        if let previousOpenFleetManager {
            FleetParkingCoordinator.shared.openFleetManager = previousOpenFleetManager
        }
        for coordinator in coordinators {
            coordinator.windowForTesting?.close()
        }
        coordinators.removeAll()
        sources.removeAll()
        windowSnapshots.removeAll()
        for state in windows {
            if state.mcpServer.windowToolsEnabled { await state.mcpServer.stopServer() }
            state.attachWindow(nil)
            state.beginClose()
            await state.tearDown()
            WindowStatesManager.shared.unregisterWindowState(state)
        }
        for window in nsWindows {
            window.orderOut(nil)
        }
        windows.removeAll()
        nsWindows.removeAll()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        try await super.tearDown()
    }

    private func candidate(_ id: Int, focused: Bool = false, parked: Bool = false) -> FleetCommandWindowCandidate {
        FleetCommandWindowCandidate(windowID: id, isFocused: focused, isParked: parked)
    }

    private func makeLiveWindow(authorityBacked: Bool = false) async throws -> WindowState {
        let state = authorityBacked ? WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime) : WindowState()
        windows.append(state)
        WindowStatesManager.shared.registerWindowState(state)
        await state.workspaceManager.awaitInitialized()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        nsWindows.append(window)
        state.attachWindow(window)
        window.tabbingMode = .disallowed
        return state
    }

    private struct CenterProbe {
        var candidates: [FleetCommandWindowCandidate]
        var saved: [Int] = []
        var savedAndExited: [Int] = []
        var opened = 0
        var keyWindow: NSWindow?
    }

    private func makeCenter(_ probe: Box<CenterProbe>, center: NotificationCenter = NotificationCenter()) -> FleetCommandCenter {
        FleetCommandCenter(
            candidates: { probe.value.candidates },
            keyWindow: { probe.value.keyWindow },
            openFleetManager: { probe.value.opened += 1 },
            saveWorkspace: { probe.value.saved.append($0) },
            saveAndExit: { probe.value.savedAndExited.append($0) },
            notificationCenter: center
        )
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private final class RecordingWindow: NSWindow {
        var performCloseCount = 0
        override func performClose(_ sender: Any?) {
            performCloseCount += 1
        }
    }

    private func observeHUD() {
        hudObserver = NotificationCenter.default.addObserver(forName: .showAgentNavigationHUD, object: nil, queue: nil) { [weak self] note in
            if let id = note.userInfo?[AgentNavigationHUDNotificationUserInfoKey.windowID] as? Int {
                MainActor.assumeIsolated { self?.hudWindowIDs.append(id) }
            }
        }
    }

    func testTargetIsNilWhenOnlyParkedWindows() {
        XCTAssertNil(FleetCommandTargeting.target([candidate(1, parked: true), candidate(2, focused: true, parked: true)]))
        XCTAssertNil(FleetCommandTargeting.target([]))
    }

    func testTargetIsFocusedUnparkedWindow() {
        XCTAssertEqual(FleetCommandTargeting.target([candidate(1, focused: true), candidate(2)]), 1)
    }

    func testTargetIsMostRecentUnparkedWhenNoneFocused() {
        XCTAssertEqual(FleetCommandTargeting.target([candidate(1), candidate(2), candidate(3, parked: true)]), 2)
    }

    func testTargetSkipsFocusedButParkedWindow() {
        XCTAssertEqual(FleetCommandTargeting.target([candidate(1), candidate(2, focused: true, parked: true)]), 1)
    }

    func testTargetIsSingleUnparkedAlongsideParked() {
        XCTAssertEqual(FleetCommandTargeting.target([candidate(1, parked: true), candidate(2)]), 2)
    }

    func testPromptTargetRevealsMostRecentWhenAllParked() {
        XCTAssertEqual(
            FleetCommandTargeting.promptTarget([candidate(1, parked: true), candidate(2, parked: true)]),
            .revealParked(2)
        )
        XCTAssertNil(FleetCommandTargeting.promptTarget([]))
    }

    func testPromptTargetPrefersUnparkedOverParked() {
        XCTAssertEqual(
            FleetCommandTargeting.promptTarget([candidate(1), candidate(2, parked: true)]),
            .window(1)
        )
    }

    func testCommandDescriptorsListEachFleetCommandOnceWithBaseTitleShortcutAndPlacement() {
        let descriptors = FleetCommandCatalog.descriptors
        XCTAssertEqual(descriptors.count, 4)
        XCTAssertEqual(Set(descriptors.map(\.id)).count, 4)
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        XCTAssertEqual(byID[.saveWorkspace]?.title, "Save Workspace")
        XCTAssertEqual(byID[.saveWorkspace]?.shortcut, FleetCommandShortcut(key: "s", modifiers: .command))
        XCTAssertEqual(byID[.saveWorkspace]?.placement, .afterSaveItem)
        XCTAssertEqual(byID[.saveAndExit]?.title, "Save & Exit Workspace")
        XCTAssertEqual(byID[.saveAndExit]?.shortcut, FleetCommandShortcut(key: "s", modifiers: [.command, .shift]))
        XCTAssertEqual(byID[.saveAndExit]?.placement, .afterSaveItem)
        XCTAssertEqual(byID[.closeWindow]?.title, "Close Window")
        XCTAssertEqual(byID[.closeWindow]?.shortcut, FleetCommandShortcut(key: "w", modifiers: [.command, .shift]))
        XCTAssertEqual(byID[.closeWindow]?.placement, .beforeSaveItem)
        XCTAssertEqual(byID[.openFleetManager]?.title, "Fleet Manager")
        XCTAssertNil(byID[.openFleetManager]?.shortcut)
        XCTAssertEqual(byID[.openFleetManager]?.placement, .afterWindowArrangement)
    }

    func testDescriptorsForEachPlacementKeepDeclarationOrder() {
        let center = makeCenter(Box(CenterProbe(candidates: [])))
        XCTAssertEqual(center.descriptors(for: .afterSaveItem).map(\.id), [.saveWorkspace, .saveAndExit])
        XCTAssertEqual(center.descriptors(for: .beforeSaveItem).map(\.id), [.closeWindow])
        XCTAssertEqual(center.descriptors(for: .afterWindowArrangement).map(\.id), [.openFleetManager])
    }

    func testCenterHandlesEveryDescriptorID() async {
        let close = RecordingWindow()
        let probe = Box(CenterProbe(candidates: [candidate(7)], keyWindow: close))
        let center = makeCenter(probe)
        for descriptor in FleetCommandCatalog.descriptors {
            await center.perform(descriptor.id)
            XCTAssertTrue(center.isEnabled(descriptor.id))
        }
        XCTAssertEqual(probe.value.saved, [7])
        XCTAssertEqual(probe.value.savedAndExited, [7])
        XCTAssertEqual(probe.value.opened, 1)
        XCTAssertEqual(close.performCloseCount, 1)
        probe.value.candidates = [candidate(7, parked: true)]
        center.refresh()
        XCTAssertFalse(center.isEnabled(.saveWorkspace))
        XCTAssertFalse(center.isEnabled(.saveAndExit))
        XCTAssertTrue(center.isEnabled(.closeWindow))
        XCTAssertTrue(center.isEnabled(.openFleetManager))
    }

    func testSaveWorkspaceDisabledAndNoOpWhenOnlyParkedWindows() async {
        let probe = Box(CenterProbe(candidates: [candidate(1, parked: true), candidate(2, parked: true)]))
        let center = makeCenter(probe)
        XCTAssertFalse(center.isEnabled(.saveWorkspace))
        await center.perform(.saveWorkspace)
        XCTAssertEqual(probe.value.saved, [])
    }

    func testSaveAndExitDisabledAndNoOpWhenOnlyParkedWindows() async {
        let probe = Box(CenterProbe(candidates: [candidate(1, parked: true), candidate(2, parked: true)]))
        let center = makeCenter(probe)
        XCTAssertFalse(center.isEnabled(.saveAndExit))
        await center.perform(.saveAndExit)
        XCTAssertEqual(probe.value.savedAndExited, [])
    }

    func testSaveCommandsEnableAndTargetSingleUnparkedWindow() async {
        let probe = Box(CenterProbe(candidates: [candidate(1, parked: true), candidate(2)]))
        let center = makeCenter(probe)
        XCTAssertTrue(center.isEnabled(.saveWorkspace))
        XCTAssertTrue(center.isEnabled(.saveAndExit))
        await center.perform(.saveWorkspace)
        await center.perform(.saveAndExit)
        XCTAssertEqual(probe.value.saved, [2])
        XCTAssertEqual(probe.value.savedAndExited, [2])
    }

    func testCenterEnablementFlipsOnKeyChangeNotification() {
        let notificationCenter = NotificationCenter()
        let probe = Box(CenterProbe(candidates: [candidate(1, parked: true)]))
        let center = makeCenter(probe, center: notificationCenter)
        XCTAssertFalse(center.isEnabled(.saveWorkspace))
        probe.value.candidates = [candidate(1, parked: true), candidate(2)]
        notificationCenter.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        XCTAssertTrue(center.isEnabled(.saveWorkspace))
    }

    func testLiveCandidatesMarkSingleWindowParked() async throws {
        let state = try await makeLiveWindow()
        let manager = WindowStatesManager.shared
        let before = FleetCommandTargeting.liveCandidates(manager: manager, parked: [])
        XCTAssertEqual(before.last?.windowID, state.windowID)
        XCTAssertEqual(before.last?.isParked, false)
        let after = FleetCommandTargeting.liveCandidates(manager: manager, parked: [state.windowID])
        XCTAssertEqual(after.last?.isParked, true)
        XCTAssertNil(FleetCommandTargeting.target(after.filter { $0.windowID == state.windowID }))
    }

    func testHUDHandlerPostsNothingWhenOnlyWindowParked() async throws {
        let state = try await makeLiveWindow()
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: state.windowID))
        GlobalKeyboardShortcutsCoordinator.shared.isApplicationActive = { true }
        observeHUD()
        GlobalKeyboardShortcutsCoordinator.shared.showAgentNavigationHUD(
            mode: AgentNavigationHUDMode.allCases[0], eventTimestamp: nil, callbackAt: 0
        )
        XCTAssertFalse(hudWindowIDs.contains(state.windowID))
    }

    func testHUDHandlerPostsForSingleUnparkedWindow() async throws {
        let state = try await makeLiveWindow()
        GlobalKeyboardShortcutsCoordinator.shared.isApplicationActive = { true }
        observeHUD()
        GlobalKeyboardShortcutsCoordinator.shared.showAgentNavigationHUD(
            mode: AgentNavigationHUDMode.allCases[0], eventTimestamp: nil, callbackAt: 0
        )
        XCTAssertEqual(hudWindowIDs.count(where: { $0 == state.windowID }), 1)
    }

    @MainActor
    private final class FleetCountingSource: FleetRosterWindowSource {
        var starts = 0
        var stops = 0
        var snapshots: [FleetRosterWindowSnapshot] = []
        private let subject = PassthroughSubject<Void, Never>()
        func windows() -> [FleetRosterWindowSnapshot] {
            snapshots
        }

        var changes: AnyPublisher<Void, Never> {
            subject.eraseToAnyPublisher()
        }

        func start() {
            starts += 1
        }

        func stop() {
            stops += 1
        }
    }

    @MainActor
    private final class FleetManualTicker: FleetRosterTicker {
        func start(interval: TimeInterval, fire: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    @MainActor
    private final class FleetFakeParking: FleetParkingControlling {
        var parkedWindowIDs: Set<Int>
        var parkCalls: [Int] = []
        var unparkCalls: [Int] = []
        init(parked: Set<Int> = []) {
            parkedWindowIDs = parked
        }

        func park(windowID: Int, reason: FleetParkReason) -> Bool {
            parkCalls.append(windowID)
            parkedWindowIDs.insert(windowID)
            return true
        }

        func unpark(windowID: Int) {
            unparkCalls.append(windowID)
            parkedWindowIDs.remove(windowID)
        }
    }

    @MainActor
    private final class FleetFakeHandle: FleetWindowHandle {
        let windowID: Int
        var activeWorkspaceID: UUID?
        private var initialized = true
        var isInitialized: Bool {
            get {
                onIsInitializedRead?()
                return initialized
            }
            set { initialized = newValue }
        }

        var isClosing = false
        var isBackgrounded = false
        var sessions: [UUID: UUID]
        var calls: [String] = []
        var routes: [AgentSessionDeepLinkRoute] = []
        var result: AgentSessionRouteResult = .routed
        var runState: AgentSessionRunState = .idle
        var workspaceAtRoute: UUID?
        var onIsInitializedRead: (() -> Void)?
        private let parking: FleetFakeParking?

        init(windowID: Int, workspaceID: UUID, sessions: [UUID: UUID], parking: FleetFakeParking? = nil) {
            self.windowID = windowID
            activeWorkspaceID = workspaceID
            self.sessions = sessions
            self.parking = parking
        }

        func queueWorkspaceChange(to id: UUID) {
            Task { @MainActor in self.activeWorkspaceID = id }
        }

        func tabID(holding sessionID: UUID) -> UUID? {
            sessions[sessionID]
        }

        func restoreBackground() {
            calls.append("restore")
        }

        func reveal() {
            calls.append("reveal")
            parking?.unpark(windowID: windowID)
        }

        func route(_ route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult {
            calls.append("route")
            routes.append(route)
            workspaceAtRoute = activeWorkspaceID
            return result
        }
    }

    private var coordinators: [FleetManagerWindowCoordinator] = []
    private var sources: [FleetCountingSource] = []
    private var windowSnapshots: [FleetRosterWindowSnapshot] = []

    private func makeCoordinator(parking: FleetParkingControlling? = nil, present: @escaping (NSWindow) -> Void = { _ in }) -> FleetManagerWindowCoordinator {
        let coordinator = FleetManagerWindowCoordinator(
            makeSource: { [unowned self] in
                let source = FleetCountingSource()
                source.snapshots = windowSnapshots
                sources.append(source)
                return source
            },
            makeTicker: { FleetManualTicker() },
            parking: parking ?? FleetParkingCoordinator.shared,
            present: present
        )
        coordinators.append(coordinator)
        return coordinator
    }

    private func fleetWindowCount() -> Int {
        NSApp.windows.count { $0.identifier?.rawValue == FleetManagerWindowCoordinator.windowIdentifier }
    }

    private func makeActions(
        handle: FleetFakeHandle?,
        parking: FleetFakeParking? = nil,
        refreshes: Box<Int>? = nil,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> FleetManagerActions {
        let refreshes = refreshes ?? Box(0)
        return FleetManagerActions(
            handle: { id in handle?.windowID == id ? handle : nil },
            parking: parking ?? FleetFakeParking(),
            requestRefresh: { refreshes.value += 1 },
            notificationCenter: notificationCenter
        )
    }

    private func snapshot(window: Int, workspace: UUID = UUID()) -> FleetRosterWindowSnapshot {
        FleetRosterWindowSnapshot(
            windowID: window, workspaceID: workspace, workspaceName: "W\(window)",
            isSystemWorkspace: false, isClosing: false, sessions: []
        )
    }

    func testLaunchOpensFleetManagerInFront() {
        var presented: [NSWindow] = []
        let coordinator = makeCoordinator(present: { presented.append($0) })
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        XCTAssertNotNil(coordinator.windowForTesting)
        XCTAssertTrue(presented.last === coordinator.windowForTesting)
        XCTAssertEqual(presented.count, 1)
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        XCTAssertEqual(fleetWindowCount(), 1)
        XCTAssertEqual(sources.count, 1)
    }

    private final class LaunchWindowOrder {
        var frontToBack: [NSWindow] = []
        var events: [String] = []

        func makeKeyAndOrderFront(_ window: NSWindow, event: String) {
            frontToBack.removeAll { $0 === window }
            frontToBack.insert(window, at: 0)
            events.append(event)
        }
    }

    private func appearLaunchWorkspace(order: LaunchWindowOrder, name: String) -> WindowState {
        let state = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
        windows.append(state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        nsWindows.append(window)
        state.attachWindow(window)
        order.makeKeyAndOrderFront(window, event: "appear:\(name)")
        WindowStatesManager.shared.registerWindowState(state)
        return state
    }

    private func drainLaunchOrdering() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testFleetManagerStaysFrontAfterLaunchWindowsAppear() async throws {
        let manager = WindowStatesManager.shared
        let previousRestore = manager.autoRestoreWorkspacesEnabled
        manager.autoRestoreWorkspacesEnabled = true
        defer { manager.autoRestoreWorkspacesEnabled = previousRestore }
        let sessionURL = WindowSessionStore.sessionFileURL()
        let previousSession = try? Data(contentsOf: sessionURL)
        await manager.persistWindowSessionImmediately(reason: "fleetLaunchFixture")
        addTeardownBlock {
            await manager.persistWindowSessionImmediately(reason: "fleetLaunchFixtureCleanup")
            if let previousSession {
                try previousSession.write(to: sessionURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: sessionURL.path) {
                try FileManager.default.removeItem(at: sessionURL)
            }
        }
        let entry = WindowSessionEntry(
            windowKind: .standard, workspaceID: nil, workspaceName: nil,
            isSystemWorkspace: true, isEphemeral: false, primaryRepoPath: nil,
            lastFocused: false, workspaceInstanceNumber: nil
        )
        await WindowSessionDiskWriter(fileURL: sessionURL).writeImmediately(
            WindowSessionSnapshot(version: 4, windows: [entry, entry])
        )
        let order = LaunchWindowOrder()
        let settled = expectation(description: "Fleet ordered front after both restored windows appear")
        let coordinator = makeCoordinator(present: {
            order.makeKeyAndOrderFront($0, event: "fleet:key-front")
            if order.events.contains("appear:last") { settled.fulfill() }
        })

        manager.loadWindowRestoreSessionIfNeeded()
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        let fleet = try XCTUnwrap(coordinator.windowForTesting)
        coordinator.finishLaunchRestoration()
        let first = appearLaunchWorkspace(order: order, name: "first")
        await first.workspaceManager.awaitInitialized()
        await drainLaunchOrdering()
        XCTAssertTrue(manager.isInitialWindowRestorePending)
        XCTAssertEqual(order.events.count(where: { $0 == "fleet:key-front" }), 1)
        let last = appearLaunchWorkspace(order: order, name: "last")
        await fulfillment(of: [settled], timeout: 10)

        let firstWindow = try XCTUnwrap(first.nsWindow)
        let lastWindow = try XCTUnwrap(last.nsWindow)
        XCTAssertEqual(order.frontToBack.map(ObjectIdentifier.init), [fleet, lastWindow, firstWindow].map(ObjectIdentifier.init))
        let lastAppearance = try XCTUnwrap(order.events.lastIndex(of: "appear:last"))
        let finalFleetRequest = try XCTUnwrap(order.events.lastIndex(of: "fleet:key-front"))
        XCTAssertGreaterThan(finalFleetRequest, lastAppearance)
        XCTAssertEqual(order.events.suffix(from: lastAppearance + 1).count(where: { $0 == "fleet:key-front" }), 1)
        XCTAssertTrue(manager.allWindows.contains { $0 === first })
        XCTAssertTrue(manager.allWindows.contains { $0 === last })
        XCTAssertFalse(manager.allWindows.contains { $0.nsWindow === fleet })
    }

    func testUserActivatedWorkspaceWindowAfterLaunchComesFront() async throws {
        let order = LaunchWindowOrder()
        let coordinator = makeCoordinator(present: { order.makeKeyAndOrderFront($0, event: "fleet:key-front") })
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        coordinator.finishLaunchRestoration()
        let workspace = appearLaunchWorkspace(order: order, name: "workspace")
        await drainLaunchOrdering()
        let window = try XCTUnwrap(workspace.nsWindow)
        let fleet = try XCTUnwrap(coordinator.windowForTesting)

        order.makeKeyAndOrderFront(window, event: "user:key-front")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await drainLaunchOrdering()

        XCTAssertEqual(order.frontToBack.map(ObjectIdentifier.init), [window, fleet].map(ObjectIdentifier.init))
        XCTAssertEqual(order.events.last, "user:key-front")
    }

    func testLaunchWithNothingToRestoreOpensOnlyFleetManager() {
        let manager = WindowStatesManager.shared
        let previousRestore = manager.autoRestoreWorkspacesEnabled
        defer { manager.autoRestoreWorkspacesEnabled = previousRestore }
        let delegate: NSApplicationDelegate = AppDelegate()
        let coordinator = makeCoordinator()
        XCTAssertTrue(manager.allWindows.isEmpty)

        for restoreEnabled in [false, true] {
            manager.autoRestoreWorkspacesEnabled = restoreEnabled
            AppDelegate.configureFleetManagerAtLaunch(coordinator)
            let requestsDefaultWindow = delegate.applicationShouldOpenUntitledFile?(NSApplication.shared) ?? true

            XCTAssertFalse(requestsDefaultWindow, "Launch must not request a default workspace window; restore=\(restoreEnabled)")
            XCTAssertTrue(manager.allWindows.isEmpty)
            XCTAssertNotNil(coordinator.windowForTesting)
            XCTAssertEqual(fleetWindowCount(), 1)
        }
    }

    func testLaunchRestoresWorkspaceWindowsBehindFleet() async throws {
        let first = try await makeLiveWindow()
        let second = try await makeLiveWindow()
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: second.windowID, reason: .operator))
        let before = WindowStatesManager.shared.allWindows.map(\.windowID)
        let workspaces = [first, second].map(\.workspaceManager.activeWorkspaceID)
        var presented: [NSWindow] = []
        let coordinator = makeCoordinator(present: { presented.append($0) })
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        XCTAssertEqual(WindowStatesManager.shared.allWindows.map(\.windowID), before)
        XCTAssertEqual([first, second].map(\.workspaceManager.activeWorkspaceID), workspaces)
        XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: second.windowID))
        XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: first.windowID))
        XCTAssertEqual(presented.count, 1)
        XCTAssertTrue(presented.last === coordinator.windowForTesting)
    }

    func testLaunchFleetDoesNotChangeAllWindowsCount() {
        let before = WindowStatesManager.shared.allWindows.map(\.windowID)
        let coordinator = makeCoordinator()
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        AppDelegate.configureFleetManagerAtLaunch(coordinator)
        XCTAssertEqual(WindowStatesManager.shared.allWindows.map(\.windowID), before)
        XCTAssertNil(WindowStatesManager.shared.latestWindowState)
    }

    private func registerProgrammaticWindow(requestID: UUID?) {
        let state = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime, openRequestID: requestID)
        windows.append(state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        nsWindows.append(window)
        state.attachWindow(window)
        WindowStatesManager.shared.registerWindowState(state)
    }

    private func withFleetOnlyRouting(_ body: (WindowRoutingService, UUID, String) async throws -> Void) async throws {
        XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty)
        let previousPark = GlobalSettingsStore.shared.fleetParkAgentWindows()
        GlobalSettingsStore.shared.setFleetParkAgentWindows(false, commit: false)
        AppWindowOpener.shared.resetForTesting()
        AppWindowOpener.shared.installRequestAware { [unowned self] requestID in
            registerProgrammaticWindow(requestID: requestID)
        }
        let connectionID = UUID()
        let client = "FleetOnly-\(connectionID)"
        WorkspaceApprovalManager.shared.addAutoApproval(clientID: client, operation: .createWorkspace)
        let coordinator = makeCoordinator()
        coordinator.open()
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
        await service.prepareDomainTools()
        func cleanup() async {
            await ServerNetworkManager.shared.debugRemoveConnection(connectionID)
            WorkspaceApprovalManager.shared.removeAutoApproval(clientID: client, operation: .createWorkspace)
            AppWindowOpener.shared.resetForTesting()
            GlobalSettingsStore.shared.setFleetParkAgentWindows(previousPark, commit: false)
        }
        do {
            try await body(service, connectionID, client)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    private func callFleetRouting(_ service: WindowRoutingService, connectionID: UUID, client: String, toolName: String = "manage_workspaces", args: [String: Value]) async throws -> Value {
        let tools = await service.tools
        let tool = try XCTUnwrap(tools.first { $0.name == toolName })
        let metadata = MCPRequestMetadata(connectionID: connectionID, clientName: client, windowID: nil)
        let invocation = ToolInvocationContext.trustedLocal(toolName: toolName, metadata: metadata)
        return try await ServerNetworkManager.currentConnectionIDTaskLocal.withValue(connectionID) {
            try await MCPInvocationContextBridge.withInvocation(invocation) { try await tool(args) }
        }
    }

    func testMCPOpenWorkspaceWithOnlyFleetOpenCreatesWindow() async throws {
        let state = try await makeLiveWindow(authorityBacked: true)
        let name = "Fleet reopen \(UUID())"
        let creation = try state.workspaceManager.createPersistentWorkspace(name: name, repoPaths: [], savedInLibrary: true)
        let workspace = try await creation.publishedWorkspace()
        WindowStatesManager.shared.unregisterWindowState(state)
        try await withFleetOnlyRouting { service, connectionID, client in
            let response = try await self.callFleetRouting(service, connectionID: connectionID, client: client, args: [
                "action": .string("switch"), "workspace": .string(name), "open_in_new_window": .bool(true)
            ])
            XCTAssertEqual(response.objectValue?["status"]?.stringValue, "ok")
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertEqual(WindowStatesManager.shared.latestWindowState?.workspaceManager.activeWorkspaceID, workspace.id)
        }
    }

    func testMCPOpenWorkspaceBeforeAnyWorkspaceWindowAppeared() async throws {
        try await withFleetOnlyRouting { service, connectionID, client in
            let name = "Fleet first \(UUID())"
            let response = try await self.callFleetRouting(service, connectionID: connectionID, client: client, args: [
                "action": .string("create"), "name": .string(name), "open_in_new_window": .bool(true)
            ])
            XCTAssertEqual(response.objectValue?["status"]?.stringValue, "ok")
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertEqual(WindowStatesManager.shared.latestWindowState?.workspaceManager.activeWorkspace?.name, name)
        }
    }

    func testMCPCallNeedingExistingWindowStillErrorsWithNone() async throws {
        try await withFleetOnlyRouting { service, connectionID, client in
            do {
                _ = try await self.callFleetRouting(service, connectionID: connectionID, client: client, args: ["action": .string("list_tabs")])
                XCTFail("An existing-window call must not create a workspace window")
            } catch {
                XCTAssertFalse(String(describing: error).isEmpty)
            }
            XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty)
        }
    }

    func testSettingsCommandWithFleetKeyTargetsWorkspaceWindow() async throws {
        let first = try await makeLiveWindow()
        let second = try await makeLiveWindow()
        makeCoordinator().open()
        first.isCurrentlyFocused = true
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: first.windowID, reason: .operator))
        first.isCurrentlyFocused = true
        var targets: [Int] = []
        try await AppSettingsCommand.open(present: { targets.append($0.windowID)
            XCTAssertNil($1)
        })
        XCTAssertEqual(targets, [second.windowID])
        first.isCurrentlyFocused = false
        second.isCurrentlyFocused = true
        try await AppSettingsCommand.open(selectedTab: .mcp, present: { targets.append($0.windowID)
            XCTAssertEqual($1, .mcp)
        })
        XCTAssertEqual(targets, [second.windowID, second.windowID])
    }

    func testSettingsCommandWithNoWorkspaceWindowsOpensSettings() async throws {
        XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty)
        makeCoordinator().open()
        AppWindowOpener.shared.installRequestAware { [unowned self] requestID in
            registerProgrammaticWindow(requestID: requestID)
        }
        defer { AppWindowOpener.shared.resetForTesting() }
        var targets: [Int] = []
        try await AppSettingsCommand.open(present: { targets.append($0.windowID)
            XCTAssertNil($1)
        })
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first, WindowStatesManager.shared.latestWindowState?.windowID)
    }

    func testMCPBindContextCreateIfMissingWithOnlyFleetOpen() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FleetBind-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withFleetOnlyRouting { service, connectionID, client in
            let response = try await self.callFleetRouting(service, connectionID: connectionID, client: client, toolName: "bind_context", args: [
                "op": .string("bind"), "working_dirs": .array([.string(root.path)]), "create_if_missing": .bool(true)
            ])
            XCTAssertNotNil(response.objectValue?["binding"])
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, 1)
            XCTAssertEqual(WindowStatesManager.shared.latestWindowState?.workspaceManager.activeWorkspace?.repoPaths, [root.path])
        }
    }

    func testSettingsDeepLinkWithNoWorkspaceWindowsUsesCommandTarget() async throws {
        XCTAssertTrue(WindowStatesManager.shared.allWindows.isEmpty)
        makeCoordinator().open()
        AppWindowOpener.shared.installRequestAware { [unowned self] requestID in
            registerProgrammaticWindow(requestID: requestID)
        }
        defer { AppWindowOpener.shared.resetForTesting() }
        var targets: [Int] = []
        try await AppSettingsCommand.open(notification: Notification(name: .showMCPSettingsTab), selectedTab: .mcp, present: {
            targets.append($0.windowID)
            XCTAssertEqual($1, .mcp)
        })
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first, WindowStatesManager.shared.latestWindowState?.windowID)
    }

    func testFleetSettingsMenuDispatchesToApplicationCommandWithoutSceneTarget() throws {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = appMenu
        menu.addItem(applicationItem)
        let item = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        appMenu.addItem(item)
        var opens = 0
        let target = AppSettingsMenuTarget(open: { opens += 1 })
        AppSettingsCommand.installNativeMenuAction(in: menu, target: target)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(opens, 1)
    }

    func testOpenTwiceYieldsOneFleetManagerWindow() {
        let coordinator = makeCoordinator()
        coordinator.open()
        let first = coordinator.windowForTesting
        coordinator.open()
        XCTAssertNotNil(first)
        XCTAssertTrue(coordinator.windowForTesting === first)
        XCTAssertEqual(fleetWindowCount(), 1)
        XCTAssertEqual(sources.count, 1)
    }

    func testOpenDoesNotChangeAllWindowsCount() async throws {
        _ = try await makeLiveWindow()
        let before = WindowStatesManager.shared.allWindows.count
        let coordinator = makeCoordinator()
        coordinator.open()
        XCTAssertEqual(WindowStatesManager.shared.allWindows.count, before)
        coordinator.open()
        XCTAssertEqual(WindowStatesManager.shared.allWindows.count, before)
    }

    func testOpenStartsModelOnceAndCloseStopsIt() {
        let coordinator = makeCoordinator()
        coordinator.open()
        coordinator.open()
        XCTAssertEqual(sources.map(\.starts), [1])
        XCTAssertEqual(sources.map(\.stops), [0])
        coordinator.windowForTesting?.close()
        XCTAssertEqual(sources.map(\.stops), [1])
        XCTAssertNil(coordinator.windowForTesting)
        XCTAssertNil(coordinator.modelForTesting)
    }

    func testReopenAfterCloseBuildsFreshModelWithImmediateRoster() {
        let coordinator = makeCoordinator()
        coordinator.open()
        XCTAssertEqual(coordinator.modelForTesting?.roster.sections.count, 0)
        coordinator.windowForTesting?.close()
        windowSnapshots = [snapshot(window: 41)]
        coordinator.open()
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(coordinator.modelForTesting?.roster.sections.map(\.windowID), [41])
    }

    func testInstallWiresOpenFleetManagerClosureOnParkingCoordinator() {
        let parking = FleetParkingCoordinator()
        let coordinator = makeCoordinator(parking: parking)
        coordinator.install(into: parking)
        parking.openFleetManager()
        parking.openFleetManager()
        XCTAssertNotNil(coordinator.windowForTesting)
        XCTAssertEqual(fleetWindowCount(), 1)
    }

    func testUnboundMCPToolStillResolvesToOnlyRegisteredWindowWithFleetOpen() async throws {
        let state = try await makeLiveWindow()
        let manager = WindowStatesManager.shared
        let started = await state.mcpServer.startServer()
        XCTAssertTrue(started)
        XCTAssertTrue(state.mcpServer.windowToolsEnabled)
        let coordinator = makeCoordinator()
        coordinator.open()
        XCTAssertEqual(manager.windowCountAndMode().count, 1)
        XCTAssertFalse(manager.windowCountAndMode().isMultiWindowActive)
        XCTAssertTrue(manager.latestWindowState === state)
        XCTAssertTrue(manager.firstMCPEnabledWindow() === state)
        let resolution = try await AppDomainRuntimeComposition.shared.runtime.domainHost
            .resolveUniqueWindowTool(toolName: "get_file_tree")
        let scope = try XCTUnwrap(resolution).scope
        XCTAssertTrue(String(describing: scope).hasSuffix("window(id: \(state.windowID))"))
    }

    func testShowOnParkedWindowUnparksAndRoutesOnce() async {
        let parking = FleetFakeParking(parked: [3])
        let workspace = UUID(), session = UUID(), tab = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: workspace, sessions: [session: tab], parking: parking)
        let actions = makeActions(handle: handle, parking: parking)
        await actions.show(rowID: session, windowID: 3, workspaceID: workspace, sessionID: session)
        XCTAssertEqual(handle.calls, ["reveal", "route"])
        XCTAssertEqual(handle.routes, [AgentSessionDeepLinkRoute(windowID: 3, workspaceID: workspace, tabID: tab, sessionID: session, interactionID: nil)])
        XCTAssertFalse(parking.parkedWindowIDs.contains(3))
        XCTAssertNil(actions.staleMessage(for: session))
    }

    func testShowOnBackgroundedWindowRestoresThenRoutes() async {
        let workspace = UUID(), session = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: workspace, sessions: [session: UUID()])
        handle.isBackgrounded = true
        let actions = makeActions(handle: handle)
        await actions.show(rowID: session, windowID: 3, workspaceID: workspace, sessionID: session)
        XCTAssertEqual(handle.calls, ["restore", "reveal", "route"])
    }

    func testShowOnStaleRowOtherWorkspaceChangesNothing() async {
        let parking = FleetFakeParking(parked: [3])
        let session = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: UUID(), sessions: [session: UUID()], parking: parking)
        let actions = makeActions(handle: handle, parking: parking)
        let before = handle.activeWorkspaceID
        await actions.show(rowID: session, windowID: 3, workspaceID: UUID(), sessionID: session)
        XCTAssertEqual(handle.calls, [])
        XCTAssertEqual(parking.parkedWindowIDs, [3])
        XCTAssertEqual(handle.activeWorkspaceID, before)
        XCTAssertEqual(handle.runState, .idle)
    }

    func testShowOnStaleRowMissingSessionChangesNothing() async {
        let parking = FleetFakeParking(parked: [3])
        let workspace = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: workspace, sessions: [:], parking: parking)
        let actions = makeActions(handle: handle, parking: parking)
        await actions.show(rowID: UUID(), windowID: 3, workspaceID: workspace, sessionID: UUID())
        XCTAssertEqual(handle.calls, [])
        XCTAssertEqual(parking.parkedWindowIDs, [3])
        XCTAssertEqual(handle.runState, .idle)
    }

    func testShowOnUninitializedOrClosingWindowIsStaleAndCallsNothing() async {
        let workspace = UUID(), session = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: workspace, sessions: [session: UUID()])
        handle.isInitialized = false
        let actions = makeActions(handle: handle)
        await actions.show(rowID: session, windowID: 3, workspaceID: workspace, sessionID: session)
        XCTAssertEqual(handle.calls, [])
        handle.isInitialized = true
        handle.isClosing = true
        await actions.show(rowID: session, windowID: 3, workspaceID: workspace, sessionID: session)
        XCTAssertEqual(handle.calls, [])
        let missing = makeActions(handle: nil)
        await missing.show(rowID: session, windowID: 9, workspaceID: workspace, sessionID: session)
        XCTAssertNotNil(missing.staleMessage(for: session))
    }

    func testShowHasNoSuspensionBetweenPrecheckAndRoute() async {
        let workspace = UUID(), other = UUID(), session = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: workspace, sessions: [session: UUID()])
        handle.onIsInitializedRead = { handle.queueWorkspaceChange(to: other) }
        let actions = makeActions(handle: handle)
        await actions.show(rowID: session, windowID: 3, workspaceID: workspace, sessionID: session)
        XCTAssertEqual(handle.workspaceAtRoute, workspace)
        XCTAssertEqual(handle.calls, ["reveal", "route"])
    }

    func testLiveShowOnMatchingRowLeavesActiveWorkspaceUnchanged() async throws {
        let state = try await makeLiveWindow()
        let manager = state.workspaceManager
        let workspace = try XCTUnwrap(manager.activeWorkspaceID)
        let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspace })
        let tab = ComposeTabState(id: UUID())
        manager.workspaces[index].composeTabs.append(tab)
        manager.workspaces[index].activeComposeTabID = tab.id
        state.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index])
        let session = AgentModeViewModel.TabSession(tabID: tab.id)
        session.hasLoadedPersistedState = true
        session.runState = .idle
        state.agentModeViewModel.test_installLiveSession(session)
        let sessionID = UUID()
        XCTAssertNotNil(state.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
        // An installed binding admits operations only after restoration is authoritative.
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        var changes = 0
        let sink = manager.$activeWorkspaceID.dropFirst().sink { _ in changes += 1 }
        var reveals = 0
        state.test_beforePostActivationReveal = { reveals += 1 }
        defer { state.test_beforePostActivationReveal = nil }
        let handle = WindowStateFleetHandle(state: state)
        XCTAssertEqual(handle.tabID(holding: sessionID), tab.id)
        let refreshes = Box(0)
        let actions = FleetManagerActions(
            handle: { $0 == state.windowID ? handle : nil },
            parking: FleetParkingCoordinator.shared,
            requestRefresh: { refreshes.value += 1 },
            notificationCenter: NotificationCenter()
        )
        let rowID = UUID()
        await actions.show(rowID: rowID, windowID: state.windowID, workspaceID: workspace, sessionID: sessionID)
        sink.cancel()
        XCTAssertEqual(reveals, 1)
        XCTAssertNil(actions.staleMessage(for: rowID))
        XCTAssertEqual(refreshes.value, 0)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(manager.activeWorkspaceID, workspace)
        XCTAssertEqual(state.promptManager.activeComposeTabID, tab.id)
    }

    func testStaleShowRowShowsV6MessageAndRefreshes() async {
        let refreshes = Box(0)
        let session = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: UUID(), sessions: [:])
        let actions = makeActions(handle: handle, refreshes: refreshes)
        await actions.show(rowID: session, windowID: 3, workspaceID: UUID(), sessionID: session)
        XCTAssertEqual(actions.staleMessage(for: session), "This session is no longer in window 3")
        XCTAssertEqual(refreshes.value, 1)
    }

    func testShowRoutesNonRoutedResultAsStaleMessage() async {
        let refreshes = Box(0)
        let workspace = UUID(), session = UUID()
        let handle = FleetFakeHandle(windowID: 3, workspaceID: workspace, sessions: [session: UUID()])
        handle.result = .tabUnavailable
        let actions = makeActions(handle: handle, refreshes: refreshes)
        await actions.show(rowID: session, windowID: 3, workspaceID: workspace, sessionID: session)
        XCTAssertEqual(actions.staleMessage(for: session), "This session is no longer in window 3")
        XCTAssertEqual(refreshes.value, 1)
    }

    func testParkSectionParksThatWindowIDOnly() {
        let parking = FleetFakeParking()
        let refreshes = Box(0)
        let notificationCenter = NotificationCenter()
        var posted = 0
        let token = notificationCenter.addObserver(forName: FleetCommandCenter.refreshNotification, object: nil, queue: nil) { _ in posted += 1 }
        defer { notificationCenter.removeObserver(token) }
        let actions = makeActions(handle: nil, parking: parking, refreshes: refreshes, notificationCenter: notificationCenter)
        actions.park(windowID: 5)
        XCTAssertEqual(parking.parkCalls, [5])
        XCTAssertEqual(parking.unparkCalls, [])
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(posted, 1)
    }

    func testUnparkSectionUnparksThatWindowIDOnly() {
        let parking = FleetFakeParking(parked: [5, 6])
        let actions = makeActions(handle: nil, parking: parking)
        actions.unpark(windowID: 5)
        XCTAssertEqual(parking.unparkCalls, [5])
        XCTAssertEqual(parking.parkCalls, [])
        XCTAssertEqual(parking.parkedWindowIDs, [6])
    }

    func testUnparkOnBackgroundedWindowRestoresFirst() {
        let parking = FleetFakeParking(parked: [3])
        let handle = FleetFakeHandle(windowID: 3, workspaceID: UUID(), sessions: [:], parking: parking)
        handle.isBackgrounded = true
        let actions = makeActions(handle: handle, parking: parking)
        actions.unpark(windowID: 3)
        XCTAssertEqual(handle.calls, ["restore"])
        XCTAssertEqual(parking.unparkCalls, [3])
    }

    func testLiveHandleShowUnparksSingleLiveParkedWindow() async throws {
        let state = try await makeLiveWindow()
        let workspace = try XCTUnwrap(state.workspaceManager.activeWorkspaceID)
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: state.windowID))
        let handle = WindowStateFleetHandle(state: state)
        XCTAssertTrue(handle.isInitialized)
        XCTAssertFalse(handle.isClosing)
        XCTAssertEqual(handle.activeWorkspaceID, workspace)
        XCTAssertNil(handle.tabID(holding: UUID()))
        handle.reveal()
        XCTAssertFalse(FleetParkingCoordinator.shared.parkedWindowIDs.contains(state.windowID))
    }

    func testWindowMenuCommandOpensOrFocusesFleetManagerThroughCenter() async {
        let probe = Box(CenterProbe(candidates: []))
        let center = makeCenter(probe)

        await center.perform(.openFleetManager)

        XCTAssertEqual(probe.value.opened, 1)
    }

    func testDockMenuItemOpensOrFocusesFleetManager() throws {
        var events: [String] = []
        let controller = DockMenuController(
            activateApplication: { events.append("activate") },
            openFleetManager: { events.append("fleet") }
        )
        let item = try XCTUnwrap(controller.makeMenu().items.first { $0.title == "Fleet Manager" })

        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: nil))
        XCTAssertEqual(events, ["fleet", "activate"])
    }

    func testDockMenuKeepsNewWindowFirstAndAddsFleetManager() {
        let menu = DockMenuController().makeMenu()

        XCTAssertEqual(menu.items.map(\.title), ["New Window", "Fleet Manager"])
    }

    func testDockReopenWithOnlyParkedWindowsOpensFleetManagerThroughWiredClosure() {
        let parking = FleetParkingCoordinator()
        let coordinator = makeCoordinator(parking: parking)
        coordinator.install(into: parking)
        let inputs = FleetAppLifecycleInputs(
            backgroundModeHasWindow: false,
            fleetParkedCount: 1,
            visibleWindowCount: 0
        )

        XCTAssertTrue(FleetAppLifecycleDecision.handleReopen(
            inputs,
            restore: { XCTFail("unexpected restore") },
            openFleetManager: parking.openFleetManager
        ))
        XCTAssertNotNil(coordinator.windowForTesting)
        XCTAssertEqual(fleetWindowCount(), 1)
    }

    func testCloseWindowCommandClosesOnlyKeyFleetManagerWindow() async {
        let fleetManager = RecordingWindow()
        let parkedWorkspace = RecordingWindow()
        let center = makeCenter(Box(CenterProbe(
            candidates: [candidate(1, parked: true), candidate(2, parked: true)],
            keyWindow: fleetManager
        )))

        await center.perform(.closeWindow)

        XCTAssertEqual(fleetManager.performCloseCount, 1)
        XCTAssertEqual(parkedWorkspace.performCloseCount, 0)
    }

    func testCloseWindowCommandWithNoKeyWindowIsNoOp() async {
        let center = makeCenter(Box(CenterProbe(candidates: [])))

        await center.perform(.closeWindow)

        XCTAssertTrue(center.isEnabled(.closeWindow))
    }
}

@MainActor
final class FleetManagerActionTests: XCTestCase {
    private var root: URL?
    private var previousStorage: String?
    private var previousApproval: Any?
    private var previousCachedApproval: WorkspaceApprovalSettings?
    private var previousAutoStart = false
    private var settingsCaptured = false
    private var states: [WindowState] = []
    private var windows: [ActionRecordingWindow] = []
    private let clientID = "fleet-actions-\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        let sandbox = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let prefix = URL(fileURLWithPath: sandbox).resolvingSymlinksInPath().path + "/"
        guard WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path.hasPrefix(prefix),
              WindowStatesManager.shared.allWindows.isEmpty,
              WorkspaceApprovalManager.shared.pendingRequest == nil
        else { throw FixtureFailure.notIsolated }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FleetManagerActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = directory
        let defaults = UserDefaults.standard
        previousStorage = defaults.string(forKey: "GlobalCustomStorageURL")
        previousApproval = defaults.object(forKey: "workspace.approvalSettings")
        previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        settingsCaptured = true
        // The shared domain runtime's metadata path policy is fixed at composition, so per-test storage must live under its owned root.
        let ownedStorageParent = AppProfileLocations.current.applicationSupportRoot.appendingPathComponent("FleetRosterStorage-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: ownedStorageParent) }
        UserDefaults.standard.set(AppProfileLocations.current.customWorkspaceDirectory(selectedDirectory: ownedStorageParent).path, forKey: "GlobalCustomStorageURL")
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        FleetParkingCoordinator.shared.resetForTesting()
        FleetParkingCoordinator.shared.setAutomaticBackstopDeliveryEnabledForTesting(false)
        let approval = WorkspaceApprovalManager.shared
        guard !approval.settings.clientPolicies.keys.contains(where: { MCPClientIdentity.matches($0, clientID) }) else { throw FixtureFailure.notIsolated }
        previousCachedApproval = approval.settings
        approval.setAutoApproveAll(false)
        approval.setAutoApproveOperation(.deleteWorkspace, enabled: false)
        XCTAssertFalse(approval.settings.shouldAutoApprove(operation: .deleteWorkspace, clientID: clientID))
    }

    override func tearDown() async throws {
        if let pending = WorkspaceApprovalManager.shared.pendingRequest, pending.clientID == clientID {
            WorkspaceApprovalManager.shared.cancelPending(requestID: pending.id)
        }
        for state in states {
            state.workspaceManager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting(nil)
            if state.mcpServer.windowToolsEnabled { await state.mcpServer.stopServer() }
            state.attachWindow(nil)
            state.beginClose()
            await state.tearDown()
            WindowStatesManager.shared.unregisterWindowState(state)
        }
        for window in windows {
            window.orderOut(nil)
        }
        states.removeAll()
        windows.removeAll()
        FleetParkingCoordinator.shared.resetForTesting()
        await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
        if settingsCaptured {
            let approval = WorkspaceApprovalManager.shared
            if let previousCachedApproval {
                approval.removeAllAutoApprovals(for: clientID)
                approval.setAutoApproveAll(previousCachedApproval.autoApproveAll)
                approval.setAutoApproveOperation(.deleteWorkspace, enabled: previousCachedApproval.autoApproveOperations.contains(.deleteWorkspace))
                let cachedRestored = approvalSettingsMatch(approval.settings, previousCachedApproval)
                XCTAssertTrue(cachedRestored, "Cached approval settings and unrelated policies/timestamps must be restored exactly")
                print("FM06_FIXTURE approval-restored client=\(clientID) exactCached=\(cachedRestored) priorGlobal=\(previousCachedApproval.autoApproveAll) priorOperations=\(previousCachedApproval.autoApproveOperations.map(\.rawValue).sorted()) unrelatedPolicies=\(previousCachedApproval.clientPolicies.count)")
            }
            let defaults = UserDefaults.standard
            if let previousApproval {
                defaults.set(previousApproval, forKey: "workspace.approvalSettings")
                XCTAssertTrue((defaults.object(forKey: "workspace.approvalSettings") as? NSObject)?.isEqual(previousApproval) == true)
            } else {
                defaults.removeObject(forKey: "workspace.approvalSettings")
                XCTAssertNil(defaults.object(forKey: "workspace.approvalSettings"))
            }
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
            if let previousStorage { defaults.set(previousStorage, forKey: "GlobalCustomStorageURL") }
            else { defaults.removeObject(forKey: "GlobalCustomStorageURL") }
        }
        if let root { try FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    func testArchiveEligibilityComesFromRealSidebarConversationContent() async throws {
        let chat = try await makeChats(content: false)
        let vm = chat.state.agentModeViewModel
        XCTAssertFalse(vm.sidebarSessions(for: chat.state.promptManager.currentComposeTabs).first { $0.tabID == chat.target.tabID }?.canStash ?? true)
        XCTAssertFalse(vm.fleetSidebarCanStash(tabID: chat.target.tabID, sessionID: chat.targetID, workspaceID: chat.workspace.id, promptManager: chat.state.promptManager))
        let actions = makeActions(chat.state)
        XCTAssertFalse(actions.canArchive(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID))

        chat.target.appendItem(.user("Keep this chat", sequenceIndex: 0))
        vm.refreshDerivedTranscriptState(for: chat.target)
        vm.syncSidebarUIState(refresh: true)

        XCTAssertTrue(vm.sidebarSessions(for: chat.state.promptManager.currentComposeTabs).first { $0.tabID == chat.target.tabID }?.canStash == true)
        XCTAssertTrue(vm.fleetSidebarCanStash(tabID: chat.target.tabID, sessionID: chat.targetID, workspaceID: chat.workspace.id, promptManager: chat.state.promptManager))
        XCTAssertTrue(actions.canArchive(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID))
        XCTAssertFalse(vm.fleetSidebarCanStash(tabID: chat.target.tabID, sessionID: UUID(), workspaceID: chat.workspace.id, promptManager: chat.state.promptManager))
    }

    func testRealBridgeBuildsOnlyOneTabTargetsWithCommandRowPlacement() async throws {
        let chat = try await makeChats()
        var calls = 0
        for action in [AgentSidebarBulkActionKind.stash, .delete] {
            let admitted = await chat.state.agentModeViewModel.performFleetSidebarCommand(
                action, tabID: chat.target.tabID, sessionID: chat.targetID, workspaceID: chat.workspace.id,
                promptManager: chat.state.promptManager,
                sink: { kind, origin, placement, targets, prompt in
                    calls += 1
                    XCTAssertEqual(kind, action)
                    XCTAssertEqual(origin, .command)
                    XCTAssertEqual(placement, .row)
                    XCTAssertTrue(prompt === chat.state.promptManager)
                    XCTAssertEqual(targets.workspaceID, chat.workspace.id)
                    XCTAssertEqual(targets.stashTabIDs, action == .stash ? [chat.target.tabID] : [])
                    XCTAssertEqual(targets.activeDeleteTabIDs, action == .delete ? [chat.target.tabID] : [])
                    XCTAssertTrue(targets.archivedDeleteTargets.isEmpty)
                    XCTAssertTrue(targets.pinTabIDs.isEmpty)
                    XCTAssertTrue(targets.unpinTabIDs.isEmpty)
                }
            )
            XCTAssertTrue(admitted)
        }
        XCTAssertEqual(calls, 2)
        assertBothTabsUnchanged(chat)
    }

    func testArchiveDefaultSinkActuallyStashesTargetAndPreservesPeer() async throws {
        let chat = try await makeChats()
        let actions = makeActions(chat.state)
        var placements: [AgentSidebarCommandProgressPlacement?] = []
        let observation = chat.state.agentModeViewModel.ui.sessionSidebar.$selectionState.sink {
            if let operation = $0.inFlightAction { placements.append(operation.commandProgressPlacement) }
        }
        defer { observation.cancel() }

        await actions.archive(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID)

        XCTAssertFalse(chat.state.promptManager.currentComposeTabs.contains { $0.id == chat.target.tabID })
        XCTAssertTrue(chat.state.workspaceManager.activeWorkspace?.stashedTabs.contains { $0.tab.id == chat.target.tabID } == true)
        XCTAssertEqual(chat.state.promptManager.currentComposeTabs.first { $0.id == chat.peer.tabID }, chat.peerTab)
        XCTAssertEqual(chat.peer.runState, .completed)
        XCTAssertFalse(placements.isEmpty)
        XCTAssertTrue(placements.allSatisfy { $0 == .row })
    }

    func testDeleteChatPresentationCancelHasNoMutation() async throws {
        let chat = try await makeChats()
        let actions = makeActions(chat.state)
        actions.requestDeleteChat(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID)
        XCTAssertEqual(actions.confirmation?.title, "Delete chat?")
        XCTAssertEqual(actions.confirmation?.message, "This permanently deletes this chat.")
        XCTAssertFalse(actions.isDeletionInFlight)

        actions.cancelDeletion()
        await actions.confirmDeletion()

        XCTAssertNil(actions.confirmation)
        assertBothTabsUnchanged(chat)
    }

    func testDeleteChatDefaultSinkActuallyDeletesTargetAndPreservesPeer() async throws {
        let chat = try await makeChats()
        let actions = makeActions(chat.state)
        var placements: [AgentSidebarCommandProgressPlacement?] = []
        let observation = chat.state.agentModeViewModel.ui.sessionSidebar.$selectionState.sink {
            if let operation = $0.inFlightAction { placements.append(operation.commandProgressPlacement) }
        }
        defer { observation.cancel() }
        actions.requestDeleteChat(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID)

        await actions.confirmDeletion()

        XCTAssertFalse(chat.state.promptManager.currentComposeTabs.contains { $0.id == chat.target.tabID })
        XCTAssertFalse(chat.state.workspaceManager.activeWorkspace?.stashedTabs.contains { $0.tab.id == chat.target.tabID } == true)
        XCTAssertEqual(chat.state.promptManager.currentComposeTabs.first { $0.id == chat.peer.tabID }, chat.peerTab)
        XCTAssertEqual(chat.peer.runState, .completed)
        XCTAssertFalse(placements.isEmpty)
        XCTAssertTrue(placements.allSatisfy { $0 == .row })
    }

    func testChatConfirmationRevalidatesSessionIdentityInsteadOfDeletingReplacement() async throws {
        let chat = try await makeChats()
        let actions = makeActions(chat.state)
        actions.requestDeleteChat(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID)
        let replacementID = UUID()
        _ = try XCTUnwrap(chat.state.agentModeViewModel.test_installPersistentSessionBinding(sessionID: replacementID, on: chat.target))
        // An installed binding admits operations only after restoration is authoritative.
        chat.target.recordRestorationAuthoritative(.persistedPayloadApplied)

        await actions.confirmDeletion()

        XCTAssertTrue(chat.state.promptManager.currentComposeTabs.contains { $0.id == chat.target.tabID })
        XCTAssertEqual(chat.target.activeAgentSessionID, replacementID)
        XCTAssertEqual(chat.state.promptManager.currentComposeTabs.first { $0.id == chat.peer.tabID }, chat.peerTab)
        XCTAssertEqual(actions.staleMessage(for: chat.targetID), "This session is no longer in window \(chat.state.windowID)")
    }

    func testRealBridgeRefusesWorkspaceMismatchSelectionAndMutationInFlight() async throws {
        let chat = try await makeChats()
        let vm = chat.state.agentModeViewModel
        let store = vm.ui.sessionSidebar
        let identity = AgentSidebarSelectionIdentity.active(tabID: chat.target.tabID)
        var calls = 0
        for refusal in ["workspace", "selection", "mutation"] {
            store.clearSelection()
            var workspaceID = chat.workspace.id
            var token: UUID?
            if refusal == "workspace" { workspaceID = UUID() }
            if refusal == "selection" {
                _ = store.handleSelectionGesture(.toggle, identity: identity, renderedOrder: [identity], workspaceID: workspaceID)
                XCTAssertTrue(store.selectionState.showsSelectionPresentation)
            }
            if refusal == "mutation" {
                token = try XCTUnwrap(store.beginBulkAction(kind: .delete, origin: .command, presentationTargets: [identity], commandProgressPlacement: .row, workspaceID: workspaceID))
                XCTAssertTrue(store.selectionState.isMutationInFlight)
            }
            XCTAssertFalse(vm.canPerformDirectSidebarCommand(workspaceID: workspaceID), refusal)
            for action in [AgentSidebarBulkActionKind.stash, .delete] {
                let admitted = await vm.performFleetSidebarCommand(
                    action, tabID: chat.target.tabID, sessionID: chat.targetID, workspaceID: workspaceID,
                    promptManager: chat.state.promptManager,
                    sink: { _, _, _, _, _ in calls += 1 }
                )
                XCTAssertFalse(admitted, refusal)
                _ = await vm.performFleetSidebarCommand(action, tabID: chat.target.tabID, sessionID: chat.targetID, workspaceID: workspaceID, promptManager: chat.state.promptManager)
            }
            assertBothTabsUnchanged(chat)
            if let token { store.finishBulkAction(token: token, workspaceID: workspaceID, notice: nil) }
        }
        XCTAssertEqual(calls, 0)
    }

    func testArchiveWithoutConversationAndStaleBridgeTargetsDoNothing() async throws {
        let chat = try await makeChats(content: false)
        let vm = chat.state.agentModeViewModel
        let archive = await vm.performFleetSidebarCommand(.stash, tabID: chat.target.tabID, sessionID: chat.targetID, workspaceID: chat.workspace.id, promptManager: chat.state.promptManager)
        let staleDelete = await vm.performFleetSidebarCommand(.delete, tabID: chat.target.tabID, sessionID: UUID(), workspaceID: chat.workspace.id, promptManager: chat.state.promptManager)
        XCTAssertFalse(archive)
        XCTAssertFalse(staleDelete)
        assertBothTabsUnchanged(chat)
    }

    func testWorkspaceConfirmationPreservesFullWarningAndPositiveActivityCounts() {
        let probe = DeletionProbe()
        let actions = workspaceActions(probe)
        actions.requestDeleteWorkspace(section: section(probe, running: 2, waiting: 1))
        XCTAssertEqual(actions.confirmation?.title, "Delete workspace?")
        XCTAssertEqual(actions.confirmation?.message, "This will delete \"Target\" and its saved tabs and session history, including pinned tabs. Running work will be stopped and window 7 closes. Your project folders are kept.\n2 running, 1 waiting sessions.")
        actions.cancelDeletion()
        actions.requestDeleteWorkspace(section: section(probe))
        XCTAssertEqual(actions.confirmation?.message, "This will delete \"Target\" and its saved tabs and session history, including pinned tabs. Running work will be stopped and window 7 closes. Your project folders are kept.")
    }

    func testWorkspaceInitialDuplicateRefusalUsesExactMCPMessage() async {
        let probe = DeletionProbe()
        probe.other = FakeDeletionTarget(windowID: 8, workspace: probe.workspace, log: probe.log)
        let actions = workspaceActions(probe)
        actions.requestDeleteWorkspace(section: section(probe))
        await actions.confirmDeletion()
        XCTAssertEqual(actions.deletionError, "Workspace 'Target' is active in multiple windows: 7, 8. Close those windows or switch them away before deleting.")
        XCTAssertEqual(probe.log.events, [])
        XCTAssertEqual(probe.parked, [7])
    }

    func testWorkspaceCancelBeforeAdmissionDoesNothing() async {
        let probe = DeletionProbe()
        let actions = workspaceActions(probe)
        actions.requestDeleteWorkspace(section: section(probe))
        actions.cancelDeletion()
        await actions.confirmDeletion()
        XCTAssertEqual(probe.log.events, [])
        XCTAssertEqual(probe.target.deletionWorkspaceID, probe.workspace.id)
        XCTAssertEqual(probe.parked, [7])
        XCTAssertNil(actions.confirmation)
    }

    func testRootConfirmationAndFailureSurviveRosterRemovalAndRepeatedConfirm() async {
        let probe = DeletionProbe()
        let entered = expectation(description: "delete suspended")
        let gate = SuspensionGate(entered: entered)
        probe.target.deleteEffect = { await gate.pause() }
        probe.target.deleteResult = false
        let source = ActionRosterSource(snapshot: snapshot(probe))
        let model = FleetRosterModel(source: source, ticker: ActionTicker())
        model.start()
        defer { model.stop()
            gate.release()
        }
        let actions = workspaceActions(probe)
        actions.requestDeleteWorkspace(section: section(probe))
        let first = Task { await actions.confirmDeletion() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(actions.isDeletionInFlight)
        XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7", "delete:start"])
        let removed = expectation(description: "roster section removed")
        let observation = model.$roster.dropFirst().filter(\.sections.isEmpty).prefix(1).sink { _ in removed.fulfill() }
        source.snapshot.isSystemWorkspace = true
        source.changed.send()
        await fulfillment(of: [removed], timeout: 5)
        observation.cancel()
        XCTAssertTrue(model.roster.sections.isEmpty)
        XCTAssertEqual(actions.confirmation?.workspaceID, probe.workspace.id)
        XCTAssertEqual(actions.confirmation?.windowID, 7)
        await actions.confirmDeletion()
        actions.cancelDeletion()
        XCTAssertTrue(actions.isDeletionInFlight)
        XCTAssertNotNil(actions.confirmation)
        XCTAssertEqual(probe.log.events.count(where: { $0 == "delete:start" }), 1)

        gate.release()
        await first.value

        XCTAssertFalse(actions.isDeletionInFlight)
        XCTAssertNotNil(actions.confirmation)
        XCTAssertEqual(actions.deletionError, "Workspace 'Target' could not be deleted. Window 7 remains open on the system workspace.")
        XCTAssertFalse(probe.log.events.contains("close:7"))
    }

    func testRealOwnerAwaitsDeleteThenClosesOriginalWithWorkspaceDeleteAuthorization() async {
        let probe = DeletionProbe()
        let entered = expectation(description: "awaited delete")
        let gate = SuspensionGate(entered: entered)
        probe.target.deleteEffect = { await gate.pause() }
        let owner = probe.owner()
        let task = Task { await owner.execute() }
        defer { gate.release() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7", "delete:start"])
        XCTAssertEqual(probe.target.deletionWorkspaceID, probe.target.fallback.id)
        XCTAssertTrue(probe.authorizations.isEmpty)

        gate.release()
        let result = await task.value

        guard case .closeRequested(windowID: 7) = result else { return XCTFail("Expected committed close, got \(result)") }
        XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7", "delete:start", "delete:end", "close:7"])
        XCTAssertEqual(probe.target.deletedIDs, [probe.workspace.id])
        XCTAssertEqual(probe.authorizations.count, 1)
        XCTAssertEqual(probe.authorizations.first?.source, .workspaceDelete)
        XCTAssertEqual(probe.authorizations.first?.bypassConfirmation, true)
        XCTAssertEqual(probe.authorizations.first?.bypassBackgroundPreservation, true)
        XCTAssertEqual(WorkspaceWindowDeletion.closeAuthorization(), probe.authorizations.first)
    }

    func testRealOwnerUnparkedSuccessDoesNotRequestUnpark() async {
        let probe = DeletionProbe()
        probe.parked = []
        let result = await probe.owner().execute()
        guard case .closeRequested(windowID: 7) = result else { return XCTFail("Expected close") }
        XCTAssertEqual(probe.log.events, ["switch:false", "delete:start", "delete:end", "close:7"])
    }

    func testBothNonSwitchedResultsBeforeCancellationLeaveLiteralStateUnchanged() async {
        for switchResult in [WorkspaceSwitchResult.cancelled("Declined"), .blocked("Busy")] {
            let probe = DeletionProbe()
            probe.target.switchResult = switchResult
            let actions = workspaceActions(probe)
            actions.requestDeleteWorkspace(section: section(probe))
            await actions.confirmDeletion()
            XCTAssertEqual(actions.deletionError, switchResult.message)
            XCTAssertEqual(probe.target.runStates, [.running, .waitingForQuestion])
            XCTAssertEqual(probe.target.deletionWorkspaceID, probe.workspace.id)
            XCTAssertEqual(probe.parked, [7])
            XCTAssertEqual(probe.log.events, ["switch:false"])
            XCTAssertTrue(probe.target.deletedIDs.isEmpty)
            XCTAssertTrue(probe.authorizations.isEmpty)
        }
    }

    func testBothNonSwitchedResultsAfterSwitchOwnedCancellationPreserveCancellationOnly() async {
        for switchResult in [WorkspaceSwitchResult.cancelled("Cancelled while settling"), .blocked("Chat still busy")] {
            let probe = DeletionProbe()
            probe.target.switchResult = switchResult
            probe.target.switchEffect = { probe.target.runStates = [.cancelled, .cancelled] }
            let actions = workspaceActions(probe)
            actions.requestDeleteWorkspace(section: section(probe))
            await actions.confirmDeletion()
            XCTAssertEqual(actions.deletionError, switchResult.message)
            XCTAssertEqual(probe.target.runStates, [.cancelled, .cancelled])
            XCTAssertEqual(probe.target.deletionWorkspaceID, probe.workspace.id)
            XCTAssertEqual(probe.parked, [7])
            XCTAssertEqual(probe.log.events, ["switch:false"])
            XCTAssertTrue(probe.target.deletedIDs.isEmpty)
            XCTAssertTrue(probe.authorizations.isEmpty)
        }
    }

    func testFalseDeleteAfterSwitchUnparksButNeverCloses() async {
        let probe = DeletionProbe()
        probe.target.deleteResult = false
        let result = await probe.owner().execute()
        guard case let .deleteFailed(message) = result else { return XCTFail("Expected delete failure") }
        XCTAssertEqual(message, "Workspace 'Target' could not be deleted. Window 7 remains open on the system workspace.")
        XCTAssertEqual(probe.target.deletionWorkspaceID, probe.target.fallback.id)
        XCTAssertEqual(probe.parked, [])
        XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7", "delete:start", "delete:end"])
        XCTAssertTrue(probe.authorizations.isEmpty)
    }

    func testCloseFailureIsCommittedPartialSuccessAndDoesNotReplayDelete() async {
        let probe = DeletionProbe()
        let failure = NSError(domain: "FleetClose", code: 41, userInfo: [NSLocalizedDescriptionKey: "Close request refused"])
        probe.closeError = failure
        let result = await probe.owner().execute()
        guard case let .closeFailed(error) = result else { return XCTFail("Expected close failure after commit") }
        XCTAssertEqual(error as NSError, failure)
        XCTAssertEqual(probe.target.deletedIDs, [probe.workspace.id])
        XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7", "delete:start", "delete:end", "close:7"])
    }

    func testOriginalRegistrationWorkspaceAndClosingAreCheckedBeforeSwitch() async {
        for change in ["registration", "workspace", "closing"] {
            let probe = DeletionProbe()
            let owner = probe.owner()
            if change == "registration" { probe.registered = FakeDeletionTarget(windowID: 7, workspace: probe.workspace, log: probe.log) }
            if change == "workspace" { probe.target.deletionWorkspaceID = UUID() }
            if change == "closing" { probe.target.isClosing = true }
            let result = await owner.execute()
            guard case .targetChanged = result else { XCTFail("Expected stale original: \(change)")
                continue
            }
            XCTAssertEqual(probe.log.events, [])
            XCTAssertEqual(probe.parked, [7])
        }
    }

    func testDuplicateArrivingDuringSwitchUnparksOriginalBeforeRefusingDeletion() async {
        let probe = DeletionProbe()
        let entered = expectation(description: "switch suspended")
        let gate = SuspensionGate(entered: entered)
        probe.target.switchEffect = { await gate.pause() }
        let task = Task { await probe.owner().execute() }
        defer { gate.release() }
        await fulfillment(of: [entered], timeout: 5)
        probe.other = FakeDeletionTarget(windowID: 8, workspace: probe.workspace, log: probe.log)
        gate.release()
        let result = await task.value
        guard case let .targetChanged(message) = result else { return XCTFail("Post-switch duplicate is a failed outcome, never success") }
        XCTAssertTrue(message.contains("not deleted"))
        XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7"])
        XCTAssertEqual(probe.parked, [])
        XCTAssertEqual(probe.target.deletionWorkspaceID, probe.target.fallback.id)
        XCTAssertEqual(probe.other?.deletionWorkspaceID, probe.workspace.id)
        XCTAssertTrue(probe.target.deletedIDs.isEmpty)
        XCTAssertTrue(probe.authorizations.isEmpty)
    }

    func testChangedRegistrationOrFallbackAfterSwitchNeverActsOnReplacement() async {
        for change in ["registration", "fallback"] {
            let probe = DeletionProbe()
            let entered = expectation(description: "switch \(change) suspended")
            let gate = SuspensionGate(entered: entered)
            probe.target.switchEffect = { await gate.pause() }
            let task = Task { await probe.owner().execute() }
            await fulfillment(of: [entered], timeout: 5)
            let replacement = FakeDeletionTarget(windowID: 7, workspace: probe.workspace, log: probe.log)
            if change == "registration" { probe.registered = replacement }
            else { probe.target.workspaceAfterSwitch = UUID() }
            gate.release()
            let result = await task.value
            guard case .targetChanged = result else { XCTFail("Expected changed \(change)")
                continue
            }
            XCTAssertEqual(probe.log.events, ["switch:false"])
            XCTAssertEqual(probe.parked, [7])
            XCTAssertTrue(probe.target.deletedIDs.isEmpty)
            XCTAssertTrue(replacement.deletedIDs.isEmpty)
            XCTAssertTrue(probe.authorizations.isEmpty)
        }
    }

    func testRetargetOrCloseDuringAwaitedDeleteReportsCommitWithoutClosingChangedTarget() async {
        for change in ["registration", "workspace", "closing"] {
            let probe = DeletionProbe()
            let entered = expectation(description: "delete \(change) suspended")
            let gate = SuspensionGate(entered: entered)
            probe.target.deleteEffect = { await gate.pause() }
            let task = Task { await probe.owner().execute() }
            await fulfillment(of: [entered], timeout: 5)
            if change == "registration" { probe.registered = FakeDeletionTarget(windowID: 7, workspace: probe.workspace, log: probe.log) }
            if change == "workspace" { probe.target.deletionWorkspaceID = UUID() }
            if change == "closing" { probe.target.isClosing = true }
            gate.release()
            let result = await task.value
            guard case let .deletionCommittedWithoutClose(message) = result else { XCTFail("Expected committed deletion: \(change)")
                continue
            }
            XCTAssertTrue(message.contains("deleted"))
            XCTAssertTrue(message.contains("not closed"))
            XCTAssertEqual(probe.target.deletedIDs, [probe.workspace.id])
            XCTAssertEqual(probe.log.events, ["switch:false", "unpark:7", "delete:start", "delete:end"])
            XCTAssertTrue(probe.authorizations.isEmpty)
        }
    }

    func testProductionAdapterDeletesBeforeCloseThenProductionUnregistrationPreservesPeer() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        let peer = try await makeChats(name: "Peer")
        peer.target.runState = .running
        peer.peer.runState = .waitingForApproval
        XCTAssertEqual(peer.target.runState, .running)
        XCTAssertEqual(peer.peer.runState, .waitingForApproval)
        let peerRunStates = peer.state.agentModeViewModel.sessions.mapValues(\.runState)
        XCTAssertEqual(peerRunStates, [peer.target.tabID: .running, peer.peer.tabID: .waitingForApproval])
        let targetWindow = try XCTUnwrap(windows.first)
        let peerWindow = try XCTUnwrap(windows.last)
        var phases: [WorkspaceSwitchPhase] = []
        target.workspaceManager.setWorkspaceSwitchPhaseDidChangeHandlerForTesting { phases.append($0) }
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: target.windowID))

        let result = await WorkspaceWindowDeletion(target: target, workspace: workspace).execute()

        guard case let .closeRequested(windowID) = result else { return XCTFail("Expected production-adapter success: \(result)") }
        XCTAssertEqual(windowID, target.windowID)
        XCTAssertTrue(target.workspaceManager.activeWorkspace?.isSystemWorkspace == true)
        XCTAssertFalse(phases.isEmpty)
        XCTAssertFalse(phases.contains(.savingCurrentWorkspace))
        XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: target.windowID))
        XCTAssertFalse(target.workspaceManager.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(targetWindow.performCloseCount, 1)
        XCTAssertEqual(peerWindow.performCloseCount, 0)
        XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === target })
        XCTAssertEqual(peer.state.agentModeViewModel.sessions.mapValues(\.runState), peerRunStates)

        // Close-request evidence ends above; onDisappear delivery is FM-05's live boundary.
        WindowStatesManager.shared.unregisterWindowState(target)

        XCTAssertFalse(WindowStatesManager.shared.allWindows.contains { $0.windowID == target.windowID })
        XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === peer.state })
        XCTAssertEqual(peer.state.agentModeViewModel.sessions.mapValues(\.runState), peerRunStates)
    }

    func testActualMCPDefaultExecutorDeletesUnparksAndReturnsOnlyTargetClosedWindowID() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        let peer = try await makeChats(name: "Peer")
        peer.target.runState = .running
        peer.peer.runState = .waitingForApproval
        XCTAssertEqual(peer.target.runState, .running)
        XCTAssertEqual(peer.peer.runState, .waitingForApproval)
        let before = peer.state.agentModeViewModel.sessions.mapValues(\.runState)
        XCTAssertEqual(before, [peer.target.tabID: .running, peer.peer.tabID: .waitingForApproval])
        WorkspaceApprovalManager.shared.addAutoApproval(clientID: clientID, operation: .deleteWorkspace)
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: target.windowID))
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)

        let response = try await callDelete(service, target: target, workspace: workspace.id.uuidString)

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.closed, target.windowID)
        XCTAssertFalse(target.workspaceManager.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(target.workspaceManager.activeWorkspace?.isSystemWorkspace == true)
        XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: target.windowID))
        XCTAssertEqual(windows.first?.performCloseCount, 1)
        XCTAssertEqual(windows.last?.performCloseCount, 0)
        XCTAssertEqual(peer.state.agentModeViewModel.sessions.mapValues(\.runState), before)
    }

    func testActualMCPPreflightPreservesMissingParameterUnknownWindowAndInactiveWorkspaceErrors() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        var executions = 0
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared, deletionExecutor: { _, _ in
            executions += 1
            return .closeRequested(windowID: target.windowID)
        })
        do {
            _ = try await callDelete(service, target: target, workspace: nil)
            XCTFail("Missing workspace must fail")
        } catch { assertMCPError(error, kind: "invalidParams", message: "Missing required 'workspace' parameter (UUID or name) for 'delete' action.") }
        do {
            _ = try await callDelete(service, target: target, workspace: workspace.id.uuidString, windowID: -42)
            XCTFail("Unknown window must fail")
        } catch { assertMCPError(error, kind: "invalidParams", message: "Unknown window_id -42. Valid window IDs: \(target.windowID)") }
        let fallback = target.workspaceManager.getOrCreateSystemWorkspace()
        let switched = await target.workspaceManager.requestWorkspaceSwitch(to: fallback, saveState: false)
        XCTAssertTrue(switched.didSwitch)
        do {
            _ = try await callDelete(service, target: target, workspace: workspace.id.uuidString)
            XCTFail("Inactive target must fail")
        } catch { assertMCPError(error, kind: "invalidParams", message: "close_window requires the workspace to be active in the target window. Workspace 'Target' is not active in any window.") }
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(windows.first?.performCloseCount, 0)
    }

    func testActualMCPDuplicatePreflightPreservesExactErrorWithoutExecutor() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        let (peer, _) = try await makeState(name: "Peer")
        peer.workspaceManager.reloadWorkspacesFromDisk()
        let switched = await peer.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: false)
        XCTAssertTrue(switched.didSwitch)
        var executions = 0
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared, deletionExecutor: { _, _ in
            executions += 1
            return .closeRequested(windowID: target.windowID)
        })
        do {
            _ = try await callDelete(service, target: target, workspace: workspace.id.uuidString)
            XCTFail("Duplicate workspace must fail")
        } catch {
            let ids = [target.windowID, peer.windowID].sorted().map(String.init).joined(separator: ", ")
            assertMCPError(error, kind: "invalidParams", message: "Workspace 'Target' is active in multiple windows: \(ids). Close those windows or switch them away before deleting.")
        }
        XCTAssertEqual(executions, 0)
        XCTAssertTrue(target.workspaceManager.workspaces.contains { $0.id == workspace.id })
    }

    func testActualMCPDeniedApprovalNeverReachesDeletionExecutor() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        var executions = 0
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared, deletionExecutor: { _, _ in
            executions += 1
            return .closeRequested(windowID: target.windowID)
        })
        let presented = expectation(description: "real delete approval")
        let approval = WorkspaceApprovalManager.shared
        let observation = approval.$pendingRequest.compactMap(\.self).filter { $0.clientID == self.clientID }.prefix(1).sink { _ in presented.fulfill() }
        defer { observation.cancel() }
        let task = Task { () -> Error? in
            do { _ = try await self.callDelete(service, target: target, workspace: workspace.id.uuidString)
                return nil
            } catch { return error }
        }
        await fulfillment(of: [presented], timeout: 5)
        guard let pending = approval.pendingRequest else { task.cancel()
            return XCTFail("Approval did not present")
        }
        approval.resolveApproval(requestID: pending.id, respondingWindowID: target.windowID, allow: false)
        let completionError = await task.value
        let error = try XCTUnwrap(completionError)
        assertMCPError(error, kind: "invalidRequest", message: "Workspace deletion was denied by the user.")
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(target.workspaceManager.activeWorkspaceID, workspace.id)
        XCTAssertEqual(windows.first?.performCloseCount, 0)
    }

    func testActualMCPRevalidatesTargetAfterAwaitedApproval() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
        let presented = expectation(description: "approval before retarget")
        let approval = WorkspaceApprovalManager.shared
        let observation = approval.$pendingRequest.compactMap(\.self).filter { $0.clientID == self.clientID }.prefix(1).sink { _ in presented.fulfill() }
        defer { observation.cancel() }
        let task = Task { () -> Error? in
            do { _ = try await self.callDelete(service, target: target, workspace: workspace.id.uuidString)
                return nil
            } catch { return error }
        }
        await fulfillment(of: [presented], timeout: 5)
        guard let pending = approval.pendingRequest else { task.cancel()
            return XCTFail("Approval did not present")
        }
        let switched = await target.workspaceManager.requestWorkspaceSwitch(to: target.workspaceManager.getOrCreateSystemWorkspace(), saveState: false)
        XCTAssertTrue(switched.didSwitch)
        approval.resolveApproval(requestID: pending.id, respondingWindowID: target.windowID, allow: true)
        let completionError = await task.value
        let error = try XCTUnwrap(completionError)
        assertMCPError(error, kind: "invalidRequest", message: "Workspace 'Target' was not deleted because window \(target.windowID) changed.")
        XCTAssertTrue(target.workspaceManager.workspaces.contains { $0.id == workspace.id })
        XCTAssertEqual(windows.first?.performCloseCount, 0)
    }

    func testActualMCPMapsEveryOwnerRefusalToInvalidRequestAndNeverOKWithNilClosedID() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        WorkspaceApprovalManager.shared.addAutoApproval(clientID: clientID, operation: .deleteWorkspace)
        let outcomes: [(WorkspaceWindowDeletion.Result, String)] = [
            (.notSwitched(message: "Switch declined"), "Switch declined"),
            (.notSwitched(message: "Switch busy after cancellation"), "Switch busy after cancellation"),
            (.deleteFailed(message: "Delete failed after switch"), "Delete failed after switch"),
            (.targetChanged(message: "Target changed before delete"), "Target changed before delete"),
            (.targetChanged(message: "Workspace was not deleted: duplicate after switch"), "Workspace was not deleted: duplicate after switch"),
            (.deletionCommittedWithoutClose(message: "Workspace deleted, changed window not closed"), "Workspace deleted, changed window not closed")
        ]
        for (outcome, message) in outcomes {
            var executions = 0
            let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared, deletionExecutor: { state, resolved in
                executions += 1
                XCTAssertTrue(state === target)
                XCTAssertEqual(resolved.id, workspace.id)
                return outcome
            })
            do {
                _ = try await callDelete(service, target: target, workspace: workspace.id.uuidString)
                XCTFail("Must throw invalidRequest, never ok/nil: \(message)")
            } catch { assertMCPError(error, kind: "invalidRequest", message: message) }
            XCTAssertEqual(executions, 1)
        }
        XCTAssertEqual(windows.first?.performCloseCount, 0)
    }

    func testActualMCPPreservesCloseRequestErrorAfterCommittedDeletion() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        WorkspaceApprovalManager.shared.addAutoApproval(clientID: clientID, operation: .deleteWorkspace)
        let failure = NSError(domain: "WindowStatesManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown window_id \(target.windowID)"])
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared, deletionExecutor: { _, _ in .closeFailed(failure) })
        do {
            _ = try await callDelete(service, target: target, workspace: workspace.id.uuidString)
            XCTFail("Close error must propagate unchanged")
        } catch { XCTAssertEqual(error as NSError, failure) }
    }

    func testChatConfirmationRejectsSessionMovedToAnotherTab() async throws {
        let chat = try await makeChats()
        let vm = chat.state.agentModeViewModel
        let actions = makeActions(chat.state)
        actions.requestDeleteChat(rowID: chat.targetID, windowID: chat.state.windowID, workspaceID: chat.workspace.id, sessionID: chat.targetID)
        _ = vm.test_installPersistentSessionBinding(sessionID: nil, on: chat.target)
        _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: chat.targetID, on: chat.peer))

        await actions.confirmDeletion()

        XCTAssertTrue(chat.state.promptManager.currentComposeTabs.contains { $0.id == chat.target.tabID })
        XCTAssertTrue(chat.state.promptManager.currentComposeTabs.contains { $0.id == chat.peer.tabID })
        XCTAssertEqual(chat.peer.activeAgentSessionID, chat.targetID)
        XCTAssertEqual(actions.staleMessage(for: chat.targetID), "This session is no longer in window \(chat.state.windowID)")
    }

    func testRealOwnerInitialDuplicateRefusesBeforeSwitch() async {
        let probe = DeletionProbe()
        probe.other = FakeDeletionTarget(windowID: 8, workspace: probe.workspace, log: probe.log)

        let result = await probe.owner().execute()

        guard case let .targetChanged(message) = result else { return XCTFail("Expected duplicate refusal") }
        XCTAssertEqual(message, "Workspace 'Target' is active in multiple windows: 7, 8. Close those windows or switch them away before deleting.")
        XCTAssertEqual(probe.log.events, [])
        XCTAssertEqual(probe.parked, [7])
        XCTAssertEqual(probe.target.deletionWorkspaceID, probe.workspace.id)
    }

    func testCloseFailurePresentationExplicitlyReportsDeletionCommitted() async {
        let probe = DeletionProbe()
        probe.closeError = NSError(domain: "FleetClose", code: 41, userInfo: [NSLocalizedDescriptionKey: "Close request refused"])
        let actions = workspaceActions(probe)
        actions.requestDeleteWorkspace(section: section(probe))

        await actions.confirmDeletion()

        XCTAssertEqual(actions.deletionError, "Workspace 'Target' was deleted, but window 7 could not be closed: Close request refused")
        XCTAssertNotNil(actions.confirmation)
        XCTAssertEqual(probe.target.deletedIDs, [probe.workspace.id])
        XCTAssertEqual(probe.log.events.count(where: { $0 == "delete:start" }), 1)
    }

    func testActualMCPDuplicateArrivingDuringApprovalRefusesWithoutDeletion() async throws {
        let (target, workspace) = try await makeState(name: "Target")
        let (peer, _) = try await makeState(name: "Peer")
        let service = WindowRoutingService(windowStates: .shared, networkMgr: .shared)
        let presented = expectation(description: "approval before duplicate")
        let approval = WorkspaceApprovalManager.shared
        let observation = approval.$pendingRequest.compactMap(\.self).filter { $0.clientID == self.clientID }.prefix(1).sink { _ in presented.fulfill() }
        defer { observation.cancel() }
        let task = Task { () -> Error? in
            do { _ = try await self.callDelete(service, target: target, workspace: workspace.id.uuidString)
                return nil
            } catch { return error }
        }
        await fulfillment(of: [presented], timeout: 5)
        guard let pending = approval.pendingRequest else { task.cancel()
            return XCTFail("Approval did not present")
        }
        peer.workspaceManager.reloadWorkspacesFromDisk()
        let switched = await peer.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: false)
        XCTAssertTrue(switched.didSwitch)
        approval.resolveApproval(requestID: pending.id, respondingWindowID: target.windowID, allow: true)
        let completionError = await task.value
        let error = try XCTUnwrap(completionError)
        let ids = [target.windowID, peer.windowID].sorted().map(String.init).joined(separator: ", ")
        assertMCPError(error, kind: "invalidRequest", message: "Workspace 'Target' is active in multiple windows: \(ids). Close those windows or switch them away before deleting.")
        XCTAssertEqual(target.workspaceManager.activeWorkspaceID, workspace.id)
        XCTAssertEqual(peer.workspaceManager.activeWorkspaceID, workspace.id)
        XCTAssertTrue(target.workspaceManager.workspaces.contains { $0.id == workspace.id })
        XCTAssertTrue(windows.allSatisfy { $0.performCloseCount == 0 })
    }

    private func approvalSettingsMatch(_ current: WorkspaceApprovalSettings, _ previous: WorkspaceApprovalSettings) -> Bool {
        current.autoApproveAll == previous.autoApproveAll
            && current.autoApproveOperations == previous.autoApproveOperations
            && Set(current.clientPolicies.keys) == Set(previous.clientPolicies.keys)
            && previous.clientPolicies.allSatisfy { key, expected in
                guard let actual = current.clientPolicies[key] else { return false }
                return actual.clientID == expected.clientID
                    && actual.allowedOperations == expected.allowedOperations
                    && actual.createdAt == expected.createdAt
                    && actual.lastUsedAt == expected.lastUsedAt
            }
    }

    private enum FixtureFailure: Error { case notIsolated }

    @MainActor
    private final class ActionRecordingWindow: NSWindow {
        var performCloseCount = 0
        override func performClose(_ sender: Any?) {
            performCloseCount += 1
        }
    }

    private struct Chats {
        let state: WindowState
        let workspace: WorkspaceModel
        let target: AgentModeViewModel.TabSession
        let targetID: UUID
        let targetTab: ComposeTabState
        let peer: AgentModeViewModel.TabSession
        let peerTab: ComposeTabState
    }

    private func makeState(name: String) async throws -> (WindowState, WorkspaceModel) {
        guard states.count < 2 else { throw FixtureFailure.notIsolated }
        let root = try XCTUnwrap(root)
        let repo = root.appendingPathComponent("repo-\(states.count)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let state = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
        states.append(state)
        WindowStatesManager.shared.registerWindowState(state)
        await state.workspaceManager.awaitInitialized()
        let creation = try state.workspaceManager.createPersistentWorkspace(name: name, repoPaths: [repo.path], savedInLibrary: true)
        let workspace = try await creation.publishedWorkspace()
        let result = await state.workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: false)
        XCTAssertTrue(result.didSwitch, result.message ?? "Initial fixture switch failed")
        let window = ActionRecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        windows.append(window)
        state.attachWindow(window)
        return (state, workspace)
    }

    private func makeChats(name: String = "Target", content: Bool = true) async throws -> Chats {
        let (state, workspace) = try await makeState(name: name)
        let vm = state.agentModeViewModel
        let initialTabs = state.promptManager.currentComposeTabs
        guard initialTabs.count == 1, let initialTab = initialTabs.first,
              initialTab.activeAgentSessionID == nil, vm.sessions.count == 1,
              let initialSession = vm.sessions[initialTab.id], initialSession.runState == .idle,
              initialSession.items.isEmpty, initialSession.activeAgentSessionID == nil
        else { throw FixtureFailure.notIsolated }
        vm.test_removeSession(tabID: initialTab.id)
        print("FM06_FIXTURE removed-initial-blank window=\(state.windowID) tab=\(initialTab.id)")
        let targetID = UUID(), peerID = UUID()
        let targetTab = ComposeTabState(id: UUID(), name: "Target chat", activeAgentSessionID: targetID)
        let peerTab = ComposeTabState(id: UUID(), name: "Peer chat", activeAgentSessionID: peerID)
        let index = try XCTUnwrap(state.workspaceManager.workspaces.firstIndex { $0.id == workspace.id })
        state.workspaceManager.workspaces[index].composeTabs = [targetTab, peerTab]
        state.workspaceManager.workspaces[index].activeComposeTabID = targetTab.id
        state.promptManager.loadComposeTabsFromWorkspace(state.workspaceManager.workspaces[index], syncPromptText: true)
        let target = vm.session(for: targetTab.id)
        let peer = vm.session(for: peerTab.id)
        for (session, id) in [(target, targetID), (peer, peerID)] {
            session.hasLoadedPersistedState = true
            _ = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: id, on: session))
            // An installed binding admits operations only after restoration is authoritative.
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
        }
        target.runState = .idle
        peer.runState = .completed
        for tabID in [targetTab.id, peerTab.id, targetTab.id] {
            await state.promptManager.switchComposeTab(tabID)
        }
        if content {
            target.appendItem(.user("Target instruction", sequenceIndex: 0))
            target.appendItem(.assistant("Target answer", sequenceIndex: 1))
            vm.refreshDerivedTranscriptState(for: target)
        }
        vm.syncSidebarUIState(refresh: true)
        let normalizedTarget = try XCTUnwrap(state.promptManager.currentComposeTabs.first { $0.id == targetTab.id })
        let normalizedPeer = try XCTUnwrap(state.promptManager.currentComposeTabs.first { $0.id == peerTab.id })
        print("FM06_FIXTURE normalized-tabs window=\(state.windowID) target=\(String(reflecting: normalizedTarget)) peer=\(String(reflecting: normalizedPeer))")
        return Chats(state: state, workspace: workspace, target: target, targetID: targetID, targetTab: normalizedTarget, peer: peer, peerTab: normalizedPeer)
    }

    private func assertBothTabsUnchanged(_ chat: Chats, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(chat.state.promptManager.currentComposeTabs, [chat.targetTab, chat.peerTab], file: file, line: line)
        XCTAssertEqual(chat.target.runState, .idle, file: file, line: line)
        XCTAssertEqual(chat.peer.runState, .completed, file: file, line: line)
        XCTAssertFalse(chat.state.workspaceManager.activeWorkspace?.stashedTabs.contains { $0.tab.id == chat.target.tabID } == true, file: file, line: line)
    }

    private func makeActions(_ state: WindowState) -> FleetManagerActions {
        FleetManagerActions(handle: { $0 == state.windowID ? WindowStateFleetHandle(state: state) : nil }, parking: FleetParkingCoordinator.shared, requestRefresh: {}, notificationCenter: NotificationCenter())
    }

    private func section(_ probe: DeletionProbe, running: Int = 0, waiting: Int = 0) -> FleetRosterSection {
        FleetRosterSection(workspaceID: probe.workspace.id, workspaceName: "Target", windowID: 7, isParked: probe.parked.contains(7), runningCount: running, waitingCount: waiting, rows: [])
    }

    private func snapshot(_ probe: DeletionProbe) -> FleetRosterWindowSnapshot {
        FleetRosterWindowSnapshot(windowID: 7, workspaceID: probe.workspace.id, workspaceName: "Target", isSystemWorkspace: false, isClosing: false, sessions: [])
    }

    private func workspaceActions(_ probe: DeletionProbe) -> FleetManagerActions {
        FleetManagerActions(handle: { _ in nil }, parking: ActionParking(), requestRefresh: {}, notificationCenter: NotificationCenter(), workspaceWindowIDs: { probe.holders($0) }, deleteWorkspace: { id, workspaceID in
            XCTAssertEqual(id, 7)
            XCTAssertEqual(workspaceID, probe.workspace.id)
            return await probe.owner().execute()
        })
    }

    private func callDelete(_ service: WindowRoutingService, target: WindowState, workspace: String?, windowID: Int? = nil) async throws -> (status: String?, closed: Int?) {
        await service.prepareDomainTools()
        let tools = await service.tools
        let tool = try XCTUnwrap(tools.first { $0.name == "manage_workspaces" })
        let connectionID = UUID()
        let metadata = MCPRequestMetadata(connectionID: connectionID, clientName: clientID, windowID: nil)
        let invocation = ToolInvocationContext.trustedLocal(toolName: "manage_workspaces", metadata: metadata)
        let data = try await ServerNetworkManager.currentConnectionIDTaskLocal.withValue(connectionID) {
            try await MCPInvocationContextBridge.withInvocation(invocation) {
                if let workspace {
                    let value = try await tool(["action": .string("delete"), "workspace": .string(workspace), "window_id": .int(windowID ?? target.windowID), "close_window": .bool(true)])
                    return try JSONEncoder().encode(value)
                }
                let value = try await tool(["action": .string("delete"), "window_id": .int(target.windowID), "close_window": .bool(true)])
                return try JSONEncoder().encode(value)
            }
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json["status"] as? String, json["closed_window_id"] as? Int)
    }

    private func assertMCPError(_ error: Error, kind: String, message: String, file: StaticString = #filePath, line: UInt = #line) {
        let payload = Mirror(reflecting: error).children.first
        XCTAssertEqual(payload?.label, kind, file: file, line: line)
        XCTAssertEqual(payload?.value as? String, message, file: file, line: line)
    }

    @MainActor
    private final class SuspensionGate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(entered: XCTestExpectation) {
            self.entered = entered
        }

        func pause() async {
            await withCheckedContinuation { continuation in
                if released { continuation.resume()
                    return
                }
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    @MainActor
    private final class ActionParking: FleetParkingControlling {
        var parkedWindowIDs: Set<Int> = []
        func park(windowID: Int, reason: FleetParkReason) -> Bool {
            parkedWindowIDs.insert(windowID)
            return true
        }

        func unpark(windowID: Int) {
            parkedWindowIDs.remove(windowID)
        }
    }

    @MainActor
    private final class ActionTicker: FleetRosterTicker {
        func start(interval: TimeInterval, fire: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    @MainActor
    private final class ActionRosterSource: FleetRosterWindowSource {
        var snapshot: FleetRosterWindowSnapshot
        let changed = PassthroughSubject<Void, Never>()
        init(snapshot: FleetRosterWindowSnapshot) {
            self.snapshot = snapshot
        }

        func windows() -> [FleetRosterWindowSnapshot] {
            [snapshot]
        }

        var changes: AnyPublisher<Void, Never> {
            changed.eraseToAnyPublisher()
        }
    }

    @MainActor
    private final class DeletionLog { var events: [String] = [] }

    @MainActor
    private final class FakeDeletionTarget: WorkspaceWindowDeletionTarget {
        let windowID: Int
        var deletionWorkspaceID: UUID?
        var isClosing = false
        let fallback = WorkspaceModel(name: "System", repoPaths: [], isSystemWorkspace: true)
        var workspaceAfterSwitch: UUID?
        var switchResult: WorkspaceSwitchResult = .switched
        var switchEffect: (() async -> Void)?
        var deleteEffect: (() async -> Void)?
        var deleteResult = true
        var runStates: [AgentSessionRunState] = [.running, .waitingForQuestion]
        var deletedIDs: [UUID] = []
        let log: DeletionLog
        init(windowID: Int, workspace: WorkspaceModel, log: DeletionLog) {
            self.windowID = windowID
            deletionWorkspaceID = workspace.id
            self.log = log
        }

        func systemWorkspaceForDeletion() -> WorkspaceModel {
            fallback
        }

        func switchForDeletion(to workspace: WorkspaceModel, saveState: Bool) async -> WorkspaceSwitchResult {
            log.events.append("switch:\(saveState)")
            XCTAssertEqual(workspace.id, fallback.id)
            await switchEffect?()
            if switchResult.didSwitch { deletionWorkspaceID = workspaceAfterSwitch ?? workspace.id }
            return switchResult
        }

        func deleteForDeletion(_ workspace: WorkspaceModel) async -> Bool {
            log.events.append("delete:start")
            await deleteEffect?()
            if deleteResult { deletedIDs.append(workspace.id) }
            log.events.append("delete:end")
            return deleteResult
        }
    }

    @MainActor
    private final class DeletionProbe {
        let workspace = WorkspaceModel(name: "Target", repoPaths: [])
        let log = DeletionLog()
        let target: FakeDeletionTarget
        var registered: FakeDeletionTarget?
        var other: FakeDeletionTarget?
        var parked: Set<Int> = [7]
        var authorizations: [WindowCloseAuthorization] = []
        var closeError: Error?
        init() {
            target = FakeDeletionTarget(windowID: 7, workspace: workspace, log: log)
            registered = target
        }

        func holders(_ workspaceID: UUID) -> [Int] {
            [registered, other].compactMap(\.self).filter { $0.deletionWorkspaceID == workspaceID }.map(\.windowID).sorted()
        }

        func owner() -> WorkspaceWindowDeletion {
            WorkspaceWindowDeletion(target: target, workspace: workspace, registeredTarget: { id in
                guard self.registered?.windowID == id else { return nil }
                return self.registered
            }, showingWindowIDs: { self.holders($0) }, isParked: { self.parked.contains($0) }, unpark: { id in
                self.log.events.append("unpark:\(id)")
                self.parked.remove(id)
            }, requestClose: { id, authorization in
                self.log.events.append("close:\(id)")
                self.authorizations.append(authorization)
                if let closeError = self.closeError { throw closeError }
            })
        }
    }
}
