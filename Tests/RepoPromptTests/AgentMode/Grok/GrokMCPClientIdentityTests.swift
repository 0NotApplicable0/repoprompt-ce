@testable import RepoPrompt
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

    func testGrokMCPClientIDHintMatchesGrokClientID() {
        // The provider kind's MCP client hint is the exact "grok-client" string these tests pin.
        XCTAssertEqual(AgentProviderKind.grokMCPClientID, grokClientID)
        XCTAssertEqual(AgentProviderKind.grok.mcpClientNameHint, grokClientID)
    }

    func testGrokClientIsRecognizedAsHeadlessAgentClient() {
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient(grokClientID))
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
