import Combine
import Foundation

struct FleetRoster: Equatable {
    var sections: [FleetRosterSection]
}

struct FleetRosterSection: Equatable {
    var workspaceID: UUID
    var workspaceName: String
    var windowID: Int
    var isParked: Bool
    var runningCount: Int
    var waitingCount: Int
    var rows: [FleetRosterRow]

    var allRows: [FleetRosterRow] {
        rows.flatMap { [$0] + $0.children.flatMap(\.allRows) }
    }
}

struct FleetRosterRow: Equatable {
    var id: UUID
    var name: String
    var agent: String
    var model: String
    var runState: AgentSessionRunState
    var lastActivityAt: Date
    var pendingKind: FleetRosterPendingKind?
    var parent: FleetRosterParentLink?
    var rollup: FleetRosterRollup
    var children: [FleetRosterRow]

    var allRows: [FleetRosterRow] {
        [self] + children.flatMap(\.allRows)
    }
}

enum FleetRosterPendingKind: Equatable {
    case approval
    case question
    case operatorTurn
}

enum FleetRosterParentLink: Equatable {
    case sameWindow(UUID)
    case otherWindow(windowID: Int, sessionID: UUID, name: String)
}

struct FleetRosterRollup: Equatable {
    var totalSubagents: Int
    var runningCount: Int
    var waitingCount: Int
    var otherWindowCount: Int
}

struct FleetRosterWindowSnapshot: Equatable {
    var windowID: Int
    var workspaceID: UUID
    var workspaceName: String
    var isSystemWorkspace: Bool
    var isClosing: Bool
    var sessions: [FleetRosterSessionSnapshot]
}

struct FleetRosterSessionSnapshot: Equatable {
    var tabID: UUID
    var sessionID: UUID
    var parentSessionID: UUID?
    var indexParentSessionID: UUID?
    var composeTabName: String?
    var indexEntryName: String?
    var agent: String
    var model: String
    var runState: AgentSessionRunState
    var lastActivityAt: Date

    var resolvedParentSessionID: UUID? {
        guard let parentID = parentSessionID ?? indexParentSessionID, parentID != sessionID else { return nil }
        return parentID
    }
}

enum FleetRosterProjection {
    static func derive(_ windows: [FleetRosterWindowSnapshot], parked: Set<Int>) -> FleetRoster {
        let includedWindows = windows.filter { !$0.isSystemWorkspace && !$0.isClosing }
        let holders = Dictionary(grouping: includedWindows.flatMap { window in
            window.sessions.map { (window, $0) }
        }, by: { $0.1.sessionID })

        return FleetRoster(sections: includedWindows.map { window in
            section(for: window, holders: holders, parked: parked.contains(window.windowID))
        })
    }

    private static func section(
        for window: FleetRosterWindowSnapshot,
        holders: [UUID: [(FleetRosterWindowSnapshot, FleetRosterSessionSnapshot)]],
        parked: Bool
    ) -> FleetRosterSection {
        let rows = window.sessions.map { session in
            row(for: session, in: window, holders: holders)
        }
        let sameWindowParentIDs = Set(window.sessions.map(\.sessionID))
        let cyclicIDs = cycleIDs(in: rows)
        var childrenByParentID: [UUID: [FleetRosterRow]] = [:]
        var topLevelRows: [FleetRosterRow] = []

        for row in rows {
            guard case let .sameWindow(parentID)? = row.parent,
                  sameWindowParentIDs.contains(parentID),
                  !cyclicIDs.contains(row.id),
                  !cyclicIDs.contains(parentID)
            else {
                topLevelRows.append(row)
                continue
            }
            childrenByParentID[parentID, default: []].append(row)
        }

        topLevelRows = topLevelRows.map {
            nested($0, childrenByParentID: childrenByParentID, ancestors: [])
        }

        return FleetRosterSection(
            workspaceID: window.workspaceID,
            workspaceName: window.workspaceName,
            windowID: window.windowID,
            isParked: parked,
            runningCount: window.sessions.count(where: { $0.runState == .running }),
            waitingCount: window.sessions.count(where: { isWaiting($0.runState) }),
            rows: topLevelRows
        )
    }

    private static func nested(
        _ row: FleetRosterRow,
        childrenByParentID: [UUID: [FleetRosterRow]],
        ancestors: Set<UUID>
    ) -> FleetRosterRow {
        guard !ancestors.contains(row.id) else { return row }
        var nestedRow = row
        let descendants = childrenByParentID[row.id] ?? []
        nestedRow.children = descendants.map {
            nested($0, childrenByParentID: childrenByParentID, ancestors: ancestors.union([row.id]))
        }
        return nestedRow
    }

    private static func cycleIDs(in rows: [FleetRosterRow]) -> Set<UUID> {
        var parents: [UUID: UUID] = [:]
        for row in rows {
            if case let .sameWindow(parentID)? = row.parent {
                parents[row.id] = parentID
            }
        }
        var result: Set<UUID> = []
        for id in parents.keys {
            var path: [UUID] = []
            var current: UUID? = id
            while let value = current, let parent = parents[value] {
                if let start = path.firstIndex(of: value) {
                    result.formUnion(path[start...])
                    break
                }
                path.append(value)
                current = parent
            }
        }
        return result
    }

    private static func row(
        for session: FleetRosterSessionSnapshot,
        in window: FleetRosterWindowSnapshot,
        holders: [UUID: [(FleetRosterWindowSnapshot, FleetRosterSessionSnapshot)]]
    ) -> FleetRosterRow {
        FleetRosterRow(
            id: session.sessionID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(session.composeTabName ?? session.indexEntryName),
            agent: session.agent,
            model: session.model,
            runState: session.runState,
            lastActivityAt: session.lastActivityAt,
            pendingKind: pendingKind(for: session.runState),
            parent: parentLink(for: session, in: window, holders: holders),
            rollup: rollup(for: session.sessionID, windowID: window.windowID, holders: holders),
            children: []
        )
    }

    private static func parentLink(
        for session: FleetRosterSessionSnapshot,
        in window: FleetRosterWindowSnapshot,
        holders: [UUID: [(FleetRosterWindowSnapshot, FleetRosterSessionSnapshot)]]
    ) -> FleetRosterParentLink? {
        guard let parentID = session.resolvedParentSessionID else { return nil }
        if window.sessions.contains(where: { $0.sessionID == parentID }) {
            return .sameWindow(parentID)
        }
        let otherHolders = (holders[parentID] ?? []).filter { $0.0.windowID != window.windowID }
        guard otherHolders.count == 1, let holder = otherHolders.first else { return nil }
        return .otherWindow(
            windowID: holder.0.windowID,
            sessionID: parentID,
            name: AgentSessionRestoreSupport.normalizedSessionTitle(holder.1.composeTabName ?? holder.1.indexEntryName)
        )
    }

    private static func rollup(
        for parentID: UUID,
        windowID: Int,
        holders: [UUID: [(FleetRosterWindowSnapshot, FleetRosterSessionSnapshot)]]
    ) -> FleetRosterRollup {
        let children = holders.values.compactMap { entries in
            entries.first(where: { $0.1.resolvedParentSessionID == parentID })
        }
        return FleetRosterRollup(
            totalSubagents: children.count,
            runningCount: children.count(where: { $0.1.runState == .running }),
            waitingCount: children.count(where: { isWaiting($0.1.runState) }),
            otherWindowCount: children.count(where: { $0.0.windowID != windowID })
        )
    }

    private static func pendingKind(for state: AgentSessionRunState) -> FleetRosterPendingKind? {
        switch state {
        case .waitingForApproval:
            .approval
        case .waitingForQuestion:
            .question
        case .waitingForUser:
            .operatorTurn
        case .idle, .running, .completed, .cancelled, .failed:
            nil
        }
    }

    private static func isWaiting(_ state: AgentSessionRunState) -> Bool {
        switch state {
        case .waitingForUser, .waitingForQuestion, .waitingForApproval:
            true
        case .idle, .running, .completed, .cancelled, .failed:
            false
        }
    }
}

@MainActor
protocol FleetRosterWindowSource: AnyObject {
    func windows() -> [FleetRosterWindowSnapshot]
    var changes: AnyPublisher<Void, Never> { get }
    func start()
    func stop()
}

extension FleetRosterWindowSource {
    func start() {}
    func stop() {}
}

@MainActor
protocol FleetRosterTicker: AnyObject {
    func start(interval: TimeInterval, fire: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class TimerFleetRosterTicker: FleetRosterTicker {
    private var timer: Timer?

    func start(interval: TimeInterval, fire: @escaping @MainActor () -> Void) {
        stop()
        let newTimer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in fire() }
        }
        // .common keeps the 2 s refresh alive during menu and event-tracking run-loop modes.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class FleetRosterModel: ObservableObject {
    static let tickInterval: TimeInterval = 2

    @Published private(set) var roster: FleetRoster
    private let source: FleetRosterWindowSource
    private let parked: @MainActor () -> Set<Int>
    private let ticker: FleetRosterTicker
    private let didRefresh: @MainActor (FleetRoster) -> Void
    private var changes: AnyCancellable?
    private var refreshScheduled = false
    private var running = false

    init(
        source: FleetRosterWindowSource,
        parked: @escaping @MainActor () -> Set<Int> = { [] },
        ticker: FleetRosterTicker? = nil,
        didRefresh: @escaping @MainActor (FleetRoster) -> Void = { _ in }
    ) {
        self.source = source
        self.parked = parked
        self.ticker = ticker ?? TimerFleetRosterTicker()
        self.didRefresh = didRefresh
        roster = FleetRosterProjection.derive(source.windows(), parked: parked())
    }

    func start() {
        running = true
        source.start()
        changes = source.changes.sink { [weak self] _ in self?.scheduleRefresh() }
        ticker.start(interval: Self.tickInterval) { [weak self] in self?.scheduleRefresh() }
    }

    func stop() {
        running = false
        changes = nil
        ticker.stop()
        source.stop()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            refreshScheduled = false
            refresh()
        }
    }

    private func refresh() {
        guard running else { return }
        let next = FleetRosterProjection.derive(source.windows(), parked: parked())
        if next != roster {
            roster = next
        }
        didRefresh(next)
    }
}

@MainActor
final class LiveFleetRosterWindowSource: FleetRosterWindowSource {
    private let manager: WindowStatesManager
    private let changesSubject = PassthroughSubject<Void, Never>()
    private var managerSubscription: AnyCancellable?
    private var windowSubscriptions = Set<AnyCancellable>()

    init(manager: WindowStatesManager? = nil) {
        self.manager = manager ?? .shared
        subscribe()
    }

    func start() {
        guard managerSubscription == nil else { return }
        subscribe()
    }

    func stop() {
        managerSubscription = nil
        windowSubscriptions.removeAll()
    }

    private func subscribe() {
        managerSubscription = manager.$allWindows.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.observeWindows() }
        }
        observeWindows()
    }

    func windows() -> [FleetRosterWindowSnapshot] {
        manager.allWindows.compactMap(snapshot(for:))
    }

    var changes: AnyPublisher<Void, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    private func observeWindows() {
        guard managerSubscription != nil else { return }
        windowSubscriptions.removeAll()
        for window in manager.allWindows {
            window.agentModeViewModel.$sessions.dropFirst().sink { [weak self] _ in
                Task { @MainActor in self?.observeWindows() }
            }.store(in: &windowSubscriptions)
            for session in window.agentModeViewModel.sessions.values {
                session.$runState.dropFirst().sink { [weak self] _ in
                    // A run-state publisher emits before its stored value is readable (R1).
                    Task { @MainActor in self?.changesSubject.send() }
                }.store(in: &windowSubscriptions)
            }
        }
        changesSubject.send()
    }

    private func snapshot(for window: WindowState) -> FleetRosterWindowSnapshot? {
        guard let workspace = window.workspaceManager.activeWorkspace else { return nil }
        let viewModel = window.agentModeViewModel
        let tabs = Dictionary(workspace.composeTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabOrder = Dictionary(workspace.composeTabs.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let sessions = viewModel.sessions.values.sorted { lhs, rhs in
            let lhsOrder = tabOrder[lhs.tabID] ?? Int.max
            let rhsOrder = tabOrder[rhs.tabID] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.activeAgentSessionID?.uuidString ?? "") < (rhs.activeAgentSessionID?.uuidString ?? "")
        }.compactMap { session -> FleetRosterSessionSnapshot? in
            guard let sessionID = session.activeAgentSessionID else { return nil }
            let tab = tabs[session.tabID]
            let entry = viewModel.sessionIndex[sessionID]
            return FleetRosterSessionSnapshot(
                tabID: session.tabID,
                sessionID: sessionID,
                parentSessionID: session.hasLoadedPersistedState ? session.parentSessionID : nil,
                indexParentSessionID: entry?.parentSessionID,
                composeTabName: tab?.name,
                indexEntryName: entry?.name,
                agent: session.selectedAgent.rawValue,
                model: session.selectedModelRaw ?? "",
                runState: session.runState,
                lastActivityAt: session.lastActivityAt
            )
        }
        return FleetRosterWindowSnapshot(
            windowID: window.windowID,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isClosing: window.isClosing,
            sessions: sessions
        )
    }
}
