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

        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        // Force scalarPreferences.ui to exist (via an unrelated UI setting) without ever
        // setting orchestrationGraphEnabled, so the member is absent, not merely false.
        store.setShowTooltips(false)
        XCTAssertFalse(store.orchestrationGraphEnabled())

        let reloaded = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL)
        )
        XCTAssertFalse(reloaded.orchestrationGraphEnabled())
    }
}
