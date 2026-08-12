import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentPermissionSecureStoreTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override func setUp() {
        super.setUp()
        encoder.outputFormatting = [.sortedKeys]
    }

    func testPlainDocumentReadUsesCanonicalPlainOnly() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
                bashToolEnabled: true
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .fullAccess)
        XCTAssertEqual(permissions.bashToolEnabled, true)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertNil(store.diagnostic(for: .codex))
    }

    func testMissingSubagentDocumentCreatesAndSavesSafeManagedPolicy() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.nonInteractive(reason: .permissionDecision)])

        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.globalPolicy(), .safeManaged)
        XCTAssertNil(store.diagnostic(for: .subagent))
    }

    func testMissingSubagentPolicyFieldNormalizesToSafeManagedPolicy() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureSubagentPermissionDocument(globalPolicyRaw: nil)
        )
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)

        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.globalPolicy(), .safeManaged)
        XCTAssertNil(store.diagnostic(for: .subagent))
    }

    func testMissingPlainDocumentCreatesAndSavesProductDefaults() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .autoReview)
        XCTAssertEqual(permissions.bashToolEnabled, true)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertTrue(secureStrings.savedPlainValues.contains { $0.key == key })

        let saved = try decode(SecureCodexPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .autoReview)
        XCTAssertEqual(saved.bashToolEnabled, true)
        XCTAssertNil(store.diagnostic(for: .codex))
    }

    func testMissingCodexFieldsNormalizeToProductDefaults() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalReviewerRaw: nil,
                bashToolEnabled: nil
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .autoReview)
        XCTAssertEqual(permissions.bashToolEnabled, true)
        XCTAssertNil(store.diagnostic(for: .codex))

        let saved = try decode(SecureCodexPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .autoReview)
        XCTAssertEqual(saved.bashToolEnabled, true)
    }

    func testNoSecureStoreFallbackUsesProductDefaults() throws {
        let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(AgentModePermissionPreferences.subagentPermissionPolicy(defaults: defaults), .safeManaged)
        XCTAssertTrue(CodexAgentToolPreferences.bashToolEnabled(defaults: defaults))
        XCTAssertEqual(CodexAgentToolPreferences.permissionLevel(defaults: defaults), .autoReview)
    }

    @MainActor
    func testProductDefaultsFlowThroughTopLevelSettingsSnapshot() throws {
        let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let secureStrings = FakeSecurePlainStringStore()
        let secureStore = makeStore(secureStrings: secureStrings)
        let snapshots = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: secureStore,
            codexMCPServerEntries: { [] }
        )

        let binding = snapshots.topLevelSettingsControlsBinding(providerID: .codex)

        XCTAssertEqual(binding.permission.displayName, CodexAgentToolPreferences.PermissionLevel.autoReview.displayName)
        XCTAssertEqual(binding.runtimePermission.codexApprovalReviewer, .autoReview)
        XCTAssertEqual(binding.codexTools?.bashToolEnabled, true)
    }

    func testSuccessfulResetPersistsProductDefaultsAcrossRelaunch() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
                bashToolEnabled: false
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertTrue(store.resetAgentPermissionsToSafeDefaults().succeeded)
        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(store.codexPermissions().permissionLevel(), .autoReview)
        XCTAssertEqual(store.codexPermissions().bashToolEnabled, true)

        let saved = try decode(SecureCodexPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .autoReview)
        XCTAssertEqual(saved.bashToolEnabled, true)

        let restartedStore = makeStore(secureStrings: secureStrings)
        XCTAssertEqual(restartedStore.codexPermissions().permissionLevel(), .autoReview)
        XCTAssertEqual(restartedStore.codexPermissions().bashToolEnabled, true)
    }

    func testMissingPlainDocumentWriteFailureFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore(saveError: KeychainService.KeychainError.invalidData)
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)
    }

    func testMalformedSubagentPlainDocumentFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        secureStrings.plainValues[key] = "{not-json"
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .decodeFailed)
    }

    func testSubagentReadFailureFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore(plainGetError: KeychainService.KeychainError.interactionNotAllowed)
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .keychainInteractionNotAllowed)
    }

    func testMalformedCodexPlainDocumentFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = "{not-json"
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .decodeFailed)
    }

    func testMalformedPlainDocumentFailsClosed() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.claude.storageKey
        secureStrings.plainValues[key] = "{not-json"
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.claudePermissions()

        XCTAssertEqual(permissions.permissionLevel(), .requireApproval)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(permissions.mcpStrictModeEnabled, true)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .claude)?.kind, .decodeFailed)
    }

    func testUnsupportedFuturePlainSchemaFailsClosed() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                schemaVersion: SecureCodexPermissionDocument.currentSchemaVersion + 1,
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                bashToolEnabled: true
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .unsupportedFutureSchema)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
    }

    @MainActor
    func testCodexPermissionReadInteractionDeniedFailsClosedAndMarksDiagnosticsDegraded() throws {
        let secureStrings = FakeSecurePlainStringStore(plainGetError: KeychainService.KeychainError.interactionNotAllowed)
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.codexPermissions()

        XCTAssertEqual(permissions.permissionLevel(), .defaultPermission)
        XCTAssertEqual(permissions.bashToolEnabled, false)
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])

        let diagnostic = try XCTUnwrap(store.diagnostic(for: .codex))
        XCTAssertEqual(diagnostic.domain, .codex)
        XCTAssertEqual(diagnostic.kind, .keychainInteractionNotAllowed)
        XCTAssertTrue(diagnostic.message.contains("codex"))
        XCTAssertFalse(diagnostic.message.contains(AgentPermissionSecureDomain.codex.storageKey))
        XCTAssertTrue(AgentPermissionStorageDiagnosticsViewModel.isDegrading(kind: diagnostic.kind))

        let viewModel = AgentPermissionStorageDiagnosticsViewModel(
            securePermissions: store,
            notificationCenter: NotificationCenter()
        )
        XCTAssertTrue(viewModel.isSecurePermissionStorageDegraded)
        XCTAssertEqual(viewModel.storageDiagnostics.map(\.kind), [.keychainInteractionNotAllowed])
    }

    func testAccessModesCapturedForPlainReadsWritesAndDeletesOnly() {
        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        _ = store.codexPermissions()
        XCTAssertEqual(secureStrings.plainGetAccessModes, [.nonInteractive(reason: .permissionDecision)])
        XCTAssertEqual(secureStrings.plainSaveAccessModes, [.nonInteractive(reason: .permissionDecision)])

        XCTAssertTrue(store.updateCodexPermissions { document in
            document.bashToolEnabled = false
        })
        XCTAssertEqual(secureStrings.plainSaveAccessModes.last, .interactive)

        secureStrings.failSaveKeys = Set(AgentPermissionSecureDomain.allCases.map(\.storageKey))
        let resetResult = store.resetAgentPermissionsToSafeDefaults()

        XCTAssertFalse(resetResult.succeeded)
        XCTAssertEqual(Set(resetResult.failedDomains), Set(AgentPermissionSecureDomain.allCases))
        XCTAssertEqual(secureStrings.plainDeleteAccessModes, Array(repeating: .interactive, count: AgentPermissionSecureDomain.allCases.count))
        XCTAssertEqual(store.codexPermissions().permissionLevel(), .defaultPermission)
        XCTAssertEqual(store.codexPermissions().bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)

        secureStrings.failSaveKeys.removeAll()
        let restartedStore = makeStore(secureStrings: secureStrings)
        let restartedPermissions = restartedStore.codexPermissions()
        XCTAssertEqual(restartedPermissions.permissionLevel(), .autoReview)
        XCTAssertEqual(restartedPermissions.bashToolEnabled, true)
        XCTAssertNil(restartedStore.diagnostic(for: .codex))
    }

    func testUpdateWriteFailureForcesEffectiveCacheFailClosed() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.codex.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureCodexPermissionDocument(
                approvalPolicyRaw: CodexAgentToolPreferences.ApprovalPolicy.never.persistedValue,
                sandboxModeRaw: CodexAgentToolPreferences.SandboxMode.dangerFullAccess.persistedValue,
                approvalReviewerRaw: CodexAgentToolPreferences.ApprovalReviewer.user.persistedValue,
                bashToolEnabled: true,
                mcpServerTogglesByNormalizedName: ["external-tools": false]
            )
        )
        let store = makeStore(secureStrings: secureStrings)
        XCTAssertEqual(store.codexPermissions().permissionLevel(), .fullAccess)
        XCTAssertEqual(store.codexPermissions().bashToolEnabled, true)

        secureStrings.failSaveKeys = [key]
        XCTAssertFalse(store.updateCodexPermissions { document in
            document.approvalPolicyRaw = CodexAgentToolPreferences.ApprovalPolicy.onRequest.persistedValue
        })

        let effective = store.codexPermissions()
        XCTAssertEqual(effective.permissionLevel(), .defaultPermission)
        XCTAssertEqual(effective.bashToolEnabled, false)
        XCTAssertEqual(store.diagnostic(for: .codex)?.kind, .keychainWriteFailed)

        secureStrings.failSaveKeys.removeAll()
        XCTAssertTrue(store.updateCodexPermissions { document in
            document.bashToolEnabled = false
        })
        let retried = store.codexPermissions()
        XCTAssertEqual(retried.permissionLevel(), .fullAccess)
        XCTAssertEqual(retried.bashToolEnabled, false)
        XCTAssertEqual(retried.mcpServerTogglesByNormalizedName, ["external-tools": false])
        XCTAssertNil(store.diagnostic(for: .codex))
    }

    func testSubagentSchemaV2MigratesExpandedProviderKeysToV3() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        secureStrings.plainValues[key] = try encode(
            SecureSubagentPermissionDocument(
                schemaVersion: 2,
                globalPolicyRaw: AgentSubagentPermissionPolicy.custom.rawValue,
                providerPermissionLevelsRawByProviderID: [
                    AgentProviderBindingID.antigravity.rawValue:
                        AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.rawValue,
                    AgentProviderBindingID.grok.rawValue:
                        GrokAgentToolPreferences.PermissionLevel.fullAccess.rawValue
                ]
            )
        )
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.subagentPermissions()

        XCTAssertEqual(permissions.schemaVersion, 3)
        XCTAssertEqual(permissions.globalPolicy(), .custom)
        XCTAssertEqual(
            permissions.providerPermissionLevel(for: .antigravity),
            .antigravity(.sandboxedAutoApprove)
        )
        XCTAssertEqual(permissions.providerPermissionLevel(for: .grok), .grok(.fullAccess))

        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.schemaVersion, SecureSubagentPermissionDocument.currentSchemaVersion)
        XCTAssertNil(store.diagnostic(for: .subagent))
    }

    func testSubagentFutureSchemaFailsClosedWithoutRewriting() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        let payload = try encode(
            SecureSubagentPermissionDocument(
                schemaVersion: SecureSubagentPermissionDocument.currentSchemaVersion + 1,
                globalPolicyRaw: AgentSubagentPermissionPolicy.inheritProviderSettings.rawValue,
                providerPermissionLevelsRawByProviderID: [
                    AgentProviderBindingID.grok.rawValue:
                        GrokAgentToolPreferences.PermissionLevel.fullAccess.rawValue
                ]
            )
        )
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.subagentPolicy(), .safeManaged)
        XCTAssertEqual(store.providerSubagentPermissionLevel(for: .grok), .grok(.managedDefault))
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .unsupportedFutureSchema)

        XCTAssertFalse(store.updateSubagentPermissions { document in
            document.globalPolicyRaw = AgentSubagentPermissionPolicy.custom.rawValue
        })
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .subagent)?.kind, .unsupportedFutureSchema)
    }

    func testUTF8BOMProviderDocumentsDecodeWithoutNormalization() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let antigravityKey = AgentPermissionSecureDomain.antigravity.storageKey
        let grokKey = AgentPermissionSecureDomain.grok.storageKey
        let antigravityPayload = try "\u{FEFF}" + encode(SecureAntigravityPermissionDocument(
            permissionLevelRaw: AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.rawValue
        ))
        let grokPayload = try "\u{FEFF}" + encode(SecureGrokPermissionDocument(
            permissionLevelRaw: GrokAgentToolPreferences.PermissionLevel.fullAccess.rawValue
        ))
        secureStrings.plainValues[antigravityKey] = antigravityPayload
        secureStrings.plainValues[grokKey] = grokPayload
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .sandboxedAutoApprove)
        XCTAssertEqual(store.grokPermissions().permissionLevel(), .fullAccess)
        XCTAssertEqual(secureStrings.plainValues[antigravityKey], antigravityPayload)
        XCTAssertEqual(secureStrings.plainValues[grokKey], grokPayload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertNil(store.diagnostic(for: .antigravity))
        XCTAssertNil(store.diagnostic(for: .grok))
    }

    func testUTF8BOMDuplicateProviderDocumentsFailClosedWithoutRewriting() {
        let secureStrings = FakeSecurePlainStringStore()
        let antigravityKey = AgentPermissionSecureDomain.antigravity.storageKey
        let grokKey = AgentPermissionSecureDomain.grok.storageKey
        let antigravityPayload = """
        \u{FEFF}{"schemaVersion":1,"updatedAt":0,"permissionLevelRaw":"managedDefault","permissionLevelRaw":"fullAccess"}
        """
        let grokPayload = """
        \u{FEFF}{"schemaVersion":1,"updatedAt":0,"permissionLevelRaw":"managedDefault","permissionLevelRaw":"fullAccess"}
        """
        secureStrings.plainValues[antigravityKey] = antigravityPayload
        secureStrings.plainValues[grokKey] = grokPayload
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .managedDefault)
        XCTAssertEqual(store.grokPermissions().permissionLevel(), .managedDefault)
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .decodeFailed)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .decodeFailed)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)

        XCTAssertFalse(store.setAntigravityPermissionLevel(.fullAccess))
        XCTAssertFalse(store.setGrokPermissionLevel(.fullAccess))
        XCTAssertEqual(secureStrings.plainValues[antigravityKey], antigravityPayload)
        XCTAssertEqual(secureStrings.plainValues[grokKey], grokPayload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
    }

    func testAntigravityAndGrokUnknownPermissionValuesNormalizeFailClosed() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let antigravityKey = AgentPermissionSecureDomain.antigravity.storageKey
        let grokKey = AgentPermissionSecureDomain.grok.storageKey
        secureStrings.plainValues[antigravityKey] = try encode(
            SecureAntigravityPermissionDocument(
                permissionLevelRaw: AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.rawValue
            )
        )
        secureStrings.plainValues[grokKey] = try encode(
            SecureGrokPermissionDocument(permissionLevelRaw: "futureFullAccess")
        )
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .managedDefault)
        XCTAssertEqual(store.grokPermissions().permissionLevel(), .managedDefault)

        let savedAntigravity = try decode(
            SecureAntigravityPermissionDocument.self,
            from: secureStrings.plainValues[antigravityKey]
        )
        let savedGrok = try decode(SecureGrokPermissionDocument.self, from: secureStrings.plainValues[grokKey])
        XCTAssertEqual(
            savedAntigravity.permissionLevelRaw,
            AntigravityAgentToolPreferences.PermissionLevel.managedDefault.rawValue
        )
        XCTAssertEqual(savedGrok.permissionLevelRaw, GrokAgentToolPreferences.PermissionLevel.managedDefault.rawValue)
        XCTAssertNil(store.diagnostic(for: .antigravity))
        XCTAssertNil(store.diagnostic(for: .grok))
    }

    func testProviderLegacyPermissionLevelsMigrateOnlyWhenSecureDocumentsAreMissing() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .managedDefault)
        XCTAssertEqual(store.grokPermissions().permissionLevel(), .managedDefault)
        XCTAssertNil(secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey])
        XCTAssertNil(secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey])

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .fullAccess
        )
        XCTAssertEqual(GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .fullAccess)
        XCTAssertNil(defaults.object(forKey: "antigravityToolPermissionLevel"))
        XCTAssertNil(defaults.object(forKey: "grokToolPermissionLevel"))

        let savedAntigravity = try decode(
            SecureAntigravityPermissionDocument.self,
            from: secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey]
        )
        let savedGrok = try decode(
            SecureGrokPermissionDocument.self,
            from: secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey]
        )
        XCTAssertEqual(savedAntigravity.permissionLevel(), .fullAccess)
        XCTAssertEqual(savedGrok.permissionLevel(), .fullAccess)
    }

    func testProviderInitializationCreatesCanonicalDefaultsBeforeLaterLegacyValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertNotNil(secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey])
        XCTAssertNotNil(secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey])

        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertNil(defaults.object(forKey: "antigravityToolPermissionLevel"))
        XCTAssertNil(defaults.object(forKey: "grokToolPermissionLevel"))
    }

    func testEphemeralProviderStoreRetainsLegacyValuesForLaterDurableMigration() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let ephemeralStrings = FakeSecurePlainStringStore(persistsValuesAcrossLaunches: false)
        let ephemeralStore = makeStore(secureStrings: ephemeralStrings)
        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: ephemeralStore),
            .fullAccess
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: ephemeralStore),
            .fullAccess
        )
        AntigravityAgentToolPreferences.setPermissionLevel(
            .managedDefault,
            defaults: defaults,
            secureStore: ephemeralStore
        )
        GrokAgentToolPreferences.setPermissionLevel(
            .managedDefault,
            defaults: defaults,
            secureStore: ephemeralStore
        )
        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: ephemeralStore),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: ephemeralStore),
            .managedDefault
        )
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")

        let durableStrings = FakeSecurePlainStringStore()
        let durableStore = makeStore(secureStrings: durableStrings)
        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: durableStore),
            .fullAccess
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: durableStore),
            .fullAccess
        )
        XCTAssertNil(defaults.object(forKey: "antigravityToolPermissionLevel"))
        XCTAssertNil(defaults.object(forKey: "grokToolPermissionLevel"))
    }

    func testExistingSecureProviderDocumentsWinOverLegacyPermissionLevels() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey] = try encode(
            SecureAntigravityPermissionDocument(permissionLevelRaw: "managedDefault")
        )
        secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey] = try encode(
            SecureGrokPermissionDocument(permissionLevelRaw: "managedDefault")
        )
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertNil(defaults.object(forKey: "antigravityToolPermissionLevel"))
        XCTAssertNil(defaults.object(forKey: "grokToolPermissionLevel"))
    }

    func testMalformedOrFutureSecureProviderDocumentsDoNotUsePermissiveLegacyValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey] = "{not-json"
        secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey] = try encode(
            SecureGrokPermissionDocument(
                schemaVersion: SecureGrokPermissionDocument.currentSchemaVersion + 1,
                permissionLevelRaw: GrokAgentToolPreferences.PermissionLevel.fullAccess.rawValue
            )
        )
        let store = makeStore(secureStrings: secureStrings)
        let malformedAntigravityPayload = secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey]
        let futureGrokPayload = secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey]

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .decodeFailed)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .unsupportedFutureSchema)

        XCTAssertFalse(store.setAntigravityPermissionLevel(.fullAccess))
        XCTAssertFalse(store.setGrokPermissionLevel(.fullAccess))
        XCTAssertEqual(
            secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey],
            malformedAntigravityPayload
        )
        XCTAssertEqual(
            secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey],
            futureGrokPayload
        )
    }

    func testLegacyProviderMigrationWriteFailuresFailClosedAndRetainLegacyKeys() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        secureStrings.failSaveKeys = [
            AgentPermissionSecureDomain.antigravity.storageKey,
            AgentPermissionSecureDomain.grok.storageKey
        ]
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .keychainWriteFailed)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .keychainWriteFailed)
    }

    func testProviderPreferenceWriteFailuresFailClosedAndRetainLegacyKeys() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        let antigravityKey = AgentPermissionSecureDomain.antigravity.storageKey
        let grokKey = AgentPermissionSecureDomain.grok.storageKey
        secureStrings.plainValues[antigravityKey] = try encode(SecureAntigravityPermissionDocument())
        secureStrings.plainValues[grokKey] = try encode(SecureGrokPermissionDocument())
        secureStrings.failSaveKeys = [antigravityKey, grokKey]
        let store = makeStore(secureStrings: secureStrings)

        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(
            GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .keychainWriteFailed)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .keychainWriteFailed)
    }

    private func makeStore(
        secureStrings: FakeSecurePlainStringStore,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AgentPermissionSecureStore {
        AgentPermissionSecureStore(
            secureStrings: secureStrings,
            notificationCenter: notificationCenter,
            now: { Date(timeIntervalSince1970: 1234) }
        )
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AgentPermissionSecureStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func encode(_ document: some Encodable) throws -> String {
        let data = try encoder.encode(document)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func decode<Document: Decodable>(_ type: Document.Type, from payload: String?) throws -> Document {
        let payload = try XCTUnwrap(payload)
        return try decoder.decode(Document.self, from: Data(payload.utf8))
    }
}

private final class FakeSecurePlainStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches: Bool

    var plainValues: [String: String] = [:]
    var plainGetError: Error?
    var saveError: Error?
    var failSaveKeys: Set<String> = []

    private(set) var plainGetAccessModes: [KeychainAccessMode] = []
    private(set) var plainSaveAccessModes: [KeychainAccessMode] = []
    private(set) var plainDeleteAccessModes: [KeychainAccessMode] = []
    private(set) var savedPlainValues: [(key: String, value: String)] = []

    init(
        plainPayload: String? = nil,
        plainGetError: Error? = nil,
        saveError: Error? = nil,
        persistsValuesAcrossLaunches: Bool = true
    ) {
        if let plainPayload {
            plainValues[AgentPermissionSecureDomain.codex.storageKey] = plainPayload
        }
        self.plainGetError = plainGetError
        self.saveError = saveError
        self.persistsValuesAcrossLaunches = persistsValuesAcrossLaunches
    }

    func getPlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws -> String? {
        plainGetAccessModes.append(accessMode)
        if let plainGetError {
            throw plainGetError
        }
        return plainValues[account.identifier]
    }

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode: KeychainAccessMode
    ) throws {
        plainSaveAccessModes.append(accessMode)
        if let saveError {
            throw saveError
        }
        if failSaveKeys.contains(account.identifier) {
            throw KeychainService.KeychainError.invalidData
        }
        plainValues[account.identifier] = value
        savedPlainValues.append((key: account.identifier, value: value))
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode: KeychainAccessMode) throws {
        plainDeleteAccessModes.append(accessMode)
        plainValues.removeValue(forKey: account.identifier)
    }
}
