import Foundation

enum GrokAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable {
        case managedDefault
        case fullAccess

        var displayName: String {
            switch self {
            case .managedDefault:
                "Default"
            case .fullAccess:
                "Full Access"
            }
        }

        var detailText: String {
            switch self {
            case .managedDefault:
                "Grok runs kernel-sandboxed to the workspace (`--sandbox workspace --permission-mode bypassPermissions`); RepoPrompt MCP tools are injected and auto-approved."
            case .fullAccess:
                "Grok auto-approves all tool requests (`--permission-mode bypassPermissions`). No sandbox — writes are not confined to the workspace."
            }
        }

        var iconName: String {
            switch self {
            case .managedDefault:
                "shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            }
        }

        var isWarning: Bool {
            self == .fullAccess
        }

        /// Passes `--sandbox workspace` (kernel-confines writes to the CWD) when true.
        /// Both permission levels bypass permissions so MCP tool calls never stall in
        /// headless mode; only the managed default additionally enables the sandbox.
        var useSandbox: Bool {
            self == .managedDefault
        }

        /// True for Full Access: bypass permissions WITHOUT a sandbox. The provider emits
        /// `--permission-mode bypassPermissions` and no `--sandbox` flag in this case.
        var dangerouslySkipPermissions: Bool {
            self == .fullAccess
        }

        static func from(rawValue: String?) -> PermissionLevel {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return .managedDefault
            }
            switch raw.lowercased() {
            case PermissionLevel.fullAccess.rawValue.lowercased():
                return .fullAccess
            case PermissionLevel.managedDefault.rawValue.lowercased():
                return .managedDefault
            default:
                return .managedDefault
            }
        }
    }

    private static let permissionLevelKey = "grokToolPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        _ = secureStore
        return PermissionLevel.from(rawValue: defaults.string(forKey: permissionLevelKey))
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        _ = secureStore
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }
}
