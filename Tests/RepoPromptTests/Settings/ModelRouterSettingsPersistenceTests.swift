import Foundation
@testable import RepoPromptApp
import RepoPromptProviderQuota
import RepoPromptSettingsCore
import XCTest

@MainActor
final class ModelRouterSettingsPersistenceTests: XCTestCase {
    func testRouterContentRequiresSchemaV9AndRoundTripsUnknownRaws() throws {
        let router = GlobalScalarPreferences.ModelRouterSettings(
            enabled: true,
            selectedBackendRawValue: "future-router",
            candidateRoleRawValues: ["explore", "future-role"],
            allowedProviderRawValues: ["codexExec", "future-provider"]
        )
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: router))
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.modelRouterSchemaVersion)
        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 10)
        let decoded = try JSONDecoder().decode(GlobalSettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.scalarPreferences?.modelRouter, router)
    }

    func testScopedProviderPolicyAndGuidanceRequireSchemaV10AndRoundTrip() throws {
        let router = GlobalScalarPreferences.ModelRouterSettings(
            enabled: true,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "engineer"],
            allowedProviderRawValues: ["codexExec", "claudeCode"],
            primaryProviderRawValue: "codexExec",
            subagentProviderRawValue: "claudeCode",
            customInstructions: "Prefer Claude Opus for execution."
        )
        let document = GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: router))
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.scopedModelRouterSchemaVersion)
        let decoded = try JSONDecoder().decode(GlobalSettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.scalarPreferences?.modelRouter, router)
    }

    func testStoreWritesV9AndPreservesUnknownSiblingsDuringKnownEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "future-role"],
            allowedProviderRawValues: ["codexExec", "future-provider"]
        ))
        try fileStore.save(document)

        var rawRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileStore.fileURL)) as? [String: Any])
        var scalarPreferences = try XCTUnwrap(rawRoot["scalarPreferences"] as? [String: Any])
        var rawRouter = try XCTUnwrap(scalarPreferences["modelRouter"] as? [String: Any])
        rawRouter["futurePolicy"] = ["mode": "strict"]
        scalarPreferences["modelRouter"] = rawRouter
        rawRoot["scalarPreferences"] = scalarPreferences
        try JSONSerialization.data(withJSONObject: rawRoot, options: [.prettyPrinted, .sortedKeys])
            .write(to: fileStore.fileURL, options: .atomic)
        XCTAssertThrowsError(try FrozenV130GlobalSettingsDocument.load(from: fileStore.fileURL)) { error in
            XCTAssertEqual(
                error as? FrozenV130GlobalSettingsDocument.CompatibilityError,
                .unsupportedFutureSchema(GlobalSettingsDocument.modelRouterSchemaVersion)
            )
        }

        let suite = "ModelRouterSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        store.setModelRouterCandidateRoles([.explore, .engineer])
        store.setModelRouterAllowedProviders([.codexExec, .claudeCode])

        let loaded = try fileStore.load()
        XCTAssertEqual(loaded.schemaVersion, 9)
        XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.candidateRoleRawValues, ["explore", "engineer", "future-role"])
        XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.allowedProviderRawValues, ["claudeCode", "codexExec", "future-provider"])
        let savedRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fileStore.fileURL)) as? [String: Any])
        let savedRouter = ((savedRoot["scalarPreferences"] as? [String: Any])?["modelRouter"] as? [String: Any])
        XCTAssertEqual((savedRouter?["futurePolicy"] as? [String: Any])?["mode"] as? String, "strict")
    }

    func testMissingRouterGroupRemainsBaselineSchema() {
        XCTAssertEqual(GlobalSettingsDocument().requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)
    }

    func testFirstEnableMaterializesAllOnlyFromUnmaterializedPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: nil,
            allowedProviderRawValues: nil
        ))
        try fileStore.save(document)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ModelRouter.first-enable.\(UUID())"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.codexExec, .claudeCode]
        )
        let raw = try XCTUnwrap(try fileStore.load().scalarPreferences?.modelRouter)
        XCTAssertEqual(Set(raw.candidateRoleRawValues ?? []), Set(AgentModelCatalog.TaskLabelKind.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(raw.allowedProviderRawValues ?? []), ["codexExec", "claudeCode"])
    }

    func testExplicitEmptyConsentSurvivesReloadAndVMDoesNotDefaultItToAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "future-role"],
            allowedProviderRawValues: ["codexExec", "future-provider"]
        ))
        try fileStore.save(document)
        let suite = "ModelRouter.explicit-empty.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: fileStore)
        store.setModelRouterCandidateRoles([])
        store.setModelRouterAllowedProviders([])

        let raw = try XCTUnwrap(try fileStore.load().scalarPreferences?.modelRouter)
        XCTAssertEqual(raw.candidateRoleRawValues, ["future-role"])
        XCTAssertEqual(raw.allowedProviderRawValues, ["future-provider"])

        let reloaded = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "\(suite).reload")),
            fileStore: fileStore
        ).modelRouterConfiguration()
        XCTAssertTrue(reloaded.candidateRolesMaterialized)
        XCTAssertTrue(reloaded.allowedProvidersMaterialized)
        XCTAssertTrue(reloaded.candidateRoles.isEmpty)
        XCTAssertTrue(reloaded.allowedProviders.isEmpty)
        XCTAssertTrue(RouterSettingsViewModel.effectiveRoles(reloaded).isEmpty)
        XCTAssertTrue(RouterSettingsViewModel.effectiveProviders(reloaded, available: [.codexExec]).isEmpty)
        XCTAssertEqual(reloaded.unknownRoleRawValues, ["future-role"])
        XCTAssertEqual(reloaded.unknownProviderRawValues, ["future-provider"])
    }

    func testNilConsentUsesFirstUseDefaultsWithoutMutatingStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GlobalSettingsStore(
            defaults: XCTUnwrap(UserDefaults(suiteName: "ModelRouter.nil-consent.\(UUID())")),
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.setModelRouterBackend(.jev)
        let configuration = store.modelRouterConfiguration()
        XCTAssertFalse(configuration.candidateRolesMaterialized)
        XCTAssertFalse(configuration.allowedProvidersMaterialized)
        XCTAssertEqual(RouterSettingsViewModel.effectiveRoles(configuration), Set(AgentModelCatalog.TaskLabelKind.allCases))
        XCTAssertEqual(
            RouterSettingsViewModel.effectiveProviders(configuration, available: [.codexExec, .claudeCode]),
            [.codexExec, .claudeCode]
        )
    }

    func testMaterializedProviderPolicyDoesNotAutoAuthorizeNewProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ModelRouter.new-provider.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: [.explore, .engineer],
            providers: [.codexExec]
        )
        XCTAssertEqual(store.modelRouterConfiguration().allowedProviders, [.codexExec])
        XCTAssertFalse(store.modelRouterConfiguration().allowedProviders.contains(.claudeCode))
    }

    func testDefaultsPersistenceAndBackgroundConsentDoNotChangeRoutingRevision() throws {
        try withUsageStore { store, file in
            XCTAssertFalse(store.modelRouterConfiguration().usageBalancing.enabled)
            XCTAssertEqual(store.modelRouterConfiguration().usageBalancing.preset, .evenPace)
            XCTAssertFalse(store.modelRouterConfiguration().allowPaidFastRouting)
            store.setUsageBalancingEnabled(true)
            store.setUsageBalancingPreset(.expiringQuota)
            store.setAllowPaidFastRouting(true)
            let revision = store.modelRouterSettingsRevision
            let grant = ClaudeCLIUsageGrant(credentialProfileID: "fixture", grantedAt: Date(timeIntervalSince1970: 2_000_000_000))
            store.setClaudeBalancingRefreshGrant(grant)
            XCTAssertEqual(store.modelRouterSettingsRevision, revision, "Acquisition consent is not routing policy")
            let saved = try file.load()
            XCTAssertEqual(saved.scalarPreferences?.modelRouter?.usageBalancingPreset, "expiringQuota")
            XCTAssertEqual(saved.scalarPreferences?.modelRouter?.allowPaidFastRouting, true)
            for (old, current) in [("qualityFirst", AgentUsageBalancingPreset.nearLimits), ("balanced", .evenPace), ("favorLargerPlan", .expiringQuota)] {
                store.updateModelRouterScalar(commit: false) { $0.usageBalancingPreset = old }
                XCTAssertEqual(store.modelRouterConfiguration().usageBalancing.preset, current)
            }
            XCTAssertEqual(saved.scalarPreferences?.agentMode?.claudeBalancingRefreshGrant, grant)
            store.updateModelRouterScalar(commit: false) { $0.usageBalancingPreset = "future-policy" }
            XCTAssertFalse(store.modelRouterConfiguration().usageBalancing.enabled, "Unknown policies fail closed without discarding their raw values")
        }
    }

    func testOldGrantCompatibilityAndDeferredSetupAreExplicit() throws {
        let old = try JSONDecoder().decode(ClaudeCLIUsageGrant.self, from: Data(#"{"credentialProfileID":"fixture","grantedAt":0,"consentVersion":1}"#.utf8))
        XCTAssertTrue(old.isReady)
        let pending = ClaudeCLIUsageGrant(credentialProfileID: "fixture", grantedAt: Date(), setupCompleted: false)
        XCTAssertFalse(pending.isReady)
        let decoded = try JSONDecoder().decode(ClaudeCLIUsageGrant.self, from: JSONEncoder().encode(pending))
        XCTAssertFalse(decoded.isReady, "Pending setup must not become ready on reboot")
    }

    func testRoutingLeasesAreDefaultOffAndRespectSetupAndProfileConsent() throws {
        try withUsageStore { store, file in
            let codex = CodexProviderQuotaService(clientFactory: { UsageNoIOClient() }, accountIDProvider: { nil })
            let claude = ProviderAccountQuotaService(periodicReads: false, read: { _ in throw ProviderQuotaReadError.needsConsent })
            let advisor = AgentUsageBalancer()
            var currentProfile = "fixture"
            let owner = ProviderUsageRoutingObservation(settings: store, codex: codex, claude: claude, advisor: advisor, accountID: { nil }, profileProvider: { currentProfile }, isAppActive: { false }, budgetURL: file.fileURL.deletingLastPathComponent().appendingPathComponent("budget.json"))
            XCTAssertFalse(owner.hasObserverDemand)
            XCTAssertFalse(store.modelRouterConfiguration().enabled)
            store.setUsageBalancingEnabled(true)
            XCTAssertTrue(store.setModelRouterCustomInstructions("Prefer Claude for execution"))
            store.setClaudeCLIUsageGrant(.init(credentialProfileID: "fixture", grantedAt: Date(), setupCompleted: false), commit: false)
            advisor.onRoutingActivity?()
            XCTAssertFalse(owner.hasObserverDemand, "Grant alone cannot bypass deferred trust/setup")
            store.setClaudeCLIUsageGrant(.init(credentialProfileID: "fixture", grantedAt: Date()), commit: false)
            advisor.onRoutingActivity?()
            XCTAssertTrue(owner.hasObserverDemand)
            currentProfile = "different-profile"
            advisor.onRoutingActivity?()
            XCTAssertFalse(owner.hasObserverDemand)
            currentProfile = "fixture"
            advisor.onRoutingActivity?()
            XCTAssertTrue(owner.hasObserverDemand)
            store.setClaudeCLIUsageGrant(nil, commit: false)
            advisor.onRoutingActivity?()
            XCTAssertFalse(owner.hasObserverDemand, "Revocation is independent of presentation visibility")
            withExtendedLifetime(owner) {}
        }
    }

    func testRandomnessAndReviewDiversityPersist() throws {
        try withUsageStore { store, file in
            store.updateModelRouterScalar(commit: true) {
                $0.enabled = true
                $0.selectedBackendRawValue = "jev"
                $0.candidateRoleRawValues = ["explore", "engineer"]
            }
            store.setUsageBalancingPreset(.expiringQuota)
            store.setAllowPaidFastRouting(true)
            let levels: [(AgentRoutingRandomness, String)] = [(.low, "low"), (.medium, "medium"), (.high, "high"), (.off, "off")]
            for (level, raw) in levels {
                let revision = store.modelRouterSettingsRevision
                store.setRandomness(level)
                let router = try rawModelRouter(file)
                XCTAssertEqual(router["randomness"] as? String, raw, "persisted randomness raw for \(raw)")
                XCTAssertEqual(try file.load().scalarPreferences?.modelRouter?.randomness, raw, "typed load randomness for \(raw)")
                XCTAssertEqual(store.modelRouterConfiguration().randomness, level, "in-memory configuration randomness for \(raw)")
                XCTAssertEqual(try reloadedStore(file).modelRouterConfiguration().randomness, level, "reloaded store randomness for \(raw)")
                XCTAssertEqual(AgentRoutingRandomness.stored(raw), level, "enum exact match for \(raw)")
                XCTAssertEqual(store.modelRouterSettingsRevision, revision &+ 1, "revision bumps once for distinct randomness change \(raw)")
                let changedRevision = store.modelRouterSettingsRevision
                store.setRandomness(level)
                XCTAssertEqual(store.modelRouterSettingsRevision, changedRevision, "identical randomness repeat does not bump revision")
                XCTAssertEqual(router["enabled"] as? Bool, true)
                XCTAssertEqual(router["selectedBackendRawValue"] as? String, "jev")
                XCTAssertEqual(router["candidateRoleRawValues"] as? [String], ["explore", "engineer"])
                XCTAssertEqual(router["usageBalancingPreset"] as? String, "expiringQuota")
                XCTAssertEqual(router["allowPaidFastRouting"] as? Bool, true)
                XCTAssertEqual(try file.load().schemaVersion, GlobalSettingsDocument.modelRouterSchemaVersion)
            }
            for enabled in [true, false] {
                let revision = store.modelRouterSettingsRevision
                store.setReviewDiversityEnabled(enabled)
                let router = try rawModelRouter(file)
                XCTAssertEqual(router["reviewDiversityEnabled"] as? Bool, enabled, "persisted review diversity raw for \(enabled)")
                XCTAssertEqual(try file.load().scalarPreferences?.modelRouter?.reviewDiversityEnabled, enabled, "typed load review diversity for \(enabled)")
                XCTAssertEqual(store.modelRouterConfiguration().reviewDiversityEnabled, enabled, "in-memory configuration review diversity for \(enabled)")
                XCTAssertEqual(try reloadedStore(file).modelRouterConfiguration().reviewDiversityEnabled, enabled, "reloaded store review diversity for \(enabled)")
                XCTAssertEqual(store.modelRouterSettingsRevision, revision &+ 1, "revision bumps once for distinct review diversity change \(enabled)")
                let changedRevision = store.modelRouterSettingsRevision
                store.setReviewDiversityEnabled(enabled)
                XCTAssertEqual(store.modelRouterSettingsRevision, changedRevision, "identical review diversity repeat does not bump revision")
                XCTAssertEqual(router["randomness"] as? String, "off")
                XCTAssertEqual(store.modelRouterConfiguration().randomness, .off)
                XCTAssertEqual(router["enabled"] as? Bool, true)
                XCTAssertEqual(router["selectedBackendRawValue"] as? String, "jev")
                XCTAssertEqual(router["candidateRoleRawValues"] as? [String], ["explore", "engineer"])
                XCTAssertEqual(router["usageBalancingPreset"] as? String, "expiringQuota")
                XCTAssertEqual(router["allowPaidFastRouting"] as? Bool, true)
                XCTAssertEqual(try file.load().schemaVersion, GlobalSettingsDocument.modelRouterSchemaVersion)
            }
            store.setModelRouterProvider(.codexExec, scope: .primarySession)
            XCTAssertEqual(try file.load().schemaVersion, GlobalSettingsDocument.scopedModelRouterSchemaVersion)
            store.setRandomness(.high)
            store.setReviewDiversityEnabled(true)
            let router = try rawModelRouter(file)
            let loaded = try file.load()
            let configuration = store.modelRouterConfiguration()
            let reloaded = try reloadedStore(file).modelRouterConfiguration()
            XCTAssertEqual(router["randomness"] as? String, "high")
            XCTAssertEqual(router["reviewDiversityEnabled"] as? Bool, true)
            XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.randomness, "high")
            XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.reviewDiversityEnabled, true)
            XCTAssertEqual(configuration.randomness, .high)
            XCTAssertTrue(configuration.reviewDiversityEnabled)
            XCTAssertEqual(reloaded.randomness, .high)
            XCTAssertTrue(reloaded.reviewDiversityEnabled)
            XCTAssertEqual(router["primaryProviderRawValue"] as? String, "codexExec")
            XCTAssertEqual(loaded.scalarPreferences?.modelRouter?.primaryProviderRawValue, "codexExec")
            XCTAssertEqual(configuration.primaryProvider, .codexExec)
            XCTAssertEqual(loaded.schemaVersion, GlobalSettingsDocument.scopedModelRouterSchemaVersion)
        }
    }

    func testPreChangeSettingsReadOverrideDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        var router = GlobalScalarPreferences.ModelRouterSettings(
            enabled: true,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["explore", "engineer"],
            allowedProviderRawValues: ["codexExec", "claudeCode"]
        )
        router.usageBalancingEnabled = true
        router.usageBalancingPreset = "nearLimits"
        router.allowPaidFastRouting = true
        try file.save(GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: router)))
        let raw = try rawModelRouter(file)
        XCTAssertNil(raw["randomness"], "pre-change file has no randomness key")
        XCTAssertNil(raw["reviewDiversityEnabled"], "pre-change file has no review diversity key")
        XCTAssertEqual(try file.load().schemaVersion, GlobalSettingsDocument.modelRouterSchemaVersion)
        let store = try reloadedStore(file)
        let configuration = store.modelRouterConfiguration()
        XCTAssertEqual(configuration.randomness, .off, "missing randomness reads off")
        XCTAssertFalse(configuration.reviewDiversityEnabled, "missing review diversity reads false")
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.selectedBackendID, .jev)
        XCTAssertEqual(configuration.candidateRoles, [.explore, .engineer])
        XCTAssertEqual(configuration.allowedProviders, [.codexExec, .claudeCode])
        XCTAssertTrue(configuration.usageBalancing.enabled)
        XCTAssertEqual(configuration.usageBalancing.preset, .nearLimits)
        XCTAssertTrue(configuration.allowPaidFastRouting)
        let revision = store.modelRouterSettingsRevision
        store.setUsageBalancingPreset(.evenPace)
        let edited = try rawModelRouter(file)
        XCTAssertNil(edited["randomness"], "sibling edit does not materialize defaults: randomness")
        XCTAssertNil(edited["reviewDiversityEnabled"], "sibling edit does not materialize defaults: review diversity")
        XCTAssertEqual(edited["usageBalancingPreset"] as? String, "evenPace")
        XCTAssertEqual(store.modelRouterSettingsRevision, revision &+ 1)
        XCTAssertEqual(try file.load().schemaVersion, GlobalSettingsDocument.modelRouterSchemaVersion)
    }

    func testUnknownRandomnessReadsOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        let router = GlobalScalarPreferences.ModelRouterSettings(enabled: false, selectedBackendRawValue: "jev")
        try file.save(GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: router)))
        try patchRawModelRouter(file) { $0["randomness"] = "medium" }
        XCTAssertEqual(try reloadedStore(file).modelRouterConfiguration().randomness, .medium, "known raw medium decodes to medium")
        try patchRawModelRouter(file) { $0["reviewDiversityEnabled"] = true }
        XCTAssertTrue(try reloadedStore(file).modelRouterConfiguration().reviewDiversityEnabled, "only literal true enables: true")
        try patchRawModelRouter(file) { $0["reviewDiversityEnabled"] = false }
        XCTAssertFalse(try reloadedStore(file).modelRouterConfiguration().reviewDiversityEnabled, "only literal true enables: false")
        for raw in ["future-level", "High", " low", "", "extreme"] {
            try patchRawModelRouter(file) {
                $0["randomness"] = raw
                $0.removeValue(forKey: "reviewDiversityEnabled")
            }
            let store = try reloadedStore(file)
            XCTAssertEqual(store.modelRouterConfiguration().randomness, .off, "unknown randomness reads off: \(raw)")
            XCTAssertFalse(store.modelRouterConfiguration().reviewDiversityEnabled)
            XCTAssertEqual(AgentRoutingRandomness.stored(raw), .off)
            store.setUsageBalancingPreset(.nearLimits)
            let edited = try rawModelRouter(file)
            XCTAssertEqual(edited["randomness"] as? String, raw, "sibling edit preserves unknown randomness raw: \(raw)")
            XCTAssertEqual(edited["usageBalancingPreset"] as? String, "nearLimits")
            store.setRandomness(.low)
            XCTAssertEqual(try rawModelRouter(file)["randomness"] as? String, "low", "explicit setter overwrites unknown raw: \(raw)")
            XCTAssertEqual(store.modelRouterConfiguration().randomness, .low)
        }
    }

    private func rawModelRouter(_ file: GlobalSettingsFileStore) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
        let preferences = try XCTUnwrap(root["scalarPreferences"] as? [String: Any])
        return try XCTUnwrap(preferences["modelRouter"] as? [String: Any])
    }

    private func patchRawModelRouter(_ file: GlobalSettingsFileStore, _ patch: (inout [String: Any]) -> Void) throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file.fileURL)) as? [String: Any])
        var preferences = try XCTUnwrap(root["scalarPreferences"] as? [String: Any])
        var router = try XCTUnwrap(preferences["modelRouter"] as? [String: Any])
        patch(&router)
        preferences["modelRouter"] = router
        root["scalarPreferences"] = preferences
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: file.fileURL, options: .atomic)
    }

    private func reloadedStore(_ file: GlobalSettingsFileStore) throws -> GlobalSettingsStore {
        let suite = "ModelRouterSettingsPersistenceTests.reload.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return GlobalSettingsStore(defaults: defaults, fileStore: file)
    }

    private func withUsageStore(_ body: (GlobalSettingsStore, GlobalSettingsFileStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ModelRouterSettingsPersistenceTests.usage.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        let store = GlobalSettingsStore(defaults: defaults, fileStore: file)
        try body(store, file)
    }

    private actor UsageNoIOClient: CodexQuotaAppServerClient {
        func startIfNeeded() throws {
            XCTFail("Default-off observer must never start a provider")
        }

        func subscribeNotifications() -> AsyncStream<CodexQuotaNotification> {
            AsyncStream { $0.finish() }
        }

        func request(method _: String, params _: [String: CodexJSONValue]?, timeout _: TimeInterval?) throws -> [String: CodexJSONValue] {
            throw ProviderQuotaReadError.transport
        }

        func stop() {}
    }
}
