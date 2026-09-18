@testable import RepoPromptApp
import XCTest

/// Regression coverage for the Grok (`grok`) MCP client identity.
///
/// Unlike `agy` (which is Gemini-derived and may announce a `gemini*` clientInfo.name over MCP),
/// `grok` (xAI's Grok CLI) is an independent client. RepoPrompt still does not rely on grok's
/// announced name for routing — it uses PID-based routing keyed on the explicit "grok-client"
/// hint (`AgentProviderKind.grokMCPClientID`, surfaced via `AgentProviderKind.mcpClientNameHint`,
/// and registered by `GrokAgentProvider` via expected-PID routing). These tests lock in that the
/// explicit "grok-client" hint RepoPrompt uses for PID-based routing canonicalizes to the grok
/// family and is recognized as a known headless agent client, independent of whatever name
/// `grok` announces over MCP.
final class GrokMCPClientIdentityTests: XCTestCase {
    /// The hint RepoPrompt registers for grok (`AgentProviderKind.grokMCPClientID`).
    private let grokClientID = "grok-client"

    func testGrokClientCanonicalizesToGrokFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID(grokClientID), "grok-client")
    }

    func testBareGrokNameCanonicalizesToGrokFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok"), "grok-client")
    }

    func testGrokAnnouncedShellNameCanonicalizesToGrokFamily() {
        // Shell announcements retain the historical storage identity while matching the headless hint.
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell-RepoPromptCE"), "grok-shell")
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell-SomeOtherServer"), "grok-shell")
        XCTAssertTrue(MCPClientIdentity.matches("grok-client", "grok-shell-RepoPromptCE"))
    }

    func testNonGrokPrefixIsNotMisclassifiedAsGrok() {
        // A word that merely starts with the letters "grok" but is not a separated leading token
        // must NOT be swallowed into the grok family.
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("grokkenstein"))
    }

    func testGrokMCPClientIDHintMatchesGrokClientID() {
        // The provider kind's MCP client hint is the exact "grok-client" string these tests pin.
        XCTAssertEqual(AgentProviderKind.grokMCPClientID, grokClientID)
        XCTAssertEqual(AgentProviderKind.grok.mcpClientNameHint, grokClientID)
    }

    func testGrokClientIsRecognizedAsHeadlessAgentClient() {
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient(grokClientID))
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("grok-shell"))
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient("grok-shell-RepoPromptCE"))
    }

    func testGrokStorageKeysRemainStableAcrossFamilyAliases() {
        for (name, expectedKey) in [
            ("grok-shell", "grok-shell"),
            ("grok-shell-RepoPromptCE", "grok-shell"),
            ("  GROK-SHELL-SomeOtherServer  ", "grok-shell"),
            ("grok", "grok-client"),
            ("grok-client", "grok-client"),
            ("grok v1.0.3", "grok-client"),
            ("grok-client/1.0.3", "grok-client")
        ] {
            XCTAssertEqual(MCPClientIdentity.storageKey(name), expectedKey, name)
        }
    }

    func testGrokShellAndClientAreSymmetricFamilyAliases() {
        for name in ["grok-shell", "grok-shell-RepoPromptCE", "grok-shell-SomeOtherServer"] {
            XCTAssertTrue(MCPClientIdentity.matches(name, grokClientID), name)
            XCTAssertTrue(MCPClientIdentity.matches(grokClientID, name), name)
            XCTAssertTrue(MCPClientIdentity.sameFamily(name, grokClientID), name)
            XCTAssertTrue(MCPClientIdentity.sameFamily(grokClientID, name), name)
            XCTAssertTrue(MCPClientIdentity.sameFamily(name, "grok v1.0.3"), name)
            XCTAssertFalse(MCPClientIdentity.matches(name, "cursor"), name)
            XCTAssertFalse(MCPClientIdentity.sameFamily(name, "antigravity-client"), name)
        }
    }

    func testGrokClientIsNotMisclassifiedAsAnotherFamily() {
        // The explicit "grok-client" hint must resolve to its own grok family and must never be
        // swallowed by another known client family (e.g. the gemini-cli branch).
        XCTAssertNotEqual(MCPClientIdentity.canonicalFamilyID(grokClientID), "gemini-cli-mcp-client")
        XCTAssertNotEqual(MCPClientIdentity.canonicalFamilyID(grokClientID), "antigravity-client")
    }

    func testGrokClientMatchesItselfAndBareGrok() {
        XCTAssertTrue(MCPClientIdentity.matches(grokClientID, grokClientID))
        XCTAssertTrue(MCPClientIdentity.matches(grokClientID, "grok"))
        XCTAssertTrue(MCPClientIdentity.sameFamily(grokClientID, "grok"))
    }
}
