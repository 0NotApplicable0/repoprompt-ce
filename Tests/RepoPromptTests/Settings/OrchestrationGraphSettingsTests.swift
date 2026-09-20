import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class OrchestrationGraphSettingsTests: XCTestCase {
    func testCatalogExposesOrchestrationGraphFlagAsUserFacingBoolean() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestrationGraphSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "OrchestrationGraphSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let service = AppSettingsMCPService(store: store)
        let key = "ui.orchestration_graph_enabled"

        let listed = try await service.handleForTesting([
            "op": .string("list"),
            "group": .string("ui"),
            "detailed": .bool(true)
        ])
        let settings = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue)
        let catalog = try XCTUnwrap(settings.first { $0.objectValue?["key"]?.stringValue == key })
        XCTAssertEqual(catalog.objectValue?["type"]?.stringValue, "boolean")
        XCTAssertEqual(catalog.objectValue?["value"]?.boolValue, false)
    }

    func testFlagRoundTripsFalseTrueFalseThroughAppSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestrationGraphSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "OrchestrationGraphSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        let service = AppSettingsMCPService(store: store)
        let key = "ui.orchestration_graph_enabled"

        let getDefault = try await service.handleForTesting([
            "op": .string("get"),
            "key": .string(key)
        ])
        XCTAssertEqual(getDefault.objectValue?["values"]?.objectValue?[key]?.boolValue, false)

        let setTrue = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(true)
        ])
        XCTAssertEqual(setTrue.objectValue?["old_value"]?.boolValue, false)
        XCTAssertEqual(setTrue.objectValue?["new_value"]?.boolValue, true)
        XCTAssertEqual(setTrue.objectValue?["changed"]?.boolValue, true)
        XCTAssertTrue(store.orchestrationGraphEnabled())

        let reloadedAfterTrue = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertTrue(reloadedAfterTrue.orchestrationGraphEnabled())

        let setFalse = try await service.handleForTesting([
            "op": .string("set"),
            "key": .string(key),
            "value": .bool(false)
        ])
        XCTAssertEqual(setFalse.objectValue?["old_value"]?.boolValue, true)
        XCTAssertEqual(setFalse.objectValue?["new_value"]?.boolValue, false)
        XCTAssertEqual(setFalse.objectValue?["changed"]?.boolValue, true)
        XCTAssertFalse(store.orchestrationGraphEnabled())

        let reloadedAfterFalse = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertFalse(reloadedAfterFalse.orchestrationGraphEnabled())
    }

    func testMissingKeyDefaultsToFalse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestrationGraphSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "OrchestrationGraphSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")

        // Hand-write the on-disk document before any GlobalSettingsStore exists: scalarPreferences.ui
        // exists (via an unrelated key) but has no "orchestrationGraphEnabled" member, so the member is
        // absent, not merely false.
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument())
        var rootJSON = try readSettingsJSON(at: fileURL)
        var scalarPreferences = (rootJSON["scalarPreferences"] as? [String: Any]) ?? [:]
        scalarPreferences["ui"] = ["showTooltips": false]
        rootJSON["scalarPreferences"] = scalarPreferences
        try writeSettingsJSON(rootJSON, to: fileURL)

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertFalse(store.orchestrationGraphEnabled())

        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertFalse(reloaded.orchestrationGraphEnabled())
    }

    func testPersistedJSONKeyPinsTheFlag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchestrationGraphSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "OrchestrationGraphSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileURL = root.appendingPathComponent("globalSettings.json")

        // Before any GlobalSettingsStore exists: produce a valid on-disk document through the
        // lower-level file store, then hand-write the raw JSON key under test onto it. This is
        // the assertion an aliased accessor (e.g. pointed at showDatesInMessageTimestamps)
        // cannot survive: it names the key on disk, not just the typed struct round trip.
        let fileStore = GlobalSettingsFileStore(fileURL: fileURL)
        try fileStore.save(GlobalSettingsDocument())
        var rootJSON = try readSettingsJSON(at: fileURL)
        var scalarPreferences = (rootJSON["scalarPreferences"] as? [String: Any]) ?? [:]
        scalarPreferences["ui"] = ["orchestrationGraphEnabled": true]
        rootJSON["scalarPreferences"] = scalarPreferences
        try writeSettingsJSON(rootJSON, to: fileURL)

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertTrue(store.orchestrationGraphEnabled())
    }

    private func readSettingsJSON(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func writeSettingsJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
