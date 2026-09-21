import SwiftUI

/// Single-window policy for the orchestration graph.
///
/// With the graph flag on, the app is one graph window: routes that would attach a second main
/// `WindowState` (Dock → New Window, File → New Window, MCP `open_in_new_window`) stop doing so.
/// The flag only limits a *second* window, so every route can still recover from zero windows.
/// The flag is read live at each action; nothing caches it at launch.
@MainActor
struct OrchestrationGraphWindowPolicy {
    var isGraphEnabled: @MainActor () -> Bool
    var mainWindowCount: @MainActor () -> Int

    init(
        isGraphEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.orchestrationGraphEnabled() },
        mainWindowCount: @escaping @MainActor () -> Int = { WindowStatesManager.shared.allWindows.count }
    ) {
        self.isGraphEnabled = isGraphEnabled
        self.mainWindowCount = mainWindowCount
    }

    static var production: OrchestrationGraphWindowPolicy {
        OrchestrationGraphWindowPolicy()
    }

    var allowsAdditionalMainWindow: Bool {
        !isGraphEnabled() || mainWindowCount() == 0
    }

    var mountsGraphShell: Bool {
        isGraphEnabled()
    }

    /// File → New Window (⌘N). `openWindow` is the scene's `openWindow(id: "main")` action, so the
    /// command works with zero windows and before any `AppWindowOpener` install. When the policy
    /// forbids another window the command does nothing.
    static func performNewWindowCommand(
        policy: OrchestrationGraphWindowPolicy,
        openWindow: () -> Void
    ) {
        guard policy.allowsAdditionalMainWindow else { return }
        openWindow()
    }
}

/// Root surface of a main window while the orchestration graph flag is on.
///
/// OG-04 only mounts the shell: it renders the layout of an empty projection. Session data and the
/// inspector arrive in later stories (OG-05).
struct OrchestrationGraphShell: View {
    @ObservedObject var windowState: WindowState

    private let layout = OrchestrationGraphLayout.make(
        projection: OrchestrationGraphProjection.make(
            workspaces: [],
            persisted: [],
            live: [],
            isHistoryScanIncomplete: false
        )
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Orchestration Graph")
                .font(.title2.weight(.semibold))
            if layout.clusters.isEmpty {
                Text("No sessions yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(layout.clusters, id: \.key) { cluster in
                    Text(cluster.workspaceName ?? "Unassigned")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
