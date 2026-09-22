import Combine
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
        !isGraphEnabled() || (mainWindowCount() == 0 && !AppWindowOpener.shared.isGraphWindowOpenInFlight)
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
        guard AppWindowOpener.shared.tryBeginGraphWindowOpen(policy: policy) else { return }
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
        if let route = sessionRoutes[sessionID] {
            return .session(workspaceID: route.workspaceID, tabID: route.tabID, sessionID: sessionID)
        }
        var workspaceID: UUID?
        for node in projection.nodes {
            if case let .session(session) = node, session.sessionID == sessionID {
                workspaceID = session.workspaceID
                break
            }
        }
        guard let workspaceID,
              let sibling = sessionRoutes.values.first(where: { $0.workspaceID == workspaceID })
        else { return nil }
        return .session(workspaceID: workspaceID, tabID: sibling.tabID, sessionID: sessionID)
    }

    /// Live/persisted compose tabs, then parent dispatch so nested workers share the orchestrator's tab.
    static func resolvedSessionRoutes(
        seed: [UUID: SessionRoute],
        live: [OrchestrationGraphProjection.LiveSessionInput],
        projection: OrchestrationGraphProjection
    ) -> [UUID: SessionRoute] {
        var routes = seed
        for session in live {
            guard let workspaceID = session.workspaceID, let tabID = session.composeTabID else { continue }
            if routes[session.sessionID] == nil {
                routes[session.sessionID] = SessionRoute(workspaceID: workspaceID, tabID: tabID)
            }
        }
        var changed = true
        while changed {
            changed = false
            for edge in projection.edges where edge.kind == .dispatch {
                guard case let .session(parentID) = edge.source,
                      case let .session(childID) = edge.target,
                      routes[childID] == nil,
                      let parentRoute = routes[parentID]
                else { continue }
                routes[childID] = parentRoute
                changed = true
            }
        }
        return routes
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

/// Produces the shell's snapshot. Production waits for workspace init, merges live Agent Mode
/// sessions over the persisted scan, and can be invoked again when those inputs change.
struct OrchestrationGraphSnapshotLoader {
    let load: @MainActor () async -> OrchestrationGraphSnapshot

    /// Saved workspaces of the graph window, persisted sessions of those workspaces, and live
    /// sessions from this window and any other registered main window.
    static func production(windowState: WindowState) -> OrchestrationGraphSnapshotLoader {
        OrchestrationGraphSnapshotLoader { [weak windowState] in
            guard let windowState else { return .empty }
            await windowState.workspaceManager.awaitInitialized()
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
                            runState: .fromPersistedRaw(record.lastRunStateRaw),
                            composeTabID: record.composeTabID
                        ))
                        if let tabID = record.composeTabID {
                            routes[record.id] = .init(workspaceID: workspaceID, tabID: tabID)
                        }
                    }
                }
            } catch {
                isIncomplete = true
            }

            let live = liveSessionInputs(from: windowState)
            let projection = OrchestrationGraphProjection.make(
                workspaces: workspaces.map { .init(id: $0.id, name: $0.name) },
                persisted: persisted,
                live: live,
                isHistoryScanIncomplete: isIncomplete
            )
            return OrchestrationGraphSnapshot(
                projection: projection,
                sessionRoutes: OrchestrationGraphSnapshot.resolvedSessionRoutes(
                    seed: routes,
                    live: live,
                    projection: projection
                )
            )
        }
    }

    @MainActor
    private static func liveSessionInputs(from windowState: WindowState) -> [OrchestrationGraphProjection.LiveSessionInput] {
        var windows = WindowStatesManager.shared.allWindows
        if !windows.contains(where: { $0 === windowState }) {
            windows.append(windowState)
        }
        var liveByID: [UUID: OrchestrationGraphProjection.LiveSessionInput] = [:]
        for window in windows {
            for (sessionID, entry) in window.agentModeViewModel.sessionIndex {
                let workspaceID = workspaceID(forTab: entry.tabID, window: window)
                    ?? window.workspaceManager.activeWorkspaceID
                liveByID[sessionID] = .init(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    name: entry.name,
                    parentSessionID: entry.parentSessionID,
                    runState: .fromPersistedRaw(entry.lastRunStateRaw),
                    statusText: nil,
                    composeTabID: entry.tabID
                )
            }
            for (tabID, session) in window.agentModeViewModel.sessions {
                guard let sessionID = session.activeAgentSessionID else { continue }
                let existing = liveByID[sessionID]
                let workspaceID = workspaceID(forTab: tabID, window: window)
                    ?? existing?.workspaceID
                let name = window.agentModeViewModel.sessionIndex[sessionID]?.name
                    ?? composeTabName(tabID: tabID, window: window)
                    ?? existing?.name
                    ?? ""
                liveByID[sessionID] = .init(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    name: name,
                    parentSessionID: session.parentSessionID ?? existing?.parentSessionID,
                    runState: .fromPersistedRaw(session.runState.rawValue),
                    statusText: session.runningStatusText,
                    composeTabID: tabID
                )
            }
        }
        return liveByID.values.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    @MainActor
    private static func workspaceID(forTab tabID: UUID, window: WindowState) -> UUID? {
        for workspace in window.workspaceManager.workspaces {
            if workspace.composeTabs.contains(where: { $0.id == tabID })
                || workspace.stashedTabs.contains(where: { $0.tab.id == tabID })
            {
                return workspace.id
            }
        }
        return window.workspaceManager.activeWorkspaceID
    }

    @MainActor
    private static func composeTabName(tabID: UUID, window: WindowState) -> String? {
        for workspace in window.workspaceManager.workspaces {
            if let tab = workspace.composeTabs.first(where: { $0.id == tabID }) {
                return tab.name
            }
            if let stashed = workspace.stashedTabs.first(where: { $0.tab.id == tabID }) {
                return stashed.tab.name
            }
        }
        return nil
    }
}

/// Holds the shell's snapshot. Selection never rebuilds, filters or replaces it.
@MainActor
final class OrchestrationGraphShellGraphState: ObservableObject {
    @Published private(set) var snapshot: OrchestrationGraphSnapshot = .empty

    private let loader: OrchestrationGraphSnapshotLoader
    private weak var windowState: WindowState?
    private var loadGeneration = 0
    private var didStart = false
    private var reloadTask: Task<Void, Never>?
    private var observations: Set<AnyCancellable> = []

    init(loader: OrchestrationGraphSnapshotLoader, windowState: WindowState? = nil) {
        self.loader = loader
        self.windowState = windowState
    }

    func loadIfNeeded() async {
        if didStart {
            await reloadTask?.value
            return
        }
        didStart = true
        await reload()
        startObserving()
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let loader = loader
        let task = Task { [weak self] in
            let snapshot = await loader.load()
            guard let self, generation == loadGeneration else { return }
            self.snapshot = snapshot
        }
        reloadTask = task
        await task.value
    }

    func cancel() {
        loadGeneration += 1
        reloadTask?.cancel()
        observations.removeAll()
    }

    private func startObserving() {
        guard observations.isEmpty, let windowState else { return }
        windowState.workspaceManager.$workspaces
            .dropFirst()
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.reload()
                }
            }
            .store(in: &observations)
        windowState.agentModeViewModel.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.reload()
                }
            }
            .store(in: &observations)
        Timer.publish(every: 8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.reload()
                }
            }
            .store(in: &observations)
    }
}

/// Root surface of a main window while the orchestration graph flag is on: the graph pane and
/// exactly one `OrchestrationGraphInspector`. Selecting a node never switches the graph window.
private struct InspectorDialogChrome: View {
    let title: String
    @ObservedObject var model: OrchestrationGraphInspectorModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") {
                    onDone()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            OrchestrationGraphInspector(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct OrchestrationGraphShell: View {
    @ObservedObject var windowState: WindowState
    @StateObject private var inspectorModel: OrchestrationGraphInspectorModel
    @StateObject private var graph: OrchestrationGraphShellGraphState
    @State private var isInspectorPresented = false
    @State private var isRefreshing = false
    @State private var workspacePendingRename: WorkspaceModel?
    @State private var renameField = ""
    @State private var workspacePendingDelete: WorkspaceModel?

    init(windowState: WindowState) {
        self.windowState = windowState
        _inspectorModel = StateObject(wrappedValue: OrchestrationGraphInspectorModel.production())
        _graph = StateObject(wrappedValue: OrchestrationGraphShellGraphState(
            loader: .production(windowState: windowState),
            windowState: windowState
        ))
    }

    init(
        windowState: WindowState,
        inspectorModel: OrchestrationGraphInspectorModel,
        snapshotLoader: OrchestrationGraphSnapshotLoader
    ) {
        self.windowState = windowState
        let graph = OrchestrationGraphShellGraphState(loader: snapshotLoader, windowState: windowState)
        _inspectorModel = StateObject(wrappedValue: inspectorModel)
        _graph = StateObject(wrappedValue: graph)
    }

    func select(_ target: OrchestrationGraphInspectorTarget) {
        inspectorModel.select(target)
        // Presenting a SwiftUI `.sheet` (a nested NSWindow) during the same
        // display-cycle as the graph canvas NSViewRepresentable aborts in
        // `-[NSWindow _postWindowNeedsUpdateConstraints]`. Hop to the next
        // run-loop turn and keep the inspector in this window.
        guard !isInspectorPresented else { return }
        DispatchQueue.main.async {
            isInspectorPresented = true
        }
    }

    func loadSnapshotIfNeeded() async {
        await graph.loadIfNeeded()
    }

    func reloadSnapshot() async {
        await graph.reload()
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
        ZStack {
            graphPane
            if isInspectorPresented {
                inspectorOverlay
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .task { await graph.loadIfNeeded() }
        .alert("Rename Workspace", isPresented: renamePresented) {
            TextField("Name", text: $renameField)
            Button("Cancel", role: .cancel) { workspacePendingRename = nil }
            Button("Save") { commitWorkspaceRename() }
        } message: {
            Text("Enter a new name for this workspace.")
        }
        .alert("Delete Workspace?", isPresented: deletePresented) {
            Button("Cancel", role: .cancel) { workspacePendingDelete = nil }
            Button("Delete", role: .destructive) { commitWorkspaceDelete() }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .onDisappear {
            graph.cancel()
            inspectorModel.requestTearDown()
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { workspacePendingRename != nil },
            set: { if !$0 { workspacePendingRename = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { workspacePendingDelete != nil },
            set: { if !$0 { workspacePendingDelete = nil } }
        )
    }

    private var deleteConfirmationMessage: String {
        let name = workspacePendingDelete?.name ?? "this workspace"
        return "This deletes “\(name)” and its saved tabs and session history. Project folders are kept. This cannot be undone."
    }

    private func beginRenameWorkspace(_ workspaceID: UUID) {
        guard let workspace = windowState.workspaceManager.workspace(withID: workspaceID) else { return }
        renameField = workspace.name
        workspacePendingRename = workspace
    }

    private func commitWorkspaceRename() {
        guard let workspace = workspacePendingRename else { return }
        windowState.workspaceManager.renameWorkspace(workspace, newName: renameField)
        workspacePendingRename = nil
        Task { await graph.reload() }
    }

    private func beginDeleteWorkspace(_ workspaceID: UUID) {
        guard let workspace = windowState.workspaceManager.workspace(withID: workspaceID),
              !workspace.isSystemWorkspace
        else { return }
        workspacePendingDelete = workspace
    }

    private func commitWorkspaceDelete() {
        guard let workspace = workspacePendingDelete else { return }
        workspacePendingDelete = nil
        if inspectorModel.mcpBindTargetWorkspaceID == workspace.id {
            inspectorModel.cancelSelection()
            isInspectorPresented = false
        }
        Task {
            _ = await windowState.workspaceManager.deleteWorkspacesAsync(
                workspaceIDs: [workspace.id],
                closeOpenWorkspaces: true
            )
            await graph.reload()
        }
    }

    private var inspectorOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            InspectorDialogChrome(
                title: inspectorDialogTitle,
                model: inspectorModel,
                onDone: dismissInspector
            )
            .frame(minWidth: 960, minHeight: 640)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .padding(28)
        }
    }

    private func dismissInspector() {
        inspectorModel.cancelSelection()
        DispatchQueue.main.async {
            isInspectorPresented = false
        }
    }

    private var inspectorDialogTitle: String {
        switch inspectorModel.surface {
        case let .workspace(id), let .loading(.workspace(id)), let .failure(.workspace(id), _):
            graph.snapshot.projection.nodes.compactMap { node in
                if case let .workspace(workspaceID, name) = node, workspaceID == id { return name }
                return nil
            }.first ?? "Workspace"
        case let .session(_, _, sessionID),
             let .loading(.session(_, _, sessionID)),
             let .failure(.session(_, _, sessionID), _):
            graph.snapshot.sessionName(for: sessionID)
        case .empty:
            "Inspector"
        }
    }

    private var graphPane: some View {
        let snapshot = graph.snapshot
        let selected = selectedIDs
        return ZStack(alignment: .topLeading) {
            Color(red: 0.09, green: 0.09, blue: 0.11)
            if snapshot.layout.clusters.isEmpty {
                Text("No sessions yet.")
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OrchestrationGraphCanvas(
                    snapshot: snapshot,
                    selectedWorkspaceID: selected.workspaceID,
                    selectedSessionID: selected.sessionID,
                    clicksEnabled: !isInspectorPresented,
                    showsEventCatcher: !isInspectorPresented,
                    onSelect: select,
                    isSystemWorkspace: { [windowState] id in
                        windowState.workspaceManager.workspace(withID: id)?.isSystemWorkspace == true
                    },
                    onRenameWorkspace: beginRenameWorkspace,
                    onDeleteWorkspace: beginDeleteWorkspace
                )
                .allowsHitTesting(!isInspectorPresented)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Orchestration Graph")
                    .font(.headline)
                    .foregroundStyle(Color.white.opacity(0.9))
                if snapshot.projection.isHistoryScanIncomplete {
                    Text("Some session history could not be read.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                refreshButton
                    .padding(16)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshGraph() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Refresh graph")
        .disabled(isRefreshing)
    }

    private func refreshGraph() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await graph.reload()
        isRefreshing = false
    }

    private var selectedIDs: (workspaceID: UUID?, sessionID: UUID?) {
        switch inspectorModel.surface {
        case let .workspace(id), let .loading(.workspace(id)), let .failure(.workspace(id), _):
            (id, nil)
        case let .session(_, _, sessionID),
             let .loading(.session(_, _, sessionID)),
             let .failure(.session(_, _, sessionID), _):
            (nil, sessionID)
        case .empty:
            (nil, nil)
        }
    }
}
