import SwiftUI

struct SettingsWindowRootView: View {
    @ObservedObject var model: SettingsWindowModel
    let windowState: WindowState?
    let windowless: WindowlessSettingsDependencies?
    @ObservedObject private var fontScale = FontScaleManager.shared

    var body: some View {
        scoped
            .safeAreaInset(edge: .top) { GlobalSettingsPersistenceBlockBanner(allowsSessionDismissal: false) }
            .environmentObject(WindowStatesManager.shared)
            .environmentObject(SparkleUpdaterManager.shared)
            .environmentObject(FontScaleManager.shared)
            .environment(\.font, fontScale.preset.font)
            .environment(\.repoPromptFontScalePreset, fontScale.preset)
    }

    @ViewBuilder
    private var scoped: some View {
        if let windowState {
            SettingsView(
                fileManager: windowState.workspaceFilesViewModel,
                promptViewModel: windowState.promptManager,
                apiSettingsViewModel: windowState.apiSettingsViewModel,
                windowState: windowState,
                onAPIKeyUpdated: {
                    Task {
                        await windowState.promptManager.refreshAvailableModels()
                    }
                },
                selectedTab: $model.selectedTab,
                closeAction: nil
            )
            .environmentObject(windowState)
            .environmentObject(windowState.workspaceManager)
        } else if let windowless {
            SettingsView(
                fileManager: windowless.fileManager,
                promptViewModel: windowless.promptViewModel,
                apiSettingsViewModel: windowless.apiSettingsViewModel,
                windowState: nil,
                windowless: windowless,
                onAPIKeyUpdated: {
                    Task {
                        await windowless.promptViewModel.refreshAvailableModels()
                    }
                },
                selectedTab: $model.selectedTab,
                closeAction: nil
            )
        }
    }
}
