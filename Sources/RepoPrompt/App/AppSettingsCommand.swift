import AppKit
import Combine
import SwiftUI

@MainActor
enum AppSettingsCommand {
    private static var notificationSubscriptions: Set<AnyCancellable> = []
    private static let menuTarget = AppSettingsMenuTarget()

    static func installNativeMenuAction(in menu: NSMenu? = nil, target: AppSettingsMenuTarget? = nil) {
        guard let appMenu = (menu ?? NSApp.mainMenu)?.items.first?.submenu,
              let item = appMenu.items.first(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
              })
        else { return }
        item.target = target ?? menuTarget
        item.action = #selector(AppSettingsMenuTarget.openSettings(_:))
        item.isEnabled = true
    }

    static func targetWindow() -> WindowState? {
        let windows = WindowStatesManager.shared.allWindows.filter { !$0.isClosing }
        return windows.first {
            $0.isCurrentlyFocused && !FleetParkingCoordinator.shared.isParked(windowID: $0.windowID)
        } ?? windows.last
    }

    static func open(
        selectedTab: SettingsTab? = nil,
        requestedWindow: WindowState? = nil,
        present: @MainActor (WindowState?, SettingsTab?) -> Void = {
            SettingsWindowCoordinator.shared.open(windowState: $0, selectedTab: $1)
        }
    ) async throws {
        let target = requestedWindow ?? targetWindow()
        guard target?.isClosing != true else { throw CancellationError() }
        present(target, selectedTab)
    }

    static func openFromMenu() {
        Task { @MainActor in
            do {
                try await open()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func open(
        notification: Notification,
        selectedTab: SettingsTab?,
        present: @MainActor (WindowState?, SettingsTab?) -> Void = {
            SettingsWindowCoordinator.shared.open(windowState: $0, selectedTab: $1)
        }
    ) async throws {
        let requested: WindowState?
        if let state = notification.object as? WindowState {
            guard WindowStatesManager.shared.allWindows.contains(where: { $0 === state }), !state.isClosing else { return }
            requested = state
        } else if let id = notification.userInfo?["windowID"] as? Int {
            if let state = WindowStatesManager.shared.window(withID: id) {
                guard !state.isClosing else { return }
                requested = state
            } else if WindowStatesManager.shared.allWindows.isEmpty {
                requested = nil
            } else {
                return
            }
        } else {
            requested = nil
        }
        try await open(selectedTab: selectedTab, requestedWindow: requested, present: present)
        if notification.name == .showModelRouterSettingsTab,
           let section = notification.userInfo?["agentDecisionsSection"] as? SettingsWindowCoordinator.AgentDecisionsSection
        {
            SettingsWindowCoordinator.shared.publishAgentDecisionsSectionRequest(section)
        }
    }

    static func installNotificationRouting() {
        guard notificationSubscriptions.isEmpty else { return }
        let routes: [(Notification.Name, SettingsTab?)] = [
            (.showSettingsPopover, nil), (.showAPISettingsTab, .apiGeneral),
            (.showManageWorkspacesTab, .manageWorkspaces), (.showManagePresetsTab, .managePresets),
            (.showMCPSettingsTab, .mcp), (.showCLIProvidersTab, .cliProviders),
            (.showAgentModeSettingsTab, .agentMode), (.showModelRouterSettingsTab, .modelRouter),
            (.showNotificationSettingsTab, .notifications), (.showAgentModelsSettingsTab, .agentModels),
            (.showAgentPermissionsSettingsTab, .agentPermissions), (.showWorkspaceApprovalsSettingsTab, .permissions),
            (.showModelPresetsTab, .modelPresets), (.showCopyPresetsTab, .copyPresets),
            (.showChatPresetsTab, .chatPresets), (.showContextBuilderSettingsTab, .contextBuilder),
            (.showLicenseUpdatesTab, .licenseUpdates), (.showKeyboardShortcutsSettingsTab, .keyboardShortcuts)
        ]
        for (name, tab) in routes {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { notification in
                    Task { @MainActor in
                        do {
                            try await open(notification: notification, selectedTab: tab)
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    }
                }
                .store(in: &notificationSubscriptions)
        }
    }
}

@MainActor
struct AppSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let action = openWindow
        let _ = AppWindowOpener.shared.installRequestAware { requestID in
            if let requestID {
                action(id: "main", value: requestID)
            } else {
                action(id: "main")
            }
        }
        let _ = DispatchQueue.main.async {
            if NSApp.keyWindow?.identifier?.rawValue == FleetManagerWindowCoordinator.windowIdentifier {
                AppSettingsCommand.installNativeMenuAction()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…", action: AppSettingsCommand.openFromMenu)
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
final class AppSettingsMenuTarget: NSObject {
    private let open: @MainActor () -> Void

    init(open: @escaping @MainActor () -> Void = { AppSettingsCommand.openFromMenu() }) {
        self.open = open
        super.init()
    }

    @objc func openSettings(_ sender: Any?) {
        open()
    }
}
