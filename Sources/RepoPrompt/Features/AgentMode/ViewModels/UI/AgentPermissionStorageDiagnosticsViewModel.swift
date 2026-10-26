//
//  AgentPermissionStorageDiagnosticsViewModel.swift
//  RepoPrompt
//
//  Shared diagnostics model for Agent Permissions settings surfaces.
//

import Combine
import Foundation

@MainActor
final class AgentPermissionStorageDiagnosticsViewModel: ObservableObject {
    /// Diagnostics reported by `AgentPermissionSecureStore`. Sanitized — no raw
    /// Keychain identifiers are exposed to UI consumers.
    @Published private(set) var storageDiagnostics: [AgentPermissionStorageDiagnostic] = []
    /// `true` when secure permission storage reports a failure that forces RepoPrompt
    /// onto safe defaults (read/write/decode/unsupported schema).
    @Published private(set) var isSecurePermissionStorageDegraded: Bool = false

    let securePermissions: AgentPermissionSecureStore?
    private let notificationCenter: NotificationCenter
    private var cancellables: Set<AnyCancellable> = []

    init(
        securePermissions: AgentPermissionSecureStore?,
        notificationCenter: NotificationCenter = .default
    ) {
        self.securePermissions = securePermissions
        self.notificationCenter = notificationCenter
        refresh()
        subscribeToSecureStoreChanges()
    }

    func refresh() {
        let diagnostics = securePermissions?.diagnostics() ?? []
        storageDiagnostics = diagnostics
        isSecurePermissionStorageDegraded = diagnostics.contains { Self.isDegrading(kind: $0.kind) }
    }

    /// Which diagnostic kinds force the UI into the degraded banner state.
    nonisolated static func isDegrading(kind: AgentPermissionStorageDiagnostic.Kind) -> Bool {
        switch kind {
        case .keychainReadFailed,
             .keychainWriteFailed,
             .keychainInteractionNotAllowed,
             .keychainAuthenticationFailed,
             .decodeFailed,
             .unsupportedFutureSchema:
            true
        case .unsupportedStoredPermission:
            false
        }
    }

    private func subscribeToSecureStoreChanges() {
        subscribeToRefreshNotification(.agentPermissionSecureStoreDidChange)
        subscribeToRefreshNotification(.agentPermissionSecureStoreDiagnosticsDidChange)
    }

    private func subscribeToRefreshNotification(_ name: Notification.Name) {
        notificationCenter.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }
}
