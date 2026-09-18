import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class GrokBuildPermissionAndIdentityTests: XCTestCase {
    // MARK: - Permission option policy

    func testEnableAlwaysApproveIsNeverAutoSelectableForGrok() {
        XCTAssertFalse(
            ACPPermissionOptionPolicy.isAutoSelectable(optionID: "enable-always-approve", for: .grokBuild)
        )
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow-once", for: .grokBuild))
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow-edits-session", for: .grokBuild))
    }

    func testOtherProvidersHaveNoDenylistedOptions() {
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "enable-always-approve", for: .cursor))
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "anything", for: .openCode))
    }

    func testDenylistMatchingNormalizesCaseAndWhitespace() {
        XCTAssertFalse(
            ACPPermissionOptionPolicy.isAutoSelectable(optionID: "  Enable-Always-Approve ", for: .grokBuild)
        )
    }

    // MARK: - MCP client identity

    func testGrokShellFamilyMatchesLiveObservedClientName() {
        // Frozen fixture: captured from grok 1.0.3 connecting to an ACP-injected MCP server
        // named "RepoPromptCE" on 2026-08-13.
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell-RepoPromptCE"), "grok-shell")
        XCTAssertTrue(MCPClientIdentity.matches("grok-shell-RepoPromptCE", AgentProviderKind.grokBuild.mcpClientNameHint))
    }

    func testGrokShellFamilyRequiresSeparatorBoundary() {
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("grok-shellx"))
        XCTAssertNil(MCPClientIdentity.canonicalFamilyID("grok-shel"))
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("grok-shell"), "grok-shell")
    }
}
