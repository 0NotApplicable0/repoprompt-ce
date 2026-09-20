import Foundation

// SEARCH-HELPER: Secure Agent Permission Storage, Keychain-backed permission documents, fail-closed permissions

/// Permission storage domains persisted as one canonical plain JSON secure document each.
enum AgentPermissionSecureDomain: String, CaseIterable, Hashable {
    case subagent
    case codex
    case claude
    case openCode
    case cursor
    case antigravity
    case grok
    case grokBuild

    var secureStorageAccount: SecureStorageAccount {
        switch self {
        case .subagent:
            .agentPermissionSubagentDocument
        case .codex:
            .agentPermissionCodexDocument
        case .claude:
            .agentPermissionClaudeDocument
        case .openCode:
            .agentPermissionOpenCodeDocument
        case .cursor:
            .agentPermissionCursorDocument
        case .antigravity:
            .agentPermissionAntigravityDocument
        case .grok:
            .agentPermissionGrokDocument
        case .grokBuild:
            .agentPermissionGrokBuildDocument
        }
    }

    var storageKey: String {
        secureStorageAccount.identifier
    }
}

struct AgentPermissionStorageDiagnostic: Equatable {
    enum Kind: Equatable {
        case keychainReadFailed
        case keychainWriteFailed
        case keychainInteractionNotAllowed
        case keychainAuthenticationFailed
        case decodeFailed
        case unsupportedStoredPermission
        case unsupportedFutureSchema
    }

    let domain: AgentPermissionSecureDomain
    let kind: Kind
    let message: String
    let occurredAt: Date
}

struct AgentPermissionStorageResetResult: Equatable {
    let succeededDomains: [AgentPermissionSecureDomain]
    let failedDomains: [AgentPermissionSecureDomain]

    var succeeded: Bool {
        failedDomains.isEmpty
    }
}

extension Notification.Name {
    static let agentPermissionSecureStoreDidChange = Notification.Name("RepoPrompt.agentPermissionSecureStoreDidChange")
    static let agentPermissionSecureStoreDiagnosticsDidChange = Notification.Name("RepoPrompt.agentPermissionSecureStoreDiagnosticsDidChange")
}

enum AgentPermissionSecureStoreNotificationKey {
    static let domain = "domain"
    static let writeSucceeded = "writeSucceeded"
}

struct SecureSubagentPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var updatedAt: Date
    var globalPolicyRaw: String?
    var providerPermissionLevelsRawByProviderID: [String: String]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        globalPolicyRaw: String? = AgentSubagentPermissionPolicy.safeManaged.rawValue,
        providerPermissionLevelsRawByProviderID: [String: String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.globalPolicyRaw = globalPolicyRaw
        self.providerPermissionLevelsRawByProviderID = providerPermissionLevelsRawByProviderID
    }

    static func failClosedDocument(now: Date = Date()) -> SecureSubagentPermissionDocument {
        SecureSubagentPermissionDocument(updatedAt: now)
    }

    func globalPolicy() -> AgentSubagentPermissionPolicy {
        AgentSubagentPermissionPolicy(rawValue: globalPolicyRaw ?? "") ?? .safeManaged
    }

    func providerPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        guard let raw = providerPermissionLevelsRawByProviderID?[providerID.rawValue] else {
            return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
        }
        if let level = AgentProviderPermissionLevelID(providerID: providerID, subagentRawValue: raw) {
            return level
        }
        if providerID == .antigravity {
            return .antigravity(.safeManagedUnavailable)
        }
        if providerID == .grok {
            return .grok(.storedPermissionUnavailable)
        }
        return AgentProviderPermissionLevelID.subagentDefault(for: providerID)
    }
}

struct SecureCodexPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var approvalPolicyRaw: String?
    var sandboxModeRaw: String?
    var approvalReviewerRaw: String?
    var bashToolEnabled: Bool?
    var mcpServerTogglesByNormalizedName: [String: Bool]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        approvalPolicyRaw: String? = CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue,
        sandboxModeRaw: String? = CodexAgentToolPreferences.SandboxMode.workspaceWrite.persistedValue,
        approvalReviewerRaw: String? = CodexAgentToolPreferences.ApprovalReviewer.autoReview.persistedValue,
        bashToolEnabled: Bool? = true,
        mcpServerTogglesByNormalizedName: [String: Bool]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.approvalPolicyRaw = approvalPolicyRaw
        self.sandboxModeRaw = sandboxModeRaw
        self.approvalReviewerRaw = approvalReviewerRaw
        self.bashToolEnabled = bashToolEnabled
        self.mcpServerTogglesByNormalizedName = mcpServerTogglesByNormalizedName
    }

    static func failClosedDocument(now: Date = Date()) -> SecureCodexPermissionDocument {
        SecureCodexPermissionDocument(
            updatedAt: now,
            approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
            bashToolEnabled: false
        )
    }

    func approvalPolicy() -> CodexAgentToolPreferences.ApprovalPolicy {
        CodexAgentToolPreferences.ApprovalPolicy(storedValue: approvalPolicyRaw ?? "") ?? .onRequest
    }

    func sandboxMode() -> CodexAgentToolPreferences.SandboxMode {
        CodexAgentToolPreferences.SandboxMode(storedValue: sandboxModeRaw ?? "") ?? .workspaceWrite
    }

    func approvalReviewer() -> CodexAgentToolPreferences.ApprovalReviewer {
        guard let approvalReviewerRaw else { return .autoReview }
        return CodexAgentToolPreferences.ApprovalReviewer(storedValue: approvalReviewerRaw) ?? .user
    }

    func permissionLevel() -> CodexAgentToolPreferences.PermissionLevel {
        CodexAgentToolPreferences.PermissionLevel.from(
            sandbox: sandboxMode(),
            approvalReviewer: approvalReviewer()
        )
    }

    func mcpServerEnabled(normalizedName: String) -> Bool {
        let key = Self.normalizedMCPServerKey(normalizedName)
        return mcpServerTogglesByNormalizedName?[key] ?? false
    }

    static func normalizedMCPServerKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct SecureClaudePermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionModeRaw: String?
    var bashToolEnabled: Bool?
    var mcpStrictModeEnabled: Bool?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionModeRaw: String? = ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode,
        bashToolEnabled: Bool? = true,
        mcpStrictModeEnabled: Bool? = true
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionModeRaw = permissionModeRaw
        self.bashToolEnabled = bashToolEnabled
        self.mcpStrictModeEnabled = mcpStrictModeEnabled
    }

    static func failClosedDocument(now: Date = Date()) -> SecureClaudePermissionDocument {
        SecureClaudePermissionDocument(updatedAt: now, bashToolEnabled: false, mcpStrictModeEnabled: true)
    }

    func permissionMode() -> String {
        Self.normalizedPermissionMode(permissionModeRaw, preserveUnknown: true)
    }

    func permissionLevel() -> ClaudeAgentToolPreferences.PermissionLevel {
        ClaudeAgentToolPreferences.PermissionLevel.from(permissionMode: permissionMode())
    }

    static func normalizedPermissionMode(_ raw: String?, preserveUnknown: Bool) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed.lowercased() {
        case "acceptedits":
            return ClaudeAgentToolPreferences.PermissionLevel.autoApproveEdits.permissionMode
        case "auto":
            return ClaudeAgentToolPreferences.PermissionLevel.auto.permissionMode
        case "bypasspermissions":
            return ClaudeAgentToolPreferences.PermissionLevel.fullAccess.permissionMode
        case "default":
            return ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        default:
            return preserveUnknown && !trimmed.isEmpty
                ? trimmed
                : ClaudeAgentToolPreferences.PermissionLevel.requireApproval.permissionMode
        }
    }
}

struct SecureOpenCodePermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = OpenCodeAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureOpenCodePermissionDocument {
        SecureOpenCodePermissionDocument(updatedAt: now)
    }

    func permissionLevel() -> OpenCodeAgentToolPreferences.PermissionLevel {
        OpenCodeAgentToolPreferences.PermissionLevel(rawValue: permissionLevelRaw ?? "") ?? .managedDefault
    }

    func sessionModeID() -> String {
        permissionLevel().sessionModeID
    }
}

struct SecureCursorPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = CursorAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureCursorPermissionDocument {
        SecureCursorPermissionDocument(updatedAt: now)
    }

    func permissionLevel() -> CursorAgentToolPreferences.PermissionLevel {
        CursorAgentToolPreferences.PermissionLevel.from(rawValue: permissionLevelRaw)
    }
}

struct SecureAntigravityPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = AntigravityAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureAntigravityPermissionDocument {
        SecureAntigravityPermissionDocument(updatedAt: now, permissionLevelRaw: nil)
    }

    func permissionLevel() -> AntigravityAgentToolPreferences.PermissionLevel {
        AntigravityAgentToolPreferences.PermissionLevel.headlessLevel(from: permissionLevelRaw)
            ?? .safeManagedUnavailable
    }
}

struct SecureGrokPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = GrokAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureGrokPermissionDocument {
        SecureGrokPermissionDocument(updatedAt: now, permissionLevelRaw: nil)
    }

    func permissionLevel() -> GrokAgentToolPreferences.PermissionLevel {
        GrokAgentToolPreferences.PermissionLevel.storedLevel(from: permissionLevelRaw)
            ?? .storedPermissionUnavailable
    }
}

struct SecureGrokBuildPermissionDocument: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: Date
    var permissionLevelRaw: String?

    init(
        schemaVersion: Int = currentSchemaVersion,
        updatedAt: Date = Date(),
        permissionLevelRaw: String? = GrokBuildAgentToolPreferences.PermissionLevel.managedDefault.rawValue
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.permissionLevelRaw = permissionLevelRaw
    }

    static func failClosedDocument(now: Date = Date()) -> SecureGrokBuildPermissionDocument {
        SecureGrokBuildPermissionDocument(updatedAt: now)
    }

    func permissionLevel() -> GrokBuildAgentToolPreferences.PermissionLevel {
        GrokBuildAgentToolPreferences.PermissionLevel.from(rawValue: permissionLevelRaw)
    }
}

final class AgentPermissionSecureStore {
    static let shared = AgentPermissionSecureStore(secureStrings: SecureKeysService())

    private let secureStrings: SecurePlainStringStoring
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date
    private let notificationCenter: NotificationCenter

    private var subagentCache: SecureSubagentPermissionDocument?
    private var codexCache: SecureCodexPermissionDocument?
    private var claudeCache: SecureClaudePermissionDocument?
    private var openCodeCache: SecureOpenCodePermissionDocument?
    private var cursorCache: SecureCursorPermissionDocument?
    private var antigravityCache: SecureAntigravityPermissionDocument?
    private var grokCache: SecureGrokPermissionDocument?
    private var grokBuildCache: SecureGrokBuildPermissionDocument?
    private var unpersistedMissingDomains: Set<AgentPermissionSecureDomain> = []
    private var diagnosticsByDomain: [AgentPermissionSecureDomain: AgentPermissionStorageDiagnostic] = [:]
    private let permissionDecisionAccessMode: KeychainAccessMode = .nonInteractive(reason: .permissionDecision)

    var persistsValuesAcrossLaunches: Bool {
        secureStrings.persistsValuesAcrossLaunches
    }

    private struct DeferredSideEffects {
        private var requestedDiagnosticsDomains: Set<AgentPermissionSecureDomain> = []
        var diagnosticsNotifications: [AgentPermissionSecureDomain] = []
        var changeNotifications: [(domain: AgentPermissionSecureDomain, writeSucceeded: Bool)] = []

        mutating func requestDiagnosticsNotification(for domain: AgentPermissionSecureDomain) {
            if requestedDiagnosticsDomains.insert(domain).inserted {
                diagnosticsNotifications.append(domain)
            }
        }

        mutating func requestChangeNotification(domain: AgentPermissionSecureDomain, writeSucceeded: Bool) {
            changeNotifications.append((domain, writeSucceeded))
        }
    }

    init(
        secureStrings: SecurePlainStringStoring,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.secureStrings = secureStrings
        self.notificationCenter = notificationCenter
        self.now = now
        encoder.outputFormatting = [.sortedKeys]
    }

    // MARK: - Diagnostics

    func diagnostics() -> [AgentPermissionStorageDiagnostic] {
        withLock { diagnosticsByDomain.values.sorted { $0.domain.rawValue < $1.domain.rawValue } }
    }

    func diagnostic(for domain: AgentPermissionSecureDomain) -> AgentPermissionStorageDiagnostic? {
        withLock { diagnosticsByDomain[domain] }
    }

    func clearCachedDocuments() {
        withLock {
            subagentCache = nil
            codexCache = nil
            claudeCache = nil
            openCodeCache = nil
            cursorCache = nil
            antigravityCache = nil
            grokCache = nil
            grokBuildCache = nil
            unpersistedMissingDomains.removeAll()
        }
    }

    @discardableResult
    func resetAgentPermissionsToSafeDefaults() -> AgentPermissionStorageResetResult {
        withLockAndDeferredSideEffects { effects in
            var succeededDomains: [AgentPermissionSecureDomain] = []
            var failedDomains: [AgentPermissionSecureDomain] = []
            let resetDate = now()

            func record(_ domain: AgentPermissionSecureDomain, _ succeeded: Bool) {
                if succeeded {
                    succeededDomains.append(domain)
                } else {
                    failedDomains.append(domain)
                }
            }

            var subagent = SecureSubagentPermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeSubagent(&subagent)
            record(.subagent, resetLocked(subagent, domain: .subagent, cache: &subagentCache, deferred: &effects))

            var codex = SecureCodexPermissionDocument(updatedAt: resetDate)
            _ = normalizeCodex(&codex)
            record(.codex, resetLocked(codex, domain: .codex, cache: &codexCache, deferred: &effects))

            var claude = SecureClaudePermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeClaude(&claude)
            record(.claude, resetLocked(claude, domain: .claude, cache: &claudeCache, deferred: &effects))

            var openCode = SecureOpenCodePermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeOpenCode(&openCode)
            record(.openCode, resetLocked(openCode, domain: .openCode, cache: &openCodeCache, deferred: &effects))

            var cursor = SecureCursorPermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeCursor(&cursor)
            record(.cursor, resetLocked(cursor, domain: .cursor, cache: &cursorCache, deferred: &effects))

            var antigravity = SecureAntigravityPermissionDocument(updatedAt: resetDate)
            _ = normalizeAntigravity(&antigravity)
            record(
                .antigravity,
                resetLocked(antigravity, domain: .antigravity, cache: &antigravityCache, deferred: &effects)
            )

            var grok = SecureGrokPermissionDocument(updatedAt: resetDate)
            _ = normalizeGrok(&grok)
            record(.grok, resetLocked(grok, domain: .grok, cache: &grokCache, deferred: &effects))

            var grokBuild = SecureGrokBuildPermissionDocument.failClosedDocument(now: resetDate)
            _ = normalizeGrokBuild(&grokBuild)
            record(.grokBuild, resetLocked(grokBuild, domain: .grokBuild, cache: &grokBuildCache, deferred: &effects))

            return AgentPermissionStorageResetResult(
                succeededDomains: succeededDomains,
                failedDomains: failedDomains
            )
        }
    }

    // MARK: - Public reads

    func subagentPermissions() -> SecureSubagentPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadSubagentPermissionsLocked(deferred: &effects)
        }
    }

    func subagentPolicy() -> AgentSubagentPermissionPolicy {
        subagentPermissions().globalPolicy()
    }

    func providerSubagentPermissionLevel(for providerID: AgentProviderBindingID) -> AgentProviderPermissionLevelID {
        subagentPermissions().providerPermissionLevel(for: providerID)
    }

    func codexPermissions() -> SecureCodexPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadCodexPermissionsLocked(deferred: &effects)
        }
    }

    func claudePermissions() -> SecureClaudePermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadClaudePermissionsLocked(deferred: &effects)
        }
    }

    func openCodePermissions() -> SecureOpenCodePermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadOpenCodePermissionsLocked(deferred: &effects)
        }
    }

    func cursorPermissions() -> SecureCursorPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadCursorPermissionsLocked(deferred: &effects)
        }
    }

    func antigravityPermissions() -> SecureAntigravityPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadAntigravityPermissionsLocked(deferred: &effects)
        }
    }

    func grokPermissions() -> SecureGrokPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadGrokPermissionsLocked(deferred: &effects)
        }
    }

    func grokBuildPermissions() -> SecureGrokBuildPermissionDocument {
        withLockAndDeferredSideEffects { effects in
            loadGrokBuildPermissionsLocked(deferred: &effects)
        }
    }

    // MARK: - Public writes

    @discardableResult
    func updateSubagentPermissions(_ mutation: (inout SecureSubagentPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .subagent, cache: &subagentCache)
            var document = loadSubagentPermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .subagent, deferred: &effects) else { return false }
            let previousGrokRaw = document.providerPermissionLevelsRawByProviderID?[AgentProviderBindingID.grok.rawValue]
            mutation(&document)
            let grokRaw = document.providerPermissionLevelsRawByProviderID?[AgentProviderBindingID.grok.rawValue]
            if grokRaw == GrokAgentToolPreferences.PermissionLevel.storedPermissionUnavailable.rawValue,
               grokRaw != previousGrokRaw
            {
                effects.requestChangeNotification(domain: .subagent, writeSucceeded: false)
                return false
            }
            normalizeSubagent(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .subagent, cache: &subagentCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateCodexPermissions(_ mutation: (inout SecureCodexPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .codex, cache: &codexCache)
            var document = loadCodexPermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .codex, deferred: &effects) else { return false }
            mutation(&document)
            normalizeCodex(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .codex, cache: &codexCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateClaudePermissions(_ mutation: (inout SecureClaudePermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .claude, cache: &claudeCache)
            var document = loadClaudePermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .claude, deferred: &effects) else { return false }
            mutation(&document)
            normalizeClaude(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .claude, cache: &claudeCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateOpenCodePermissions(_ mutation: (inout SecureOpenCodePermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .openCode, cache: &openCodeCache)
            var document = loadOpenCodePermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .openCode, deferred: &effects) else { return false }
            mutation(&document)
            normalizeOpenCode(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .openCode, cache: &openCodeCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateCursorPermissions(_ mutation: (inout SecureCursorPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .cursor, cache: &cursorCache)
            var document = loadCursorPermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .cursor, deferred: &effects) else { return false }
            mutation(&document)
            normalizeCursor(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .cursor, cache: &cursorCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateAntigravityPermissions(_ mutation: (inout SecureAntigravityPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .antigravity, cache: &antigravityCache)
            var document = loadAntigravityPermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .antigravity, deferred: &effects) else { return false }
            mutation(&document)
            normalizeAntigravity(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .antigravity, cache: &antigravityCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateGrokPermissions(_ mutation: (inout SecureGrokPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            resetFailedCacheBeforeMutation(domain: .grok, cache: &grokCache)
            var document = loadGrokPermissionsLocked(deferred: &effects)
            guard mutationCanProceed(domain: .grok, deferred: &effects) else { return false }
            mutation(&document)
            guard GrokAgentToolPreferences.PermissionLevel.storedLevel(from: document.permissionLevelRaw) != nil else {
                effects.requestChangeNotification(domain: .grok, writeSucceeded: false)
                return false
            }
            normalizeGrok(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .grok, cache: &grokCache, deferred: &effects)
        }
    }

    @discardableResult
    func updateGrokBuildPermissions(_ mutation: (inout SecureGrokBuildPermissionDocument) -> Void) -> Bool {
        withLockAndDeferredSideEffects { effects in
            effects.requestChangeNotification(domain: .grokBuild, writeSucceeded: false)
            return false
        }
    }

    @discardableResult
    func setCodexPermissionLevel(_ level: CodexAgentToolPreferences.PermissionLevel) -> Bool {
        updateCodexPermissions { document in
            document.approvalPolicyRaw = level.approvalPolicy.persistedValue
            document.sandboxModeRaw = level.sandboxMode.persistedValue
            document.approvalReviewerRaw = level.approvalReviewer.persistedValue
        }
    }

    @discardableResult
    func setClaudePermissionLevel(_ level: ClaudeAgentToolPreferences.PermissionLevel) -> Bool {
        updateClaudePermissions { document in
            document.permissionModeRaw = level.permissionMode
        }
    }

    @discardableResult
    func setOpenCodePermissionLevel(_ level: OpenCodeAgentToolPreferences.PermissionLevel) -> Bool {
        updateOpenCodePermissions { document in
            document.permissionLevelRaw = level.rawValue
        }
    }

    @discardableResult
    func setCursorPermissionLevel(_ level: CursorAgentToolPreferences.PermissionLevel) -> Bool {
        updateCursorPermissions { document in
            document.permissionLevelRaw = level.rawValue
        }
    }

    @discardableResult
    func setAntigravityPermissionLevel(_ level: AntigravityAgentToolPreferences.PermissionLevel) -> Bool {
        withLockAndDeferredSideEffects { effects in
            guard AntigravityAgentToolPreferences.PermissionLevel.allCases.contains(level) else {
                effects.requestChangeNotification(domain: .antigravity, writeSucceeded: false)
                return false
            }
            resetFailedCacheBeforeMutation(domain: .antigravity, cache: &antigravityCache)
            var document = loadAntigravityPermissionsLocked(deferred: &effects)
            let canReplaceRetiredACPValue = AntigravityAgentToolPreferences.PermissionLevel
                .isRetiredACPRawValue(document.permissionLevelRaw)
            guard diagnosticsByDomain[.antigravity] == nil || canReplaceRetiredACPValue else {
                effects.requestChangeNotification(domain: .antigravity, writeSucceeded: false)
                return false
            }
            document.permissionLevelRaw = level.rawValue
            normalizeAntigravity(&document)
            document.updatedAt = now()
            return saveLocked(document, domain: .antigravity, cache: &antigravityCache, deferred: &effects)
        }
    }

    @discardableResult
    func setGrokPermissionLevel(_ level: GrokAgentToolPreferences.PermissionLevel) -> Bool {
        guard GrokAgentToolPreferences.PermissionLevel.allCases.contains(level) else {
            return withLockAndDeferredSideEffects { effects in
                effects.requestChangeNotification(domain: .grok, writeSucceeded: false)
                return false
            }
        }
        return updateGrokPermissions { document in
            document.permissionLevelRaw = level.rawValue
        }
    }

    @discardableResult
    func setGrokBuildPermissionLevel(_ level: GrokBuildAgentToolPreferences.PermissionLevel) -> Bool {
        updateGrokBuildPermissions { document in
            document.permissionLevelRaw = level.rawValue
        }
    }

    /// Imports a legacy preference only when no canonical secure document exists. A malformed,
    /// unreadable, or future-schema document is authoritative and therefore fails closed instead
    /// of being replaced by a potentially permissive legacy value.
    /// - Returns: `true` when canonical secure state is usable. Callers may remove a legacy key
    ///   only when the secure backend also persists across launches.
    @discardableResult
    func migrateLegacyAntigravityPermissionLevelIfNeeded(
        _ level: AntigravityAgentToolPreferences.PermissionLevel?,
        legacyValueWasPresent: Bool
    ) -> Bool {
        withLockAndDeferredSideEffects { effects in
            // Re-read only a cache explicitly known to come from a non-persisting missing-document
            // read. A cache carrying a failed user write must retain its diagnostic and legacy key.
            if unpersistedMissingDomains.remove(.antigravity) != nil {
                antigravityCache = nil
            }
            let recognizedLevel = level.flatMap {
                AntigravityAgentToolPreferences.PermissionLevel.headlessLevel(from: $0.rawValue)
            }
            let hasUnsupportedLegacyValue = legacyValueWasPresent && recognizedLevel == nil
            let persistedLevel = recognizedLevel ?? .managedDefault
            let document = loadLocked(
                domain: .antigravity,
                cache: &antigravityCache,
                missingDocument: SecureAntigravityPermissionDocument(
                    updatedAt: now(),
                    permissionLevelRaw: hasUnsupportedLegacyValue ? nil : persistedLevel.rawValue
                ),
                failClosedDocument: SecureAntigravityPermissionDocument.failClosedDocument(now: now()),
                normalize: normalizeAntigravity,
                persistMissingDocument: !hasUnsupportedLegacyValue,
                deferred: &effects
            )
            validateAntigravityDocumentLocked(document, deferred: &effects)
            return !hasUnsupportedLegacyValue && diagnosticsByDomain[.antigravity] == nil
        }
    }

    /// Imports a legacy preference only when no canonical secure document exists. See the
    /// Antigravity migration above for the fail-closed precedence and return-value contracts.
    @discardableResult
    func migrateLegacyGrokPermissionLevelIfNeeded(
        _ level: GrokAgentToolPreferences.PermissionLevel?,
        legacyValueWasPresent: Bool
    ) -> Bool {
        withLockAndDeferredSideEffects { effects in
            if unpersistedMissingDomains.remove(.grok) != nil {
                grokCache = nil
            }
            let recognizedLevel = level.flatMap {
                GrokAgentToolPreferences.PermissionLevel.storedLevel(from: $0.rawValue)
            }
            let hasUnsupportedLegacyValue = legacyValueWasPresent && recognizedLevel == nil
            let persistedLevel = recognizedLevel ?? .managedDefault
            let document = loadLocked(
                domain: .grok,
                cache: &grokCache,
                missingDocument: SecureGrokPermissionDocument(
                    updatedAt: now(),
                    permissionLevelRaw: hasUnsupportedLegacyValue ? nil : persistedLevel.rawValue
                ),
                failClosedDocument: SecureGrokPermissionDocument.failClosedDocument(now: now()),
                normalize: normalizeGrok,
                persistMissingDocument: !hasUnsupportedLegacyValue,
                deferred: &effects
            )
            validateGrokDocumentLocked(document, deferred: &effects)
            return !hasUnsupportedLegacyValue && diagnosticsByDomain[.grok] == nil
        }
    }

    // MARK: - Locked loads

    private func loadSubagentPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureSubagentPermissionDocument {
        loadLocked(
            domain: .subagent,
            cache: &subagentCache,
            failClosedDocument: SecureSubagentPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeSubagent,
            deferred: &effects
        )
    }

    private func loadCodexPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureCodexPermissionDocument {
        loadLocked(
            domain: .codex,
            cache: &codexCache,
            missingDocument: SecureCodexPermissionDocument(updatedAt: now()),
            failClosedDocument: SecureCodexPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeCodex,
            deferred: &effects
        )
    }

    private func loadClaudePermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureClaudePermissionDocument {
        loadLocked(
            domain: .claude,
            cache: &claudeCache,
            failClosedDocument: SecureClaudePermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeClaude,
            deferred: &effects
        )
    }

    private func loadOpenCodePermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureOpenCodePermissionDocument {
        loadLocked(
            domain: .openCode,
            cache: &openCodeCache,
            failClosedDocument: SecureOpenCodePermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeOpenCode,
            deferred: &effects
        )
    }

    private func loadCursorPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureCursorPermissionDocument {
        loadLocked(
            domain: .cursor,
            cache: &cursorCache,
            failClosedDocument: SecureCursorPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeCursor,
            deferred: &effects
        )
    }

    private func loadAntigravityPermissionsLocked(
        deferred effects: inout DeferredSideEffects
    ) -> SecureAntigravityPermissionDocument {
        let document = loadLocked(
            domain: .antigravity,
            cache: &antigravityCache,
            missingDocument: SecureAntigravityPermissionDocument(updatedAt: now()),
            failClosedDocument: SecureAntigravityPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeAntigravity,
            persistMissingDocument: false,
            deferred: &effects
        )
        validateAntigravityDocumentLocked(document, deferred: &effects)
        return document
    }

    private func validateAntigravityDocumentLocked(
        _ document: SecureAntigravityPermissionDocument,
        deferred effects: inout DeferredSideEffects
    ) {
        guard diagnosticsByDomain[.antigravity] == nil,
              document.permissionLevel() == .safeManagedUnavailable
        else {
            return
        }
        let message = if AntigravityAgentToolPreferences.PermissionLevel
            .isRetiredACPRawValue(document.permissionLevelRaw)
        {
            "Stored Antigravity permission mode is retired and cannot run headlessly. Choose a current Headless permission level or reset permissions."
        } else {
            "Stored Antigravity permission value is unsupported and cannot run headlessly. Reset permissions before choosing a new Headless permission level."
        }
        recordDiagnostic(domain: .antigravity, kind: .unsupportedStoredPermission, message: message)
        effects.requestDiagnosticsNotification(for: .antigravity)
    }

    private func loadGrokPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureGrokPermissionDocument {
        let document = loadLocked(
            domain: .grok,
            cache: &grokCache,
            missingDocument: SecureGrokPermissionDocument(updatedAt: now()),
            failClosedDocument: SecureGrokPermissionDocument.failClosedDocument(now: now()),
            normalize: normalizeGrok,
            persistMissingDocument: false,
            deferred: &effects
        )
        validateGrokDocumentLocked(document, deferred: &effects)
        return document
    }

    private func validateGrokDocumentLocked(
        _ document: SecureGrokPermissionDocument,
        deferred effects: inout DeferredSideEffects
    ) {
        guard diagnosticsByDomain[.grok] == nil,
              document.permissionLevel() == .storedPermissionUnavailable
        else { return }
        recordDiagnostic(
            domain: .grok,
            kind: .unsupportedStoredPermission,
            message: GrokAgentToolPreferences.PermissionLevel.storedPermissionUnavailable.detailText
        )
        effects.requestDiagnosticsNotification(for: .grok)
    }

    private func loadGrokBuildPermissionsLocked(deferred effects: inout DeferredSideEffects) -> SecureGrokBuildPermissionDocument {
        loadLocked(
            domain: .grokBuild,
            cache: &grokBuildCache,
            failClosedDocument: SecureGrokBuildPermissionDocument.failClosedDocument(now: now()),
            normalize: { _ in false },
            persistMissingDocument: false,
            deferred: &effects
        )
    }

    private struct StoredDocumentFailure {
        let kind: AgentPermissionStorageDiagnostic.Kind
        let message: String
    }

    private enum StoredDocumentDecodeResult<Document> {
        case success(document: Document, normalized: Bool)
        case failure(StoredDocumentFailure)
    }

    private func loadLocked<Document: Codable>(
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        missingDocument: Document? = nil,
        failClosedDocument: Document,
        normalize: (inout Document) -> Bool,
        persistMissingDocument: Bool = true,
        deferred effects: inout DeferredSideEffects
    ) -> Document {
        if let cache {
            return cache
        }

        let plainPayload: String?
        do {
            plainPayload = try secureStrings.getPlainValue(
                for: domain.secureStorageAccount,
                accessMode: permissionDecisionAccessMode
            )
        } catch {
            unpersistedMissingDomains.remove(domain)
            let kind = readFailureKind(for: error)
            return failClosed(
                domain: domain,
                failure: StoredDocumentFailure(kind: kind, message: sanitizedDiagnosticMessage(domain: domain, kind: kind, error: error)),
                failClosedDocument: failClosedDocument,
                cache: &cache,
                deferred: &effects
            )
        }

        guard let payload = plainPayload else {
            var document = missingDocument ?? failClosedDocument
            _ = normalize(&document)
            guard persistMissingDocument else {
                unpersistedMissingDomains.insert(domain)
                cache = document
                if clearDiagnostic(for: domain) {
                    effects.requestDiagnosticsNotification(for: domain)
                }
                return document
            }
            unpersistedMissingDomains.remove(domain)
            do {
                try saveDocument(document, domain: domain, accessMode: permissionDecisionAccessMode)
                cache = document
                if clearDiagnostic(for: domain) {
                    effects.requestDiagnosticsNotification(for: domain)
                }
                return document
            } catch {
                let kind = keychainFailureKind(for: error, fallback: .keychainWriteFailed)
                recordDiagnostic(domain: domain, kind: kind, error: error)
                effects.requestDiagnosticsNotification(for: domain)
                cache = failClosedDocument
                return failClosedDocument
            }
        }

        unpersistedMissingDomains.remove(domain)

        switch decodeStoredDocument(payload, normalize: normalize) {
        case let .success(document, normalized):
            return finishLoadedDocument(
                document,
                normalized: normalized,
                domain: domain,
                cache: &cache,
                deferred: &effects
            )
        case let .failure(plainFailure):
            return failClosed(domain: domain, failure: plainFailure, failClosedDocument: failClosedDocument, cache: &cache, deferred: &effects)
        }
    }

    private func decodeStoredDocument<Document: Codable>(
        _ payload: String,
        normalize: (inout Document) -> Bool
    ) -> StoredDocumentDecodeResult<Document> {
        let data = Data(payload.utf8)
        do {
            if try JSONDuplicateKeyScanner.containsDuplicateKeys(in: data) {
                return .failure(StoredDocumentFailure(
                    kind: .decodeFailed,
                    message: "Secure permission document contains duplicate JSON object keys."
                ))
            }
        } catch {
            return .failure(StoredDocumentFailure(
                kind: .decodeFailed,
                message: "Secure permission document byte encoding could not be validated safely."
            ))
        }

        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            return .failure(StoredDocumentFailure(kind: .decodeFailed, message: error.localizedDescription))
        }

        if schemaVersion(of: document) > supportedSchemaVersion(of: document) {
            return .failure(StoredDocumentFailure(
                kind: .unsupportedFutureSchema,
                message: "Unsupported future schema version \(schemaVersion(of: document))."
            ))
        }

        var normalizedDocument = document
        let normalized = normalize(&normalizedDocument)
        return .success(document: normalizedDocument, normalized: normalized)
    }

    private func finishLoadedDocument<Document: Codable>(
        _ document: Document,
        normalized: Bool,
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Document {
        cache = document
        if clearDiagnostic(for: domain) {
            effects.requestDiagnosticsNotification(for: domain)
        }
        if normalized {
            do {
                try saveDocument(document, domain: domain, accessMode: permissionDecisionAccessMode)
            } catch {
                let kind = keychainFailureKind(for: error, fallback: .keychainWriteFailed)
                recordDiagnostic(domain: domain, kind: kind, error: error)
                effects.requestDiagnosticsNotification(for: domain)
                cache = failClosedDocument(for: domain) as? Document
                return cache ?? document
            }
        }
        return document
    }

    private func failClosed<Document>(
        domain: AgentPermissionSecureDomain,
        failure: StoredDocumentFailure,
        failClosedDocument: Document,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Document {
        recordDiagnostic(domain: domain, kind: failure.kind, message: failure.message)
        effects.requestDiagnosticsNotification(for: domain)
        cache = failClosedDocument
        return failClosedDocument
    }

    private func saveLocked<Document: Codable>(
        _ document: Document,
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Bool {
        unpersistedMissingDomains.remove(domain)
        do {
            try saveDocument(document, domain: domain)
            cache = document
            if clearDiagnostic(for: domain) {
                effects.requestDiagnosticsNotification(for: domain)
            }
            effects.requestChangeNotification(domain: domain, writeSucceeded: true)
            return true
        } catch {
            recordDiagnostic(domain: domain, kind: keychainFailureKind(for: error, fallback: .keychainWriteFailed), error: error)
            effects.requestDiagnosticsNotification(for: domain)
            cache = failClosedDocument(for: domain) as? Document
            effects.requestChangeNotification(domain: domain, writeSucceeded: false)
            return false
        }
    }

    /// A failed read/decode/normalization write leaves a conservative cache that must never be
    /// treated as authoritative for a later user mutation. Retry the source read first; if it is
    /// still degraded, refuse the write and preserve the unknown document byte-for-byte.
    private func resetFailedCacheBeforeMutation(
        domain: AgentPermissionSecureDomain,
        cache: inout (some Any)?
    ) {
        guard diagnosticsByDomain[domain] != nil else { return }
        cache = nil
    }

    private func mutationCanProceed(
        domain: AgentPermissionSecureDomain,
        deferred effects: inout DeferredSideEffects
    ) -> Bool {
        guard diagnosticsByDomain[domain] == nil else {
            effects.requestChangeNotification(domain: domain, writeSucceeded: false)
            return false
        }
        return true
    }

    private func resetLocked<Document: Codable>(
        _ document: Document,
        domain: AgentPermissionSecureDomain,
        cache: inout Document?,
        deferred effects: inout DeferredSideEffects
    ) -> Bool {
        unpersistedMissingDomains.remove(domain)
        do {
            try saveDocument(document, domain: domain)
            cache = document
            if clearDiagnostic(for: domain) {
                effects.requestDiagnosticsNotification(for: domain)
            }
            effects.requestChangeNotification(domain: domain, writeSucceeded: true)
            return true
        } catch {
            recordDiagnostic(domain: domain, kind: keychainFailureKind(for: error, fallback: .keychainWriteFailed), error: error)
            effects.requestDiagnosticsNotification(for: domain)
            try? secureStrings.deletePlainValue(for: domain.secureStorageAccount, accessMode: .interactive)
            cache = failClosedDocument(for: domain) as? Document
            effects.requestChangeNotification(domain: domain, writeSucceeded: false)
            return false
        }
    }

    private func saveDocument(
        _ document: some Codable,
        domain: AgentPermissionSecureDomain,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        let data = try encoder.encode(document)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw AgentPermissionSecureStoreError.encodingFailed
        }
        try secureStrings.savePlainValue(payload, for: domain.secureStorageAccount, accessMode: accessMode)
    }

    // MARK: - Normalization

    @discardableResult
    private func normalizeSubagent(_ document: inout SecureSubagentPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureSubagentPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureSubagentPermissionDocument.currentSchemaVersion
            changed = true
        }
        if AgentSubagentPermissionPolicy(rawValue: document.globalPolicyRaw ?? "") == nil {
            document.globalPolicyRaw = AgentSubagentPermissionPolicy.safeManaged.rawValue
            changed = true
        }

        return changed
    }

    @discardableResult
    private func normalizeCodex(_ document: inout SecureCodexPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureCodexPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureCodexPermissionDocument.currentSchemaVersion
            changed = true
        }
        let approval = CodexAgentToolPreferences.ApprovalPolicy(storedValue: document.approvalPolicyRaw ?? "") ?? .onRequest
        if document.approvalPolicyRaw != approval.persistedValue {
            document.approvalPolicyRaw = approval.persistedValue
            changed = true
        }
        let sandbox = CodexAgentToolPreferences.SandboxMode(storedValue: document.sandboxModeRaw ?? "") ?? .workspaceWrite
        if document.sandboxModeRaw != sandbox.persistedValue {
            document.sandboxModeRaw = sandbox.persistedValue
            changed = true
        }
        let reviewer: CodexAgentToolPreferences.ApprovalReviewer = if let raw = document.approvalReviewerRaw {
            CodexAgentToolPreferences.ApprovalReviewer(storedValue: raw) ?? .user
        } else {
            .autoReview
        }
        if document.approvalReviewerRaw != reviewer.persistedValue {
            document.approvalReviewerRaw = reviewer.persistedValue
            changed = true
        }
        if document.bashToolEnabled == nil {
            document.bashToolEnabled = true
            changed = true
        }
        let originalToggles = document.mcpServerTogglesByNormalizedName ?? [:]
        var normalized: [String: Bool] = [:]
        for (key, value) in originalToggles {
            let normalizedKey = SecureCodexPermissionDocument.normalizedMCPServerKey(key)
            guard !normalizedKey.isEmpty else { continue }
            normalized[normalizedKey] = value
        }
        if normalized != originalToggles {
            document.mcpServerTogglesByNormalizedName = normalized.isEmpty ? nil : normalized
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeClaude(_ document: inout SecureClaudePermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureClaudePermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureClaudePermissionDocument.currentSchemaVersion
            changed = true
        }
        let mode = SecureClaudePermissionDocument.normalizedPermissionMode(document.permissionModeRaw, preserveUnknown: true)
        if document.permissionModeRaw != mode {
            document.permissionModeRaw = mode
            changed = true
        }
        if document.bashToolEnabled == nil {
            document.bashToolEnabled = false
            changed = true
        }
        if document.mcpStrictModeEnabled == nil {
            document.mcpStrictModeEnabled = true
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeOpenCode(_ document: inout SecureOpenCodePermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureOpenCodePermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureOpenCodePermissionDocument.currentSchemaVersion
            changed = true
        }
        let level = OpenCodeAgentToolPreferences.PermissionLevel(rawValue: document.permissionLevelRaw ?? "") ?? .managedDefault
        if document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeCursor(_ document: inout SecureCursorPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureCursorPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureCursorPermissionDocument.currentSchemaVersion
            changed = true
        }
        let level = CursorAgentToolPreferences.PermissionLevel.from(rawValue: document.permissionLevelRaw)
        if document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeAntigravity(_ document: inout SecureAntigravityPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureAntigravityPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureAntigravityPermissionDocument.currentSchemaVersion
            changed = true
        }
        if let level = AntigravityAgentToolPreferences.PermissionLevel.headlessLevel(
            from: document.permissionLevelRaw
        ), document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeGrok(_ document: inout SecureGrokPermissionDocument) -> Bool {
        guard let level = GrokAgentToolPreferences.PermissionLevel.storedLevel(from: document.permissionLevelRaw) else {
            return false
        }
        var changed = false
        if document.schemaVersion != SecureGrokPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureGrokPermissionDocument.currentSchemaVersion
            changed = true
        }
        if document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    @discardableResult
    private func normalizeGrokBuild(_ document: inout SecureGrokBuildPermissionDocument) -> Bool {
        var changed = false
        if document.schemaVersion != SecureGrokBuildPermissionDocument.currentSchemaVersion {
            document.schemaVersion = SecureGrokBuildPermissionDocument.currentSchemaVersion
            changed = true
        }
        let level = GrokBuildAgentToolPreferences.PermissionLevel.from(rawValue: document.permissionLevelRaw)
        if document.permissionLevelRaw != level.rawValue {
            document.permissionLevelRaw = level.rawValue
            changed = true
        }
        return changed
    }

    // MARK: - Helpers

    private func supportedSchemaVersion(of document: some Any) -> Int {
        switch document {
        case _ as SecureSubagentPermissionDocument:
            SecureSubagentPermissionDocument.currentSchemaVersion
        case _ as SecureCodexPermissionDocument:
            SecureCodexPermissionDocument.currentSchemaVersion
        case _ as SecureClaudePermissionDocument:
            SecureClaudePermissionDocument.currentSchemaVersion
        case _ as SecureOpenCodePermissionDocument:
            SecureOpenCodePermissionDocument.currentSchemaVersion
        case _ as SecureCursorPermissionDocument:
            SecureCursorPermissionDocument.currentSchemaVersion
        case _ as SecureAntigravityPermissionDocument:
            SecureAntigravityPermissionDocument.currentSchemaVersion
        case _ as SecureGrokPermissionDocument:
            SecureGrokPermissionDocument.currentSchemaVersion
        case _ as SecureGrokBuildPermissionDocument:
            SecureGrokBuildPermissionDocument.currentSchemaVersion
        default:
            1
        }
    }

    private func schemaVersion(of document: some Any) -> Int {
        switch document {
        case let value as SecureSubagentPermissionDocument:
            value.schemaVersion
        case let value as SecureCodexPermissionDocument:
            value.schemaVersion
        case let value as SecureClaudePermissionDocument:
            value.schemaVersion
        case let value as SecureOpenCodePermissionDocument:
            value.schemaVersion
        case let value as SecureCursorPermissionDocument:
            value.schemaVersion
        case let value as SecureAntigravityPermissionDocument:
            value.schemaVersion
        case let value as SecureGrokPermissionDocument:
            value.schemaVersion
        case let value as SecureGrokBuildPermissionDocument:
            value.schemaVersion
        default:
            1
        }
    }

    private func failClosedDocument(for domain: AgentPermissionSecureDomain) -> Any {
        switch domain {
        case .subagent:
            SecureSubagentPermissionDocument.failClosedDocument(now: now())
        case .codex:
            SecureCodexPermissionDocument.failClosedDocument(now: now())
        case .claude:
            SecureClaudePermissionDocument.failClosedDocument(now: now())
        case .openCode:
            SecureOpenCodePermissionDocument.failClosedDocument(now: now())
        case .cursor:
            SecureCursorPermissionDocument.failClosedDocument(now: now())
        case .antigravity:
            SecureAntigravityPermissionDocument.failClosedDocument(now: now())
        case .grok:
            SecureGrokPermissionDocument.failClosedDocument(now: now())
        case .grokBuild:
            SecureGrokBuildPermissionDocument.failClosedDocument(now: now())
        }
    }

    private func readFailureKind(for error: Error) -> AgentPermissionStorageDiagnostic.Kind {
        keychainFailureKind(for: error, fallback: .keychainReadFailed)
    }

    private func isAccessDeniedFailure(_ error: Error) -> Bool {
        guard let keychainError = error as? KeychainService.KeychainError else {
            return false
        }
        switch keychainError {
        case .interactionNotAllowed, .authenticationFailed, .userInteractionCancelled:
            return true
        default:
            return false
        }
    }

    private func keychainFailureKind(
        for error: Error,
        fallback: AgentPermissionStorageDiagnostic.Kind
    ) -> AgentPermissionStorageDiagnostic.Kind {
        guard let keychainError = error as? KeychainService.KeychainError else {
            return fallback
        }
        switch keychainError {
        case .interactionNotAllowed:
            return .keychainInteractionNotAllowed
        case .authenticationFailed, .userInteractionCancelled:
            return .keychainAuthenticationFailed
        default:
            return fallback
        }
    }

    private func recordDiagnostic(
        domain: AgentPermissionSecureDomain,
        kind: AgentPermissionStorageDiagnostic.Kind,
        error: Error
    ) {
        recordDiagnostic(domain: domain, kind: kind, message: sanitizedDiagnosticMessage(domain: domain, kind: kind, error: error))
    }

    private func sanitizedDiagnosticMessage(
        domain: AgentPermissionSecureDomain,
        kind: AgentPermissionStorageDiagnostic.Kind,
        error: Error
    ) -> String {
        switch kind {
        case .keychainInteractionNotAllowed:
            "Secure permission storage for \(domain.rawValue) could not be accessed without user interaction. Safe defaults are active."
        case .keychainAuthenticationFailed:
            "Secure permission storage for \(domain.rawValue) could not be authenticated. Safe defaults are active."
        default:
            error.localizedDescription
        }
    }

    private func recordDiagnostic(
        domain: AgentPermissionSecureDomain,
        kind: AgentPermissionStorageDiagnostic.Kind,
        message: String
    ) {
        diagnosticsByDomain[domain] = AgentPermissionStorageDiagnostic(
            domain: domain,
            kind: kind,
            message: message,
            occurredAt: now()
        )
    }

    @discardableResult
    private func clearDiagnostic(for domain: AgentPermissionSecureDomain) -> Bool {
        diagnosticsByDomain.removeValue(forKey: domain) != nil
    }

    private func postChangeNotification(domain: AgentPermissionSecureDomain, writeSucceeded: Bool) {
        notificationCenter.post(
            name: .agentPermissionSecureStoreDidChange,
            object: self,
            userInfo: [
                AgentPermissionSecureStoreNotificationKey.domain: domain.rawValue,
                AgentPermissionSecureStoreNotificationKey.writeSucceeded: writeSucceeded
            ]
        )
    }

    private func postDiagnosticsNotification(domain: AgentPermissionSecureDomain) {
        notificationCenter.post(
            name: .agentPermissionSecureStoreDiagnosticsDidChange,
            object: self,
            userInfo: [
                AgentPermissionSecureStoreNotificationKey.domain: domain.rawValue
            ]
        )
    }

    private func performDeferredSideEffects(_ effects: DeferredSideEffects) {
        for domain in effects.diagnosticsNotifications {
            postDiagnosticsNotification(domain: domain)
        }
        for notification in effects.changeNotifications {
            postChangeNotification(domain: notification.domain, writeSucceeded: notification.writeSucceeded)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func withLockAndDeferredSideEffects<T>(_ body: (inout DeferredSideEffects) -> T) -> T {
        var effects = DeferredSideEffects()
        let result: T = {
            lock.lock()
            defer { lock.unlock() }
            return body(&effects)
        }()
        performDeferredSideEffects(effects)
        return result
    }

    private enum AgentPermissionSecureStoreError: LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                "Failed to encode secure permission document."
            }
        }
    }
}
