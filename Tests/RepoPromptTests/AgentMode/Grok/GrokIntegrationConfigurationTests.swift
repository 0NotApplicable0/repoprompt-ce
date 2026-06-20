@testable import RepoPrompt
import XCTest

/// Tests for grok's TOML MCP config management (`~/.grok/config.toml`,
/// `[mcp_servers.RepoPromptCE]`). Mirrors the agy integration-config tests but targets grok's
/// surgical TOML section manager instead of the gemini JSON map.
final class GrokIntegrationConfigurationTests: XCTestCase {
    func testConfigURLIsHomeLevelGrokConfigToml() {
        let url = GrokIntegrationConfiguration.configURL()
        XCTAssertTrue(url.path.hasSuffix(".grok/config.toml"), "unexpected path: \(url.path)")
    }

    func testMergedContentOnEmptyAddsRepoPromptSection() {
        let merged = GrokIntegrationConfiguration.mergedContent(existingContent: nil)
        XCTAssertFalse(merged.wasMCPServerAlreadyPresent)
        XCTAssertTrue(merged.content.contains(GrokIntegrationConfiguration.sectionHeader))
        XCTAssertTrue(merged.content.contains("command ="))
        XCTAssertTrue(merged.content.contains("enabled = true"))
        XCTAssertTrue(merged.content.contains("startup_timeout_sec = \(GrokIntegrationConfiguration.startupTimeoutSeconds)"))
    }

    func testMergedContentPreservesOtherServersAndContent() {
        let existing = """
        [cli]
        installer = "internal"

        [mcp_servers.other]
        command = "/usr/bin/other"
        enabled = true
        """
        let merged = GrokIntegrationConfiguration.mergedContent(existingContent: existing)
        XCTAssertFalse(merged.wasMCPServerAlreadyPresent)
        XCTAssertTrue(merged.content.contains("[mcp_servers.other]"), "other server dropped")
        XCTAssertTrue(merged.content.contains("[cli]"), "unrelated section dropped")
        XCTAssertTrue(merged.content.contains(GrokIntegrationConfiguration.sectionHeader))
    }

    func testMergedContentIsIdempotentAndReportsAlreadyPresent() {
        let first = GrokIntegrationConfiguration.mergedContent(existingContent: nil)
        let second = GrokIntegrationConfiguration.mergedContent(existingContent: first.content)
        XCTAssertTrue(second.wasMCPServerAlreadyPresent)
        XCTAssertEqual(first.content, second.content, "re-merge must be stable (no duplicate section)")
        // Exactly one RepoPrompt section header.
        let occurrences = second.content.components(separatedBy: GrokIntegrationConfiguration.sectionHeader).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testContentRemovingRepoPromptStripsOurSectionAndPreservesRest() {
        let existing = """
        [mcp_servers.other]
        command = "/usr/bin/other"
        enabled = true

        """ + GrokIntegrationConfiguration.mcpSectionString(for: .repoPrompt) + "\n"
        let removed = GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: existing)
        XCTAssertNotNil(removed)
        XCTAssertTrue(removed!.wasMCPServerPresent)
        XCTAssertFalse(removed!.content.contains(GrokIntegrationConfiguration.sectionHeader))
        XCTAssertTrue(removed!.content.contains("[mcp_servers.other]"), "unrelated server must survive removal")
    }

    func testContentRemovingRepoPromptNilOnEmpty() {
        XCTAssertNil(GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: nil))
        XCTAssertNil(GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: ""))
    }

    func testMergeThenRemoveRoundTrips() {
        let merged = GrokIntegrationConfiguration.mergedContent(existingContent: nil)
        let removed = GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: merged.content)
        XCTAssertNotNil(removed)
        XCTAssertFalse(removed!.content.contains(GrokIntegrationConfiguration.sectionHeader))
    }

    func testRemoveStripsDescendantTables() {
        let existing = """
        [mcp_servers.other]
        command = "/usr/bin/other"

        """ + GrokIntegrationConfiguration.mcpSectionString(for: .repoPrompt) + "\n" + """
        [mcp_servers.RepoPromptCE.env]
        FOO = "bar"

        [mcp_servers.keep]
        command = "/usr/bin/keep"
        """
        let removed = GrokIntegrationConfiguration.contentRemovingRepoPrompt(existingContent: existing)
        XCTAssertNotNil(removed)
        XCTAssertTrue(removed!.wasMCPServerPresent)
        XCTAssertFalse(removed!.content.contains(GrokIntegrationConfiguration.sectionHeader))
        XCTAssertFalse(removed!.content.contains("[mcp_servers.RepoPromptCE.env]"), "descendant table must be removed with its parent")
        XCTAssertFalse(removed!.content.contains("FOO = \"bar\""))
        XCTAssertTrue(removed!.content.contains("[mcp_servers.keep]"), "unrelated server after descendant must survive")
        XCTAssertTrue(removed!.content.contains("[mcp_servers.other]"))
    }
}
