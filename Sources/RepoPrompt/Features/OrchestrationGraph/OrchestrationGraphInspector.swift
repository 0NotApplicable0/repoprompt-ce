import SwiftUI

/// A node the orchestration graph can open in its inspector.
enum OrchestrationGraphInspectorTarget: Equatable, Hashable {
    case workspace(workspaceID: UUID)
    case session(workspaceID: UUID, tabID: UUID, sessionID: UUID)

    var workspaceID: UUID {
        switch self {
        case let .workspace(workspaceID), let .session(workspaceID, _, _): workspaceID
        }
    }
}

/// Why the inspector could not mount a target.
enum OrchestrationGraphInspectorFailure: Equatable {
    case workspaceUnavailable
    case workspaceSwitchBlocked(String)
    /// The session's compose tab is neither open nor stashed; the inspector never creates one.
    case sessionTabUnavailable
    case sessionUnavailable
    case sessionMismatch
    case blockedByActiveDifferentSession
    case timedOut

    var message: String {
        switch self {
        case .workspaceUnavailable:
            "The workspace is no longer available."
        case let .workspaceSwitchBlocked(message):
            message
        case .sessionTabUnavailable:
            "The session's tab is no longer open in its workspace."
        case .sessionUnavailable:
            "The session could not be found."
        case .sessionMismatch:
            "The session belongs to a different workspace or tab."
        case .blockedByActiveDifferentSession:
            "Another session is running in this tab."
        case .timedOut:
            "Opening this workspace took too long. Close and try again."
        }
    }

    /// `nil` when the activation succeeded.
    init?(_ result: AgentRouteSessionActivationResult) {
        switch result {
        case .ready:
            return nil
        case .sessionNotFound:
            self = .sessionUnavailable
        case .sessionWorkspaceMismatch, .sessionTabMismatch:
            self = .sessionMismatch
        case .blockedByActiveDifferentSession:
            self = .blockedByActiveDifferentSession
        }
    }
}

/// What the inspector currently shows.
enum OrchestrationGraphInspectorSurface: Equatable {
    case empty
    case loading(OrchestrationGraphInspectorTarget)
    case workspace(UUID)
    case session(workspaceID: UUID, tabID: UUID, sessionID: UUID)
    case failure(OrchestrationGraphInspectorTarget, OrchestrationGraphInspectorFailure)
}

/// Owns the graph inspector's single, lazily created host `WindowState`.
///
/// The host is never registered with `WindowStatesManager` and never gets an `NSWindow`.
/// Selections are latest-wins: a result is published only if no newer selection arrived meanwhile.
@MainActor
final class OrchestrationGraphInspectorModel: ObservableObject {
    typealias HostFactory = @MainActor () -> WindowState
    typealias ActivationGate = @MainActor (OrchestrationGraphInspectorTarget) async -> Void

    let instanceID = UUID()
    @Published private(set) var surface: OrchestrationGraphInspectorSurface = .empty
    @Published private(set) var mcpBindTargetWorkspaceID: UUID?
    @Published private(set) var hostWindowState: WindowState?

    private let hostFactory: HostFactory
    private let activationGate: ActivationGate?
    private var desiredTarget: OrchestrationGraphInspectorTarget?
    private var generation = 0
    private var workerTask: Task<Void, Never>?
    private var tearDownTask: Task<Void, Never>?
    private var isTornDown = false

    init(hostFactory: @escaping HostFactory, activationGate: ActivationGate? = nil) {
        self.hostFactory = hostFactory
        self.activationGate = activationGate
    }

    /// Production host: a full window composition on the app's domain runtime.
    static func production() -> OrchestrationGraphInspectorModel {
        OrchestrationGraphInspectorModel(hostFactory: {
            WindowState(inspectorHostDomainRuntime: AppDomainRuntimeComposition.shared.runtime)
        })
    }

    func select(_ target: OrchestrationGraphInspectorTarget) {
        guard !isTornDown else { return }
        generation += 1
        desiredTarget = target
        surface = .loading(target)
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drainSelections()
        }
    }

    /// Stops an in-flight open so the inspector dialog can dismiss.
    /// Keeps a warm host so the next click does not rebuild WindowState (disk decode,
    /// MCP, Agent Mode) on the main thread. Recycle only when a workspace switch is
    /// still hydrating roots — that reuse used to freeze the second open.
    func cancelSelection() {
        generation += 1
        desiredTarget = nil
        workerTask?.cancel()
        workerTask = nil
        surface = .empty
        mcpBindTargetWorkspaceID = nil
        guard let host = hostWindowState, host.workspaceManager.isSwitchingWorkspace else { return }
        hostWindowState = nil
        Task { await host.tearDown() }
    }

    /// Waits until every queued selection has been applied.
    func waitForIdle() async {
        while let task = workerTask {
            await task.value
        }
    }

    /// Starts the one-time teardown without waiting for it. Later selections are ignored.
    func requestTearDown() {
        guard tearDownTask == nil else { return }
        isTornDown = true
        desiredTarget = nil
        generation += 1
        let worker = workerTask
        worker?.cancel()
        tearDownTask = Task {
            await worker?.value
            await self.releaseHost()
        }
    }

    /// Starts the teardown if needed and waits until the host is torn down.
    func tearDown() async {
        requestTearDown()
        await tearDownTask?.value
    }

    private func releaseHost() async {
        guard let host = hostWindowState else { return }
        hostWindowState = nil
        mcpBindTargetWorkspaceID = nil
        await host.tearDown()
    }

    private func drainSelections() async {
        while let target = desiredTarget, !isTornDown, !Task.isCancelled {
            desiredTarget = nil
            let requestGeneration = generation
            await Task.yield()
            let host = resolvedHost()
            let result = if activationGate == nil {
                await activateWithDeadline(target, on: host)
            } else {
                await activate(target, on: host)
            }
            guard requestGeneration == generation, !isTornDown, !Task.isCancelled else { continue }
            switch result {
            case let .success(surface):
                self.surface = surface
                switch surface {
                case let .workspace(workspaceID):
                    mcpBindTargetWorkspaceID = workspaceID
                case let .session(workspaceID, _, _):
                    mcpBindTargetWorkspaceID = workspaceID
                default:
                    mcpBindTargetWorkspaceID = activeTabID(of: host).flatMap {
                        host.workspaceManager.bindingCandidate(forContextID: $0)?.workspaceID
                    }
                }
            case let .failure(failure):
                surface = .failure(target, failure)
                mcpBindTargetWorkspaceID = nil
            }
        }
        workerTask = nil
    }

    private func resolvedHost() -> WindowState {
        if let hostWindowState {
            return hostWindowState
        }
        let host = hostFactory()
        hostWindowState = host
        return host
    }

    private func activeTabID(of host: WindowState) -> UUID? {
        host.promptManager.activeComposeTabID
    }

    private enum ActivationResult: Sendable {
        case success(OrchestrationGraphInspectorSurface)
        case failure(OrchestrationGraphInspectorFailure)
    }

    private func activateWithDeadline(
        _ target: OrchestrationGraphInspectorTarget,
        on host: WindowState
    ) async -> ActivationResult {
        let work = Task { @MainActor in
            await self.activate(target, on: host)
        }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        let result: ActivationResult = await withTaskGroup(of: ActivationResult?.self) { group in
            group.addTask {
                await work.value
            }
            group.addTask {
                _ = try? await timeout.value
                return nil
            }
            var winner: ActivationResult?
            for await item in group {
                if let item {
                    winner = item
                } else {
                    winner = .failure(.timedOut)
                    work.cancel()
                }
                group.cancelAll()
                break
            }
            return winner ?? .failure(.timedOut)
        }
        timeout.cancel()
        return result
    }

    private func activate(
        _ target: OrchestrationGraphInspectorTarget,
        on host: WindowState
    ) async -> ActivationResult {
        let manager = host.workspaceManager
        await waitForWorkspaces(manager, workspaceID: target.workspaceID)
        guard !Task.isCancelled else { return .failure(.timedOut) }
        guard let workspace = manager.workspace(withID: target.workspaceID) else {
            return .failure(.workspaceUnavailable)
        }

        // Skip full switchWorkspace: git/root hydration hangs Opening… on the MainActor.
        let alreadyOpen = manager.activeWorkspaceID == workspace.id
        manager.activeWorkspace = workspace
        if !alreadyOpen {
            host.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
        }
        if let activationGate {
            await activationGate(target)
        }
        guard !Task.isCancelled else { return .failure(.timedOut) }

        switch target {
        case let .workspace(workspaceID):
            if !alreadyOpen {
                let hostForHydration = host
                let workspaceForHydration = workspace
                Task { @MainActor in
                    await hostForHydration.agentModeViewModel.handleWorkspaceSwitch(workspaceForHydration)
                }
            }
            return .success(.workspace(workspaceID))
        case let .session(workspaceID, tabID, sessionID):
            if !alreadyOpen {
                await host.agentModeViewModel.handleWorkspaceSwitch(workspace)
            }
            guard !Task.isCancelled else { return .failure(.timedOut) }
            guard let activeWorkspace = manager.activeWorkspace, activeWorkspace.id == workspace.id else {
                return .failure(.workspaceUnavailable)
            }
            return await activateSession(
                workspaceID: workspaceID,
                tabID: tabID,
                sessionID: sessionID,
                activeWorkspace: activeWorkspace,
                on: host
            )
        }
    }

    /// `WindowState.routeToAgentSession` without app activation, window focus, or a saved-state switch.
    private func activateSession(
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID,
        activeWorkspace: WorkspaceModel,
        on host: WindowState
    ) async -> ActivationResult {
        let tabIsActive = activeWorkspace.composeTabs.contains { $0.id == tabID }
        let tabIsStashed = activeWorkspace.stashedTabs.contains { $0.tab.id == tabID }
        guard tabIsActive || tabIsStashed else {
            return .failure(.sessionTabUnavailable)
        }

        let activation = await host.agentModeViewModel.activateRoutedAgentSession(
            tabID: tabID,
            sessionID: sessionID,
            workspace: activeWorkspace
        )
        if let failure = OrchestrationGraphInspectorFailure(activation) {
            return .failure(failure)
        }

        if tabIsStashed {
            guard await host.promptManager.restoreStashedComposeTab(containingTabID: tabID) != nil else {
                return .failure(.sessionTabUnavailable)
            }
        } else if host.promptManager.activeComposeTabID != tabID {
            await host.promptManager.switchComposeTab(tabID)
        }
        guard host.promptManager.activeComposeTabID == tabID else {
            return .failure(.sessionTabUnavailable)
        }
        guard let finalWorkspace = host.workspaceManager.activeWorkspace, finalWorkspace.id == workspaceID else {
            return .failure(.workspaceUnavailable)
        }

        let finalActivation = await host.agentModeViewModel.activateRoutedAgentSession(
            tabID: tabID,
            sessionID: sessionID,
            workspace: finalWorkspace
        )
        if let failure = OrchestrationGraphInspectorFailure(finalActivation) {
            return .failure(failure)
        }
        return .success(.session(workspaceID: workspaceID, tabID: tabID, sessionID: sessionID))
    }

    private func waitForWorkspaces(_ manager: WorkspaceManagerViewModel, workspaceID: UUID) async {
        if manager.isInitialized || manager.workspace(withID: workspaceID) != nil {
            return
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !Task.isCancelled, !manager.isInitialized {
            if manager.workspace(withID: workspaceID) != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func workspace(_ workspace: WorkspaceModel, holdsTab tabID: UUID) -> Bool {
        workspace.composeTabs.contains { $0.id == tabID }
            || workspace.stashedTabs.contains { $0.tab.id == tabID }
    }
}

/// Trailing pane of the orchestration graph: traditional `ContentView` of the inspector host.
struct OrchestrationGraphInspector: View {
    @ObservedObject var model: OrchestrationGraphInspectorModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.surface {
        case .empty:
            placeholder("Select a workspace or session in the graph.")
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening…")
                    .foregroundStyle(.secondary)
            }
        case .workspace, .session:
            if let host = model.hostWindowState {
                ContentView(windowState: host)
                    .environmentObject(host)
                    .environmentObject(host.workspaceManager)
                    .environmentObject(host.mcpServer)
            } else {
                placeholder("Select a workspace or session in the graph.")
            }
        case let .failure(_, failure):
            placeholder(failure.message)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
    }
}
