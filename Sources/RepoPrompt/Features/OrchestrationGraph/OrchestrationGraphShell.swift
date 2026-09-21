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

/// Graph data the shell renders: the projection, its layout, and the route each session node opens.
///
/// A session with no recorded compose tab has no route; its node cannot be selected.
struct OrchestrationGraphSnapshot: Equatable {
    struct SessionRoute: Equatable, Hashable {
        let workspaceID: UUID
        let tabID: UUID
    }

    let projection: OrchestrationGraphProjection
    let layout: OrchestrationGraphLayout
    let sessionRoutes: [UUID: SessionRoute]

    init(projection: OrchestrationGraphProjection, sessionRoutes: [UUID: SessionRoute] = [:]) {
        self.projection = projection
        layout = OrchestrationGraphLayout.make(projection: projection)
        self.sessionRoutes = sessionRoutes
    }

    static let empty = OrchestrationGraphSnapshot(
        projection: OrchestrationGraphProjection.make(
            workspaces: [],
            persisted: [],
            live: [],
            isHistoryScanIncomplete: false
        )
    )

    func target(forSessionID sessionID: UUID) -> OrchestrationGraphInspectorTarget? {
        sessionRoutes[sessionID].map {
            .session(workspaceID: $0.workspaceID, tabID: $0.tabID, sessionID: sessionID)
        }
    }

    func sessionName(for sessionID: UUID) -> String {
        for node in projection.nodes {
            if case let .session(session) = node, session.sessionID == sessionID {
                return session.name.isEmpty ? "Untitled session" : session.name
            }
        }
        return "Untitled session"
    }
}

/// Produces the shell's snapshot. Runs on the shell's first appearance, never in an initializer.
struct OrchestrationGraphSnapshotLoader {
    let load: @MainActor () async -> OrchestrationGraphSnapshot

    /// Saved workspaces of the graph window plus the persisted sessions of exactly those workspaces.
    static func production(windowState: WindowState) -> OrchestrationGraphSnapshotLoader {
        OrchestrationGraphSnapshotLoader { [weak windowState] in
            guard let windowState else { return .empty }
            let workspaces = windowState.workspaceManager.workspaces
            let sessionRoot = AgentSessionDataService.defaultWorkspaceRootURL()
            var workspaceIDByDirectory: [String: UUID] = [:]
            for workspace in workspaces {
                let directory = WorkspaceSessionSidecarMigration.workspaceDirectory(for: workspace, root: sessionRoot)
                workspaceIDByDirectory[directory.standardizedFileURL.path] = workspace.id
            }
            let directories = workspaceIDByDirectory.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
            let scanner = HistorySessionScanner(
                applicationSupportRoot: sessionRoot.deletingLastPathComponent(),
                scanCacheTTL: 0,
                workspaceDirectoryProvider: { _ in directories }
            )

            var persisted: [OrchestrationGraphProjection.PersistedSessionInput] = []
            var routes: [UUID: OrchestrationGraphSnapshot.SessionRoute] = [:]
            var isIncomplete = false
            do {
                let scan = try await scanner.scanWorkspacesRefreshing(matching: nil)
                isIncomplete = scan.isTruncated
                for result in scan.workspaces {
                    let directoryPath = result.workspaceDir.standardizedFileURL.path
                    guard let workspaceID = workspaceIDByDirectory[directoryPath] ?? result.workspaceID else { continue }
                    for record in result.records {
                        persisted.append(.init(
                            sessionID: record.id,
                            workspaceID: workspaceID,
                            name: record.name,
                            parentSessionID: record.parentSessionID,
                            runState: .fromPersistedRaw(record.lastRunStateRaw)
                        ))
                        if let tabID = record.composeTabID {
                            routes[record.id] = .init(workspaceID: workspaceID, tabID: tabID)
                        }
                    }
                }
            } catch {
                isIncomplete = true
            }

            let projection = OrchestrationGraphProjection.make(
                workspaces: workspaces.map { .init(id: $0.id, name: $0.name) },
                persisted: persisted,
                live: [],
                isHistoryScanIncomplete: isIncomplete
            )
            return OrchestrationGraphSnapshot(projection: projection, sessionRoutes: routes)
        }
    }
}

/// Holds the shell's snapshot. Selection never rebuilds, filters or replaces it.
@MainActor
final class OrchestrationGraphShellGraphState: ObservableObject {
    @Published private(set) var snapshot: OrchestrationGraphSnapshot = .empty

    private let loader: OrchestrationGraphSnapshotLoader
    private var loadTask: Task<Void, Never>?

    init(loader: OrchestrationGraphSnapshotLoader) {
        self.loader = loader
    }

    func loadIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let loader = loader
        let task = Task { [weak self] in
            let snapshot = await loader.load()
            guard !Task.isCancelled else { return }
            self?.snapshot = snapshot
        }
        loadTask = task
        await task.value
    }

    func cancel() {
        loadTask?.cancel()
    }
}

/// Root surface of a main window while the orchestration graph flag is on: the graph pane and
/// exactly one `OrchestrationGraphInspector`. Selecting a node never switches the graph window.
struct OrchestrationGraphShell: View {
    @ObservedObject var windowState: WindowState
    @StateObject private var inspectorModel: OrchestrationGraphInspectorModel
    @StateObject private var graph: OrchestrationGraphShellGraphState

    init(windowState: WindowState) {
        self.windowState = windowState
        _inspectorModel = StateObject(wrappedValue: OrchestrationGraphInspectorModel.production())
        _graph = StateObject(wrappedValue: OrchestrationGraphShellGraphState(
            loader: .production(windowState: windowState)
        ))
    }

    init(
        windowState: WindowState,
        inspectorModel: OrchestrationGraphInspectorModel,
        snapshotLoader: OrchestrationGraphSnapshotLoader
    ) {
        self.windowState = windowState
        let graph = OrchestrationGraphShellGraphState(loader: snapshotLoader)
        _inspectorModel = StateObject(wrappedValue: inspectorModel)
        _graph = StateObject(wrappedValue: graph)
    }

    func select(_ target: OrchestrationGraphInspectorTarget) {
        inspectorModel.select(target)
    }

    func loadSnapshotIfNeeded() async {
        await graph.loadIfNeeded()
    }

    #if DEBUG
        var inspectorModelForTesting: OrchestrationGraphInspectorModel {
            inspectorModel
        }

        var snapshotForTesting: OrchestrationGraphSnapshot {
            graph.snapshot
        }
    #endif

    var body: some View {
        HSplitView {
            graphPane
                .frame(minWidth: 240, idealWidth: 320, maxHeight: .infinity, alignment: .topLeading)
            OrchestrationGraphInspector(model: inspectorModel)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 320)
        .task { await graph.loadIfNeeded() }
        .onDisappear {
            graph.cancel()
            inspectorModel.requestTearDown()
        }
    }

    private var graphPane: some View {
        let snapshot = graph.snapshot
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Orchestration Graph")
                    .font(.title2.weight(.semibold))
                if snapshot.projection.isHistoryScanIncomplete {
                    Text("Some session history could not be read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if snapshot.layout.clusters.isEmpty {
                    Text("No sessions yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.layout.clusters, id: \.key) { cluster in
                        clusterView(cluster, snapshot: snapshot)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func clusterView(
        _ cluster: OrchestrationGraphLayout.Cluster,
        snapshot: OrchestrationGraphSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let workspaceID = cluster.workspaceID {
                Button(cluster.workspaceName ?? "Workspace") {
                    select(.workspace(workspaceID: workspaceID))
                }
                .buttonStyle(.link)
            } else {
                Text("Unassigned")
                    .foregroundStyle(.secondary)
            }
            ForEach(cluster.sessionIDs, id: \.self) { sessionID in
                let target = snapshot.target(forSessionID: sessionID)
                Button(snapshot.sessionName(for: sessionID)) {
                    if let target {
                        select(target)
                    }
                }
                .buttonStyle(.link)
                .disabled(target == nil)
                .padding(.leading, 12)
            }
        }
    }
}
