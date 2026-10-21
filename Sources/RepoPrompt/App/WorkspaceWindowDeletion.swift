import Foundation

@MainActor
protocol WorkspaceWindowDeletionTarget: AnyObject {
    var windowID: Int { get }
    var deletionWorkspaceID: UUID? { get }
    var isClosing: Bool { get }
    func systemWorkspaceForDeletion() -> WorkspaceModel
    func switchForDeletion(to workspace: WorkspaceModel, saveState: Bool, origin: WorkspaceSwitchOrigin) async -> WorkspaceSwitchResult
    func deleteForDeletion(_ workspace: WorkspaceModel) async -> Bool
}

@MainActor
struct WorkspaceWindowDeletion {
    enum Result {
        case closeRequested(windowID: Int)
        case notSwitched(message: String)
        case deleteFailed(message: String)
        case targetChanged(message: String)
        case deletionCommittedWithoutClose(message: String)
        case closeFailed(Error)

        var message: String? {
            switch self {
            case .closeRequested:
                nil
            case let .notSwitched(message), let .deleteFailed(message), let .targetChanged(message), let .deletionCommittedWithoutClose(message):
                message
            case let .closeFailed(error):
                "Workspace deletion committed, but the window could not be closed: \(error.localizedDescription)"
            }
        }
    }

    private let target: any WorkspaceWindowDeletionTarget
    private let windowID: Int
    private let workspace: WorkspaceModel
    private let registeredTarget: @MainActor (Int) -> (any WorkspaceWindowDeletionTarget)?
    private let showingWindowIDs: @MainActor (UUID) -> [Int]
    private let isParked: @MainActor (Int) -> Bool
    private let unpark: @MainActor (Int) -> Void
    private let requestClose: @MainActor (Int, WindowCloseAuthorization) throws -> Void
    private let authorization: WindowCloseAuthorization
    private let origin: WorkspaceSwitchOrigin

    init(
        target: any WorkspaceWindowDeletionTarget,
        workspace: WorkspaceModel,
        registeredTarget: @escaping @MainActor (Int) -> (any WorkspaceWindowDeletionTarget)? = { WindowStatesManager.shared.window(withID: $0) },
        showingWindowIDs: @escaping @MainActor (UUID) -> [Int] = { workspaceID in
            WindowStatesManager.shared.allWindows.filter { $0.workspaceManager.activeWorkspaceID == workspaceID }.map(\.windowID)
        },
        isParked: @escaping @MainActor (Int) -> Bool = { FleetParkingCoordinator.shared.isParked(windowID: $0) },
        unpark: @escaping @MainActor (Int) -> Void = { FleetParkingCoordinator.shared.unpark(windowID: $0) },
        requestClose: @escaping @MainActor (Int, WindowCloseAuthorization) throws -> Void = {
            try WindowStatesManager.shared.requestCloseWindow(windowID: $0, authorization: $1)
        },
        authorization: WindowCloseAuthorization = WorkspaceWindowDeletion.closeAuthorization(),
        origin: WorkspaceSwitchOrigin = .person
    ) {
        self.target = target
        windowID = target.windowID
        self.workspace = workspace
        self.registeredTarget = registeredTarget
        self.showingWindowIDs = showingWindowIDs
        self.isParked = isParked
        self.unpark = unpark
        self.requestClose = requestClose
        self.authorization = authorization
        self.origin = origin
    }

    nonisolated static func closeAuthorization() -> WindowCloseAuthorization {
        WindowCloseAuthorization(source: .workspaceDelete, bypassConfirmation: true, bypassBackgroundPreservation: true)
    }

    nonisolated static func duplicateWorkspaceMessage(name: String, windowIDs: [Int]) -> String {
        "Workspace '\(name)' is active in multiple windows: \(windowIDs.sorted().map(String.init).joined(separator: ", ")). Close those windows or switch them away before deleting."
    }

    func execute() async -> Result {
        guard isCurrent(workspaceID: workspace.id) else { return .targetChanged(message: changedMessage) }
        let initialHolders = showingWindowIDs(workspace.id)
        guard !initialHolders.contains(where: { $0 != windowID }) else {
            return .targetChanged(message: Self.duplicateWorkspaceMessage(name: workspace.name, windowIDs: initialHolders))
        }
        let fallback = target.systemWorkspaceForDeletion()
        guard isCurrent(workspaceID: workspace.id) else { return .targetChanged(message: changedMessage) }
        let holdersBeforeSwitch = showingWindowIDs(workspace.id)
        guard !holdersBeforeSwitch.contains(where: { $0 != windowID }) else {
            return .targetChanged(message: Self.duplicateWorkspaceMessage(name: workspace.name, windowIDs: holdersBeforeSwitch))
        }
        let switched = await target.switchForDeletion(to: fallback, saveState: false, origin: origin)
        guard switched.didSwitch else {
            return .notSwitched(message: switched.message ?? "Workspace switch was cancelled.")
        }
        guard isCurrent(workspaceID: fallback.id) else { return .targetChanged(message: changedMessage) }
        // A valid original fallback must be unparked before duplicate/deletion admission, without another await.
        if isParked(windowID) { unpark(windowID) }
        let otherHolders = showingWindowIDs(workspace.id).filter { $0 != windowID }.sorted()
        guard otherHolders.isEmpty else {
            return .targetChanged(message: "Workspace '\(workspace.name)' was not deleted because it became active in windows: \(otherHolders.map(String.init).joined(separator: ", ")). Window \(windowID) remains open on the system workspace.")
        }
        guard isCurrent(workspaceID: fallback.id) else { return .targetChanged(message: changedMessage) }
        guard await target.deleteForDeletion(workspace) else {
            return .deleteFailed(message: "Workspace '\(workspace.name)' could not be deleted. Window \(windowID) remains open on the system workspace.")
        }
        guard isCurrent(workspaceID: fallback.id) else {
            return .deletionCommittedWithoutClose(message: "Workspace '\(workspace.name)' was deleted, but window \(windowID) changed and was not closed.")
        }
        do {
            try requestClose(windowID, authorization)
            return .closeRequested(windowID: windowID)
        } catch {
            return .closeFailed(error)
        }
    }

    private var changedMessage: String {
        "Workspace '\(workspace.name)' was not deleted because window \(windowID) changed."
    }

    private func isCurrent(workspaceID: UUID) -> Bool {
        guard let registered = registeredTarget(windowID) else { return false }
        return registered === target && !target.isClosing && target.deletionWorkspaceID == workspaceID
    }
}

extension WindowState: WorkspaceWindowDeletionTarget {
    var deletionWorkspaceID: UUID? {
        workspaceManager.activeWorkspaceID
    }

    func systemWorkspaceForDeletion() -> WorkspaceModel {
        workspaceManager.getOrCreateSystemWorkspace()
    }

    func switchForDeletion(to workspace: WorkspaceModel, saveState: Bool, origin: WorkspaceSwitchOrigin) async -> WorkspaceSwitchResult {
        await workspaceManager.requestWorkspaceSwitch(to: workspace, saveState: saveState, origin: origin)
    }

    func deleteForDeletion(_ workspace: WorkspaceModel) async -> Bool {
        await workspaceManager.deleteWorkspaceAsync(workspace)
    }
}
