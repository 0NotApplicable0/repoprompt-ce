import Combine
import Foundation

@MainActor
final class RouterSettingsViewModel: ObservableObject {
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
    @Published private(set) var operationMessage: String?
    @Published private(set) var isPerformingCredentialOperation = false

    private let settingsStore: GlobalSettingsStore
    private let runtime: AgentTaskRouterRuntime
    private let apiSettingsViewModel: APISettingsViewModel
    private var cancellables = Set<AnyCancellable>()

    init(
        settingsStore: GlobalSettingsStore,
        runtime: AgentTaskRouterRuntime,
        apiSettingsViewModel: APISettingsViewModel
    ) {
        self.settingsStore = settingsStore
        self.runtime = runtime
        self.apiSettingsViewModel = apiSettingsViewModel
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
        scheduleRefresh()
    }

    var selectedBackendID: AgentTaskRouterBackendID? {
        configuration.selectedBackendID
    }

    var canEnable: Bool {
        readiness.isReady && Set(targetPreviews.map(\.target)).count >= 2
    }

    func selectBackend(_ id: AgentTaskRouterBackendID) {
        settingsStore.setModelRouterBackend(id)
        Task {
            await runtime.coordinator.cancelAll()
            await runtime.jevCredentialService.cancelValidation()
            await refresh()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || canEnable else { return }
        if enabled,
           configuration.candidateRoles.isEmpty,
           configuration.allowedProviders.isEmpty,
           let selectedBackendID
        {
            settingsStore.enableModelRouterWithCurrentPolicy(
                backendID: selectedBackendID,
                roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
                providers: Set(targetPreviews.map(\.provider))
            )
        } else {
            settingsStore.setModelRouterEnabled(enabled)
        }
        scheduleRefresh()
    }

    func validateAndSaveJevKey(_ key: String) async {
        isPerformingCredentialOperation = true
        operationMessage = nil
        let result = await runtime.jevCredentialService.validateAndSave(key, operationID: UUID())
        isPerformingCredentialOperation = false
        operationMessage = message(for: result)
        await refresh()
    }

    func revalidateStoredJevKey() async {
        isPerformingCredentialOperation = true
        operationMessage = nil
        let result = await runtime.jevCredentialService.validateStoredKey(
            operationID: UUID(),
            accessMode: .interactive
        )
        isPerformingCredentialOperation = false
        operationMessage = message(for: result)
        await refresh()
    }

    func removeJevKey() async {
        isPerformingCredentialOperation = true
        operationMessage = nil
        do {
            try await runtime.jevCredentialService.delete(operationID: UUID())
            operationMessage = "Stored Jev key removed."
        } catch {
            operationMessage = "The stored Jev key could not be removed."
        }
        isPerformingCredentialOperation = false
        await runtime.coordinator.cancelAll()
        await refresh()
    }

    func refresh() async {
        configuration = settingsStore.modelRouterConfiguration()
        backendOptions = await runtime.registry.registrations().map {
            BackendOption(id: $0.id, displayName: $0.displayName)
        }
        if let id = configuration.selectedBackendID,
           let registration = await runtime.registry.registration(for: id)
        {
            readiness = await registration.backend.readinessSnapshot()
        } else if let raw = configuration.selectedBackendRawValue, !raw.isEmpty {
            readiness = .temporarilyUnavailable(generation: 0, reason: "Router backend '\(raw)' is not available in this build.")
        } else {
            readiness = .needsConfiguration(generation: 0, reason: "Choose a routing backend.")
        }
        rebuildTargetPreviews()
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            await Task.yield()
            await self?.refresh()
        }
    }

    private func rebuildTargetPreviews() {
        targetPreviews = MCPAgentRoleDefaultsService.resolutions(
            availability: apiSettingsViewModel.agentAvailability
        ).filter { !$0.overrideUnavailable }.map { resolution in
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
    }

    private func message(for result: JevRouterCredentialService.ValidationResult) -> String {
        switch result {
        case let .saved(_, model): "Key validated for \(model). Routing remains disabled until a reviewed policy is available."
        case .missingKey: "Enter a TypeSafe API key."
        case .superseded: "Validation was cancelled or superseded."
        case let .failed(message): message
        }
    }
}
