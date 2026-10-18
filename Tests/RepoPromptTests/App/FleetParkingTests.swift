import AppKit
import Combine
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSettingsCore
import RepoPromptShared
import SwiftUI
import XCTest

@MainActor
final class FleetParkingTests: XCTestCase {
    private var previousAutoStart = false
    private var didChangeAutoStart = false
    private var windows: [WindowState] = []
    private var nsWindows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let prefix = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        guard WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path.hasPrefix(prefix)
        else { throw FleetFixtureError.unsafeSandbox }
        guard WindowStatesManager.shared.pendingURLs.isEmpty,
              !WindowStatesManager.shared.isTerminating
        else { throw FleetFixtureError.notReady }
        _ = NSApplication.shared
        previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        didChangeAutoStart = true
        FleetParkingCoordinator.shared.resetForTesting()
        FleetParkingCoordinator.shared.setAutomaticBackstopDeliveryEnabledForTesting(false)
    }

    override func tearDown() async throws {
        FleetParkingCoordinator.shared.resetForTesting()
        for state in windows {
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
        if didChangeAutoStart {
            GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        }
        didChangeAutoStart = false
        try await super.tearDown()
    }

    private func makeWindow(register: Bool = false, attach: Bool = true) async throws -> WindowState {
        let state = WindowState()
        windows.append(state)
        if register { WindowStatesManager.shared.registerWindowState(state) }
        let initialized = expectation(description: "workspace initialized")
        var waiting = true
        defer { waiting = false }
        state.workspaceManager.onceInitialized {
            if waiting {
                initialized.fulfill()
            }
        }
        await fulfillment(of: [initialized], timeout: 5)
        guard state.workspaceManager.isInitialized,
              !state.workspaceManager.isSwitchingWorkspace
        else { throw FleetFixtureError.notReady }
        await state.workspaceManager.awaitInitialized()
        if attach {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            nsWindows.append(window)
            state.attachWindow(window)
            window.tabbingMode = .disallowed
            window.orderFront(nil)
        }
        if register {
            XCTAssertTrue(WindowStatesManager.shared.window(withID: state.windowID) === state)
        }
        return state
    }

    private func runningSession(in state: WindowState) -> AgentModeViewModel.TabSession {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.hasLoadedPersistedState = true
        session.runState = .running
        state.agentModeViewModel.test_installLiveSession(session)
        return session
    }

    private func coordinator(
        effects: EffectLog? = nil,
        groups: FakeTabGroups? = nil,
        visibility: FakeVisibility? = nil,
        clock: FakeClock? = nil,
        center: NotificationCenter = NotificationCenter()
    ) -> FleetParkingCoordinator {
        let effects = effects ?? EffectLog()
        let visibility = visibility ?? FakeVisibility()
        let clock = clock ?? FakeClock()
        return FleetParkingCoordinator(
            tabGroups: groups ?? FakeTabGroups(effects: effects),
            ordering: RecordingOrdering(effects: effects),
            visibility: visibility,
            now: { clock.now },
            windowLookup: { [weak self] id in self?.windows.first { $0.windowID == id } },
            notificationCenter: center
        )
    }

    func testParkingTwoRegisteredWindowsKeepsThemRegisteredAndRunning() async throws {
        let a = try await makeWindow(register: true)
        let b = try await makeWindow(register: true)
        let sa = runningSession(in: a)
        let sb = runningSession(in: b)
        let c = coordinator()
        XCTAssertTrue(c.park(windowID: a.windowID))
        XCTAssertTrue(c.park(windowID: b.windowID))
        XCTAssertEqual(c.parkedWindowIDs, [a.windowID, b.windowID])
        XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === a })
        XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === b })
        XCTAssertFalse(a.isClosing)
        XCTAssertFalse(b.isClosing)
        XCTAssertEqual(sa.runState, .running)
        XCTAssertEqual(sb.runState, .running)
        XCTAssertFalse(FleetAppLifecycleDecision.shouldTerminateAfterLastWindowClosed(
            .init(backgroundModeHasWindow: false, fleetParkedCount: 2, visibleWindowCount: 0)
        ))
        c.unpark(windowID: a.windowID)
        XCTAssertEqual(c.parkedWindowIDs, [b.windowID])
    }

    private struct ClosePeerSnapshot: Equatable {
        let identity: ObjectIdentifier
        let nativeIdentity: ObjectIdentifier?
        let workspaceID: UUID?
        let tabIDs: [UUID]
        let runStates: [UUID: AgentSessionRunState]
        let parked: Bool
        let visible: Bool
    }

    private func installClosePeerSessions(in state: WindowState) throws {
        let running = runningSession(in: state)
        let waiting = runningSession(in: state)
        waiting.runState = .waitingForApproval
        let manager = state.workspaceManager
        let index = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == manager.activeWorkspaceID })
        manager.workspaces[index].composeTabs.append(contentsOf: [
            ComposeTabState(id: running.tabID), ComposeTabState(id: waiting.tabID)
        ])
        state.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index])
        XCTAssertTrue(state.agentModeViewModel.sessions[running.tabID] === running)
        XCTAssertTrue(state.agentModeViewModel.sessions[waiting.tabID] === waiting)
        XCTAssertEqual(running.runState, .running)
        XCTAssertEqual(waiting.runState, .waitingForApproval)
        XCTAssertTrue(manager.activeWorkspace?.composeTabs.contains { $0.id == running.tabID } == true)
        XCTAssertTrue(manager.activeWorkspace?.composeTabs.contains { $0.id == waiting.tabID } == true)
    }

    private func closePeerSnapshot(_ state: WindowState) -> ClosePeerSnapshot {
        ClosePeerSnapshot(
            identity: ObjectIdentifier(state),
            nativeIdentity: state.nsWindow.map(ObjectIdentifier.init),
            workspaceID: state.workspaceManager.activeWorkspaceID,
            tabIDs: state.workspaceManager.activeWorkspace?.composeTabs.map(\.id) ?? [],
            runStates: state.agentModeViewModel.sessions.mapValues(\.runState),
            parked: FleetParkingCoordinator.shared.isParked(windowID: state.windowID),
            visible: state.nsWindow?.isVisible == true
        )
    }

    func testNativeWillCloseWithoutSceneDisappearanceUnregistersOnlyTarget() async throws {
        let manager = WindowStatesManager.shared
        let target = try await makeWindow(register: true)
        let peer = try await makeWindow(register: true)
        let nativeWindow = try XCTUnwrap(target.nsWindow)
        nativeWindow.isReleasedWhenClosed = false
        XCTAssertTrue(nativeWindow.delegate is InterceptingWindowDelegateProxy)
        try installClosePeerSessions(in: peer)
        let peerBefore = closePeerSnapshot(peer)
        var saveCount = 0
        let saveListener = target.workspaceManager.addBeforeSaveListener { _ in saveCount += 1 }
        var countNotifications = 0
        let countObservation = NotificationCenter.default.publisher(for: .windowCountDidChange)
            .sink { _ in countNotifications += 1 }
        defer {
            target.workspaceManager.removeBeforeSaveListener(saveListener)
            countObservation.cancel()
        }
        let nativeClose = expectation(description: "exact target native willClose")
        var nativeCloseCount = 0
        let observation = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification, object: nativeWindow
        ).sink { notification in
            guard let window = notification.object as? NSWindow, window === nativeWindow else { return }
            nativeCloseCount += 1
            if nativeCloseCount == 1 { nativeClose.fulfill() }
        }
        defer { observation.cancel() }

        target.requestClose(authorization: WorkspaceWindowDeletion.closeAuthorization())
        await fulfillment(of: [nativeClose], timeout: 5)

        print("native willClose witness: target=\(target.windowID) count=\(nativeCloseCount)")
        XCTAssertEqual(nativeCloseCount, 1)
        guard nativeCloseCount == 1 else { return }
        XCTAssertFalse(nativeWindow.isVisible)
        XCTAssertNil(manager.window(withID: target.windowID), "native-closed target still registered")
        XCTAssertTrue(manager.window(withID: peer.windowID) === peer)
        XCTAssertFalse(peer.isClosing)
        XCTAssertEqual(closePeerSnapshot(peer), peerBefore)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(countNotifications, 1)
        manager.handleWindowClosed(target)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(countNotifications, 1)
    }

    func testNativeWillCloseAfterUnparkWithAttachBeforeRegistrationPreservesParkedPeer() async throws {
        let manager = WindowStatesManager.shared
        let target = try await makeWindow()
        let nativeWindow = try XCTUnwrap(target.nsWindow)
        nativeWindow.isReleasedWhenClosed = false
        nativeWindow.delegate = nil
        manager.registerWindowState(target)
        let peer = try await makeWindow(register: true)
        try installClosePeerSessions(in: peer)
        let parking = FleetParkingCoordinator.shared
        XCTAssertTrue(parking.park(windowID: target.windowID))
        XCTAssertTrue(parking.park(windowID: peer.windowID))
        XCTAssertEqual(parking.parkedWindowIDs, [target.windowID, peer.windowID])
        XCTAssertTrue(manager.window(withID: target.windowID) === target)
        XCTAssertTrue(manager.window(withID: peer.windowID) === peer)
        XCTAssertFalse(target.isClosing)
        XCTAssertFalse(peer.isClosing)
        XCTAssertFalse(nativeWindow.isVisible)
        XCTAssertFalse(peer.nsWindow?.isVisible == true)
        let peerBefore = closePeerSnapshot(peer)
        parking.unpark(windowID: target.windowID)
        XCTAssertTrue(nativeWindow.isVisible)
        XCTAssertEqual(parking.parkedWindowIDs, [peer.windowID])
        XCTAssertNil(nativeWindow.delegate)
        let nativeClose = expectation(description: "exact unparked target native willClose")
        var nativeCloseCount = 0
        let observation = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification, object: nativeWindow
        ).sink { notification in
            guard let window = notification.object as? NSWindow, window === nativeWindow else { return }
            nativeCloseCount += 1
            if nativeCloseCount == 1 { nativeClose.fulfill() }
        }
        defer { observation.cancel() }

        target.requestClose(authorization: WorkspaceWindowDeletion.closeAuthorization())
        await fulfillment(of: [nativeClose], timeout: 5)

        print("native willClose witness: target=\(target.windowID) count=\(nativeCloseCount)")
        XCTAssertEqual(nativeCloseCount, 1)
        guard nativeCloseCount == 1 else { return }
        XCTAssertFalse(nativeWindow.isVisible)
        XCTAssertNil(manager.window(withID: target.windowID), "native-closed target still registered")
        XCTAssertFalse(parking.isParked(windowID: target.windowID))
        XCTAssertTrue(manager.window(withID: peer.windowID) === peer)
        XCTAssertFalse(peer.isClosing)
        XCTAssertEqual(closePeerSnapshot(peer), peerBefore)
    }

    func testNativeAndSceneCloseIngressAndReentrantUnregisterRunEffectsOnce() async throws {
        let manager = WindowStatesManager.shared
        let state = try await makeWindow(register: true)
        let nativeWindow = try XCTUnwrap(state.nsWindow)
        nativeWindow.isReleasedWhenClosed = false
        var saveCount = 0
        let saveListener = state.workspaceManager.addBeforeSaveListener { _ in
            saveCount += 1
            if saveCount == 1 { manager.handleWindowClosed(state) }
        }
        var removalPublications = 0
        let removalObservation = manager.$allWindows.dropFirst().sink { publishedWindows in
            guard !publishedWindows.contains(where: { $0 === state }) else { return }
            removalPublications += 1
            if removalPublications == 1 { manager.unregisterWindowState(state) }
        }
        var countNotifications = 0
        let countObservation = NotificationCenter.default.publisher(for: .windowCountDidChange)
            .sink { _ in countNotifications += 1 }
        defer {
            state.workspaceManager.removeBeforeSaveListener(saveListener)
            removalObservation.cancel()
            countObservation.cancel()
        }

        manager.handleWindowClosed(state)
        manager.handleWindowClosed(state)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nativeWindow)

        XCTAssertNil(manager.window(withID: state.windowID))
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(removalPublications, 1)
        XCTAssertEqual(countNotifications, 1)
    }

    func testNativeCloseIgnoresUnrelatedReplacedAndDetachedWindowObjects() async throws {
        let manager = WindowStatesManager.shared
        let state = try await makeWindow(register: true)
        let oldWindow = try XCTUnwrap(state.nsWindow)
        oldWindow.isReleasedWhenClosed = false
        let nativeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        nativeWindow.isReleasedWhenClosed = false
        nsWindows.append(nativeWindow)
        var saveCount = 0
        let saveListener = state.workspaceManager.addBeforeSaveListener { _ in saveCount += 1 }
        var countNotifications = 0
        let countObservation = NotificationCenter.default.publisher(for: .windowCountDidChange)
            .sink { _ in countNotifications += 1 }
        defer {
            state.workspaceManager.removeBeforeSaveListener(saveListener)
            countObservation.cancel()
        }

        state.attachWindow(oldWindow)
        state.attachWindow(oldWindow)
        state.attachWindow(nativeWindow)
        oldWindow.delegate = nil
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: NSObject())
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: oldWindow)
        XCTAssertTrue(manager.window(withID: state.windowID) === state)
        XCTAssertFalse(state.isClosing)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(countNotifications, 0)

        state.attachWindow(nil)
        nativeWindow.delegate = nil
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nativeWindow)
        XCTAssertTrue(manager.window(withID: state.windowID) === state)
        XCTAssertFalse(state.isClosing)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(countNotifications, 0)

        state.attachWindow(nativeWindow)
        state.attachWindow(nativeWindow)
        nativeWindow.tabbingMode = .disallowed
        nativeWindow.orderFront(nil)
        let nativeClose = expectation(description: "replacement window actual native willClose")
        var nativeCloseCount = 0
        let observation = NotificationCenter.default.publisher(
            for: NSWindow.willCloseNotification, object: nativeWindow
        ).sink { notification in
            guard let window = notification.object as? NSWindow, window === nativeWindow else { return }
            nativeCloseCount += 1
            if nativeCloseCount == 1 { nativeClose.fulfill() }
        }
        defer { observation.cancel() }

        state.requestClose(authorization: WorkspaceWindowDeletion.closeAuthorization())
        await fulfillment(of: [nativeClose], timeout: 5)

        print("replacement native willClose witness: target=\(state.windowID) count=\(nativeCloseCount)")
        XCTAssertEqual(nativeCloseCount, 1)
        XCTAssertFalse(nativeWindow.isVisible)
        XCTAssertNil(manager.window(withID: state.windowID))
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(countNotifications, 1)
    }

    func testSceneCloseIngressDuringTerminationSkipsSaveAndUnregistration() async throws {
        let manager = WindowStatesManager.shared
        let state = try await makeWindow(register: true)
        var saveCount = 0
        let saveListener = state.workspaceManager.addBeforeSaveListener { _ in saveCount += 1 }
        var countNotifications = 0
        let countObservation = NotificationCenter.default.publisher(for: .windowCountDidChange)
            .sink { _ in countNotifications += 1 }
        manager.setTerminatingForTesting(true)
        defer {
            manager.setTerminatingForTesting(false)
            state.workspaceManager.removeBeforeSaveListener(saveListener)
            countObservation.cancel()
        }

        manager.handleWindowClosed(state)
        manager.handleWindowClosed(state)

        XCTAssertTrue(state.isClosing)
        XCTAssertTrue(manager.window(withID: state.windowID) === state)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(countNotifications, 0)
    }

    func testUnparkingOffScreenWindowOrdersFrontWithoutMakingKey() async throws {
        let state = try await makeWindow()
        let window = try XCTUnwrap(state.nsWindow)
        let effects = EffectLog()
        let c = coordinator(effects: effects)
        XCTAssertTrue(c.park(windowID: state.windowID))
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        effects.events.removeAll()
        c.unpark(windowID: state.windowID)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(effects.events, [.orderFront(ObjectIdentifier(window))])
    }

    func testUnparkVisibleWindowDoesNotOrderFront() async throws {
        let state = try await makeWindow()
        let window = try XCTUnwrap(state.nsWindow)
        let effects = EffectLog()
        let c = coordinator(effects: effects)
        XCTAssertTrue(c.park(windowID: state.windowID))
        window.orderFront(nil)
        effects.events.removeAll()
        c.unpark(windowID: state.windowID)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(effects.events.isEmpty)
        XCTAssertFalse(c.isParked(windowID: state.windowID))
    }

    func testParkingTabbedWindowMovesItToOwnWindowThenOrdersOutOnlyThatWindow() async throws {
        let target = try await makeWindow()
        let sibling = try await makeWindow()
        let targetWindow = try XCTUnwrap(target.nsWindow)
        let siblingWindow = try XCTUnwrap(sibling.nsWindow)
        let effects = EffectLog()
        let groups = FakeTabGroups(effects: effects)
        groups.group = [ObjectIdentifier(targetWindow), ObjectIdentifier(siblingWindow)]
        let c = coordinator(effects: effects, groups: groups)
        XCTAssertTrue(siblingWindow.isVisible)
        XCTAssertTrue(c.park(windowID: target.windowID))
        XCTAssertEqual(effects.events, [
            .moveToOwnWindow(ObjectIdentifier(targetWindow)), .orderOut(ObjectIdentifier(targetWindow))
        ])
        XCTAssertTrue(siblingWindow.isVisible)
        XCTAssertFalse(targetWindow.isVisible)
        XCTAssertEqual(c.parkedWindowIDs, [target.windowID])
    }

    func testParkWithoutAttachedWindowIsRefused() async throws {
        let state = try await makeWindow(attach: false)
        let c = coordinator()
        XCTAssertFalse(c.park(windowID: state.windowID))
        XCTAssertTrue(c.parkedWindowIDs.isEmpty)
    }

    func testParkAndUnparkAreIdempotent() async throws {
        let state = try await makeWindow()
        let window = try XCTUnwrap(state.nsWindow)
        let effects = EffectLog()
        let c = coordinator(effects: effects)
        XCTAssertTrue(c.park(windowID: state.windowID))
        XCTAssertTrue(c.park(windowID: state.windowID))
        c.unpark(windowID: state.windowID)
        c.unpark(windowID: state.windowID)
        XCTAssertEqual(effects.events, [
            .orderOut(ObjectIdentifier(window)), .orderFront(ObjectIdentifier(window))
        ])
    }

    func testBeginCloseClearsParkedID() async throws {
        let state = try await makeWindow(register: true)
        XCTAssertTrue(WindowStatesManager.shared.window(withID: state.windowID) === state)
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: state.windowID))
        XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
        state.beginClose()
        XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
    }

    func testBackstopUnparksWhenIsVisibleBecomesTrueDespiteOcclusionNotVisible() async throws {
        let state = try await makeWindow()
        let window = try XCTUnwrap(state.nsWindow)
        let center = NotificationCenter()
        let visibility = FakeVisibility()
        let c = coordinator(visibility: visibility, center: center)
        XCTAssertTrue(c.park(windowID: state.windowID))
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        visibility.occlusionVisible[ObjectIdentifier(window)] = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(c.isParked(windowID: state.windowID))
        XCTAssertEqual(visibility.occlusionSamples, 0)
    }

    func testBackstopSamplesOnDidBecomeKeyAndDidChangeScreen() async throws {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            let state = try await makeWindow()
            let window = try XCTUnwrap(state.nsWindow)
            let center = NotificationCenter()
            let c = coordinator(center: center)
            XCTAssertTrue(c.park(windowID: state.windowID))
            window.orderFront(nil)
            center.post(name: name, object: window)
            XCTAssertFalse(c.isParked(windowID: state.windowID), name.rawValue)
        }
    }

    func testBackstopReparksDuringSettleAfterParkOnOpenThenUnparksAfterIt() async throws {
        let state = try await makeWindow()
        let window = try XCTUnwrap(state.nsWindow)
        let effects = EffectLog()
        let clock = FakeClock()
        let center = NotificationCenter()
        let c = coordinator(effects: effects, clock: clock, center: center)
        clock.now = 10
        XCTAssertTrue(c.park(windowID: state.windowID, reason: .onOpen))
        effects.events.removeAll()
        clock.now = 10.5
        window.orderFront(nil)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertTrue(c.isParked(windowID: state.windowID))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(effects.events, [.orderOut(ObjectIdentifier(window))])
        clock.now = 11
        window.orderFront(nil)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertFalse(c.isParked(windowID: state.windowID))
        XCTAssertTrue(window.isVisible)
    }

    func testBackstopDecisionTable() {
        typealias D = FleetParkingCoordinator
        XCTAssertEqual(D.parkOnOpenSettleTime, 1)
        XCTAssertEqual(D.backstopAction(isParked: false, isVisible: true, settleUntil: nil, now: 0), .none)
        XCTAssertEqual(D.backstopAction(isParked: true, isVisible: false, settleUntil: nil, now: 0), .none)
        XCTAssertEqual(D.backstopAction(isParked: true, isVisible: true, settleUntil: nil, now: 0), .unpark)
        XCTAssertEqual(D.backstopAction(isParked: true, isVisible: true, settleUntil: 11, now: 10.999), .orderOutAgain)
        XCTAssertEqual(D.backstopAction(isParked: true, isVisible: true, settleUntil: 11, now: 11), .unpark)
    }

    func testTerminateIsFalseWhileBackgroundModeHidesAWindowAndReopenRestoresIt() {
        let snapshot = FleetAppLifecycleInputs(
            backgroundModeHasWindow: true, fleetParkedCount: 0, visibleWindowCount: 0
        )
        var restored = 0
        let opener = FleetManagerOpenerSpy()
        XCTAssertFalse(FleetAppLifecycleDecision.shouldTerminateAfterLastWindowClosed(snapshot))
        XCTAssertTrue(FleetAppLifecycleDecision.handleReopen(
            snapshot, restore: { restored += 1 }, openFleetManager: opener.open
        ))
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(opener.count, 0)
        let combined = FleetAppLifecycleInputs(
            backgroundModeHasWindow: true, fleetParkedCount: 2, visibleWindowCount: 0
        )
        XCTAssertEqual(FleetAppLifecycleDecision.reopenAction(combined), .restoreBackgroundMode)
        XCTAssertTrue(FleetAppLifecycleDecision.handleReopen(
            combined, restore: { restored += 1 }, openFleetManager: opener.open
        ))
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(opener.count, 0)
    }

    func testReopenWithOnlyFleetParkedWindowsOpensFleetManagerAndReturnsTrue() async throws {
        let state = try await makeWindow()
        let c = coordinator()
        XCTAssertTrue(c.park(windowID: state.windowID))
        let snapshot = FleetAppLifecycleInputs(
            backgroundModeHasWindow: false,
            fleetParkedCount: c.parkedWindowIDs.count,
            visibleWindowCount: 0
        )
        let opener = FleetManagerOpenerSpy()
        XCTAssertTrue(FleetAppLifecycleDecision.handleReopen(
            snapshot, restore: { XCTFail("unexpected restore") }, openFleetManager: opener.open
        ))
        XCTAssertEqual(opener.count, 1)
    }

    func testTerminateIsTrueAndReopenIsUnhandledWithNothingParkedOrBackgrounded() {
        let snapshot = FleetAppLifecycleInputs(
            backgroundModeHasWindow: false, fleetParkedCount: 0, visibleWindowCount: 0
        )
        XCTAssertTrue(FleetAppLifecycleDecision.shouldTerminateAfterLastWindowClosed(snapshot))
        XCTAssertFalse(FleetAppLifecycleDecision.handleReopen(
            snapshot,
            restore: { XCTFail("unexpected restore") },
            openFleetManager: { XCTFail("unexpected fleet open") }
        ))
    }

    func testReopenWithVisibleWindowsIsUnhandledEvenWhenParked() {
        let snapshot = FleetAppLifecycleInputs(
            backgroundModeHasWindow: true, fleetParkedCount: 2, visibleWindowCount: 1
        )
        XCTAssertEqual(FleetAppLifecycleDecision.reopenAction(snapshot), .none)
        XCTAssertFalse(FleetAppLifecycleDecision.handleReopen(
            snapshot,
            restore: { XCTFail("unexpected restore") },
            openFleetManager: { XCTFail("unexpected fleet open") }
        ))
    }

    private func readyRoute(in state: WindowState) throws -> AgentSessionDeepLinkRoute {
        let manager = state.workspaceManager
        guard manager.isInitialized, !manager.isSwitchingWorkspace,
              let workspaceID = manager.activeWorkspaceID,
              let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { throw FleetFixtureError.notReady }
        let tab = ComposeTabState(id: UUID())
        manager.workspaces[index].composeTabs.append(tab)
        manager.workspaces[index].activeComposeTabID = tab.id
        state.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index])
        let session = AgentModeViewModel.TabSession(tabID: tab.id)
        session.hasLoadedPersistedState = true
        session.runState = .idle
        state.agentModeViewModel.test_installLiveSession(session)
        guard manager.activeWorkspace?.composeTabs.contains(where: { $0.id == tab.id }) == true,
              state.promptManager.activeComposeTabID == tab.id
        else { throw FleetFixtureError.notReady }
        return AgentSessionDeepLinkRoute(
            windowID: state.windowID, workspaceID: workspaceID, tabID: tab.id,
            sessionID: nil, interactionID: nil
        )
    }

    private func runRoute(
        _ operation: @escaping @MainActor () async -> AgentSessionRouteResult
    ) async throws -> AgentSessionRouteResult {
        let completed = expectation(description: "route completed")
        var result: AgentSessionRouteResult?
        var waiting = true
        let task = Task {
            result = await operation()
            if waiting { completed.fulfill() }
        }
        defer { waiting = false
            task.cancel()
        }
        await fulfillment(of: [completed], timeout: 5)
        return try XCTUnwrap(result)
    }

    private func parkTwo() async throws -> (WindowState, WindowState) {
        let target = try await makeWindow(register: true)
        let other = try await makeWindow(register: true)
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: target.windowID))
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: other.windowID))
        XCTAssertEqual(FleetParkingCoordinator.shared.parkedWindowIDs, [target.windowID, other.windowID])
        return (target, other)
    }

    private func assertOnlyTargetUnparked(_ target: WindowState, _ other: WindowState) {
        XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: target.windowID))
        XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: other.windowID))
        XCTAssertEqual(FleetParkingCoordinator.shared.parkedWindowIDs, [other.windowID])
        XCTAssertTrue(target.nsWindow?.isVisible == true)
        XCTAssertFalse(other.nsWindow?.isVisible == true)
    }

    func testFocusWindowIfPossibleUnparksOnlyItsWindow() async throws {
        let (target, other) = try await parkTwo()
        target.focusWindowIfPossible()
        assertOnlyTargetUnparked(target, other)
    }

    func testRevealPendingInteractionUnparksOnlyItsWindow() async throws {
        let (target, other) = try await parkTwo()
        let route = try readyRoute(in: target)
        let revealed = await target.revealPendingInteraction(
            tabID: route.tabID, surface: .agentQuestion
        )
        XCTAssertTrue(revealed)
        assertOnlyTargetUnparked(target, other)
    }

    func testRouteToAgentSessionUnparksOnlyItsWindow() async throws {
        let (target, other) = try await parkTwo()
        let ready = try readyRoute(in: target)
        let route = AgentSessionDeepLinkRoute(
            windowID: target.windowID, workspaceID: ready.workspaceID,
            tabID: UUID(), sessionID: nil, interactionID: nil
        )
        let result = try await runRoute { await target.routeToAgentSession(route) }
        XCTAssertEqual(result, .tabUnavailable)
        assertOnlyTargetUnparked(target, other)
    }

    func testRouteToAgentSessionPostActivationRevealUnparksAgainAfterReparkMidRoute() async throws {
        let (target, other) = try await parkTwo()
        let route = try readyRoute(in: target)
        var hookCount = 0
        target.test_beforePostActivationReveal = {
            hookCount += 1
            FleetParkingCoordinator.shared.unpark(windowID: target.windowID)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: target.windowID))
            XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: target.windowID))
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: target.windowID))
            XCTAssertFalse(target.nsWindow?.isVisible == true)
        }
        defer { target.test_beforePostActivationReveal = nil }
        let result = try await runRoute { await target.routeToAgentSession(route) }
        XCTAssertEqual(result, .routed)
        XCTAssertEqual(hookCount, 1)
        assertOnlyTargetUnparked(target, other)
    }

    func testDeepLinkRouterUnparksOnlyTargetWindow() async throws {
        let (target, other) = try await parkTwo()
        let unavailableWorkspace = UUID()
        XCTAssertTrue(WindowStatesManager.shared.allWindows.allSatisfy {
            $0.workspaceManager.workspace(withID: unavailableWorkspace) == nil
        })
        let route = AgentSessionDeepLinkRoute(
            windowID: target.windowID, workspaceID: unavailableWorkspace,
            tabID: UUID(), sessionID: nil, interactionID: nil
        )
        let router = AppDeepLinkRouter(windowStatesManager: WindowStatesManager.shared)
        let result = try await runRoute { await router.route(agentSession: route) }
        XCTAssertEqual(result, .workspaceUnavailable)
        assertOnlyTargetUnparked(target, other)
    }

    func testMCPApprovalBringWindowToFrontUnparksOnlyItsWindow() async throws {
        let (target, other) = try await parkTwo()
        target.mcpServer.bringWindowToFront()
        assertOnlyTargetUnparked(target, other)
    }

    func testWorkspaceApprovalPresentationUnparksOnlyTargetWindow() async throws {
        let (target, other) = try await parkTwo()
        let manager = WorkspaceApprovalManager.shared
        let clientID = "fleet-parking-probe-\(UUID().uuidString)"
        guard manager.pendingRequest == nil,
              !manager.settings.shouldAutoApprove(operation: .addFolder, clientID: clientID)
        else { throw FleetFixtureError.notReady }
        let request = WorkspaceApprovalRequest(
            clientID: clientID, operation: .addFolder, workspaceName: "FleetParkingProbe",
            workspaceID: UUID(), folderPath: "/tmp/fleet-parking-approval-probe",
            windowID: target.windowID
        )
        let presented = expectation(description: "approval presented")
        let completed = expectation(description: "approval completed")
        var presentationSeen = false
        var completionSeen = false
        var waiting = true
        let observation = manager.$pendingRequest
            .first { $0?.id == request.id }
            .sink { _ in
                presentationSeen = true
                if waiting { presented.fulfill() }
            }
        let task = Task {
            _ = await manager.requestApproval(for: request)
            completionSeen = true
            if waiting { completed.fulfill() }
        }
        defer {
            waiting = false
            observation.cancel()
            task.cancel()
            manager.cancelPending(requestID: request.id)
        }
        await fulfillment(of: [presented], timeout: 5)
        guard presentationSeen, manager.pendingRequest?.id == request.id
        else { throw FleetFixtureError.notReady }
        XCTAssertEqual(manager.presentedTargetWindowID, target.windowID)
        assertOnlyTargetUnparked(target, other)
        manager.resolveApproval(
            requestID: request.id, respondingWindowID: target.windowID, allow: false
        )
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertTrue(completionSeen)
        XCTAssertNil(manager.pendingRequest)
    }

    func testRevealOnUnparkedWindowLeavesCoordinatorUntouched() async throws {
        let target = try await makeWindow(register: true)
        let other = try await makeWindow(register: true)
        XCTAssertTrue(FleetParkingCoordinator.shared.park(windowID: other.windowID))
        target.revealWindow()
        XCTAssertEqual(FleetParkingCoordinator.shared.parkedWindowIDs, [other.windowID])
        XCTAssertTrue(target.nsWindow?.isVisible == true)
        XCTAssertFalse(other.nsWindow?.isVisible == true)
    }
}

private enum FleetFixtureError: Error {
    case unsafeSandbox
    case notReady
}

@MainActor
private final class NativeAttachCounter { var count = 0 }

/// Test-only: counts native attaches of sibling views. It proves the hosting materialised the backing views.
private struct NativeAttachProbe: NSViewRepresentable {
    let counter: NativeAttachCounter
    func makeNSView(context: Context) -> NSView {
        let view = ProbeView(frame: .zero)
        view.counter = counter
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        var counter: NativeAttachCounter?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { counter?.count += 1 }
        }
    }
}

@MainActor
private final class EffectLog {
    enum Effect: Equatable {
        case moveToOwnWindow(ObjectIdentifier)
        case orderOut(ObjectIdentifier)
        case orderFront(ObjectIdentifier)
    }

    var events: [Effect] = []
}

@MainActor
private final class FakeTabGroups: FleetTabGroupSeparating {
    var group: Set<ObjectIdentifier> = []
    let effects: EffectLog

    init(effects: EffectLog) {
        self.effects = effects
    }

    func isInTabGroup(_ window: NSWindow) -> Bool {
        group.contains(ObjectIdentifier(window))
    }

    func moveToOwnWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        effects.events.append(.moveToOwnWindow(id))
        group.remove(id)
    }
}

@MainActor
private final class RecordingOrdering: FleetWindowOrdering {
    let effects: EffectLog

    init(effects: EffectLog) {
        self.effects = effects
    }

    func orderOut(_ window: NSWindow) {
        effects.events.append(.orderOut(ObjectIdentifier(window)))
        window.orderOut(nil)
    }

    func orderFront(_ window: NSWindow) {
        effects.events.append(.orderFront(ObjectIdentifier(window)))
        window.orderFront(nil)
    }
}

@MainActor
private final class FakeVisibility: FleetWindowVisibilitySampling {
    var visible: [ObjectIdentifier: Bool] = [:]
    var occlusionVisible: [ObjectIdentifier: Bool] = [:]
    var occlusionSamples = 0

    func isVisible(_ window: NSWindow) -> Bool {
        visible[ObjectIdentifier(window)] ?? window.isVisible
    }

    func isOcclusionVisible(_ window: NSWindow) -> Bool {
        occlusionSamples += 1
        return occlusionVisible[ObjectIdentifier(window)] ?? false
    }
}

@MainActor
private final class FakeClock {
    var now: TimeInterval = 0
}

@MainActor
private final class FleetManagerOpenerSpy {
    var count = 0

    func open() {
        count += 1
    }
}

@MainActor
final class FleetAgentWindowParkingTests: XCTestCase {
    private let key = "agent_mode.fleet_park_agent_windows"

    func testCatalogListsDefaultFalseBooleanSetting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let listed = try await fixture.service.handleForTesting([
            "op": .string("list"), "group": .string("agent_mode"), "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let entry = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(entry.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(entry.objectValue?["value"]?.boolValue, false)
    }

    func testStringKeyGetAndSetRoundTripBothBooleanValues() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let initial = try await fixture.service.handleForTesting([
            "op": .string("get"), "key": .string(key)
        ])
        XCTAssertEqual(initial.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        for enabled in [true, false] {
            let result = try await fixture.service.handleForTesting([
                "op": .string("set"), "key": .string(key), "value": .bool(enabled)
            ])
            XCTAssertEqual(result.objectValue?["new_value"]?.boolValue, enabled)
            let read = try await fixture.service.handleForTesting([
                "op": .string("get"), "key": .string(key)
            ])
            XCTAssertEqual(read.objectValue?["values"]?.objectValue?[key]?.boolValue, enabled)
        }
    }

    func testStringKeySettingPersistsAcrossIsolatedStoreReload() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.service.handleForTesting([
            "op": .string("set"), "key": .string(key), "value": .bool(true)
        ])
        let reloaded = GlobalSettingsStore(
            defaults: fixture.defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fixture.fileURL)
        )
        let read = try await AppSettingsMCPService(store: reloaded).handleForTesting([
            "op": .string("get"), "key": .string(key)
        ])
        XCTAssertEqual(read.objectValue?["values"]?.objectValue?[key]?.boolValue, true)
    }

    func testAbsentAgentModeFieldReadsFalse() async throws {
        let fixture = try makeFixture(
            contents: "{\"schemaVersion\":7,\"scalarPreferences\":{\"agentMode\":{}}}"
        )
        defer { fixture.cleanup() }

        let read = try await fixture.service.handleForTesting([
            "op": .string("get"), "key": .string(key)
        ])
        XCTAssertEqual(read.objectValue?["values"]?.objectValue?[key]?.boolValue, false)
    }

    // MARK: - Enabled new-window routes park after bind (U2)

    private let routeClient = "FleetAgentWindowParkingTests"

    @MainActor
    private final class RouteFixture {
        let root: URL
        let connectionID = UUID()
        let service: WindowRoutingService
        let anchor: WindowState
        var created: [WindowState] = []
        var nsWindows: [NSWindow] = []
        var openerCalls = 0
        var attachOpenedWindows = true

        init(root: URL, service: WindowRoutingService, anchor: WindowState) {
            self.root = root
            self.service = service
            self.anchor = anchor
        }

        func openSimulatedWindow(requestID: UUID?) {
            openerCalls += 1
            let state = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime, openRequestID: requestID)
            created.append(state)
            if attachOpenedWindows {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                nsWindows.append(window)
                window.orderFront(nil)
                state.attachWindow(window)
            }
            WindowStatesManager.shared.registerWindowState(state)
        }

        @discardableResult
        func attachLate(_ state: WindowState) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            nsWindows.append(window)
            window.orderFront(nil)
            state.attachWindow(window)
            return window
        }

        func call(_ toolName: String, client: String, _ args: [String: Value]) async throws -> Value {
            let tools = await service.tools
            let tool = try XCTUnwrap(tools.first { $0.name == toolName })
            let metadata = MCPRequestMetadata(connectionID: connectionID, clientName: client, windowID: nil)
            let invocation = ToolInvocationContext.trustedLocal(toolName: toolName, metadata: metadata)
            return try await ServerNetworkManager.currentConnectionIDTaskLocal.withValue(connectionID) {
                try await MCPInvocationContextBridge.withInvocation(invocation) { try await tool(args) }
            }
        }
    }

    private func withRouteFixture(
        enabled: Bool = true,
        _ body: @MainActor (RouteFixture) async throws -> Void
    ) async throws {
        let sandbox = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let prefix = URL(fileURLWithPath: sandbox).resolvingSymlinksInPath().path + "/"
        guard WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path.hasPrefix(prefix)
        else { throw FleetFixtureError.unsafeSandbox }
        guard WindowStatesManager.shared.pendingURLs.isEmpty, !WindowStatesManager.shared.isTerminating
        else { throw FleetFixtureError.notReady }
        _ = NSApplication.shared

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetAgentWindowParkingRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let previousStorage = defaults.string(forKey: "GlobalCustomStorageURL")
        defaults.set(root.appendingPathComponent("storage").path, forKey: "GlobalCustomStorageURL")
        let previousApproval = defaults.object(forKey: "workspace.approvalSettings")
        let store = GlobalSettingsStore.shared
        let previousAutoStart = store.mcpAutoStart()
        let previousPark = store.fleetParkAgentWindows()
        store.setMCPAutoStart(false, commit: false)
        store.setFleetParkAgentWindows(enabled, commit: false)
        FleetParkingCoordinator.shared.resetForTesting()
        FleetParkingCoordinator.shared.setAutomaticBackstopDeliveryEnabledForTesting(false)
        AppWindowOpener.shared.resetForTesting()
        WorkspaceApprovalManager.shared.addAutoApproval(clientID: routeClient, operation: .createWorkspace)

        let anchor = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
        WindowStatesManager.shared.registerWindowState(anchor)
        let service = WindowRoutingService(windowStates: WindowStatesManager.shared, networkMgr: ServerNetworkManager.shared)
        await service.prepareDomainTools()
        let fixture = RouteFixture(root: root, service: service, anchor: anchor)

        func cleanup() async {
            AppWindowOpener.shared.resetForTesting()
            await ServerNetworkManager.shared.debugRemoveConnection(fixture.connectionID)
            for state in fixture.created + [anchor] {
                state.attachWindow(nil)
                state.beginClose()
                await state.tearDown()
                WindowStatesManager.shared.unregisterWindowState(state)
            }
            for window in fixture.nsWindows {
                window.orderOut(nil)
            }
            FleetParkingCoordinator.shared.resetForTesting()
            WorkspaceApprovalManager.shared.removeAutoApproval(clientID: routeClient, operation: .createWorkspace)
            if let previousApproval { defaults.set(previousApproval, forKey: "workspace.approvalSettings") }
            else { defaults.removeObject(forKey: "workspace.approvalSettings") }
            store.setFleetParkAgentWindows(previousPark, commit: false)
            store.setMCPAutoStart(previousAutoStart, commit: false)
            await WorkspaceDiskWriterComposition.processWriter.removeAllForTesting()
            if let previousStorage { defaults.set(previousStorage, forKey: "GlobalCustomStorageURL") }
            else { defaults.removeObject(forKey: "GlobalCustomStorageURL") }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            await anchor.workspaceManager.awaitInitialized()
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            try await body(fixture)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// Persists a workspace that no window shows; the anchor keeps its default workspace.
    private func persistUnshownWorkspace(_ fixture: RouteFixture, name: String) async throws -> (WorkspaceModel, String) {
        let repo = fixture.root.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let creation = try fixture.anchor.workspaceManager.createPersistentWorkspace(
            name: name, repoPaths: [repo.path], savedInLibrary: true
        )
        let workspace = try await creation.publishedWorkspace()
        return (workspace, repo.path)
    }

    private func assertParkedAfterBind(_ fixture: RouteFixture, route: String, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(fixture.openerCalls, 1, "\(route): one window opened", file: file, line: line)
        guard let opened = fixture.created.first else {
            return XCTFail("\(route): no window opened", file: file, line: line)
        }
        let bound = await ServerNetworkManager.shared.selectedWindow(for: fixture.connectionID)
        XCTAssertEqual(bound, opened.windowID, "\(route): connection bound to new window", file: file, line: line)
        XCTAssertTrue(
            FleetParkingCoordinator.shared.isParked(windowID: opened.windowID),
            "\(route): new window parked after bind", file: file, line: line
        )
        XCTAssertTrue(
            WindowStatesManager.shared.allWindows.contains { $0 === opened },
            "\(route): parked window stays registered", file: file, line: line
        )
        XCTAssertFalse(opened.nsWindow?.isVisible ?? true, "\(route): parked NSWindow is off screen", file: file, line: line)
        XCTAssertFalse(opened.nsWindow?.isKeyWindow ?? true, "\(route): parked NSWindow is not key", file: file, line: line)
    }

    func testEnabledBindWorkingDirsExistingUnshownWorkspaceParksNewWindowAfterBind() async throws {
        try await withRouteFixture { fixture in
            let (_, repoPath) = try await self.persistUnshownWorkspace(fixture, name: "Route WD \(UUID().uuidString.prefix(6))")
            _ = try await fixture.call("bind_context", client: self.routeClient, [
                "op": .string("bind"), "working_dirs": .array([.string(repoPath)])
            ])
            await self.assertParkedAfterBind(fixture, route: "bind working_dirs existing")
        }
    }

    func testEnabledBindCreateIfMissingParksNewWindowAfterBind() async throws {
        try await withRouteFixture { fixture in
            let repo = fixture.root.appendingPathComponent("created-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await fixture.call("bind_context", client: self.routeClient, [
                "op": .string("bind"), "working_dirs": .array([.string(repo.path)]),
                "create_if_missing": .bool(true)
            ])
            await self.assertParkedAfterBind(fixture, route: "bind create_if_missing")
        }
    }

    func testEnabledWorkspaceSwitchOpenInNewWindowParksNewWindowAfterBind() async throws {
        try await withRouteFixture { fixture in
            let name = "Route Switch \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            _ = try await fixture.call("manage_workspaces", client: self.routeClient, [
                "action": .string("switch"), "workspace": .string(name), "open_in_new_window": .bool(true)
            ])
            await self.assertParkedAfterBind(fixture, route: "manage_workspaces switch")
        }
    }

    func testEnabledWorkspaceCreateOpenInNewWindowParksForBothSwitchToCreatedValues() async throws {
        for switchToCreated in [true, false] {
            try await withRouteFixture { fixture in
                let repo = fixture.root.appendingPathComponent("create-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
                _ = try await fixture.call("manage_workspaces", client: self.routeClient, [
                    "action": .string("create"), "name": .string("Route Create \(UUID().uuidString.prefix(6))"),
                    "folder_path": .string(repo.path), "open_in_new_window": .bool(true),
                    "switch_to_created": .bool(switchToCreated)
                ])
                await self.assertParkedAfterBind(fixture, route: "manage_workspaces create switch_to_created=\(switchToCreated)")
            }
        }
    }

    func testDisabledSettingLeavesRoutedNewWindowUnparked() async throws {
        try await withRouteFixture(enabled: false) { fixture in
            let name = "Route Off \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            _ = try await fixture.call("manage_workspaces", client: self.routeClient, [
                "action": .string("switch"), "workspace": .string(name), "open_in_new_window": .bool(true)
            ])
            let opened = try XCTUnwrap(fixture.created.first)
            let bound = await ServerNetworkManager.shared.selectedWindow(for: fixture.connectionID)
            XCTAssertEqual(bound, opened.windowID)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: opened.windowID))
        }
    }

    // MARK: - Identity, deadline and cancellation seams (U2; no red claimed, declarations are new)

    @MainActor
    private final class FakeParkClock {
        var time: TimeInterval = 0
        private(set) var requestedSleeps: [TimeInterval] = []
        private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
        var activeSleepers: Int {
            sleepers.count
        }

        var clock: WindowParkOnOpenClock {
            WindowParkOnOpenClock(now: { self.time }, sleep: { try await self.sleep($0) })
        }

        private func sleep(_ duration: TimeInterval) async throws {
            let id = UUID()
            requestedSleeps.append(duration)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    sleepers[id] = continuation
                }
            } onCancel: {
                Task { @MainActor in
                    self.sleepers.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }

        func fireSleepers() {
            let all = sleepers
            sleepers = [:]
            for continuation in all.values {
                continuation.resume()
            }
        }
    }

    @MainActor
    private final class ParkSpy {
        var parked: [Int] = []
        var unparked: [Int] = []
        func handle(clock: FakeParkClock, parkResult: Bool = true) -> WindowParkOnOpenHandle {
            WindowParkOnOpenHandle(
                clock: clock.clock,
                park: { self.parked.append($0)
                    return parkResult
                },
                unpark: { self.unparked.append($0) }
            )
        }
    }

    private struct SyncTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// A failed synchronization fails the test; it never skips the behavior under test.
    private func waitUntil(_ description: String, timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else {
                XCTFail("timed out waiting for \(description)")
                throw SyncTimeout(description: "timed out waiting for \(description)")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testHandleDeadlineAdmitsAttachBeforeFiveSecondsAndRejectsAtOrAfter() async throws {
        for (elapsed, expectPark) in [(4.9, true), (5.0, false), (5.1, false)] as [(TimeInterval, Bool)] {
            let clock = FakeParkClock()
            let spy = ParkSpy()
            let handle = spy.handle(clock: clock)
            handle.markRegistered(windowID: 7)
            XCTAssertEqual(handle.deadline, 5)
            clock.time = elapsed
            handle.attemptParkIfAdmitted()
            XCTAssertEqual(spy.parked, expectPark ? [7] : [], "attach at \(elapsed)s")
            XCTAssertEqual(handle.phase, expectPark ? .parked : .timedOut, "attach at \(elapsed)s")
            let outcome = try await handle.awaitOutcome()
            XCTAssertEqual(outcome, expectPark ? .parked : .timedOut)
            XCTAssertEqual(clock.activeSleepers, 0)
            XCTAssertFalse(handle.hasActiveWaiter)
        }
    }

    func testHandleNoAttachWaitsRemainingDurationThenTimesOutAtDeadline() async throws {
        let clock = FakeParkClock()
        let spy = ParkSpy()
        let handle = spy.handle(clock: clock, parkResult: false)
        handle.markRegistered(windowID: 3)
        clock.time = 3
        let waiter = Task { @MainActor in try await handle.awaitOutcome() }
        try await waitUntil("timeout sleeper") { clock.activeSleepers == 1 }
        XCTAssertEqual(clock.requestedSleeps, [2], "wait uses the remaining duration, not a fresh 5 s")
        clock.time = 5
        clock.fireSleepers()
        let outcome = try await waiter.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(clock.activeSleepers, 0)
        handle.attemptParkIfAdmitted()
        XCTAssertTrue(spy.parked.isEmpty, "no late parking after timeout")
    }

    func testHandleBindAfterDeadlineSettlesImmediatelyWithoutSleeper() async throws {
        let clock = FakeParkClock()
        let spy = ParkSpy()
        let handle = spy.handle(clock: clock, parkResult: false)
        handle.markRegistered(windowID: 4)
        clock.time = 6
        let outcome = try await handle.awaitOutcome()
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertTrue(clock.requestedSleeps.isEmpty)
        XCTAssertEqual(clock.activeSleepers, 0)
    }

    func testParkedOutcomeIsImmutableAndRevealIsOwnedOnce() {
        let clock = FakeParkClock()
        let spy = ParkSpy()
        let handle = spy.handle(clock: clock)
        handle.markRegistered(windowID: 9)
        handle.attemptParkIfAdmitted()
        XCTAssertEqual(handle.phase, .parked)
        handle.cancelOwned()
        handle.cancelOwned()
        handle.revealParkedOnce()
        XCTAssertEqual(spy.unparked, [9])
        XCTAssertEqual(handle.phase, .parked)
        clock.time = 10
        handle.attemptParkIfAdmitted()
        XCTAssertEqual(handle.phase, .parked)
    }

    func testCancelledPendingHandleNeverParksLate() async throws {
        let clock = FakeParkClock()
        let spy = ParkSpy()
        let handle = spy.handle(clock: clock)
        handle.cancelOwned()
        handle.markRegistered(windowID: 2)
        handle.attemptParkIfAdmitted()
        XCTAssertTrue(spy.parked.isEmpty)
        XCTAssertEqual(handle.phase, .abandoned)
        do {
            _ = try await handle.awaitOutcome()
            XCTFail("abandoned handle must throw CancellationError")
        } catch is CancellationError {}
    }

    func testClaimOpenRequestRejectsNilStaleConsumedAndDuplicateIDs() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            var ids: [UUID] = []
            AppWindowOpener.shared.installRequestAwareForTesting { id in
                if let id { ids.append(id) }
            }
            let first = Task { @MainActor in try await manager.openNewMainWindow(parkOnOpen: true) }
            let second = Task { @MainActor in try await manager.openNewMainWindow(deferringInitialAgentSystemWorkspaceRefresh: true) }
            try await self.waitUntil("two requests") { ids.count == 2 }
            XCTAssertNotEqual(ids[0], ids[1], "fresh id per invocation")
            XCTAssertNil(manager.claimOpenRequest(id: nil))
            XCTAssertNil(manager.claimOpenRequest(id: UUID()))
            let claimed = try XCTUnwrap(manager.claimOpenRequest(id: ids[0]))
            XCTAssertTrue(claimed.request.parkOnOpen)
            XCTAssertNotNil(claimed.parkHandle)
            XCTAssertNil(manager.claimOpenRequest(id: ids[0]), "consumed/duplicate claims nothing")
            let deferral = try XCTUnwrap(manager.claimOpenRequest(id: ids[1]))
            XCTAssertNotNil(deferral.request.refreshDeferralID)
            XCTAssertFalse(deferral.request.parkOnOpen)
            XCTAssertNil(deferral.parkHandle, "deferral-only request does not park")
            manager.cancelOpen(requestID: ids[0])
            manager.cancelOpen(requestID: ids[1])
            for task in [first, second] {
                do { _ = try await task.value
                    XCTFail("expected cancellation")
                } catch is CancellationError {}
            }
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            _ = fixture
        }
    }

    func testDockNilDeliveryClaimsNoParkIntentAtManagerLevel() async throws {
        try await withRouteFixture { _ in
            let manager = WindowStatesManager.shared
            var delivered: [UUID?] = []
            // Queued before the opener exists, then drained by installation.
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.requestMainWindowFromDock()
            AppWindowOpener.shared.installRequestAware { delivered.append($0) }
            XCTAssertEqual(delivered.count, 1)
            XCTAssertNil(delivered[0] ?? nil)
            // Direct request while a park intent is pending.
            var parkID: UUID?
            AppWindowOpener.shared.installRequestAwareForTesting { id in
                if let id { parkID = id } else { delivered.append(nil) }
            }
            let task = Task { @MainActor in try await manager.openNewMainWindow(parkOnOpen: true) }
            try await self.waitUntil("park request") { parkID != nil }
            AppWindowOpener.shared.requestMainWindowFromDock()
            XCTAssertNil(manager.claimOpenRequest(id: nil), "Dock nil value claims no park intent")
            XCTAssertNotNil(manager.claimOpenRequest(id: parkID))
            try manager.cancelOpen(requestID: XCTUnwrap(parkID))
            do { _ = try await task.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            XCTAssertEqual(delivered.count, 2)
        }
    }

    func testManualScopeCancelAfterResumeRevealsParkedWindowOnceThenAdoptionThrows() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let scope = WindowParkOnOpenScope(manager: manager)
            let result = try await manager.openNewMainWindow(parkOnOpen: true, requestID: scope.requestID)
            let window = result.window
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: window.windowID), "parked at registration")
            XCTAssertEqual(manager.pendingOpenOperationCount, 1, "manager still owns the resumed handoff")
            scope.cancel()
            scope.cancel()
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: window.windowID), "revealed")
            XCTAssertThrowsError(try scope.adopt()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertTrue(manager.allWindows.contains { $0 === window })
            XCTAssertEqual(result.parkHandle?.phase, .parked)
            XCTAssertFalse(result.parkHandle?.hasActiveWaiter ?? true)
        }
    }

    func testManualScopeCancelWhileWaitingResumesOnceAndLeavesNoOperation() async throws {
        try await withRouteFixture { _ in
            let manager = WindowStatesManager.shared
            var requestID: UUID?
            AppWindowOpener.shared.installRequestAwareForTesting { requestID = $0 }
            let scope = WindowParkOnOpenScope(manager: manager)
            let task = Task { @MainActor in try await manager.openNewMainWindow(parkOnOpen: true, requestID: scope.requestID) }
            try await self.waitUntil("opener call") { requestID != nil }
            scope.cancel()
            do { _ = try await task.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertNil(manager.claimOpenRequest(id: scope.requestID))
        }
    }

    func testManualScopeCancelAfterAdoptionRevealsParkedWindowOnce() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let scope = WindowParkOnOpenScope(manager: manager)
            _ = try await manager.openNewMainWindow(parkOnOpen: true, requestID: scope.requestID)
            let window = try scope.adopt()
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: window.windowID))
            scope.cancel()
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: window.windowID))
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testOpenerErrorStaysOriginalAndLeavesNoOperation() async throws {
        try await withRouteFixture { _ in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.resetForTesting()
            do {
                _ = try await manager.openNewMainWindow(parkOnOpen: true)
                XCTFail("expected opener error")
            } catch let error as WindowOpenError {
                guard case .openerUnavailable = error else { return XCTFail("wrong error \(error)") }
            }
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testRouteOpenerErrorKeepsLegacyMessageWithSettingEnabled() async throws {
        try await withRouteFixture { fixture in
            AppWindowOpener.shared.resetForTesting()
            let name = "Route Err \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            do {
                _ = try await fixture.call("manage_workspaces", client: self.routeClient, [
                    "action": .string("switch"), "workspace": .string(name), "open_in_new_window": .bool(true)
                ])
                XCTFail("expected opener failure")
            } catch {
                XCTAssertTrue(
                    "\(error)".contains("Failed to open new window: Window opener not available"),
                    "\(error)"
                )
            }
            XCTAssertEqual(WindowStatesManager.shared.pendingOpenOperationCount, 0)
        }
    }

    func testRouteRegisteredAtZeroBoundAtZeroTimesOutAfterFullFiveSeconds() async throws {
        try await withRouteFixture { fixture in
            let clock = FakeParkClock()
            let manager = WindowStatesManager.shared
            let previousClock = manager.parkOnOpenClock
            manager.parkOnOpenClock = clock.clock
            defer { manager.parkOnOpenClock = previousClock }
            fixture.attachOpenedWindows = false
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let name = "Route Timeout \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            let route = Task { @MainActor in
                try await fixture.call("manage_workspaces", client: self.routeClient, [
                    "action": .string("switch"), "workspace": .string(name), "open_in_new_window": .bool(true)
                ])
            }
            try await self.waitUntil("park timeout sleeper") { clock.activeSleepers == 1 }
            XCTAssertEqual(clock.requestedSleeps, [5])
            clock.time = 5
            clock.fireSleepers()
            do {
                _ = try await route.value
                XCTFail("expected not-parked error")
            } catch {
                let opened = try XCTUnwrap(fixture.created.first)
                XCTAssertTrue(
                    "\(error)".contains("Window \(opened.windowID) opened but was not parked within 5 s; it stays on screen and unparked."),
                    "\(error)"
                )
                let bound = await ServerNetworkManager.shared.selectedWindow(for: fixture.connectionID)
                XCTAssertEqual(bound, opened.windowID, "bound before the park failure")
                XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: opened.windowID))
                XCTAssertTrue(manager.allWindows.contains { $0 === opened })
            }
            XCTAssertEqual(clock.activeSleepers, 0)
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    // MARK: - Lifecycle orders, Dock origins, gated cancellation and route deadline integration (U2 a4)

    // Every test below holds at most two real WindowStates.

    @MainActor
    private final class AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false
        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class LifecycleFixture {
        var states: [WindowState] = []
        var nsWindows: [NSWindow] = []

        func makeState(openRequestID: UUID?) -> WindowState {
            let state = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime, openRequestID: openRequestID)
            states.append(state)
            XCTAssertLessThanOrEqual(states.count, 2, "at most two real WindowStates per test")
            return state
        }

        @discardableResult
        func attach(_ state: WindowState) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            nsWindows.append(window)
            window.orderFront(nil)
            state.attachWindow(window)
            return window
        }
    }

    private func withLifecycleFixture(
        _ body: @MainActor (LifecycleFixture, FakeParkClock) async throws -> Void
    ) async throws {
        let sandbox = try XCTUnwrap(ProcessInfo.processInfo.environment["REPOPROMPT_TEST_SANDBOX_ROOT"])
        let prefix = URL(fileURLWithPath: sandbox).resolvingSymlinksInPath().path + "/"
        guard WindowSessionStore.sessionFileURL().resolvingSymlinksInPath().path.hasPrefix(prefix)
        else { throw FleetFixtureError.unsafeSandbox }
        guard WindowStatesManager.shared.pendingURLs.isEmpty, !WindowStatesManager.shared.isTerminating
        else { throw FleetFixtureError.notReady }
        _ = NSApplication.shared
        let store = GlobalSettingsStore.shared
        let previousAutoStart = store.mcpAutoStart()
        store.setMCPAutoStart(false, commit: false)
        let manager = WindowStatesManager.shared
        let previousClock = manager.parkOnOpenClock
        let clock = FakeParkClock()
        manager.parkOnOpenClock = clock.clock
        FleetParkingCoordinator.shared.resetForTesting()
        FleetParkingCoordinator.shared.setAutomaticBackstopDeliveryEnabledForTesting(false)
        AppWindowOpener.shared.resetForTesting()
        let fixture = LifecycleFixture()

        func cleanup() async {
            AppWindowOpener.shared.resetForTesting()
            for state in fixture.states {
                state.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral()
                state.attachWindow(nil)
                state.beginClose()
                await state.tearDown()
                manager.unregisterWindowState(state)
            }
            for window in fixture.nsWindows {
                window.contentView = nil
                window.orderOut(nil)
            }
            FleetParkingCoordinator.shared.resetForTesting()
            manager.parkOnOpenClock = previousClock
            store.setMCPAutoStart(previousAutoStart, commit: false)
        }
        do {
            try await body(fixture, clock)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// Records every id delivered to the shipped request-aware opener (nil for Dock requests).
    @MainActor
    private final class OpenerRecorder {
        var delivered: [UUID?] = []
        var ids: [UUID] {
            delivered.compactMap(\.self)
        }
    }

    private func installRecorder() -> OpenerRecorder {
        let recorder = OpenerRecorder()
        AppWindowOpener.shared.installRequestAwareForTesting { recorder.delivered.append($0) }
        return recorder
    }

    private func startOpen(
        deferring: Bool = false,
        park: Bool = true
    ) -> Task<WindowOpenResult, Error> {
        Task { @MainActor in
            try await WindowStatesManager.shared.openNewMainWindow(
                deferringInitialAgentSystemWorkspaceRefresh: deferring,
                parkOnOpen: park
            )
        }
    }

    private func makeHiddenWindow(_ fixture: LifecycleFixture) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        fixture.nsWindows.append(window) // never ordered front: the backing view attaches hidden
        return window
    }

    private func makeAccessor(for state: WindowState) -> WindowAccessor {
        WindowAccessor.attaching(state)
    }

    private func hostRoot(for state: WindowState, counter: NativeAttachCounter) -> AnyView {
        AnyView(
            Color.clear
                .background(NativeAttachProbe(counter: counter))
                .background(makeAccessor(for: state))
        )
    }

    private func hostNatively(_ state: WindowState, in window: NSWindow, counter: NativeAttachCounter) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: hostRoot(for: state, counter: counter))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testNativeAttachDeliversWindowToPendingIntentStateDuringAttach() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            manager.registerWindowState(state)
            let result = try await task.value
            let handle = try XCTUnwrap(result.parkHandle)
            XCTAssertEqual(handle.phase, .pending)
            let window = self.makeHiddenWindow(fixture)
            let counter = NativeAttachCounter()
            let host = self.hostNatively(state, in: window, counter: counter)
            XCTAssertEqual(counter.count, 1, "harness precondition: the backing views attached natively during layout")
            XCTAssertTrue(state.nsWindow === window, "the accessor's attach callback must hand the NSWindow to attachWindow during the native attach")
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "a held intent parks at the attach moment")
            XCTAssertEqual(handle.phase, .parked)
            host.rootView = self.hostRoot(for: state, counter: counter)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(state.nsWindow === window)
            XCTAssertEqual(handle.phase, .parked)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testNativeAttachBeforeRegistrationStoresWindowThenRegistrationParks() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            let window = self.makeHiddenWindow(fixture)
            let counter = NativeAttachCounter()
            _ = self.hostNatively(state, in: window, counter: counter)
            XCTAssertEqual(counter.count, 1, "harness precondition: the backing views attached natively during layout")
            XCTAssertTrue(state.nsWindow === window, "the native attach must store the NSWindow before registration")
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            XCTAssertEqual(state.parkOnOpenHandle?.phase, .pending)
            manager.registerWindowState(state)
            let result = try await task.value
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "registration parks the stored window")
            XCTAssertEqual(result.parkHandle?.phase, .parked)
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testNativeAttachWithoutParkIntentDeliversNothingUntilTheSwiftUIUpdate() async throws {
        try await withLifecycleFixture { fixture, _ in
            let state = fixture.makeState(openRequestID: nil)
            XCTAssertNil(state.parkOnOpenHandle)
            XCTAssertEqual(WindowStatesManager.shared.pendingOpenOperationCount, 0)
            let window = self.makeHiddenWindow(fixture)
            let counter = NativeAttachCounter()
            _ = self.hostNatively(state, in: window, counter: counter)
            XCTAssertEqual(counter.count, 1, "harness precondition: the backing views attached natively during layout")
            XCTAssertNil(state.nsWindow)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertNil(state.nsWindow)
            XCTAssertEqual(WindowStatesManager.shared.pendingOpenOperationCount, 0)
        }
    }

    func testNativeAttachMovedToAnotherWindowBeforeRegistrationParksTheLatestWindow() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            let windowA = self.makeHiddenWindow(fixture)
            let windowB = self.makeHiddenWindow(fixture)
            let counter = NativeAttachCounter()
            let host = self.hostNatively(state, in: windowA, counter: counter)
            XCTAssertEqual(counter.count, 1, "harness precondition: the backing views attached natively during layout")
            XCTAssertTrue(state.nsWindow === windowA, "window A is delivered when the view attaches to it")
            windowA.contentView = nil
            windowB.contentView = host
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(counter.count, 2, "harness precondition: the backing views re-attached to window B")
            XCTAssertTrue(state.nsWindow === windowB, "window B is delivered when the view attaches to it")
            manager.registerWindowState(state)
            let result = try await task.value
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            XCTAssertEqual(result.parkHandle?.phase, .parked)
            XCTAssertTrue(state.nsWindow === windowB)
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testAttachOrderRegisterThenAttachParksAtAttach() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            XCTAssertEqual(state.claimedOpenRequestID, recorder.ids[0])
            manager.registerWindowState(state)
            let result = try await task.value
            XCTAssertTrue(result.window === state)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "registered but unattached")
            let window = fixture.attach(state)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "parked at attach")
            XCTAssertFalse(window.isVisible, "attach parked the NSWindow off screen and nothing re-showed it")
            let outcome = try await result.parkHandle?.awaitOutcome()
            XCTAssertEqual(outcome, .parked)
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testAttachOrderAttachThenFirstRegistrationClaimsAndParksAtRegistration() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            fixture.attach(state)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "attach before registration never parks")
            XCTAssertEqual(state.parkOnOpenHandle?.phase, .pending)
            manager.registerWindowState(state)
            let result = try await task.value
            XCTAssertTrue(result.window === state)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "parked at first registration")
            // A duplicate registration neither re-resumes nor re-parks.
            manager.registerWindowState(state)
            XCTAssertEqual(state.parkOnOpenHandle?.phase, .parked)
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testAttachOrderLateAttachAfterDeadlineIsRejectedAndWindowStaysVisible() async throws {
        try await withLifecycleFixture { fixture, clock in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            manager.registerWindowState(state)
            let result = try await task.value
            let handle = try XCTUnwrap(result.parkHandle)
            XCTAssertEqual(handle.deadline, 5)
            clock.time = 5.1
            let window = fixture.attach(state)
            XCTAssertEqual(handle.phase, .timedOut)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            XCTAssertTrue(window.isVisible)
            let outcome = try await handle.awaitOutcome()
            XCTAssertEqual(outcome, .timedOut)
            XCTAssertTrue(clock.requestedSleeps.isEmpty)
            XCTAssertEqual(clock.activeSleepers, 0)
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
        }
    }

    func testAttachBeforeDeadlineAtFourPointNineParks() async throws {
        try await withLifecycleFixture { fixture, clock in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            manager.registerWindowState(state)
            _ = try await task.value
            clock.time = 4.9
            let window = fixture.attach(state)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            XCTAssertFalse(window.isVisible, "timely attach leaves the NSWindow off screen")
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
        }
    }

    func testDockQueuedThenDrainedNilWindowInitializedFirstClaimsNothingAndCannotStealParkIntent() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.requestMainWindowFromDock() // queued: no opener installed yet
            let drained = OpenerRecorder()
            AppWindowOpener.shared.installRequestAware { drained.delivered.append($0) } // drains queued request
            XCTAssertEqual(drained.delivered.count, 1)
            XCTAssertNil(drained.delivered[0] ?? nil, "queued Dock request carries no value")
            let recorder = self.installRecorder()
            let dockState = fixture.makeState(openRequestID: nil) // init order: nil first
            let task = self.startOpen()
            try await self.waitUntil("park request") { recorder.ids.count == 1 }
            let parkState = fixture.makeState(openRequestID: recorder.ids[0]) // then valued
            XCTAssertNil(dockState.claimedOpenRequestID)
            XCTAssertNil(dockState.parkOnOpenHandle)
            XCTAssertNotNil(parkState.parkOnOpenHandle)
            manager.registerWindowState(dockState)
            fixture.attach(dockState)
            manager.registerWindowState(parkState)
            fixture.attach(parkState)
            let result = try await task.value
            XCTAssertTrue(result.window === parkState)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: parkState.windowID))
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: dockState.windowID))
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
        }
    }

    func testDockDirectNilWindowInitializedFirstClaimsNothingAndCannotStealParkIntent() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            AppWindowOpener.shared.requestMainWindowFromDock() // direct delivery with an installed opener
            XCTAssertEqual(recorder.delivered.count, 1)
            XCTAssertNil(recorder.delivered[0] ?? nil)
            let dockState = fixture.makeState(openRequestID: nil) // init order: nil first
            let task = self.startOpen()
            try await self.waitUntil("park request") { recorder.ids.count == 1 }
            let parkState = fixture.makeState(openRequestID: recorder.ids[0])
            manager.registerWindowState(parkState) // reverse registration order
            fixture.attach(parkState)
            manager.registerWindowState(dockState)
            fixture.attach(dockState)
            let result = try await task.value
            XCTAssertTrue(result.window === parkState)
            XCTAssertNil(dockState.parkOnOpenHandle)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: parkState.windowID))
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: dockState.windowID))
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
        }
    }

    func testDockDirectNilWindowInitializedAfterValuedWindowClaimsNothing() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("park request") { recorder.ids.count == 1 }
            let parkState = fixture.makeState(openRequestID: recorder.ids[0]) // init order: valued first
            AppWindowOpener.shared.requestMainWindowFromDock() // direct Dock nil while the intent is in flight
            XCTAssertEqual(recorder.delivered.count, 2)
            XCTAssertNil(recorder.delivered[1] ?? nil)
            let dockState = fixture.makeState(openRequestID: nil)
            XCTAssertNil(dockState.claimedOpenRequestID)
            manager.registerWindowState(dockState)
            fixture.attach(dockState)
            manager.registerWindowState(parkState)
            fixture.attach(parkState)
            let result = try await task.value
            XCTAssertTrue(result.window === parkState)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: parkState.windowID))
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: dockState.windowID))
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
        }
    }

    func testTwoInFlightRequestsResolveByIdentityUnderReverseRegistrationWithParkOnlyAndCombinedIntents() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let first = self.startOpen(deferring: false, park: true) // park-only
            try await self.waitUntil("first id") { recorder.ids.count == 1 }
            let second = self.startOpen(deferring: true, park: true) // combined park + refresh deferral
            try await self.waitUntil("second id") { recorder.ids.count == 2 }
            XCTAssertNotEqual(recorder.ids[0], recorder.ids[1], "fresh id per open")
            let s1 = fixture.makeState(openRequestID: recorder.ids[0])
            let s2 = fixture.makeState(openRequestID: recorder.ids[1])
            XCTAssertNil(s1.claimedInitialRefreshDeferralID, "park-only stays refresh-undeferred")
            XCTAssertNotNil(s2.claimedInitialRefreshDeferralID, "combined request defers refresh")
            XCTAssertEqual(s2.claimedInitialRefreshDeferralWaiterID, recorder.ids[1])
            fixture.attach(s1)
            fixture.attach(s2)
            manager.registerWindowState(s2) // reverse of open order
            manager.registerWindowState(s1)
            let r2 = try await second.value
            let r1 = try await first.value
            XCTAssertTrue(r1.window === s1)
            XCTAssertTrue(r2.window === s2)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: s1.windowID))
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: s2.windowID))
            XCTAssertNil(manager.claimOpenRequest(id: recorder.ids[0]), "consumed id cannot be claimed again")
            for id in recorder.ids {
                _ = try manager.adoptOpen(requestID: id)
            }
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testDeferralOnlyRequestClaimsDeferralWithoutParkHandleAndIsNotParked() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen(deferring: true, park: false)
            try await self.waitUntil("deferral id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            XCTAssertNotNil(state.claimedInitialRefreshDeferralID)
            XCTAssertNil(state.parkOnOpenHandle)
            fixture.attach(state)
            manager.registerWindowState(state)
            let result = try await task.value
            XCTAssertTrue(result.window === state)
            XCTAssertNil(result.parkHandle)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            XCTAssertEqual(manager.pendingOpenOperationCount, 0, "plain/deferral-only opens leave no retained handoff")
        }
    }

    func testStaleConsumedAndDuplicateIDsClaimNothingInRealInitializers() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("park request") { recorder.ids.count == 1 }
            let stale = fixture.makeState(openRequestID: UUID())
            XCTAssertNil(stale.claimedOpenRequestID)
            XCTAssertNil(stale.parkOnOpenHandle)
            let matching = fixture.makeState(openRequestID: recorder.ids[0])
            XCTAssertEqual(matching.claimedOpenRequestID, recorder.ids[0])
            XCTAssertNotNil(matching.parkOnOpenHandle)
            XCTAssertNil(manager.claimOpenRequest(id: recorder.ids[0]), "duplicate value claims nothing")
            manager.cancelOpen(requestID: recorder.ids[0])
            do { _ = try await task.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            XCTAssertNil(manager.claimOpenRequest(id: recorder.ids[0]), "cancelled id is stale")
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testZeroArgumentAndDefaultInitializersClaimNothingWhileIntentIsPending() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("park request") { recorder.ids.count == 1 }
            let zero = WindowState()
            fixture.states.append(zero)
            let defaulted = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            fixture.states.append(defaulted)
            XCTAssertEqual(fixture.states.count, 2)
            XCTAssertNil(zero.claimedOpenRequestID)
            XCTAssertNil(defaulted.claimedOpenRequestID)
            XCTAssertNil(zero.parkOnOpenHandle)
            XCTAssertNil(defaulted.parkOnOpenHandle)
            XCTAssertNotNil(manager.claimOpenRequest(id: recorder.ids[0]), "intent is still unclaimed")
            manager.cancelOpen(requestID: recorder.ids[0])
            do { _ = try await task.value } catch is CancellationError {}
        }
    }

    // MARK: - Already-attached-at-claim order (injected seam; unreachable in production, see u2 a5 report)

    func testAttachBeforeClaimNoIDStateClaimsPendingRequestThenFirstRegistrationParks() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: nil)
            fixture.attach(state)
            XCTAssertNil(state.claimedOpenRequestID, "no value delivered at initialization")
            XCTAssertNil(state.parkOnOpenHandle)
            XCTAssertNotNil(state.nsWindow, "already attached at claim time")
            let claim = try XCTUnwrap(manager.claimOpenRequest(id: recorder.ids[0]))
            state.adoptClaimedOpenRequestForTesting(claim)
            XCTAssertEqual(state.claimedOpenRequestID, recorder.ids[0])
            XCTAssertEqual(state.parkOnOpenHandle?.phase, .pending)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "claim alone never parks")
            XCTAssertNil(manager.claimOpenRequest(id: recorder.ids[0]), "claim is consumed")
            manager.registerWindowState(state)
            let result = try await task.value
            XCTAssertTrue(result.window === state)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: state.windowID), "parked at first registration")
            _ = try manager.adoptOpen(requestID: recorder.ids[0])
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testCancelAfterClaimBeforeRegistrationAbandonsHandleSoLaterAttachAndRegistrationNeverPark() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let state = fixture.makeState(openRequestID: recorder.ids[0])
            XCTAssertEqual(state.parkOnOpenHandle?.phase, .pending)
            manager.cancelOpen(requestID: recorder.ids[0])
            do { _ = try await task.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            XCTAssertEqual(state.parkOnOpenHandle?.phase, .abandoned)
            fixture.attach(state)
            manager.registerWindowState(state)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: state.windowID))
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertTrue(manager.allWindows.contains { $0 === state })
            XCTAssertTrue(state.nsWindow?.isVisible ?? false)
        }
    }

    // MARK: Gated shipped cancellation

    private func routeSwitch(_ fixture: RouteFixture, name: String) -> Task<Value, Error> {
        Task { @MainActor in
            try await fixture.call("manage_workspaces", client: self.routeClient, [
                "action": .string("switch"), "workspace": .string(name), "open_in_new_window": .bool(true)
            ])
        }
    }

    func testTaskCancelWhileGatedAfterResumeBeforeAdoptionRevealsParkedWindowOnceAndAdoptionThrows() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            let clock = FakeParkClock()
            let previousClock = manager.parkOnOpenClock
            manager.parkOnOpenClock = clock.clock
            let gate = AsyncGate()
            manager.afterOpenResultGateForTesting = { await gate.wait() }
            defer {
                manager.afterOpenResultGateForTesting = nil
                manager.parkOnOpenClock = previousClock
            }
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let name = "Route Gate \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            let route = self.routeSwitch(fixture, name: name)
            try await self.waitUntil("gated resumed waiter") { gate.isWaiting }
            let opened = try XCTUnwrap(fixture.created.first)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: opened.windowID), "parked at registration")
            XCTAssertEqual(manager.pendingOpenOperationCount, 1, "manager still owns the resumed handoff")
            route.cancel()
            try await self.waitUntil("reveal by manager cancellation") {
                !FleetParkingCoordinator.shared.isParked(windowID: opened.windowID)
            }
            gate.open()
            do {
                _ = try await route.value
                XCTFail("cancelled route must not succeed")
            } catch {
                XCTAssertTrue(error is CancellationError, "new scope cancellation escapes legacy opener wrapping: \(error)")
            }
            let handle = try XCTUnwrap(opened.parkOnOpenHandle)
            XCTAssertEqual(handle.phase, .parked, "parked outcome stays immutable")
            XCTAssertTrue(handle.didReveal)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: opened.windowID))
            XCTAssertTrue(manager.allWindows.contains { $0 === opened }, "window stays registered")
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertFalse(handle.hasActiveWaiter)
            XCTAssertTrue(clock.requestedSleeps.isEmpty)
            XCTAssertEqual(clock.activeSleepers, 0)
            let bound = await ServerNetworkManager.shared.selectedWindow(for: fixture.connectionID)
            XCTAssertNotEqual(bound, opened.windowID, "cancelled before the route bound")
        }
    }

    func testTaskCancelWhileWaitingForRegistrationLeavesNoOperationAndStaleIDClaimsNothing() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let name = "Route Pending \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            let route = self.routeSwitch(fixture, name: name)
            try await self.waitUntil("opener call") { recorder.ids.count == 1 }
            XCTAssertEqual(manager.pendingOpenOperationCount, 1)
            route.cancel()
            do {
                _ = try await route.value
                XCTFail("cancelled route must not succeed")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertNil(manager.claimOpenRequest(id: recorder.ids[0]))
            let late = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime, openRequestID: recorder.ids[0])
            fixture.created.append(late)
            XCTAssertNil(late.claimedOpenRequestID, "late window with a cancelled id claims nothing")
            XCTAssertNil(late.parkOnOpenHandle)
        }
    }

    func testTaskCancelAfterAdoptionWhileParkedRevealsOnceAndDrainsEverything() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            let clock = FakeParkClock()
            let previousClock = manager.parkOnOpenClock
            manager.parkOnOpenClock = clock.clock
            let gate = AsyncGate()
            manager.afterOpenAdoptionGateForTesting = { await gate.wait() }
            defer {
                manager.afterOpenAdoptionGateForTesting = nil
                manager.parkOnOpenClock = previousClock
            }
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let name = "Route Adopted \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            let route = self.routeSwitch(fixture, name: name)
            try await self.waitUntil("adopted gate") { gate.isWaiting }
            let opened = try XCTUnwrap(fixture.created.first)
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: opened.windowID))
            XCTAssertEqual(manager.pendingOpenOperationCount, 0, "route scope owns the handle after adoption")
            route.cancel()
            try await self.waitUntil("reveal by route scope") {
                !FleetParkingCoordinator.shared.isParked(windowID: opened.windowID)
            }
            gate.open()
            do {
                _ = try await route.value
                XCTFail("cancelled route must not succeed")
            } catch let error as CancellationError {
                _ = error // scope/adoption/parking cancellation surfaces as CancellationError
            } catch let error as MCPError {
                // The shipped workspace switch observed the cancellation: the preserved legacy
                // workspace error policy (MCPError.invalidRequest) wins over a CancellationError.
                XCTAssertEqual(error.code, -32600)
                guard case let .invalidRequest(detail) = error else { return XCTFail("wrong MCP error \(error)") }
                XCTAssertTrue(detail?.contains("was cancelled before activation") ?? false, "\(error)")
            } catch {
                XCTFail("unexpected error type \(error)")
            }
            let handle = try XCTUnwrap(opened.parkOnOpenHandle)
            XCTAssertEqual(handle.phase, .parked)
            XCTAssertTrue(handle.didReveal)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: opened.windowID))
            XCTAssertTrue(manager.allWindows.contains { $0 === opened })
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertFalse(handle.hasActiveWaiter)
            XCTAssertEqual(clock.activeSleepers, 0)
        }
    }

    func testCancellationAcrossAtomicTakeIsOwnedExactlyOnce() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let scope = WindowParkOnOpenScope(manager: manager)
            let result = try await manager.openNewMainWindow(parkOnOpen: true, requestID: scope.requestID)
            let window = result.window
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: window.windowID))
            // The task is cancelled but scope.cancel() never ran: the manager still holds the resumed
            // handoff, adoption takes it, then observes cancellation and cleans up exactly once.
            let adopter = Task { @MainActor () throws -> WindowState in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return try scope.adopt()
            }
            adopter.cancel()
            do {
                _ = try await adopter.value
                XCTFail("adoption of a cancelled task must throw")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            scope.cancel()
            scope.cancel()
            let handle = try XCTUnwrap(result.parkHandle)
            XCTAssertTrue(handle.didReveal)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: window.windowID))
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertFalse(handle.hasActiveWaiter)
        }
    }

    // MARK: Shipped-route deadline integration (one injected clock)

    private struct DeadlineRoute {
        let fixture: RouteFixture
        let clock: FakeParkClock
        let gate: AsyncGate
        let route: Task<Value, Error>
        let opened: WindowState
    }

    /// Registers an unattached window at t = 0 and holds the route right after adoption.
    private func startGatedDeadlineRoute(_ fixture: RouteFixture) async throws -> DeadlineRoute {
        let manager = WindowStatesManager.shared
        let clock = FakeParkClock()
        manager.parkOnOpenClock = clock.clock
        let gate = AsyncGate()
        manager.afterOpenAdoptionGateForTesting = { await gate.wait() }
        fixture.attachOpenedWindows = false
        AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
            fixture.openSimulatedWindow(requestID: id)
        }
        let name = "Route Deadline \(UUID().uuidString.prefix(6))"
        _ = try await persistUnshownWorkspace(fixture, name: name)
        let route = routeSwitch(fixture, name: name)
        try await waitUntil("adoption gate") { gate.isWaiting }
        let opened = try XCTUnwrap(fixture.created.first)
        XCTAssertEqual(opened.parkOnOpenHandle?.deadline, 5, "registeredAt (t=0) + 5 s")
        XCTAssertNil(opened.nsWindow, "no attach before the deadline")
        return DeadlineRoute(fixture: fixture, clock: clock, gate: gate, route: route, opened: opened)
    }

    private func finishDeadlineTest(_ ctx: DeadlineRoute) {
        let manager = WindowStatesManager.shared
        manager.afterOpenAdoptionGateForTesting = nil
        manager.parkOnOpenClock = .system
    }

    private func assertExactNotParkedFailure(_ ctx: DeadlineRoute, error: Error, file: StaticString = #filePath, line: UInt = #line) async {
        let message = "Window \(ctx.opened.windowID) opened but was not parked within 5 s; it stays on screen and unparked."
        XCTAssertTrue("\(error)".contains(message), "\(error)", file: file, line: line)
        let bound = await ServerNetworkManager.shared.selectedWindow(for: ctx.fixture.connectionID)
        XCTAssertEqual(bound, ctx.opened.windowID, "bound before the park failure is evaluated", file: file, line: line)
        XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === ctx.opened }, "registered", file: file, line: line)
        XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: ctx.opened.windowID), "unparked", file: file, line: line)
        XCTAssertEqual(WindowStatesManager.shared.pendingOpenOperationCount, 0, file: file, line: line)
        XCTAssertEqual(ctx.clock.activeSleepers, 0, "sleepers drained", file: file, line: line)
        XCTAssertFalse(ctx.opened.parkOnOpenHandle?.hasActiveWaiter ?? true, file: file, line: line)
    }

    func testRouteRegisteredAtZeroBoundAtThreeTimesOutAtFiveWithTwoSecondsRemaining() async throws {
        try await withRouteFixture { fixture in
            let ctx = try await self.startGatedDeadlineRoute(fixture)
            defer { self.finishDeadlineTest(ctx) }
            ctx.clock.time = 3
            ctx.gate.open()
            try await self.waitUntil("remaining-duration sleeper") { ctx.clock.activeSleepers == 1 }
            XCTAssertEqual(ctx.clock.requestedSleeps, [2], "remaining duration, not a fresh 5 s")
            let boundWhileWaiting = await ServerNetworkManager.shared.selectedWindow(for: fixture.connectionID)
            XCTAssertEqual(boundWhileWaiting, ctx.opened.windowID, "route bound before waiting on the park outcome")
            ctx.clock.time = 5
            ctx.clock.fireSleepers()
            do {
                _ = try await ctx.route.value
                XCTFail("expected not-parked failure")
            } catch {
                await self.assertExactNotParkedFailure(ctx, error: error)
            }
            let window = fixture.attachLate(ctx.opened)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: ctx.opened.windowID), "no late parking")
            XCTAssertTrue(window.isVisible, "window stays visible")
        }
    }

    func testRouteRegisteredAtZeroBoundAtSixFailsImmediatelyAfterBindWithoutSleeper() async throws {
        try await withRouteFixture { fixture in
            let ctx = try await self.startGatedDeadlineRoute(fixture)
            defer { self.finishDeadlineTest(ctx) }
            ctx.clock.time = 6
            ctx.gate.open()
            do {
                _ = try await ctx.route.value
                XCTFail("expected immediate not-parked failure")
            } catch {
                XCTAssertTrue(ctx.clock.requestedSleeps.isEmpty, "expired deadline settles without a timer")
                await self.assertExactNotParkedFailure(ctx, error: error)
            }
            let window = fixture.attachLate(ctx.opened)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: ctx.opened.windowID))
            XCTAssertTrue(window.isVisible)
        }
    }

    func testRouteLateAttachAfterDeadlineBeforeWaitFailsImmediatelyAndStaysVisible() async throws {
        try await withRouteFixture { fixture in
            let ctx = try await self.startGatedDeadlineRoute(fixture)
            defer { self.finishDeadlineTest(ctx) }
            ctx.clock.time = 5.1
            let window = fixture.attachLate(ctx.opened)
            XCTAssertEqual(ctx.opened.parkOnOpenHandle?.phase, .timedOut, "attach at 5.1 s is rejected")
            ctx.gate.open()
            do {
                _ = try await ctx.route.value
                XCTFail("expected not-parked failure")
            } catch {
                XCTAssertTrue(ctx.clock.requestedSleeps.isEmpty)
                await self.assertExactNotParkedFailure(ctx, error: error)
            }
            XCTAssertTrue(window.isVisible)
        }
    }

    func testRouteAttachAtFourPointNineWhileWaitingParksAndRouteSucceeds() async throws {
        try await withRouteFixture { fixture in
            let ctx = try await self.startGatedDeadlineRoute(fixture)
            defer { self.finishDeadlineTest(ctx) }
            ctx.clock.time = 4.9
            ctx.gate.open()
            try await self.waitUntil("waiting sleeper") { ctx.clock.activeSleepers == 1 }
            let sleep = try XCTUnwrap(ctx.clock.requestedSleeps.first)
            XCTAssertEqual(sleep, 0.1, accuracy: 0.0001)
            let window = fixture.attachLate(ctx.opened)
            _ = try await ctx.route.value
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: ctx.opened.windowID))
            XCTAssertFalse(window.isVisible, "timely late attach leaves the NSWindow off screen")
            let bound = await ServerNetworkManager.shared.selectedWindow(for: fixture.connectionID)
            XCTAssertEqual(bound, ctx.opened.windowID)
            XCTAssertEqual(ctx.clock.activeSleepers, 0)
            XCTAssertEqual(WindowStatesManager.shared.pendingOpenOperationCount, 0)
        }
    }

    // MARK: Implementation round 1 fixes (F01 refresh deferral, F02 visibility oracle, F03 claimed matching)

    /// Reads the shipped view model's private initial-refresh deferral by reflection. A missing label
    /// fails the caller instead of passing vacuously.
    private func refreshDeferral(
        of state: WindowState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (armed: Bool, fallbackTimer: Bool) {
        let mirror = Mirror(reflecting: state.agentModeViewModel)
        func isPresent(_ label: String) -> Bool? {
            guard let child = mirror.children.first(where: { $0.label == label }) else { return nil }
            let value = Mirror(reflecting: child.value)
            return !(value.displayStyle == .optional && value.children.isEmpty)
        }
        let armed = isPresent("initialSystemWorkspaceSessionListRefreshDeferralReason")
        let timer = isPresent("initialSystemWorkspaceSessionListRefreshDeferralFallbackTask")
        XCTAssertNotNil(armed, "deferral reason state readable", file: file, line: line)
        XCTAssertNotNil(timer, "deferral fallback timer state readable", file: file, line: line)
        return (armed ?? false, timer ?? false)
    }

    func testGatedRouteCancelAfterResumeFinishesInitialRefreshDeferral() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            let clock = FakeParkClock()
            let previousClock = manager.parkOnOpenClock
            manager.parkOnOpenClock = clock.clock
            let gate = AsyncGate()
            manager.afterOpenResultGateForTesting = { await gate.wait() }
            defer {
                manager.afterOpenResultGateForTesting = nil
                manager.parkOnOpenClock = previousClock
            }
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let name = "Route Deferral Gate \(UUID().uuidString.prefix(6))"
            _ = try await self.persistUnshownWorkspace(fixture, name: name)
            let route = self.routeSwitch(fixture, name: name)
            try await self.waitUntil("gated resumed waiter") { gate.isWaiting }
            let opened = try XCTUnwrap(fixture.created.first)
            XCTAssertNotNil(opened.claimedInitialRefreshDeferralID, "shipped route defers the initial refresh")
            let before = self.refreshDeferral(of: opened)
            XCTAssertTrue(before.armed, "deferral armed while the manager owns the resumed handoff")
            XCTAssertTrue(before.fallbackTimer)
            route.cancel()
            try await self.waitUntil("reveal by manager cancellation") {
                !FleetParkingCoordinator.shared.isParked(windowID: opened.windowID)
            }
            gate.open()
            do {
                _ = try await route.value
                XCTFail("cancelled route must not succeed")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            let after = self.refreshDeferral(of: opened)
            XCTAssertFalse(after.armed, "cancellation after resume finishes the initial refresh deferral")
            XCTAssertFalse(after.fallbackTimer, "no fallback timer left armed")
            let handle = try XCTUnwrap(opened.parkOnOpenHandle)
            XCTAssertEqual(handle.phase, .parked, "parked outcome stays immutable")
            XCTAssertTrue(handle.didReveal)
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
            XCTAssertFalse(handle.hasActiveWaiter)
        }
    }

    func testManualScopeCancelAfterResumeFinishesInitialRefreshDeferralIdempotently() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let scope = WindowParkOnOpenScope(manager: manager)
            let result = try await manager.openNewMainWindow(
                deferringInitialAgentSystemWorkspaceRefresh: true,
                parkOnOpen: true,
                requestID: scope.requestID
            )
            let window = result.window
            XCTAssertTrue(self.refreshDeferral(of: window).armed, "armed at first registration")
            scope.cancel()
            scope.cancel()
            let afterCancel = self.refreshDeferral(of: window)
            XCTAssertFalse(afterCancel.armed)
            XCTAssertFalse(afterCancel.fallbackTimer)
            XCTAssertThrowsError(try scope.adopt()) { XCTAssertTrue($0 is CancellationError) }
            let afterAdopt = self.refreshDeferral(of: window)
            XCTAssertFalse(afterAdopt.armed)
            XCTAssertFalse(afterAdopt.fallbackTimer)
            let handle = try XCTUnwrap(result.parkHandle)
            XCTAssertEqual(handle.phase, .parked)
            XCTAssertTrue(handle.didReveal)
            XCTAssertFalse(FleetParkingCoordinator.shared.isParked(windowID: window.windowID))
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testCancellationAcrossAtomicTakeFinishesInitialRefreshDeferral() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let scope = WindowParkOnOpenScope(manager: manager)
            let result = try await manager.openNewMainWindow(
                deferringInitialAgentSystemWorkspaceRefresh: true,
                parkOnOpen: true,
                requestID: scope.requestID
            )
            let window = result.window
            XCTAssertTrue(self.refreshDeferral(of: window).armed)
            let adopter = Task { @MainActor () throws -> WindowState in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return try scope.adopt()
            }
            adopter.cancel()
            do {
                _ = try await adopter.value
                XCTFail("adoption of a cancelled task must throw")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            scope.cancel()
            let after = self.refreshDeferral(of: window)
            XCTAssertFalse(after.armed, "cancelled adoption finishes the deferral the caller never will")
            XCTAssertFalse(after.fallbackTimer)
            let handle = try XCTUnwrap(result.parkHandle)
            XCTAssertTrue(handle.didReveal)
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testSuccessfulAdoptionLeavesInitialRefreshDeferralToTheCaller() async throws {
        try await withRouteFixture { fixture in
            let manager = WindowStatesManager.shared
            AppWindowOpener.shared.installRequestAwareForTesting { [fixture] id in
                fixture.openSimulatedWindow(requestID: id)
            }
            let scope = WindowParkOnOpenScope(manager: manager)
            _ = try await manager.openNewMainWindow(
                deferringInitialAgentSystemWorkspaceRefresh: true,
                parkOnOpen: true,
                requestID: scope.requestID
            )
            let window = try scope.adopt()
            XCTAssertTrue(self.refreshDeferral(of: window).armed, "route caller still owns the armed deferral")
            XCTAssertTrue(FleetParkingCoordinator.shared.isParked(windowID: window.windowID))
            window.agentModeViewModel.finishInitialSystemWorkspaceSessionListRefreshDeferral()
            XCTAssertFalse(self.refreshDeferral(of: window).armed)
            scope.cancel()
        }
    }

    func testAttachedValuedAndNilWindowsKeepMainTabbingIdentifierAndProductionTabbingMode() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let task = self.startOpen()
            try await self.waitUntil("opener id") { recorder.ids.count == 1 }
            let valued = fixture.makeState(openRequestID: recorder.ids[0])
            let plain = fixture.makeState(openRequestID: nil)
            XCTAssertEqual(valued.claimedOpenRequestID, recorder.ids[0])
            XCTAssertNil(plain.claimedOpenRequestID)
            for (label, state) in [("valued", valued), ("nil", plain)] {
                let window = fixture.attach(state)
                XCTAssertEqual(window.tabbingIdentifier, "com.repoprompt.main", "\(label) tabbing identifier")
                XCTAssertEqual(window.tabbingMode, .automatic, "\(label) production tabbing mode")
            }
            manager.cancelOpen(requestID: recorder.ids[0])
            do { _ = try await task.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
        }
    }

    func testClaimedWindowWithCancelledRequestNeverFulfillsConcurrentPlainOpen() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let parked = self.startOpen(deferring: false, park: true)
            try await self.waitUntil("parked id") { recorder.ids.count == 1 }
            let plain = self.startOpen(deferring: false, park: false)
            try await self.waitUntil("plain id") { recorder.ids.count == 2 }
            let cancelledClaim = fixture.makeState(openRequestID: recorder.ids[0])
            XCTAssertEqual(cancelledClaim.claimedOpenRequestID, recorder.ids[0])
            manager.cancelOpen(requestID: recorder.ids[0])
            do { _ = try await parked.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            manager.registerWindowState(cancelledClaim)
            XCTAssertEqual(manager.pendingOpenOperationCount, 1, "cancelled claim cannot consume the unrelated plain open")
            let valued = fixture.makeState(openRequestID: recorder.ids[1])
            XCTAssertEqual(valued.claimedOpenRequestID, recorder.ids[1])
            manager.registerWindowState(valued)
            let result = try await plain.value
            XCTAssertTrue(result.window === valued, "plain open is fulfilled by its own valued window")
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testNilDockWindowCannotFulfillRequestAwarePlainOpenInEitherRegistrationOrder() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let plain = self.startOpen(deferring: false, park: false)
            try await self.waitUntil("plain id") { recorder.ids.count == 1 }
            let dock = fixture.makeState(openRequestID: nil)
            manager.registerWindowState(dock)
            XCTAssertEqual(manager.pendingOpenOperationCount, 1, "nil Dock window leaves the request-aware plain open waiting")
            let valued = fixture.makeState(openRequestID: recorder.ids[0])
            manager.registerWindowState(valued)
            let result = try await plain.value
            XCTAssertTrue(result.window === valued)
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let plain = self.startOpen(deferring: false, park: false)
            try await self.waitUntil("plain id") { recorder.ids.count == 1 }
            let valued = fixture.makeState(openRequestID: recorder.ids[0])
            let dock = fixture.makeState(openRequestID: nil)
            manager.registerWindowState(valued)
            manager.registerWindowState(dock)
            let result = try await plain.value
            XCTAssertTrue(result.window === valued)
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testCancelledClaimAndNilDockTogetherLeaveRequestAwarePlainOpenWaiting() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            let recorder = self.installRecorder()
            let parked = self.startOpen(deferring: false, park: true)
            try await self.waitUntil("parked id") { recorder.ids.count == 1 }
            let plain = self.startOpen(deferring: false, park: false)
            try await self.waitUntil("plain id") { recorder.ids.count == 2 }
            let cancelledClaim = fixture.makeState(openRequestID: recorder.ids[0])
            manager.cancelOpen(requestID: recorder.ids[0])
            do { _ = try await parked.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            let dock = fixture.makeState(openRequestID: nil)
            manager.registerWindowState(dock)
            manager.registerWindowState(cancelledClaim)
            XCTAssertEqual(manager.pendingOpenOperationCount, 1, "neither window may fulfil the plain open")
            manager.cancelOpen(requestID: recorder.ids[1])
            do { _ = try await plain.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    func testLegacyZeroArgumentOpenerStillLetsNilWindowFulfillPlainOpen() async throws {
        try await withLifecycleFixture { fixture, _ in
            let manager = WindowStatesManager.shared
            final class Counter { var calls = 0 }
            let counter = Counter()
            AppWindowOpener.shared.installForTesting { counter.calls += 1 }
            let plain = self.startOpen(deferring: false, park: false)
            try await self.waitUntil("legacy opener call") { counter.calls == 1 }
            let state = fixture.makeState(openRequestID: nil)
            manager.registerWindowState(state)
            let result = try await plain.value
            XCTAssertTrue(result.window === state, "legacy zero-argument opener keeps the unclaimed plain fallback")
            XCTAssertEqual(manager.pendingOpenOperationCount, 0)
        }
    }

    private func makeFixture(contents: String? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FleetAgentWindowParkingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "FleetAgentWindowParkingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let fileURL = root.appendingPathComponent("globalSettings.json")
        if let contents {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: fileURL))
        return Fixture(
            service: AppSettingsMCPService(store: store),
            defaults: defaults,
            fileURL: fileURL,
            cleanup: {
                defaults.removePersistentDomain(forName: suiteName)
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    private struct Fixture {
        let service: AppSettingsMCPService
        let defaults: UserDefaults
        let fileURL: URL
        let cleanup: () -> Void
    }
}
