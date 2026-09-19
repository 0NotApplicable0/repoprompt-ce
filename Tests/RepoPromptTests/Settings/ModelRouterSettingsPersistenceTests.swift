import Foundation
@testable import RepoPromptApp
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
        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 9)
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

    func testFirstEnableMaterializesAllAndPreservesUnknownRaws() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileStore = GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        var document = GlobalSettingsDocument()
        document.scalarPreferences = GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: ["future-role"],
            allowedProviderRawValues: ["future-provider"]
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
        XCTAssertTrue(raw.candidateRoleRawValues?.contains("future-role") == true)
        XCTAssertTrue(raw.allowedProviderRawValues?.contains("future-provider") == true)
        XCTAssertEqual(Set(raw.allowedProviderRawValues ?? []), ["codexExec", "claudeCode", "future-provider"])
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
}
