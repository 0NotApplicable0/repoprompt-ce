import RepoPromptFileSystem
import SwiftUI

/// Extra File-menu items that operate on the *focused* window’s workspace.
struct WorkspaceCommands: Commands {
    /// Shared window tracker injected from the app. Not observed.
    let windowStatesManager: WindowStatesManager

    /// Observed only for its `hasTarget` flag, which publishes on change, so the menu rebuilds
    /// when enablement flips and not on every window open/close.
    @ObservedObject var center: FleetCommandCenter

    @MainActor
    init(windowStatesManager: WindowStatesManager, center: FleetCommandCenter? = nil) {
        self.windowStatesManager = windowStatesManager
        _center = ObservedObject(wrappedValue: center ?? .live())
    }

    var body: some Commands {
        // Insert immediately after the system "Save" item.
        CommandGroup(after: .saveItem) {
            ForEach(center.descriptors(for: .afterSaveItem)) {
                FleetCommandButton(descriptor: $0, center: center)
            }
        }
    }
}
