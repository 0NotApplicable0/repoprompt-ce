import Foundation

enum AntigravityAgentToolPreferences {
    enum PermissionLevel: String, CaseIterable, Hashable {
        case managedDefault
        case sandboxedAutoApprove
        case fullAccess
        /// Internal runtime sentinel. It is deliberately omitted from `allCases`, so it can never
        /// be persisted or selected as a direct-agent preference.
        case safeManagedUnavailable

        static let allCases: [PermissionLevel] = [
            .managedDefault,
            .sandboxedAutoApprove,
            .fullAccess
        ]

        var displayName: String {
            switch self {
            case .managedDefault:
                "Sandboxed"
            case .sandboxedAutoApprove:
                "Sandboxed Auto-Approve"
            case .fullAccess:
                "Full Access"
            case .safeManagedUnavailable:
                "Unavailable in Safe Managed"
            }
        }

        var detailText: String {
            switch self {
            case .managedDefault:
                "Terminal access is sandboxed, but Antigravity's persisted tool grants remain in effect. Headless Antigravity cannot display approval prompts, so an ungranted request may stop with an actionable error."
            case .sandboxedAutoApprove:
                "Terminal access is sandboxed; every native and configured MCP tool request is auto-approved."
            case .fullAccess:
                "All native and MCP tool requests are auto-approved. No terminal sandbox."
            case .safeManagedUnavailable:
                "Headless Antigravity cannot provide a Safe Managed boundary because its global MCP configuration and persisted grants cannot be isolated per run."
            }
        }

        var iconName: String {
            switch self {
            case .managedDefault:
                "shield"
            case .sandboxedAutoApprove:
                "exclamationmark.shield"
            case .fullAccess:
                "exclamationmark.shield.fill"
            case .safeManagedUnavailable:
                "nosign"
            }
        }

        var isWarning: Bool {
            self != .managedDefault
        }

        /// Passes `--sandbox` to restrict terminal access when true.
        var useSandbox: Bool {
            self != .fullAccess
        }

        /// Passes `--dangerously-skip-permissions` to auto-approve all tools when true. This is an
        /// explicit opt-in because the flag also approves every third-party MCP server in agy's
        /// global config; agy's terminal sandbox does not contain those external side effects.
        var dangerouslySkipPermissions: Bool {
            self == .sandboxedAutoApprove || self == .fullAccess
        }

        var supportsHeadlessRun: Bool {
            self != .safeManagedUnavailable
        }

        static func from(rawValue: String?) -> PermissionLevel {
            headlessLevel(from: rawValue) ?? .managedDefault
        }

        static func headlessLevel(from rawValue: String?) -> PermissionLevel? {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                return nil
            }
            switch raw.lowercased() {
            case PermissionLevel.fullAccess.rawValue.lowercased():
                return .fullAccess
            case PermissionLevel.sandboxedAutoApprove.rawValue.lowercased():
                return .sandboxedAutoApprove
            case PermissionLevel.managedDefault.rawValue.lowercased():
                return .managedDefault
            default:
                return nil
            }
        }

        static func isRetiredACPRawValue(_ rawValue: String?) -> Bool {
            guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return ["default", "auto_edit", "yolo"].contains(raw.lowercased())
        }
    }

    private static let permissionLevelKey = "antigravityToolPermissionLevel"

    static func permissionLevel(
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) -> PermissionLevel {
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            let hasLegacyLevel = defaults.object(forKey: permissionLevelKey) != nil
            let legacyLevel = hasLegacyLevel
                ? PermissionLevel.headlessLevel(from: defaults.string(forKey: permissionLevelKey))
                : nil
            if secureStore.migrateLegacyAntigravityPermissionLevelIfNeeded(
                legacyLevel,
                legacyValueWasPresent: hasLegacyLevel
            ),
                hasLegacyLevel,
                secureStore.persistsValuesAcrossLaunches
            {
                defaults.removeObject(forKey: permissionLevelKey)
            }
            return secureStore.antigravityPermissions().permissionLevel()
        }
        guard defaults.object(forKey: permissionLevelKey) != nil else { return .managedDefault }
        return PermissionLevel.headlessLevel(from: defaults.string(forKey: permissionLevelKey))
            ?? .safeManagedUnavailable
    }

    static func setPermissionLevel(
        _ level: PermissionLevel,
        defaults: UserDefaults = .standard,
        secureStore: AgentPermissionSecureStore? = nil
    ) {
        // Runtime-only sentinels must never become a direct-agent preference. Persist the
        // conservative user default if an internal caller accidentally forwards one here.
        let persistedLevel = PermissionLevel.allCases.contains(level) ? level : .managedDefault
        if let secureStore = resolvedSecureStore(defaults: defaults, secureStore: secureStore) {
            if secureStore.setAntigravityPermissionLevel(persistedLevel),
               secureStore.persistsValuesAcrossLaunches
            {
                defaults.removeObject(forKey: permissionLevelKey)
            }
            return
        }
        defaults.set(persistedLevel.rawValue, forKey: permissionLevelKey)
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
