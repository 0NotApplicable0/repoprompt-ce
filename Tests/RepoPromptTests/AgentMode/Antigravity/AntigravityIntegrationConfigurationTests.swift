@testable import RepoPrompt
import XCTest

final class AntigravityIntegrationConfigurationTests: XCTestCase {
    private var serverName: String {
        AntigravityIntegrationConfiguration.repoPromptMCPServerName
    }

    func testMcpConfigDictHasStdioShape() {
        let dict = AntigravityIntegrationConfiguration.mcpConfigDict()
        XCTAssertNotNil(dict["command"] as? String)
        XCTAssertNotNil(dict["args"] as? [String])
    }

    func testConfigPathIsHomeLevelGeminiConfig() {
        let path = AntigravityIntegrationConfiguration.configURL().path
        XCTAssertTrue(path.hasSuffix(".gemini/config/mcp_config.json"), path)
    }

    func testMergeIntoMissingConfigAddsServer() {
        let (root, wasPresent) = AntigravityIntegrationConfiguration.mergedRoot(existingData: nil)
        XCTAssertFalse(wasPresent)
        let servers = root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?[serverName])
    }

    func testMergePreservesExistingUserServers() {
        let existing = Data("{\"mcpServers\":{\"other\":{\"command\":\"x\",\"args\":[]}}}".utf8)
        let (root, wasPresent) = AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)
        XCTAssertFalse(wasPresent)
        let servers = root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["other"], "existing user server must be preserved")
        XCTAssertNotNil(servers?[serverName])
    }

    func testMergeDetectsExistingRepoPromptEntry() {
        let existing = Data("{\"mcpServers\":{\"\(serverName)\":{\"command\":\"old\",\"args\":[]}}}".utf8)
        let (_, wasPresent) = AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)
        XCTAssertTrue(wasPresent)
    }

    func testMergeReplacesCaseVariantRepoPromptKeyWithoutDuplicating() {
        // An existing entry under a differently-cased variant of our canonical key must be
        // treated as present and replaced in place — not duplicated alongside the canonical
        // casing, which would leave agy with two RepoPrompt servers.
        let casedVariant = serverName.uppercased()
        XCTAssertNotEqual(casedVariant, serverName, "test requires a casing that actually differs")
        let existing = Data("{\"mcpServers\":{\"\(casedVariant)\":{\"command\":\"old\",\"args\":[]}}}".utf8)
        let (root, wasPresent) = AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)
        XCTAssertTrue(wasPresent)
        let servers = root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?[serverName], "canonical-cased key must be present")
        XCTAssertNil(servers?[casedVariant], "case-variant key must be removed, not kept alongside")
        XCTAssertEqual(servers?.count, 1, "exactly one RepoPrompt server should remain")
    }

    func testZeroByteConfigTreatedAsEmpty() {
        let (root, wasPresent) = AntigravityIntegrationConfiguration.mergedRoot(existingData: Data())
        XCTAssertFalse(wasPresent)
        let servers = root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?[serverName])
    }

    func testGarbageConfigTreatedAsEmpty() {
        let (root, _) = AntigravityIntegrationConfiguration.mergedRoot(existingData: Data("not json {{{".utf8))
        let servers = root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?[serverName])
    }

    func testMergePreservesUnknownTopLevelKeys() {
        let existing = Data("{\"unknownKey\":123,\"mcpServers\":{}}".utf8)
        let (root, _) = AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)
        XCTAssertEqual(root["unknownKey"] as? Int, 123)
    }

    // MARK: - removeInstallEntry (pure merge)

    func testRemoveRepoPromptKeepsOtherServers() {
        let existing = Data("{\"mcpServers\":{\"\(serverName)\":{\"command\":\"x\",\"args\":[]},\"other\":{\"command\":\"y\",\"args\":[]}}}".utf8)
        let result = AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: existing)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.wasMCPServerPresent == true)
        let servers = result?.root["mcpServers"] as? [String: Any]
        XCTAssertNil(servers?[serverName], "RepoPrompt entry must be removed")
        XCTAssertNotNil(servers?["other"], "unrelated user server must be preserved")
    }

    func testRemoveRepoPromptIsCaseInsensitive() {
        let casedVariant = serverName.uppercased()
        XCTAssertNotEqual(casedVariant, serverName)
        let existing = Data("{\"mcpServers\":{\"\(casedVariant)\":{\"command\":\"x\",\"args\":[]}}}".utf8)
        let result = AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: existing)
        XCTAssertTrue(result?.wasMCPServerPresent == true)
        let servers = result?.root["mcpServers"] as? [String: Any]
        XCTAssertNil(servers?[casedVariant], "case-variant RepoPrompt key must be removed")
        XCTAssertTrue(servers?.isEmpty == true)
    }

    func testRemoveRepoPromptPreservesUnknownTopLevelKeys() {
        let existing = Data("{\"unknownKey\":7,\"mcpServers\":{\"\(serverName)\":{\"command\":\"x\",\"args\":[]}}}".utf8)
        let result = AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: existing)
        XCTAssertEqual(result?.root["unknownKey"] as? Int, 7)
    }

    func testRemoveRepoPromptAbsentEntryReportsNotPresent() {
        let existing = Data("{\"mcpServers\":{\"other\":{\"command\":\"y\",\"args\":[]}}}".utf8)
        let result = AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: existing)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.wasMCPServerPresent ?? true)
    }

    func testRemoveRepoPromptNilOnMissingOrGarbageConfig() {
        XCTAssertNil(AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: nil))
        XCTAssertNil(AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: Data()))
        XCTAssertNil(AntigravityIntegrationConfiguration.rootRemovingRepoPrompt(existingData: Data("not json {{{".utf8)))
    }
}
