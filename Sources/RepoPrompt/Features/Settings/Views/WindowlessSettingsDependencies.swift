import Foundation
import RepoPromptSettingsCore

@MainActor
final class WindowlessSettingsDependencies {
    static var loadStoredAPIDataOnWindowlessInit = true

    let fileManager: WorkspaceFilesViewModel
    let promptViewModel: PromptViewModel
    let apiSettingsViewModel: APISettingsViewModel
    let settingsManager: WindowSettingsManager
    let routerSettingsViewModel: RouterSettingsViewModel
    let providerBindingService: AgentModeProviderBindingService

    init() {
        let settingsStore = GlobalSettingsStore.shared
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore())
        let keyManager = KeyManager()
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettingsViewModel = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: Self.loadStoredAPIDataOnWindowlessInit
        )
        let settingsManager = WindowSettingsManager(windowID: 0, store: settingsStore)
        let promptViewModel = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettingsViewModel,
            windowID: 0,
            settingsManager: settingsManager,
            refreshAvailableModelsOnInit: false
        )
        self.fileManager = fileManager
        self.apiSettingsViewModel = apiSettingsViewModel
        self.settingsManager = settingsManager
        self.promptViewModel = promptViewModel
        routerSettingsViewModel = RouterSettingsViewModel(
            settingsStore: settingsStore,
            runtime: WindowStatesManager.shared.modelRouterRuntime,
            apiSettingsViewModel: apiSettingsViewModel,
            workspaceManager: nil
        )
        providerBindingService = AgentModeProviderBindingService()
    }

    func tearDown() {
        routerSettingsViewModel.tearDown()
        apiSettingsViewModel.prepareForWindowClose()
        let promptViewModel = promptViewModel
        Task { await promptViewModel.tearDown() }
    }
}
