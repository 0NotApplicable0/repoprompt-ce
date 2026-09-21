//
//  AppWindowOpener.swift
//  RepoPrompt
//
//  Created by Claude on 2025-01-15.
//
//  Singleton to store the SwiftUI openWindow action, enabling programmatic
//  window creation from non-SwiftUI contexts like WindowStatesManager.
//

import SwiftUI

/// Enables programmatic opening of new windows from non-SwiftUI contexts.
///
/// WindowStatesManager cannot directly access `@Environment(\.openWindow)`,
/// so this singleton stores the action captured from a SwiftUI view.
///
/// Usage:
/// 1. A SwiftUI view calls `install(openMainWindow:)` to register the action
/// 2. Non-SwiftUI code calls `openMainWindow()` to trigger window creation
@MainActor
final class AppWindowOpener {
    static let shared = AppWindowOpener()

    private var openMainWindowImpl: (() -> Void)?
    private var pendingDockWindowRequestCount = 0

    /// Orchestration graph single-window policy, read at each action.
    var policy = OrchestrationGraphWindowPolicy.production

    private init() {}

    /// Installs the openWindow action from a SwiftUI view.
    /// Called from WindowContentView on appear.
    func install(openMainWindow: @escaping () -> Void) {
        openMainWindowImpl = openMainWindow

        let pendingRequestCount = pendingDockWindowRequestCount
        pendingDockWindowRequestCount = 0
        guard policy.allowsAdditionalMainWindow else { return }
        for _ in 0 ..< pendingRequestCount {
            openMainWindow()
        }
    }

    /// Requests a new main window from the Dock menu.
    /// Queues the request until SwiftUI has installed the window-opening action.
    func requestMainWindowFromDock() {
        guard policy.allowsAdditionalMainWindow else {
            pendingDockWindowRequestCount = 0
            return
        }
        guard let openMainWindowImpl else {
            pendingDockWindowRequestCount += 1
            return
        }
        openMainWindowImpl()
    }

    /// Opens a new main window.
    /// - Throws: `WindowOpenError.openerUnavailable` if no action has been installed, or
    ///   `WindowOpenError.singleWindowPolicy` if the orchestration graph policy forbids another window.
    func openMainWindow() throws {
        guard let impl = openMainWindowImpl else {
            throw WindowOpenError.openerUnavailable
        }
        guard policy.allowsAdditionalMainWindow else {
            throw WindowOpenError.singleWindowPolicy
        }
        impl()
    }

    /// Checks if the opener is ready to create windows.
    var isAvailable: Bool {
        openMainWindowImpl != nil
    }

    #if DEBUG
        func installForTesting(openMainWindow: @escaping () -> Void) {
            openMainWindowImpl = openMainWindow
        }

        func resetForTesting() {
            openMainWindowImpl = nil
            pendingDockWindowRequestCount = 0
        }
    #endif
}

/// Errors that can occur when opening windows programmatically.
enum WindowOpenError: Error, LocalizedError {
    case openerUnavailable
    case singleWindowPolicy

    var errorDescription: String? {
        switch self {
        case .openerUnavailable:
            "Window opener not available. No SwiftUI view has installed the openWindow action."
        case .singleWindowPolicy:
            "The orchestration graph shows a single window; no additional main window was opened."
        }
    }
}
