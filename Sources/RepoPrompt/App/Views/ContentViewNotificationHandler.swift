import SwiftUI

// MARK: - Content View Notification Handler

struct ContentViewNotificationHandler: ViewModifier {
    let windowState: WindowState
    let onShowWizard: () -> Void
    let onShowMCPPopover: () -> Void
    let onShowCreatePresetSheet: () -> Void
    let onShowMCPStatusSheet: () -> Void
    let onShowRecommendationWizard: () -> Void
    let onAppWillRestartForUpdate: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showAgentOnboardingWizard)) { _ in
                onShowWizard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMCPServerPopover)) { note in
                if let id = note.userInfo?["windowID"] as? Int,
                   id != windowState.windowID
                {
                    return
                }
                onShowMCPPopover()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCreatePresetSheet)) { note in
                // Only react if the notification's windowID matches this window
                if let id = note.userInfo?["windowID"] as? Int,
                   id == windowState.windowID
                {
                    onShowCreatePresetSheet()
                }
            }
            // Listen for notifications to show MCP status
            .onReceive(NotificationCenter.default.publisher(for: .showMCPStatusWindow)) { note in
                if let id = note.userInfo?["windowID"] as? Int,
                   id == windowState.windowID
                {
                    onShowMCPStatusSheet()
                }
            }
            // Listen for notifications to open recommendation wizard
            .onReceive(NotificationCenter.default.publisher(for: .showRecommendationWizard)) { note in
                if let id = note.userInfo?["windowID"] as? Int,
                   id == windowState.windowID
                {
                    onShowRecommendationWizard()
                }
            }
            // Listen for app restart notifications and close all sheets
            .onReceive(NotificationCenter.default.publisher(for: .appWillRestartForUpdate)) { _ in
                onAppWillRestartForUpdate()
            }
    }
}
