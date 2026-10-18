import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
protocol FleetParkingControlling: AnyObject {
    var parkedWindowIDs: Set<Int> { get }
    func park(windowID: Int, reason: FleetParkReason) -> Bool
    func unpark(windowID: Int)
}

extension FleetParkingCoordinator: FleetParkingControlling {}

@MainActor
protocol FleetWindowHandle: AnyObject {
    var windowID: Int { get }
    var activeWorkspaceID: UUID? { get }
    var isInitialized: Bool { get }
    var isClosing: Bool { get }
    var isBackgrounded: Bool { get }
    func tabID(holding sessionID: UUID) -> UUID?
    func canStash(tabID: UUID, sessionID: UUID, workspaceID: UUID) -> Bool
    func performSidebarCommand(_ action: AgentSidebarBulkActionKind, tabID: UUID, sessionID: UUID, workspaceID: UUID) async -> Bool
    func restoreBackground()
    func reveal()
    func route(_ route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult
}

@MainActor
extension FleetWindowHandle {
    func canStash(tabID: UUID, sessionID: UUID, workspaceID: UUID) -> Bool {
        false
    }

    func performSidebarCommand(_ action: AgentSidebarBulkActionKind, tabID: UUID, sessionID: UUID, workspaceID: UUID) async -> Bool {
        false
    }
}

@MainActor
final class WindowStateFleetHandle: FleetWindowHandle {
    private let state: WindowState

    init(state: WindowState) {
        self.state = state
    }

    var windowID: Int {
        state.windowID
    }

    var activeWorkspaceID: UUID? {
        state.workspaceManager.activeWorkspaceID
    }

    var isInitialized: Bool {
        state.workspaceManager.isInitialized
    }

    var isClosing: Bool {
        state.isClosing
    }

    var isBackgrounded: Bool {
        MCPBackgroundModeCoordinator.shared.backgroundedWindowID == state.windowID
    }

    func tabID(holding sessionID: UUID) -> UUID? {
        state.agentModeViewModel.sessions.values.first { $0.activeAgentSessionID == sessionID }?.tabID
    }

    func canStash(tabID: UUID, sessionID: UUID, workspaceID: UUID) -> Bool {
        state.agentModeViewModel.fleetSidebarCanStash(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID, promptManager: state.promptManager)
    }

    func performSidebarCommand(_ action: AgentSidebarBulkActionKind, tabID: UUID, sessionID: UUID, workspaceID: UUID) async -> Bool {
        await state.agentModeViewModel.performFleetSidebarCommand(action, tabID: tabID, sessionID: sessionID, workspaceID: workspaceID, promptManager: state.promptManager)
    }

    func restoreBackground() {
        MCPBackgroundModeCoordinator.shared.restore()
    }

    func reveal() {
        state.revealWindow()
    }

    func route(_ route: AgentSessionDeepLinkRoute) async -> AgentSessionRouteResult {
        await state.routeToAgentSession(route)
    }
}

@MainActor
final class FleetManagerRosterSource: FleetRosterWindowSource {
    private let inner: FleetRosterWindowSource
    private let refreshes = PassthroughSubject<Void, Never>()

    init(inner: FleetRosterWindowSource) {
        self.inner = inner
    }

    func windows() -> [FleetRosterWindowSnapshot] {
        inner.windows()
    }

    var changes: AnyPublisher<Void, Never> {
        inner.changes.merge(with: refreshes).eraseToAnyPublisher()
    }

    func start() {
        inner.start()
    }

    func stop() {
        inner.stop()
    }

    func requestRefresh() {
        refreshes.send()
    }
}

@MainActor
final class FleetManagerActions: ObservableObject {
    struct ChatTarget {
        let rowID: UUID
        let sessionID: UUID
        let tabID: UUID
    }

    struct Confirmation {
        let title: String
        let message: String
        let windowID: Int
        let workspaceID: UUID
        let workspaceName: String?
        let chat: ChatTarget?
    }

    private struct FeedbackTarget: Hashable {
        let windowID: Int
        let workspaceID: UUID
        let sessionID: UUID
    }

    private struct StaleFeedback {
        let target: FeedbackTarget
        var pendingFirstRefresh: Bool
    }

    @Published private(set) var staleMessages: [UUID: String] = [:]
    @Published private(set) var parkMessages: [Int: String] = [:]
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var isDeletionInFlight = false
    @Published private(set) var deletionError: String?

    private let handle: @MainActor (Int) -> FleetWindowHandle?
    private let parking: FleetParkingControlling
    private let requestRefresh: () -> Void
    private let notificationCenter: NotificationCenter
    private let workspaceWindowIDs: @MainActor (UUID) -> [Int]
    private let deleteWorkspace: @MainActor (Int, UUID) async -> WorkspaceWindowDeletion.Result

    init(
        handle: @escaping @MainActor (Int) -> FleetWindowHandle?,
        parking: FleetParkingControlling,
        requestRefresh: @escaping () -> Void,
        notificationCenter: NotificationCenter = .default,
        workspaceWindowIDs: @escaping @MainActor (UUID) -> [Int] = { workspaceID in
            WindowStatesManager.shared.allWindows.filter { $0.workspaceManager.activeWorkspaceID == workspaceID }.map(\.windowID)
        },
        deleteWorkspace: @escaping @MainActor (Int, UUID) async -> WorkspaceWindowDeletion.Result = { windowID, workspaceID in
            guard let state = WindowStatesManager.shared.window(withID: windowID),
                  let workspace = state.workspaceManager.workspaces.first(where: { $0.id == workspaceID })
            else {
                return .targetChanged(message: "Workspace \(workspaceID) was not deleted because window \(windowID) changed.")
            }
            return await WorkspaceWindowDeletion(target: state, workspace: workspace).execute()
        }
    ) {
        self.handle = handle
        self.parking = parking
        self.requestRefresh = requestRefresh
        self.notificationCenter = notificationCenter
        self.workspaceWindowIDs = workspaceWindowIDs
        self.deleteWorkspace = deleteWorkspace
    }

    static func staleMessage(windowID: Int) -> String {
        "This session is no longer in window \(windowID)"
    }

    func staleMessage(for rowID: UUID) -> String? {
        staleMessages[rowID]
    }

    func parkMessage(for windowID: Int) -> String? {
        parkMessages[windowID]
    }

    func show(rowID: UUID, windowID: Int, workspaceID: UUID, sessionID: UUID) async {
        guard let target = handle(windowID),
              !target.isClosing,
              target.isInitialized,
              target.activeWorkspaceID == workspaceID,
              let tabID = target.tabID(holding: sessionID)
        else {
            markStale(rowID: rowID, windowID: windowID, workspaceID: workspaceID, sessionID: sessionID)
            return
        }
        // Invariant: no await between the pre-check above and route(); with isInitialized true
        // routeToAgentSession does not suspend before comparing workspaces, so it never switches.
        // Never the multi-window deep-link router.
        if target.isBackgrounded {
            target.restoreBackground()
        }
        target.reveal()
        let result = await target.route(
            AgentSessionDeepLinkRoute(
                windowID: windowID,
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: sessionID,
                interactionID: nil
            )
        )
        if result == .routed {
            staleMessages[rowID] = nil
            staleFeedback[rowID] = nil
        } else {
            markStale(rowID: rowID, windowID: windowID, workspaceID: workspaceID, sessionID: sessionID)
        }
    }

    func canArchive(rowID: UUID, windowID: Int, workspaceID: UUID, sessionID: UUID) -> Bool {
        guard let (target, tabID) = sessionTarget(windowID: windowID, workspaceID: workspaceID, sessionID: sessionID) else { return false }
        return target.canStash(tabID: tabID, sessionID: sessionID, workspaceID: workspaceID)
    }

    func archive(rowID: UUID, windowID: Int, workspaceID: UUID, sessionID: UUID) async {
        guard !isDeletionInFlight else { return }
        guard let (target, tabID) = sessionTarget(windowID: windowID, workspaceID: workspaceID, sessionID: sessionID) else {
            markStale(rowID: rowID, windowID: windowID, workspaceID: workspaceID, sessionID: sessionID)
            return
        }
        if await target.performSidebarCommand(.stash, tabID: tabID, sessionID: sessionID, workspaceID: workspaceID) {
            requestRefresh()
        }
    }

    func requestDeleteChat(rowID: UUID, windowID: Int, workspaceID: UUID, sessionID: UUID) {
        guard !isDeletionInFlight else { return }
        guard let (_, tabID) = sessionTarget(windowID: windowID, workspaceID: workspaceID, sessionID: sessionID) else {
            markStale(rowID: rowID, windowID: windowID, workspaceID: workspaceID, sessionID: sessionID)
            return
        }
        deletionError = nil
        confirmation = Confirmation(
            title: "Delete chat?", message: "This permanently deletes this chat.",
            windowID: windowID, workspaceID: workspaceID, workspaceName: nil,
            chat: ChatTarget(rowID: rowID, sessionID: sessionID, tabID: tabID)
        )
    }

    func requestDeleteWorkspace(section: FleetRosterSection) {
        guard !isDeletionInFlight else { return }
        var message = "This will delete \"\(section.workspaceName)\" and its saved tabs and session history, including pinned tabs. Running work will be stopped and window \(section.windowID) closes. Your project folders are kept."
        if section.runningCount + section.waitingCount > 0 {
            message += "\n\(section.runningCount) running, \(section.waitingCount) waiting sessions."
        }
        confirmation = Confirmation(
            title: "Delete workspace?", message: message,
            windowID: section.windowID, workspaceID: section.workspaceID, workspaceName: section.workspaceName, chat: nil
        )
        let holders = workspaceWindowIDs(section.workspaceID)
        deletionError = holders.count > 1
            ? WorkspaceWindowDeletion.duplicateWorkspaceMessage(name: section.workspaceName, windowIDs: holders)
            : nil
    }

    func cancelDeletion() {
        guard !isDeletionInFlight else { return }
        confirmation = nil
        deletionError = nil
    }

    func confirmDeletion() async {
        guard !isDeletionInFlight, deletionError == nil, let pending = confirmation else { return }
        isDeletionInFlight = true
        defer { isDeletionInFlight = false }
        if let chat = pending.chat {
            guard let (target, tabID) = sessionTarget(windowID: pending.windowID, workspaceID: pending.workspaceID, sessionID: chat.sessionID),
                  tabID == chat.tabID
            else {
                markStale(rowID: chat.rowID, windowID: pending.windowID, workspaceID: pending.workspaceID, sessionID: chat.sessionID)
                deletionError = Self.staleMessage(windowID: pending.windowID)
                return
            }
            guard await target.performSidebarCommand(.delete, tabID: tabID, sessionID: chat.sessionID, workspaceID: pending.workspaceID) else {
                deletionError = "This chat could not be deleted because the workspace or sidebar state changed."
                return
            }
            confirmation = nil
        } else {
            let result = await deleteWorkspace(pending.windowID, pending.workspaceID)
            switch result {
            case .closeRequested:
                confirmation = nil
            case let .notSwitched(message), let .deleteFailed(message), let .targetChanged(message), let .deletionCommittedWithoutClose(message):
                deletionError = message
            case let .closeFailed(error):
                deletionError = "Workspace '\(pending.workspaceName ?? pending.workspaceID.uuidString)' was deleted, but window \(pending.windowID) could not be closed: \(error.localizedDescription)"
            }
        }
        requestRefresh()
    }

    private func sessionTarget(windowID: Int, workspaceID: UUID, sessionID: UUID) -> (any FleetWindowHandle, UUID)? {
        guard let target = handle(windowID),
              !target.isClosing, target.isInitialized, target.activeWorkspaceID == workspaceID,
              let tabID = target.tabID(holding: sessionID)
        else { return nil }
        return (target, tabID)
    }

    func park(windowID: Int) {
        let didPark = parking.park(windowID: windowID, reason: .operator)
        parkMessages[windowID] = didPark
            ? nil
            : "Window \(windowID) could not be parked. Try again."
        parkingChanged()
    }

    func unpark(windowID: Int) {
        parkMessages[windowID] = nil
        if let target = handle(windowID), target.isBackgrounded {
            target.restoreBackground()
        }
        parking.unpark(windowID: windowID)
        parkingChanged()
    }

    func reconcileFeedback(with roster: FleetRoster) {
        let live = Set(roster.sections.flatMap { section in
            section.allRows.map {
                FeedbackTarget(windowID: section.windowID, workspaceID: section.workspaceID, sessionID: $0.id)
            }
        })
        for rowID in Array(staleFeedback.keys) {
            guard var entry = staleFeedback[rowID] else { continue }
            if entry.pendingFirstRefresh {
                entry.pendingFirstRefresh = false
                staleFeedback[rowID] = entry
            } else if live.contains(entry.target) {
                staleMessages[rowID] = nil
                staleFeedback[rowID] = nil
            }
        }
        let visibleWindowIDs = Set(roster.sections.filter { !$0.isParked }.map(\.windowID))
        let nextParkMessages = parkMessages.filter { visibleWindowIDs.contains($0.key) }
        if nextParkMessages != parkMessages {
            parkMessages = nextParkMessages
        }
    }

    private var staleFeedback: [UUID: StaleFeedback] = [:]

    private func markStale(rowID: UUID, windowID: Int, workspaceID: UUID, sessionID: UUID) {
        staleFeedback[rowID] = StaleFeedback(
            target: FeedbackTarget(windowID: windowID, workspaceID: workspaceID, sessionID: sessionID),
            pendingFirstRefresh: true
        )
        staleMessages[rowID] = Self.staleMessage(windowID: windowID)
        requestRefresh()
    }

    private func parkingChanged() {
        requestRefresh()
        notificationCenter.post(name: FleetCommandCenter.refreshNotification, object: nil)
    }
}

@MainActor
final class FleetManagerWindowCoordinator: NSObject, NSWindowDelegate {
    static let windowIdentifier = "RepoPrompt.FleetManagerWindow"

    private let makeSource: @MainActor () -> FleetRosterWindowSource
    private let makeTicker: @MainActor () -> FleetRosterTicker
    private let parking: FleetParkingControlling
    private let handle: @MainActor (Int) -> FleetWindowHandle?
    private let present: (NSWindow) -> Void
    private var controller: NSWindowController?
    private var model: FleetRosterModel?

    var windowForTesting: NSWindow? {
        controller?.window
    }

    var modelForTesting: FleetRosterModel? {
        model
    }

    init(
        makeSource: @escaping @MainActor () -> FleetRosterWindowSource = { LiveFleetRosterWindowSource() },
        makeTicker: @escaping @MainActor () -> FleetRosterTicker = { TimerFleetRosterTicker() },
        parking: FleetParkingControlling = FleetParkingCoordinator.shared,
        handle: @escaping @MainActor (Int) -> FleetWindowHandle? = {
            WindowStatesManager.shared.window(withID: $0).map(WindowStateFleetHandle.init)
        },
        present: @escaping (NSWindow) -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
            $0.makeKeyAndOrderFront(nil)
        }
    ) {
        self.makeSource = makeSource
        self.makeTicker = makeTicker
        self.parking = parking
        self.handle = handle
        self.present = present
    }

    func install(into coordinator: FleetParkingCoordinator) {
        coordinator.openFleetManager = { [weak self] in self?.open() }
    }

    func open() {
        if let window = controller?.window {
            present(window)
            return
        }

        let source = FleetManagerRosterSource(inner: makeSource())
        let parking = parking
        let actions = FleetManagerActions(
            handle: handle,
            parking: parking,
            requestRefresh: { [weak source] in source?.requestRefresh() }
        )
        let model = FleetRosterModel(
            source: source,
            parked: { parking.parkedWindowIDs },
            ticker: makeTicker(),
            didRefresh: { [weak actions] roster in
                actions?.reconcileFeedback(with: roster)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Fleet Manager"
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: FleetManagerView(model: model, actions: actions))
        window.setFrameAutosaveName(Self.windowIdentifier)
        window.delegate = self
        self.model = model
        controller = NSWindowController(window: window)
        model.start()
        present(window)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        controller?.window?.delegate = nil
        controller = nil
    }
}
