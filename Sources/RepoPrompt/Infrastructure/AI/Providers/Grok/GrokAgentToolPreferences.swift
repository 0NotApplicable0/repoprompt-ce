import Foundation

enum GrokAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable {
        case managedDefault
        case fullAccess
        case storedPermissionUnavailable

        static let allCases: [PermissionLevel] = [.managedDefault, .fullAccess]

        var displayName: String {
            switch self {
            case .managedDefault:
                "Default"
            case .fullAccess:
                "Full Access"
            case .storedPermissionUnavailable:
                "Stored Permissions Unavailable"
            }
        }

        var detailText: String {
            switch self {
            case .managedDefault:
                "Grok runs kernel-sandboxed to the workspace, but `--permission-mode bypassPermissions` auto-approves every native and configured MCP tool request. The workspace sandbox does not contain external MCP side effects."
            case .fullAccess:
                "Grok auto-approves all tool requests (`--permission-mode bypassPermissions`). No sandbox — writes are not confined to the workspace."
            case .storedPermissionUnavailable:
                "Grok cannot run because stored permissions are unavailable or unsupported. Reset permissions before choosing a new permission level."
            }
        }

        var iconName: String {
            switch self {
            case .managedDefault:
                "shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            case .storedPermissionUnavailable:
                "nosign"
            }
        }

        var isWarning: Bool {
            self != .managedDefault
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
            guard rawValue != nil else { return .managedDefault }
            return storedLevel(from: rawValue) ?? .storedPermissionUnavailable
        }

        static func storedLevel(from rawValue: String?) -> PermissionLevel? {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return nil
            }
            switch raw.lowercased() {
            case PermissionLevel.fullAccess.rawValue.lowercased():
                return .fullAccess
            case PermissionLevel.managedDefault.rawValue.lowercased():
                return .managedDefault
            default:
                return nil
            }
        }
    }

    private static let permissionLevelKey = "grokToolPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let hasLegacyLevel = defaults.object(forKey: permissionLevelKey) != nil
            let legacyLevel = hasLegacyLevel
                ? PermissionLevel.storedLevel(from: defaults.string(forKey: permissionLevelKey))
                : nil
            if secureStore.migrateLegacyGrokPermissionLevelIfNeeded(
                legacyLevel,
                legacyValueWasPresent: hasLegacyLevel
            ),
                hasLegacyLevel,
                secureStore.persistsValuesAcrossLaunches
            {
                defaults.removeObject(forKey: permissionLevelKey)
            }
            return secureStore.grokPermissions().permissionLevel()
        }
        guard defaults.object(forKey: permissionLevelKey) != nil else { return .managedDefault }
        return PermissionLevel.storedLevel(from: defaults.string(forKey: permissionLevelKey))
            ?? .storedPermissionUnavailable
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        guard PermissionLevel.allCases.contains(level) else { return }
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            if secureStore.setGrokPermissionLevel(level),
               secureStore.persistsValuesAcrossLaunches
            {
                defaults.removeObject(forKey: permissionLevelKey)
            }
            return
        }
        defaults.set(level.rawValue, forKey: permissionLevelKey)
    }

    private static func resolvedSecureStore(
        defaults: UserDefaults,
        secureStore: AgentPermissionSecureStore?
    ) -> AgentPermissionSecureStore? {
        if let secureStore {
            return secureStore
        }
        return defaults === UserDefaults.standard ? AgentPermissionSecureStore.shared : nil
    }
}
