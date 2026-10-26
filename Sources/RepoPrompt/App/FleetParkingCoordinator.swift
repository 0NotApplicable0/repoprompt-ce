import AppKit
import Combine

@MainActor
protocol FleetTabGroupSeparating {
    func isInTabGroup(_ window: NSWindow) -> Bool
    func moveToOwnWindow(_ window: NSWindow)
}

@MainActor
protocol FleetWindowOrdering {
    func orderOut(_ window: NSWindow)
    func orderFront(_ window: NSWindow)
}

@MainActor
protocol FleetWindowVisibilitySampling {
    func isVisible(_ window: NSWindow) -> Bool
    func isOcclusionVisible(_ window: NSWindow) -> Bool
}

@MainActor
struct NSWindowTabGroupSeam: FleetTabGroupSeparating {
    func isInTabGroup(_ window: NSWindow) -> Bool {
        (window.tabGroup?.windows.count ?? 0) > 1
    }

    func moveToOwnWindow(_ window: NSWindow) {
        window.moveTabToNewWindow(nil)
    }
}

@MainActor
struct NSWindowOrdering: FleetWindowOrdering {
    func orderOut(_ window: NSWindow) {
        window.orderOut(nil)
    }

    func orderFront(_ window: NSWindow) {
        window.orderFront(nil)
    }
}

@MainActor
struct NSWindowVisibilitySampler: FleetWindowVisibilitySampling {
    func isVisible(_ window: NSWindow) -> Bool {
        window.isVisible
    }

    func isOcclusionVisible(_ window: NSWindow) -> Bool {
        window.occlusionState.contains(.visible)
    }
}

enum FleetParkReason: Equatable {
    case `operator`
    case onOpen
}

enum FleetVisibilityBackstopAction: Equatable {
    case none
    case unpark
    case orderOutAgain
}

@MainActor
final class FleetParkingCoordinator {
    static let shared = FleetParkingCoordinator()
    static let parkOnOpenSettleTime: TimeInterval = 1
    static let backstopNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didChangeScreenNotification
    ]

    private let tabGroups: any FleetTabGroupSeparating
    private let ordering: any FleetWindowOrdering
    private let visibility: any FleetWindowVisibilitySampling
    private let now: () -> TimeInterval
    private let windowLookup: (Int) -> WindowState?
    private let notificationCenter: NotificationCenter
    private(set) var parkedWindowIDs: Set<Int> = []
    private var settleUntil: [Int: TimeInterval] = [:]
    private var backstopCancellables: [Int: Set<AnyCancellable>] = [:]
    var openFleetManager: @MainActor () -> Void = {}

    #if DEBUG
        private var automaticBackstopDeliveryEnabled = true

        func setAutomaticBackstopDeliveryEnabledForTesting(_ enabled: Bool) {
            automaticBackstopDeliveryEnabled = enabled
        }

        func resetForTesting() {
            resetForTermination()
            automaticBackstopDeliveryEnabled = true
        }
    #endif

    init(
        tabGroups: (any FleetTabGroupSeparating)? = nil,
        ordering: (any FleetWindowOrdering)? = nil,
        visibility: (any FleetWindowVisibilitySampling)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        windowLookup: ((Int) -> WindowState?)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.tabGroups = tabGroups ?? NSWindowTabGroupSeam()
        self.ordering = ordering ?? NSWindowOrdering()
        self.visibility = visibility ?? NSWindowVisibilitySampler()
        self.now = now
        self.windowLookup = windowLookup ?? { WindowStatesManager.shared.window(withID: $0) }
        self.notificationCenter = notificationCenter
    }

    func isParked(windowID: Int) -> Bool {
        parkedWindowIDs.contains(windowID)
    }

    @discardableResult
    func park(windowID: Int, reason: FleetParkReason = .operator) -> Bool {
        guard let state = windowLookup(windowID),
              let window = state.nsWindow
        else {
            return false
        }
        guard parkedWindowIDs.insert(windowID).inserted else {
            return true
        }
        if tabGroups.isInTabGroup(window) {
            tabGroups.moveToOwnWindow(window)
        }
        if reason == .onOpen {
            settleUntil[windowID] = now() + Self.parkOnOpenSettleTime
        }
        ordering.orderOut(window)
        installBackstop(for: window, windowID: windowID)
        return true
    }

    func unpark(windowID: Int) {
        guard parkedWindowIDs.remove(windowID) != nil else {
            return
        }
        settleUntil[windowID] = nil
        backstopCancellables[windowID] = nil
        guard let window = windowLookup(windowID)?.nsWindow else {
            return
        }
        if !visibility.isVisible(window) {
            ordering.orderFront(window)
        }
    }

    func clearIfParked(windowID: Int) {
        parkedWindowIDs.remove(windowID)
        settleUntil[windowID] = nil
        backstopCancellables[windowID] = nil
    }

    func resetForTermination() {
        parkedWindowIDs.removeAll()
        settleUntil.removeAll()
        backstopCancellables.removeAll()
    }

    static func backstopAction(
        isParked: Bool,
        isVisible: Bool,
        settleUntil: TimeInterval?,
        now: TimeInterval
    ) -> FleetVisibilityBackstopAction {
        guard isParked, isVisible else {
            return .none
        }
        if let settleUntil, now < settleUntil {
            return .orderOutAgain
        }
        return .unpark
    }

    private func installBackstop(for window: NSWindow, windowID: Int) {
        var cancellables = Set<AnyCancellable>()
        for name in Self.backstopNotifications {
            notificationCenter.publisher(for: name, object: window)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.deliverBackstopNotification(windowID: windowID)
                    }
                }
                .store(in: &cancellables)
        }
        backstopCancellables[windowID] = cancellables
    }

    private func deliverBackstopNotification(windowID: Int) {
        #if DEBUG
            guard automaticBackstopDeliveryEnabled else {
                return
            }
        #endif
        guard let window = windowLookup(windowID)?.nsWindow else {
            return
        }
        switch Self.backstopAction(
            isParked: isParked(windowID: windowID),
            isVisible: visibility.isVisible(window),
            settleUntil: settleUntil[windowID],
            now: now()
        ) {
        case .none:
            break
        case .orderOutAgain:
            ordering.orderOut(window)
        case .unpark:
            unpark(windowID: windowID)
        }
    }
}

struct FleetAppLifecycleInputs: Equatable {
    var backgroundModeHasWindow: Bool
    var fleetParkedCount: Int
    var visibleWindowCount: Int
}

enum FleetReopenAction: Equatable {
    case restoreBackgroundMode
    case openFleetManager
    case none
}

enum FleetAppLifecycleDecision {
    static func shouldTerminateAfterLastWindowClosed(_ inputs: FleetAppLifecycleInputs) -> Bool {
        !inputs.backgroundModeHasWindow && inputs.fleetParkedCount == 0
    }

    static func reopenAction(_ inputs: FleetAppLifecycleInputs) -> FleetReopenAction {
        guard inputs.visibleWindowCount == 0 else {
            return .none
        }
        if inputs.backgroundModeHasWindow {
            return .restoreBackgroundMode
        }
        if inputs.fleetParkedCount > 0 {
            return .openFleetManager
        }
        return .none
    }

    @MainActor
    static func handleReopen(
        _ inputs: FleetAppLifecycleInputs,
        restore: () -> Void,
        openFleetManager: () -> Void
    ) -> Bool {
        switch reopenAction(inputs) {
        case .restoreBackgroundMode:
            restore()
            return true
        case .openFleetManager:
            openFleetManager()
            return true
        case .none:
            return false
        }
    }
}
