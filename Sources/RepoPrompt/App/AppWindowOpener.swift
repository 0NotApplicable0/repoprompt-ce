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

    private var openMainWindowImpl: ((UUID?) throws -> Void)?
    private var pendingDockWindowRequestCount = 0
    /// False for a legacy zero-argument opener, which drops the request identity.
    private(set) var deliversRequestIdentity = false

    private init() {}

    /// Installs the openWindow action from a SwiftUI view.
    /// Called from WindowContentView on appear.
    func install(openMainWindow: @escaping () -> Void) {
        installRequestAware { _ in openMainWindow() }
        deliversRequestIdentity = false
    }

    /// Installs an opener that receives the request identity (nil for requests with no identity).
    func installRequestAware(openMainWindow: @escaping (UUID?) throws -> Void) {
        openMainWindowImpl = openMainWindow
        deliversRequestIdentity = true

        let pendingRequestCount = pendingDockWindowRequestCount
        pendingDockWindowRequestCount = 0
        for _ in 0 ..< pendingRequestCount {
            try? openMainWindow(nil)
        }
    }

    /// Requests a new main window from the Dock menu.
    /// Queues the request until SwiftUI has installed the window-opening action.
    func requestMainWindowFromDock() {
        guard let openMainWindowImpl else {
            pendingDockWindowRequestCount += 1
            return
        }
        try? openMainWindowImpl(nil)
    }

    /// Opens a new main window.
    /// - Parameter requestID: identity delivered to the scene; nil for requests with no identity.
    /// - Throws: `WindowOpenError.openerUnavailable` if no action has been installed.
    func openMainWindow(requestID: UUID? = nil) throws {
        guard let impl = openMainWindowImpl else {
            throw WindowOpenError.openerUnavailable
        }
        try impl(requestID)
    }

    /// Checks if the opener is ready to create windows.
    var isAvailable: Bool {
        openMainWindowImpl != nil
    }

    #if DEBUG
        func installForTesting(openMainWindow: @escaping () -> Void) {
            openMainWindowImpl = { _ in openMainWindow() }
            deliversRequestIdentity = false
        }

        func installRequestAwareForTesting(openMainWindow: @escaping (UUID?) throws -> Void) {
            openMainWindowImpl = openMainWindow
            deliversRequestIdentity = true
        }

        func resetForTesting() {
            openMainWindowImpl = nil
            deliversRequestIdentity = false
            pendingDockWindowRequestCount = 0
        }
    #endif
}

/// Errors that can occur when opening windows programmatically.
enum WindowOpenError: Error, LocalizedError {
    case openerUnavailable
    case notParked(windowID: Int)

    var errorDescription: String? {
        switch self {
        case .openerUnavailable:
            "Window opener not available. No SwiftUI view has installed the openWindow action."
        case let .notParked(windowID):
            "Window \(windowID) opened but was not parked within 5 s; it stays on screen and unparked."
        }
    }
}
