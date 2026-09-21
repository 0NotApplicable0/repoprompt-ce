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
            WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
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
            let host = resolvedHost()
            let result = await activate(target, on: host)
            guard requestGeneration == generation, !isTornDown else { continue }
            switch result {
            case let .success(surface):
                self.surface = surface
                mcpBindTargetWorkspaceID = activeTabID(of: host).flatMap {
                    host.workspaceManager.bindingCandidate(forContextID: $0)?.workspaceID
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

    private enum ActivationResult {
        case success(OrchestrationGraphInspectorSurface)
        case failure(OrchestrationGraphInspectorFailure)
    }

    private func activate(
        _ target: OrchestrationGraphInspectorTarget,
        on host: WindowState
    ) async -> ActivationResult {
        let manager = host.workspaceManager
        await manager.awaitInitialized()
        guard let workspace = manager.workspace(withID: target.workspaceID) else {
            return .failure(.workspaceUnavailable)
        }

        if case let .session(_, tabID, _) = target,
           manager.activeWorkspaceID != workspace.id,
           !Self.workspace(workspace, holdsTab: tabID)
        {
            return .failure(.sessionTabUnavailable)
        }

        if manager.activeWorkspaceID != workspace.id {
            let switchResult = await manager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "orchestrationGraphInspector"
            )
            guard switchResult.didSwitch else {
                return .failure(.workspaceSwitchBlocked(switchResult.message ?? "Workspace switch was blocked."))
            }
        }
        if let activationGate {
            await activationGate(target)
        }
        guard let activeWorkspace = manager.activeWorkspace, activeWorkspace.id == workspace.id else {
            return .failure(.workspaceUnavailable)
        }

        switch target {
        case let .workspace(workspaceID):
            return .success(.workspace(workspaceID))
        case let .session(workspaceID, tabID, sessionID):
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

    private static func workspace(_ workspace: WorkspaceModel, holdsTab tabID: UUID) -> Bool {
        workspace.composeTabs.contains { $0.id == tabID }
            || workspace.stashedTabs.contains { $0.tab.id == tabID }
    }
}

/// Trailing pane of the orchestration graph: `AgentModeView` of the inspector's host window only.
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
            ProgressView()
        case .workspace, .session:
            if let host = model.hostWindowState {
                OrchestrationGraphInspectorHostView(host: host)
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

private struct OrchestrationGraphInspectorHostView: View {
    @ObservedObject var host: WindowState

    var body: some View {
        AgentModeView(
            windowState: host,
            agentModeVM: host.agentModeViewModel,
            promptManager: host.promptManager
        )
        .environmentObject(host)
        .environmentObject(host.workspaceManager)
        .environmentObject(host.mcpServer)
    }
}
