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

    func testMissingDevinDocumentCreatesAndSavesProviderDefault() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.devin.storageKey
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.devinPermissions().permissionLevel(), .providerDefault)

        let saved = try decode(SecureDevinPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.permissionLevel(), .providerDefault)
        XCTAssertNil(store.diagnostic(for: .devin))
    }

    func testMalformedDevinDocumentFailsClosedToNormal() {
        let secureStrings = FakeSecurePlainStringStore()
        secureStrings.plainValues[AgentPermissionSecureDomain.devin.storageKey] = "{"
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(store.devinPermissions().permissionLevel(), .normal)
        XCTAssertEqual(store.diagnostic(for: .devin)?.kind, .decodeFailed)
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

    func testCurrentSchemaSubagentRawProviderMapIsPreservedAcrossUnrelatedProviderUpdate() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        let rawLevels = [
            AgentProviderBindingID.antigravity.rawValue: "auto_edit",
            "grokBuild": "managedDefault",
            "futureProvider": "opaque"
        ]
        let payload = try encode(
            SecureSubagentPermissionDocument(
                globalPolicyRaw: AgentSubagentPermissionPolicy.custom.rawValue,
                providerPermissionLevelsRawByProviderID: rawLevels
            )
        )
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.subagentPermissions()
        let antigravityLevel = permissions.providerPermissionLevel(for: .antigravity)

        XCTAssertEqual(permissions.providerPermissionLevelsRawByProviderID, rawLevels)
        XCTAssertEqual(antigravityLevel, .antigravity(.safeManagedUnavailable))
        if case let .antigravity(level) = antigravityLevel {
            XCTAssertFalse(level.supportsHeadlessRun)
        } else {
            XCTFail("Expected an Antigravity permission level")
        }
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)

        XCTAssertTrue(store.updateSubagentPermissions { document in
            var levels = document.providerPermissionLevelsRawByProviderID ?? [:]
            levels[AgentProviderBindingID.grok.rawValue] = GrokAgentToolPreferences.PermissionLevel.managedDefault.rawValue
            document.providerPermissionLevelsRawByProviderID = levels
        })

        var expectedLevels = rawLevels
        expectedLevels[AgentProviderBindingID.grok.rawValue] = GrokAgentToolPreferences.PermissionLevel.managedDefault.rawValue
        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.providerPermissionLevelsRawByProviderID, expectedLevels)
    }

    func testInvalidGrokSubagentValueIsUnavailableAndSurvivesUnrelatedUpdate() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        let rawLevels = ["grok": "future_permission", "grokBuild": "opaque", "futureProvider": "opaque"]
        let payload = try encode(SecureSubagentPermissionDocument(
            globalPolicyRaw: AgentSubagentPermissionPolicy.custom.rawValue,
            providerPermissionLevelsRawByProviderID: rawLevels
        ))
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        guard case let .grok(level) = store.providerSubagentPermissionLevel(for: .grok) else {
            return XCTFail("Expected a Grok permission level")
        }
        assertGrokUnavailable(level)
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertTrue(store.updateSubagentPermissions { document in
            var levels = document.providerPermissionLevelsRawByProviderID ?? [:]
            levels["antigravity"] = "fullAccess"
            document.providerPermissionLevelsRawByProviderID = levels
        })
        var expected = rawLevels
        expected["antigravity"] = "fullAccess"
        let saved = try decode(SecureSubagentPermissionDocument.self, from: secureStrings.plainValues[key])
        XCTAssertEqual(saved.providerPermissionLevelsRawByProviderID, expected)
        XCTAssertEqual(saved.providerPermissionLevel(for: .grok), .grok(level))
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

        let antigravityLevel = store.antigravityPermissions().permissionLevel()
        XCTAssertEqual(antigravityLevel, .safeManagedUnavailable)
        XCTAssertFalse(antigravityLevel.supportsHeadlessRun)
        assertGrokUnavailable(store.grokPermissions().permissionLevel())
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .decodeFailed)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .decodeFailed)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)

        XCTAssertFalse(store.setAntigravityPermissionLevel(.fullAccess))
        XCTAssertFalse(store.setGrokPermissionLevel(.fullAccess))
        XCTAssertEqual(secureStrings.plainValues[antigravityKey], antigravityPayload)
        XCTAssertEqual(secureStrings.plainValues[grokKey], grokPayload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
    }

    func testUnknownProviderPermissionValuesArePreservedAndUnavailable() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let antigravityKey = AgentPermissionSecureDomain.antigravity.storageKey
        let grokKey = AgentPermissionSecureDomain.grok.storageKey
        let antigravityPayload = try encode(
            SecureAntigravityPermissionDocument(permissionLevelRaw: "futurePermission")
        )
        secureStrings.plainValues[antigravityKey] = antigravityPayload
        let grokPayload = try encode(SecureGrokPermissionDocument(permissionLevelRaw: "futureFullAccess"))
        secureStrings.plainValues[grokKey] = grokPayload
        let store = makeStore(secureStrings: secureStrings)

        let antigravityLevel = store.antigravityPermissions().permissionLevel()
        XCTAssertEqual(antigravityLevel, .safeManagedUnavailable)
        XCTAssertFalse(antigravityLevel.supportsHeadlessRun)
        assertGrokUnavailable(store.grokPermissions().permissionLevel())

        XCTAssertEqual(secureStrings.plainValues[antigravityKey], antigravityPayload)
        XCTAssertEqual(secureStrings.plainValues[grokKey], grokPayload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .unsupportedStoredPermission)
        XCTAssertTrue(store.diagnostic(for: .antigravity)?.message.lowercased().contains("reset") == true)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .unsupportedStoredPermission)
        XCTAssertTrue(store.diagnostic(for: .grok)?.message.lowercased().contains("reset") == true)
    }

    @MainActor
    func testRetiredACPAntigravityPermissionDoesNotMarkSecureStorageDegraded() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.antigravity.storageKey
        let payload = try encode(SecureAntigravityPermissionDocument(permissionLevelRaw: "auto_edit"))
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        let permissions = store.antigravityPermissions()
        let diagnostic = try XCTUnwrap(store.diagnostic(for: .antigravity))

        XCTAssertEqual(permissions.permissionLevel(), .safeManagedUnavailable)
        XCTAssertFalse(permissions.permissionLevel().supportsHeadlessRun)
        XCTAssertEqual(diagnostic.kind, .unsupportedStoredPermission)
        XCTAssertFalse(AgentPermissionStorageDiagnosticsViewModel.isDegrading(kind: diagnostic.kind))
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)

        let viewModel = AgentPermissionStorageDiagnosticsViewModel(
            securePermissions: store,
            notificationCenter: NotificationCenter()
        )
        XCTAssertFalse(viewModel.isSecurePermissionStorageDegraded)
        XCTAssertNil(AgentPermissionSecureStorageDegradedBanner.userFacingDetail(for: viewModel.storageDiagnostics))
    }

    func testCurrentSchemaAntigravityUnsupportedRawValuesArePreservedAndCannotRunHeadless() throws {
        let cases: [(rawValue: String?, allowsExplicitReplacement: Bool)] = [
            (nil, false),
            ("default", true),
            ("auto_edit", true),
            ("yolo", true),
            ("future_permission", false),
            (AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.rawValue, false)
        ]
        for testCase in cases {
            let secureStrings = FakeSecurePlainStringStore()
            let key = AgentPermissionSecureDomain.antigravity.storageKey
            let payload = try encode(SecureAntigravityPermissionDocument(permissionLevelRaw: testCase.rawValue))
            secureStrings.plainValues[key] = payload
            let store = makeStore(secureStrings: secureStrings)

            let permissions = store.antigravityPermissions()

            XCTAssertEqual(permissions.permissionLevelRaw, testCase.rawValue)
            XCTAssertEqual(permissions.permissionLevel(), .safeManagedUnavailable)
            XCTAssertFalse(permissions.permissionLevel().supportsHeadlessRun)
            XCTAssertEqual(secureStrings.plainValues[key], payload)
            XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
            XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .unsupportedStoredPermission)
            XCTAssertTrue(
                store.diagnostic(for: .antigravity)?.message.lowercased().contains("reset") == true ||
                    store.diagnostic(for: .antigravity)?.message.lowercased().contains("choose") == true
            )

            XCTAssertEqual(
                store.setAntigravityPermissionLevel(.fullAccess),
                testCase.allowsExplicitReplacement
            )
            if testCase.allowsExplicitReplacement {
                XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .fullAccess)
                XCTAssertNil(store.diagnostic(for: .antigravity))
            } else {
                XCTAssertEqual(secureStrings.plainValues[key], payload)
                XCTAssertTrue(store.resetAgentPermissionsToSafeDefaults().succeeded)
                XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .managedDefault)
                let resetDocument = try decode(
                    SecureAntigravityPermissionDocument.self,
                    from: secureStrings.plainValues[key]
                )
                XCTAssertEqual(resetDocument.permissionLevelRaw, "managedDefault")
            }
        }

        let missingSecureStrings = FakeSecurePlainStringStore()
        let missingStore = makeStore(secureStrings: missingSecureStrings)
        XCTAssertEqual(missingStore.antigravityPermissions().permissionLevel(), .managedDefault)
        XCTAssertNil(missingSecureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey])
        XCTAssertTrue(missingSecureStrings.savedPlainValues.isEmpty)
        XCTAssertNil(missingStore.diagnostic(for: .antigravity))
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

    func testFutureSecureProviderDocumentsDoNotUsePermissiveLegacyValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)
        GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey] = try encode(
            SecureAntigravityPermissionDocument(
                schemaVersion: SecureAntigravityPermissionDocument.currentSchemaVersion + 1,
                permissionLevelRaw: AntigravityAgentToolPreferences.PermissionLevel.fullAccess.rawValue
            )
        )
        secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey] = try encode(
            SecureGrokPermissionDocument(
                schemaVersion: SecureGrokPermissionDocument.currentSchemaVersion + 1,
                permissionLevelRaw: GrokAgentToolPreferences.PermissionLevel.fullAccess.rawValue
            )
        )
        let store = makeStore(secureStrings: secureStrings)
        let futureAntigravityPayload = secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey]
        let futureGrokPayload = secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey]

        let antigravityLevel = AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store)
        XCTAssertEqual(antigravityLevel, .safeManagedUnavailable)
        XCTAssertFalse(antigravityLevel.supportsHeadlessRun)
        assertGrokUnavailable(GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store))
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .unsupportedFutureSchema)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .unsupportedFutureSchema)

        XCTAssertFalse(store.setAntigravityPermissionLevel(.fullAccess))
        XCTAssertFalse(store.setGrokPermissionLevel(.fullAccess))
        XCTAssertEqual(
            secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey],
            futureAntigravityPayload
        )
        XCTAssertEqual(
            secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey],
            futureGrokPayload
        )
    }

    func testLegacyAntigravityFullAccessDoesNotOverwriteForeignSecureDocumentOrEnableHeadlessRun() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults)

        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.antigravity.storageKey
        let payload = """
        {"schemaVersion":1,"updatedAt":0,"permissionLevelRaw":"future_permission","foreign":{"owner":"agy"}}
        """
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        let level = AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store)

        XCTAssertEqual(level, .safeManagedUnavailable)
        XCTAssertFalse(level.supportsHeadlessRun)
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
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

        let antigravityLevel = AntigravityAgentToolPreferences.permissionLevel(
            defaults: defaults,
            secureStore: store
        )
        XCTAssertEqual(antigravityLevel, .safeManagedUnavailable)
        XCTAssertFalse(antigravityLevel.supportsHeadlessRun)
        assertGrokUnavailable(GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store))
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

        let antigravityLevel = AntigravityAgentToolPreferences.permissionLevel(
            defaults: defaults,
            secureStore: store
        )
        XCTAssertEqual(antigravityLevel, .safeManagedUnavailable)
        XCTAssertFalse(antigravityLevel.supportsHeadlessRun)
        assertGrokUnavailable(GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store))
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .keychainWriteFailed)
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .keychainWriteFailed)
    }

    func testAntigravitySecurePreferencesIgnoreRetiredACPAgentModeLiteralYolo() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("yolo", forKey: "antigravityACPAgentMode")

        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store),
            .managedDefault
        )
        XCTAssertEqual(defaults.string(forKey: "antigravityACPAgentMode"), "yolo")
        let saved = try decode(
            SecureAntigravityPermissionDocument.self,
            from: secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey]
        )
        XCTAssertEqual(saved.permissionLevel(), .managedDefault)
    }

    func testAntigravityOwnedLegacyYoloIsUnavailableUntilExplicitFullAccessSetter() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("yolo", forKey: "antigravityToolPermissionLevel")

        let secureStrings = FakeSecurePlainStringStore()
        let notificationCenter = NotificationCenter()
        let store = makeStore(secureStrings: secureStrings, notificationCenter: notificationCenter)

        let level = AntigravityAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store)
        XCTAssertEqual(level, .safeManagedUnavailable)
        XCTAssertFalse(level.supportsHeadlessRun)
        XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), "yolo")
        XCTAssertNil(secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey])
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)

        let changed = expectation(
            forNotification: .agentPermissionSecureStoreDidChange,
            object: store,
            notificationCenter: notificationCenter
        ) { notification in
            XCTAssertEqual(
                notification.userInfo?[AgentPermissionSecureStoreNotificationKey.domain] as? String,
                AgentPermissionSecureDomain.antigravity.rawValue
            )
            XCTAssertEqual(
                notification.userInfo?[AgentPermissionSecureStoreNotificationKey.writeSucceeded] as? Bool,
                true
            )
            return true
        }

        AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
        wait(for: [changed], timeout: 1)

        XCTAssertNil(defaults.object(forKey: "antigravityToolPermissionLevel"))
        XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .fullAccess)
        let saved = try decode(
            SecureAntigravityPermissionDocument.self,
            from: secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey]
        )
        XCTAssertEqual(saved.permissionLevel(), .fullAccess)
    }

    func testMalformedAntigravityDocumentIsPreservedAndBlocksHeadlessExecutionAndWrites() {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.antigravity.storageKey
        let payload = "{not-json"
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        let level = store.antigravityPermissions().permissionLevel()

        XCTAssertEqual(level, .safeManagedUnavailable)
        XCTAssertFalse(level.supportsHeadlessRun)
        XCTAssertEqual(store.diagnostic(for: .antigravity)?.kind, .decodeFailed)
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertFalse(store.setAntigravityPermissionLevel(.fullAccess))
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
    }

    func testResetIncludesDevinAndPersistsNormalSafeDefault() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)
        XCTAssertTrue(store.setDevinPermissionLevel(.fullApproval))

        let result = store.resetAgentPermissionsToSafeDefaults()

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.succeededDomains.contains(.devin))
        XCTAssertEqual(store.devinPermissions().permissionLevel(), .normal)

        let restartedStore = makeStore(secureStrings: secureStrings)
        XCTAssertEqual(restartedStore.devinPermissions().permissionLevel(), .normal)
        let saved = try decode(
            SecureDevinPermissionDocument.self,
            from: secureStrings.plainValues[AgentPermissionSecureDomain.devin.storageKey]
        )
        XCTAssertEqual(saved.permissionLevel(), .normal)
    }

    func testResetIncludesAntigravityAndPersistsManagedDefaultAcrossRestart() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)
        XCTAssertTrue(store.setAntigravityPermissionLevel(.fullAccess))

        let result = store.resetAgentPermissionsToSafeDefaults()

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.succeededDomains.contains(.antigravity))
        XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .managedDefault)

        let restartedStore = makeStore(secureStrings: secureStrings)
        XCTAssertEqual(restartedStore.antigravityPermissions().permissionLevel(), .managedDefault)
        let saved = try decode(
            SecureAntigravityPermissionDocument.self,
            from: secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey]
        )
        XCTAssertEqual(saved.permissionLevel(), .managedDefault)
    }

    func testGrokInvalidCanonicalDataRequiresResetWithoutRewriting() throws {
        let payloads = try [
            encode(SecureGrokPermissionDocument(permissionLevelRaw: nil)),
            encode(SecureGrokPermissionDocument(permissionLevelRaw: "future_permission")),
            "{not-json",
            "\u{FEFF}{\"schemaVersion\":1,\"updatedAt\":0,\"permissionLevelRaw\":\"managedDefault\",\"permissionLevelRaw\":\"fullAccess\"}",
            encode(SecureGrokPermissionDocument(schemaVersion: 2, permissionLevelRaw: "fullAccess"))
        ]
        for payload in payloads {
            let (defaults, suiteName) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("fullAccess", forKey: "grokToolPermissionLevel")
            let secureStrings = FakeSecurePlainStringStore()
            let key = AgentPermissionSecureDomain.grok.storageKey
            secureStrings.plainValues[key] = payload
            let store = makeStore(secureStrings: secureStrings)

            let level = GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store)
            assertGrokUnavailable(level)
            XCTAssertNotNil(store.diagnostic(for: .grok))
            XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
            XCTAssertFalse(store.setGrokPermissionLevel(.fullAccess))
            GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
            XCTAssertEqual(secureStrings.plainValues[key].map { Data($0.utf8) }, Data(payload.utf8))
            XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
            XCTAssertTrue(secureStrings.plainDeleteAccessModes.isEmpty)

            let reset = store.resetAgentPermissionsToSafeDefaults()
            XCTAssertTrue(reset.succeededDomains.contains(.grok))
            let restartedStore = makeStore(secureStrings: secureStrings)
            XCTAssertEqual(restartedStore.grokPermissions().permissionLevel(), .managedDefault)
            XCTAssertNil(restartedStore.diagnostic(for: .grok))
        }
    }

    func testGrokInvalidStoredPermissionFailsImmediatelyWithResetGuidance() async throws {
        let secureStrings = FakeSecurePlainStringStore()
        secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey] = try encode(
            SecureGrokPermissionDocument(permissionLevelRaw: "future_permission")
        )
        let level = makeStore(secureStrings: secureStrings).grokPermissions().permissionLevel()
        let provider = AgentRuntimeProviderService.shared.makeProvider(for: .grok, grokPermissionLevel: level)
        guard let unsupported = provider as? UnsupportedHeadlessAgentProvider else {
            return XCTFail("Invalid stored Grok permissions must never create a runnable provider")
        }

        do {
            _ = try await unsupported.streamAgentMessage(AgentMessage(userMessage: "do not launch"), runID: nil)
            XCTFail("Unsupported permissions must fail before returning a stream")
        } catch {
            let message = error.localizedDescription.lowercased()
            XCTAssertTrue(message.contains("permission"))
            XCTAssertTrue(message.contains("reset"))
        }
    }

    func testUnreadableGrokDataIsUnavailableWithoutMutation() throws {
        let secureStrings = FakeSecurePlainStringStore(plainGetError: KeychainService.KeychainError.interactionNotAllowed)
        let key = AgentPermissionSecureDomain.grok.storageKey
        let payload = try encode(SecureGrokPermissionDocument(permissionLevelRaw: "fullAccess"))
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)

        assertGrokUnavailable(store.grokPermissions().permissionLevel())
        XCTAssertEqual(store.diagnostic(for: .grok)?.kind, .keychainInteractionNotAllowed)
        XCTAssertFalse(store.setGrokPermissionLevel(.fullAccess))
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertTrue(secureStrings.plainDeleteAccessModes.isEmpty)
    }

    func testUnknownOwnedLegacyProviderValuesRequireExplicitSetting() throws {
        for raw in ["future_permission", "yolo", ""] {
            let (defaults, suiteName) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(raw, forKey: "antigravityToolPermissionLevel")
            defaults.set(raw, forKey: "grokToolPermissionLevel")
            let secureStrings = FakeSecurePlainStringStore()
            let store = makeStore(secureStrings: secureStrings)

            XCTAssertFalse(AntigravityAgentToolPreferences.permissionLevel(
                defaults: defaults, secureStore: store
            ).supportsHeadlessRun)
            assertGrokUnavailable(GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store))
            XCTAssertEqual(defaults.string(forKey: "antigravityToolPermissionLevel"), raw)
            XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), raw)
            XCTAssertTrue(secureStrings.plainValues.isEmpty)
            XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)

            AntigravityAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
            GrokAgentToolPreferences.setPermissionLevel(.fullAccess, defaults: defaults, secureStore: store)
            XCTAssertEqual(store.antigravityPermissions().permissionLevel(), .fullAccess)
            XCTAssertEqual(store.grokPermissions().permissionLevel(), .fullAccess)
            XCTAssertNil(defaults.object(forKey: "antigravityToolPermissionLevel"))
            XCTAssertNil(defaults.object(forKey: "grokToolPermissionLevel"))
        }
    }

    func testValidCanonicalProviderLevelsWinOverUnknownOwnedLegacyValues() throws {
        for raw in ["managedDefault", "fullAccess"] {
            let (defaults, suiteName) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("future_permission", forKey: "antigravityToolPermissionLevel")
            defaults.set("future_permission", forKey: "grokToolPermissionLevel")
            let secureStrings = FakeSecurePlainStringStore()
            secureStrings.plainValues[AgentPermissionSecureDomain.antigravity.storageKey] = try encode(
                SecureAntigravityPermissionDocument(permissionLevelRaw: raw)
            )
            secureStrings.plainValues[AgentPermissionSecureDomain.grok.storageKey] = try encode(
                SecureGrokPermissionDocument(permissionLevelRaw: raw)
            )
            let original = secureStrings.plainValues
            let store = makeStore(secureStrings: secureStrings)

            XCTAssertEqual(AntigravityAgentToolPreferences.permissionLevel(
                defaults: defaults, secureStore: store
            ).rawValue, raw)
            XCTAssertEqual(GrokAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store).rawValue, raw)
            XCTAssertEqual(secureStrings.plainValues, original)
            XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
            XCTAssertNil(store.diagnostic(for: .antigravity))
            XCTAssertNil(store.diagnostic(for: .grok))
        }
    }

    func testGrokUnavailableLevelCannotBePersistedAsAnExplicitPreference() throws {
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.grok.storageKey
        secureStrings.plainValues[key] = try encode(SecureGrokPermissionDocument(permissionLevelRaw: "future_permission"))
        let level = makeStore(secureStrings: secureStrings).grokPermissions().permissionLevel()
        assertGrokUnavailable(level)
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("fullAccess", forKey: "grokToolPermissionLevel")
        let validStrings = FakeSecurePlainStringStore()
        validStrings.plainValues[key] = try encode(SecureGrokPermissionDocument(permissionLevelRaw: "fullAccess"))
        let original = validStrings.plainValues[key]
        let store = makeStore(secureStrings: validStrings)

        XCTAssertFalse(store.setGrokPermissionLevel(level))
        XCTAssertFalse(store.updateGrokPermissions { $0.permissionLevelRaw = level.rawValue })
        GrokAgentToolPreferences.setPermissionLevel(level, defaults: defaults, secureStore: store)
        GrokAgentToolPreferences.setPermissionLevel(level, defaults: defaults)
        XCTAssertEqual(validStrings.plainValues[key], original)
        XCTAssertTrue(validStrings.savedPlainValues.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "grokToolPermissionLevel"), "fullAccess")
    }

    func testGrokCustomDefaultsPreserveInvalidPermissions() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directKey = "grokToolPermissionLevel"
        let subagentKey = AgentModePermissionPreferences.providerPermissionLevelKey(for: .grok)
        XCTAssertEqual(GrokAgentToolPreferences.permissionLevel(defaults: defaults), .managedDefault)
        XCTAssertEqual(
            AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .grok, defaults: defaults),
            .grok(.managedDefault)
        )

        let rawValues: [Any] = ["future_permission", "", ["unsupported": true]]
        for raw in rawValues {
            defaults.set(raw, forKey: directKey)
            defaults.set(raw, forKey: subagentKey)
            let originalDirect = defaults.object(forKey: directKey) as? NSObject
            let originalSubagent = defaults.object(forKey: subagentKey) as? NSObject

            let level = GrokAgentToolPreferences.permissionLevel(defaults: defaults)
            assertGrokUnavailable(level)
            XCTAssertEqual(
                AgentModePermissionPreferences.providerSubagentPermissionLevel(for: .grok, defaults: defaults),
                .grok(level)
            )
            GrokAgentToolPreferences.setPermissionLevel(level, defaults: defaults)
            AgentModePermissionPreferences.setProviderSubagentPermissionLevel(.grok(level), for: .grok, defaults: defaults)
            XCTAssertEqual(defaults.object(forKey: directKey) as? NSObject, originalDirect)
            XCTAssertEqual(defaults.object(forKey: subagentKey) as? NSObject, originalSubagent)
        }
    }

    func testGrokUnavailableSubagentPreferenceCannotBePersisted() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStrings = FakeSecurePlainStringStore()
        let key = AgentPermissionSecureDomain.subagent.storageKey
        let payload = try encode(SecureSubagentPermissionDocument(
            globalPolicyRaw: AgentSubagentPermissionPolicy.custom.rawValue,
            providerPermissionLevelsRawByProviderID: ["grok": "fullAccess"]
        ))
        secureStrings.plainValues[key] = payload
        let store = makeStore(secureStrings: secureStrings)
        let unavailable = GrokAgentToolPreferences.PermissionLevel.from(rawValue: "future_permission")

        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .grok(unavailable), for: .grok, defaults: defaults, secureStore: store
        )
        XCTAssertFalse(store.updateSubagentPermissions {
            $0.providerPermissionLevelsRawByProviderID = ["grok": unavailable.rawValue]
        })
        XCTAssertEqual(store.providerSubagentPermissionLevel(for: .grok), .grok(.fullAccess))
        XCTAssertEqual(secureStrings.plainValues[key], payload)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
    }

    func testRetiredGrokBuildMissingReadIsPassive() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secureStrings = FakeSecurePlainStringStore()
        let store = makeStore(secureStrings: secureStrings)

        XCTAssertEqual(GrokBuildAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: store), .managedDefault)
        XCTAssertEqual(store.grokBuildPermissions().permissionLevel(), .managedDefault)
        XCTAssertTrue(secureStrings.plainValues.isEmpty)
        XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
        XCTAssertTrue(secureStrings.plainDeleteAccessModes.isEmpty)
    }

    func testRetiredGrokBuildStoredValuesAreReadWithoutRewriting() throws {
        for raw in ["fullAccess", "future_permission"] {
            let secureStrings = FakeSecurePlainStringStore()
            let key = AgentPermissionSecureDomain.grokBuild.storageKey
            let payload = try encode(SecureGrokBuildPermissionDocument(permissionLevelRaw: raw))
            secureStrings.plainValues[key] = payload
            let store = makeStore(secureStrings: secureStrings)

            let document = store.grokBuildPermissions()
            XCTAssertEqual(document.permissionLevelRaw, raw)
            if raw == "fullAccess" {
                XCTAssertEqual(document.permissionLevel(), .fullAccess)
            }
            XCTAssertEqual(secureStrings.plainValues[key], payload)
            XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
            XCTAssertTrue(secureStrings.plainDeleteAccessModes.isEmpty)
        }
    }

    func testRetiredGrokBuildSettersAreUnsupportedButGlobalResetIsAllowed() throws {
        let payloads: [String?] = try [
            nil,
            encode(SecureGrokBuildPermissionDocument(permissionLevelRaw: "fullAccess")),
            encode(SecureGrokBuildPermissionDocument(permissionLevelRaw: "future_permission"))
        ]
        for payload in payloads {
            let (defaults, suiteName) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set("fullAccess", forKey: "grokBuildACPToolPermissionLevel")
            let secureStrings = FakeSecurePlainStringStore()
            let key = AgentPermissionSecureDomain.grokBuild.storageKey
            secureStrings.plainValues[key] = payload
            let store = makeStore(secureStrings: secureStrings)

            XCTAssertFalse(store.setGrokBuildPermissionLevel(.managedDefault))
            XCTAssertFalse(store.updateGrokBuildPermissions { $0.permissionLevelRaw = "fullAccess" })
            GrokBuildAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults, secureStore: store)
            GrokBuildAgentToolPreferences.setPermissionLevel(.managedDefault, defaults: defaults)
            XCTAssertEqual(secureStrings.plainValues[key], payload)
            XCTAssertTrue(secureStrings.savedPlainValues.isEmpty)
            XCTAssertEqual(defaults.string(forKey: "grokBuildACPToolPermissionLevel"), "fullAccess")

            let result = store.resetAgentPermissionsToSafeDefaults()
            XCTAssertTrue(result.succeededDomains.contains(.grokBuild))
            let restartedStore = makeStore(secureStrings: secureStrings)
            XCTAssertEqual(restartedStore.grokBuildPermissions().permissionLevel(), .managedDefault)
            let saved = try decode(SecureGrokBuildPermissionDocument.self, from: secureStrings.plainValues[key])
            XCTAssertEqual(saved.permissionLevelRaw, "managedDefault")
        }
    }

    private func assertGrokUnavailable(
        _ level: GrokAgentToolPreferences.PermissionLevel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(GrokAgentToolPreferences.PermissionLevel.allCases.contains(level), file: file, line: line)
        XCTAssertNil(
            AgentProviderPermissionLevelID(providerID: .grok, subagentRawValue: level.rawValue),
            file: file,
            line: line
        )
        let provider = AgentRuntimeProviderService.shared.makeProvider(for: .grok, grokPermissionLevel: level)
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider, file: file, line: line)
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
