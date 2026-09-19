import Combine
import Foundation

@MainActor
final class RouterSettingsViewModel: ObservableObject {
    enum BackendOperationFeedback: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)

        var message: String? {
            switch self {
            case .idle: nil
            case let .running(message), let .succeeded(message), let .failed(message): message
            }
        }
    }

    struct BackendOption: Identifiable, Equatable {
        let id: AgentTaskRouterBackendID
        let displayName: String
    }

    struct TargetPreview: Identifiable, Equatable {
        let role: AgentModelCatalog.TaskLabelKind
        let provider: AgentProviderKind
        let displayName: String
        let target: AgentRoutingExecutableTarget
        var id: String {
            role.rawValue
        }
    }

    @Published private(set) var backendOptions: [BackendOption] = []
    @Published private(set) var configuration: AgentTaskRouterConfiguration
    @Published private(set) var readiness: AgentTaskRouterBackendReadiness
    @Published private(set) var targetPreviews: [TargetPreview] = []
    @Published private(set) var backendSettingsPresentation: AgentTaskRouterBackendSettingsPresentation?
    @Published private(set) var backendOperationFeedback: BackendOperationFeedback = .idle
    @Published private(set) var isPerformingBackendOperation = false
    @Published private(set) var policyCanBuildCandidates = false

    private let settingsStore: GlobalSettingsStore
    private let runtime: AgentTaskRouterRuntime
    private let apiSettingsViewModel: APISettingsViewModel
    private weak var workspaceManager: WorkspaceManagerViewModel?
    private var readinessTask: Task<Void, Never>?
    private var observedBackendID: AgentTaskRouterBackendID?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: GlobalSettingsStore,
        runtime: AgentTaskRouterRuntime,
        apiSettingsViewModel: APISettingsViewModel,
        workspaceManager: WorkspaceManagerViewModel
    ) {
        self.settingsStore = settingsStore
        self.runtime = runtime
        self.apiSettingsViewModel = apiSettingsViewModel
        self.workspaceManager = workspaceManager
        configuration = settingsStore.modelRouterConfiguration()
        readiness = .needsConfiguration(generation: 0, reason: "Select and configure a routing backend.")
        settingsStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        apiSettingsViewModel.$agentAvailability
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        workspaceManager.$activeWorkspaceID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        scheduleRefresh()
    }

    deinit { readinessTask?.cancel() }

    var selectedBackendID: AgentTaskRouterBackendID? {
        configuration.selectedBackendID
    }

    var canEnable: Bool {
        readiness.isReady && policyCanBuildCandidates
    }

    var eligibleRoles: Set<AgentModelCatalog.TaskLabelKind> {
        Self.effectiveRoles(configuration)
    }

    var availableProviders: Set<AgentProviderKind> {
        Set(targetPreviews.map(\.provider))
    }

    var visibleProviders: [AgentProviderKind] {
        availableProviders.union(configuration.allowedProviders).sorted { $0.displayName < $1.displayName }
    }

    var distinctTargetCount: Int {
        Set(targetPreviews.filter {
            eligibleRoles.contains($0.role) && isProviderAllowed($0.provider)
        }.map(\.target)).count
    }

    func providerLimit(for scope: AgentTaskRoutingScope) -> AgentProviderKind? {
        switch scope {
        case .primarySession: configuration.primaryProvider
        case .subagent: configuration.subagentProvider
        }
    }

    func isProviderAllowed(_ provider: AgentProviderKind) -> Bool {
        Self.effectiveProviders(configuration, available: availableProviders).contains(provider)
    }

    func selectBackend(_ id: AgentTaskRouterBackendID) {
        guard settingsStore.modelRouterConfiguration().selectedBackendID != id else { return }
        settingsStore.setModelRouterBackend(id)
        synchronizeConfiguration()
        backendOperationFeedback = .idle
        Task {
            await runtime.backendSelectionDidChange(
                selectedID: id,
                shouldBootstrap: settingsStore.modelRouterConfiguration().enabled
            )
            await refresh()
        }
    }

    func setRole(_ role: AgentModelCatalog.TaskLabelKind, enabled: Bool) {
        var roles = Self.effectiveRoles(settingsStore.modelRouterConfiguration())
        if enabled { roles.insert(role) } else { roles.remove(role) }
        settingsStore.setModelRouterCandidateRoles(roles)
        synchronizeConfiguration()
        scheduleRefresh()
    }

    func setProvider(_ provider: AgentProviderKind, enabled: Bool) {
        var providers = Self.effectiveProviders(settingsStore.modelRouterConfiguration(), available: availableProviders)
        if enabled { providers.insert(provider) } else { providers.remove(provider) }
        settingsStore.setModelRouterAllowedProviders(providers)
        synchronizeConfiguration()
        scheduleRefresh()
    }

    func setProviderLimit(_ provider: AgentProviderKind?, scope: AgentTaskRoutingScope) {
        settingsStore.setModelRouterProvider(provider, scope: scope)
        synchronizeConfiguration()
        scheduleRefresh()
    }

    @discardableResult
    func setCustomInstructions(_ instructions: String) -> Bool {
        guard settingsStore.setModelRouterCustomInstructions(instructions) else { return false }
        synchronizeConfiguration()
        return true
    }

    func setEnabled(_ enabled: Bool) {
        synchronizeConfiguration()
        guard !enabled || canEnable else { return }
        if enabled,
           !configuration.candidateRolesMaterialized || !configuration.allowedProvidersMaterialized,
           let selectedBackendID
        {
            settingsStore.enableModelRouterWithCurrentPolicy(
                backendID: selectedBackendID,
                roles: Self.effectiveRoles(configuration),
                providers: Self.effectiveProviders(configuration, available: availableProviders)
            )
        } else {
            settingsStore.setModelRouterEnabled(enabled)
        }
        synchronizeConfiguration()
        scheduleRefresh()
    }

    func performBackendAction(_ action: AgentTaskRouterBackendSettingsAction) async {
        guard !isPerformingBackendOperation,
              let id = settingsStore.modelRouterConfiguration().selectedBackendID else { return }
        isPerformingBackendOperation = true
        defer { isPerformingBackendOperation = false }
        let progressMessage = switch action {
        case .validateAndSaveSecret: "Verifying and saving the key…"
        case .revalidateStoredSecret: "Checking the saved key…"
        case .removeStoredSecret: "Removing the saved key…"
        }
        backendOperationFeedback = .running(progressMessage)
        guard let controller = await runtime.registry.registration(for: id)?.settings?.controller,
              settingsStore.modelRouterConfiguration().selectedBackendID == id else { return }
        let result = await controller.perform(action)
        guard settingsStore.modelRouterConfiguration().selectedBackendID == id else { return }
        backendOperationFeedback = switch result {
        case let .succeeded(message): .succeeded(message)
        case let .missingSecret(message), let .superseded(message), let .failed(message): .failed(message)
        }
        await refresh()
    }

    func refresh() async {
        refreshRequested = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await runRefreshLoop()
        }
        refreshTask = task
        await task.value
    }

    private func runRefreshLoop() async {
        while refreshRequested {
            refreshRequested = false
            await performRefresh()
        }
        refreshTask = nil
    }

    private func performRefresh() async {
        synchronizeConfiguration()
        var capturedConfiguration = configuration
        let registrations = await runtime.registry.registrations()
        guard settingsStore.modelRouterConfiguration() == capturedConfiguration else { return }
        if configuration.selectedBackendID == nil, registrations.count == 1, let onlyBackend = registrations.first {
            settingsStore.setModelRouterBackend(onlyBackend.id)
            synchronizeConfiguration()
            capturedConfiguration = configuration
        }
        backendOptions = registrations.map { BackendOption(id: $0.id, displayName: $0.displayName) }
        let registration = configuration.selectedBackendID.flatMap { selected in
            registrations.first(where: { $0.id == selected })
        }
        backendSettingsPresentation = registration?.settings?.presentation
        if let registration {
            let snapshot = await registration.backend.readinessSnapshot()
            guard settingsStore.modelRouterConfiguration() == capturedConfiguration else { return }
            readiness = snapshot
            observeReadinessIfNeeded(registration)
        } else if let raw = configuration.selectedBackendRawValue, !raw.isEmpty {
            readiness = .temporarilyUnavailable(generation: 0, reason: "Router backend '\(raw)' is not available in this build.")
            cancelReadinessObservation()
        } else {
            readiness = .needsConfiguration(generation: 0, reason: "Choose a routing backend.")
            cancelReadinessObservation()
        }
        rebuildTargetPreviews()
    }

    private func synchronizeConfiguration() {
        let current = settingsStore.modelRouterConfiguration()
        if current.selectedBackendID != configuration.selectedBackendID {
            cancelReadinessObservation()
            backendSettingsPresentation = nil
            backendOperationFeedback = .idle
            readiness = .needsConfiguration(generation: 0, reason: "Checking the selected backend…")
        }
        configuration = current
        rebuildTargetPreviews()
    }

    private func observeReadinessIfNeeded(_ registration: AgentTaskRouterBackendRegistration) {
        guard observedBackendID != registration.id else { return }
        readinessTask?.cancel()
        observedBackendID = registration.id
        guard let controller = registration.settings?.controller else { return }
        readinessTask = Task { [weak self] in
            for await snapshot in await controller.readinessUpdates() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.observedBackendID == registration.id,
                          self?.settingsStore.modelRouterConfiguration().selectedBackendID == registration.id else { return }
                    self?.readiness = snapshot
                }
            }
        }
    }

    private func cancelReadinessObservation() {
        readinessTask?.cancel()
        readinessTask = nil
        observedBackendID = nil
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            await Task.yield()
            await self?.refresh()
        }
    }

    private func rebuildTargetPreviews() {
        let availability = apiSettingsViewModel.agentAvailability
        let workspaceID = workspaceManager?.activeWorkspaceID
        let resolutions = MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: settingsStore
        )
        targetPreviews = resolutions.filter { !$0.overrideUnavailable }.map { resolution in
            TargetPreview(
                role: resolution.role,
                provider: resolution.effective.agent,
                displayName: resolution.effectiveDisplayName,
                target: AgentRoutingExecutableTarget(
                    agentRaw: resolution.effective.agent.rawValue,
                    modelRaw: resolution.effective.modelRaw,
                    reasoningEffortRaw: resolution.effective.agent == .codexExec
                        ? CodexModelSpecifier(raw: resolution.effective.modelRaw).reasoningEffort?.rawValue
                        : nil,
                    modelParameters: resolution.modelParameters
                )
            )
        }
        let roles = Self.effectiveRoles(configuration)
        let providers = Self.effectiveProviders(configuration, available: Set(targetPreviews.map(\.provider)))
        policyCanBuildCandidates = (try? AgentTaskRoutingCandidateBuilder().build(
            workspaceID: workspaceID,
            roles: roles,
            allowedProviders: providers,
            availability: availability,
            settingsStore: settingsStore
        )) != nil
    }

    static func effectiveRoles(
        _ configuration: AgentTaskRouterConfiguration
    ) -> Set<AgentModelCatalog.TaskLabelKind> {
        configuration.candidateRolesMaterialized
            ? Set(configuration.candidateRoles)
            : Set(AgentModelCatalog.TaskLabelKind.allCases)
    }

    static func effectiveProviders(
        _ configuration: AgentTaskRouterConfiguration,
        available: Set<AgentProviderKind>
    ) -> Set<AgentProviderKind> {
        configuration.allowedProvidersMaterialized ? configuration.allowedProviders : available
    }
}
