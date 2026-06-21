@testable import RepoPrompt
import XCTest

/// Regression coverage for the Antigravity (`agy`) MCP client identity.
///
/// `MCPClientIdentity.canonicalFamilyID` matches the gemini-cli family *before* antigravity by
/// ordering (intentional — see the note in `MCPClientIdentity.swift`). These tests lock in that
/// the explicit "antigravity-client" hint RepoPrompt uses for PID-based routing canonicalizes to
/// the antigravity family and is recognized as a known headless agent client, independent of
/// whatever (possibly gemini-derived) name `agy` announces over MCP.
final class AntigravityMCPClientIdentityTests: XCTestCase {
    /// The hint RepoPrompt registers for agy (AgentProviderKind.antigravityMCPClientID).
    private let antigravityClientID = "antigravity-client"

    func testAntigravityClientCanonicalizesToAntigravityFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID(antigravityClientID), "antigravity-client")
    }

    func testBareAntigravityNameCanonicalizesToAntigravityFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("antigravity"), "antigravity-client")
    }

    func testAntigravityClientIsRecognizedAsHeadlessAgentClient() {
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient(antigravityClientID))
    }

    func testAntigravityClientIsNotMisclassifiedAsGeminiDespiteOrdering() {
        // Even though gemini-cli is matched before antigravity, the explicit "antigravity-client"
        // hint must not be swallowed by the gemini branch.
        XCTAssertNotEqual(MCPClientIdentity.canonicalFamilyID(antigravityClientID), "gemini-cli-mcp-client")
    }

    func testAntigravityClientMatchesItselfAndBareAntigravity() {
        XCTAssertTrue(MCPClientIdentity.matches(antigravityClientID, antigravityClientID))
        XCTAssertTrue(MCPClientIdentity.matches(antigravityClientID, "antigravity"))
        XCTAssertTrue(MCPClientIdentity.sameFamily(antigravityClientID, "antigravity"))
    }
}
