import AppKit
import Combine
import SwiftUI

struct FleetCommandWindowCandidate: Equatable {
    var windowID: Int
    var isFocused: Bool
    var isParked: Bool
}

enum FleetCommandTarget: Equatable {
    case window(Int)
    case revealParked(Int)
}

enum FleetCommandTargeting {
    static func target(_ candidates: [FleetCommandWindowCandidate]) -> Int? {
        let unparked = candidates.filter { !$0.isParked }
        return unparked.first(where: \.isFocused)?.windowID ?? unparked.last?.windowID
    }

    static func promptTarget(_ candidates: [FleetCommandWindowCandidate]) -> FleetCommandTarget? {
        if let id = target(candidates) { return .window(id) }
        return candidates.last.map { .revealParked($0.windowID) }
    }

    @MainActor
    static func liveCandidates(manager: WindowStatesManager, parked: Set<Int>) -> [FleetCommandWindowCandidate] {
        manager.allWindows.filter { !$0.isClosing }.map {
            FleetCommandWindowCandidate(
                windowID: $0.windowID,
                isFocused: $0.isCurrentlyFocused,
                isParked: parked.contains($0.windowID)
            )
        }
    }

    @MainActor
    static func liveTargetWindow() -> WindowState? {
        let manager = WindowStatesManager.shared
        let candidates = liveCandidates(manager: manager, parked: FleetParkingCoordinator.shared.parkedWindowIDs)
        return target(candidates).flatMap { manager.window(withID: $0) }
    }
}

enum FleetCommandKind: Hashable {
    case saveWorkspace
    case saveAndExit
    case closeWindow
    case openFleetManager
}

enum FleetCommandPlacement {
    case afterSaveItem
    case beforeSaveItem
    case afterWindowArrangement
}

struct FleetCommandShortcut: Equatable {
    var key: Character
    var modifiers: EventModifiers
}

struct FleetCommandDescriptor: Identifiable {
    var id: FleetCommandKind
    var title: String
    var shortcut: FleetCommandShortcut?
    var placement: FleetCommandPlacement
}

enum FleetCommandCatalog {
    static let descriptors: [FleetCommandDescriptor] = [
        FleetCommandDescriptor(
            id: .saveWorkspace,
            title: "Save Workspace",
            shortcut: FleetCommandShortcut(key: "s", modifiers: .command),
            placement: .afterSaveItem
        ),
        FleetCommandDescriptor(
            id: .saveAndExit,
            title: "Save & Exit Workspace",
            shortcut: FleetCommandShortcut(key: "s", modifiers: [.command, .shift]),
            placement: .afterSaveItem
        ),
        FleetCommandDescriptor(
            id: .closeWindow,
            title: "Close Window",
            shortcut: FleetCommandShortcut(key: "w", modifiers: [.command, .shift]),
            placement: .beforeSaveItem
        ),
        FleetCommandDescriptor(
            id: .openFleetManager,
            title: "Fleet Manager",
            shortcut: nil,
            placement: .afterWindowArrangement
        )
    ]
}

@MainActor
final class FleetCommandCenter: ObservableObject {
    static let refreshNotification = Notification.Name("FleetCommandCenter.refresh")

    @Published private(set) var hasTarget: Bool

    private let candidates: () -> [FleetCommandWindowCandidate]
    private let keyWindow: () -> NSWindow?
    private let openFleetManager: () -> Void
    private let saveWorkspace: (Int) -> Void
    private let saveAndExit: (Int) async -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        candidates: @escaping () -> [FleetCommandWindowCandidate],
        keyWindow: @escaping () -> NSWindow?,
        openFleetManager: @escaping () -> Void,
        saveWorkspace: @escaping (Int) -> Void,
        saveAndExit: @escaping (Int) async -> Void,
        notificationCenter: NotificationCenter = .default,
        windowsChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.candidates = candidates
        self.keyWindow = keyWindow
        self.openFleetManager = openFleetManager
        self.saveWorkspace = saveWorkspace
        self.saveAndExit = saveAndExit
        hasTarget = FleetCommandTargeting.target(candidates()) != nil
        let names = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            Self.refreshNotification
        ]
        Publishers.MergeMany(names.map { notificationCenter.publisher(for: $0).map { _ in () } })
            .merge(with: windowsChanged)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    static func live() -> FleetCommandCenter {
        FleetCommandCenter(
            candidates: {
                FleetCommandTargeting.liveCandidates(
                    manager: WindowStatesManager.shared,
                    parked: FleetParkingCoordinator.shared.parkedWindowIDs
                )
            },
            keyWindow: { NSApplication.shared.keyWindow },
            openFleetManager: { FleetParkingCoordinator.shared.openFleetManager() },
            saveWorkspace: { WindowStatesManager.shared.window(withID: $0)?.workspaceManager.pollAndSaveState() },
            saveAndExit: { await WindowStatesManager.shared.window(withID: $0)?.workspaceManager.saveAndExitToFallback() },
            windowsChanged: WindowStatesManager.shared.$allWindows.map { _ in () }.eraseToAnyPublisher()
        )
    }

    func descriptors(for placement: FleetCommandPlacement) -> [FleetCommandDescriptor] {
        FleetCommandCatalog.descriptors.filter { $0.placement == placement }
    }

    func isEnabled(_ kind: FleetCommandKind) -> Bool {
        switch kind {
        case .saveWorkspace, .saveAndExit: hasTarget
        case .closeWindow, .openFleetManager: true
        }
    }

    func perform(_ kind: FleetCommandKind) async {
        switch kind {
        case .saveWorkspace:
            if let id = FleetCommandTargeting.target(candidates()) { saveWorkspace(id) }
        case .saveAndExit:
            if let id = FleetCommandTargeting.target(candidates()) { await saveAndExit(id) }
        case .closeWindow:
            keyWindow()?.performClose(nil)
        case .openFleetManager:
            openFleetManager()
        }
    }

    func refresh() {
        let value = FleetCommandTargeting.target(candidates()) != nil
        if hasTarget != value { hasTarget = value }
    }
}

struct FleetCommandButton: View {
    let descriptor: FleetCommandDescriptor
    @ObservedObject var center: FleetCommandCenter

    var body: some View {
        Button(descriptor.title) { Task { await center.perform(descriptor.id) } }
            .optionalKeyboardShortcut(descriptor.shortcut)
            .disabled(!center.isEnabled(descriptor.id))
    }
}

private extension View {
    @ViewBuilder
    func optionalKeyboardShortcut(_ shortcut: FleetCommandShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}
