import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

@MainActor
final class AgentLifecycleExecutionContractTests: XCTestCase {
    func testAgentRunLifecycleWaitDefaultsAndExplicitOverrides() throws {
        let expected = MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        XCTAssertEqual(AgentRunMCPToolService.defaultWaitTimeoutSeconds, expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(nil), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(nil), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(nil), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.null), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.null), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.null), expected)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedStartTimeoutSeconds(.int(0)), 0)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(30)), 30)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedSteerTimeoutSeconds(.double(45.5)), 45.5)
        XCTAssertEqual(try AgentRunMCPToolService.resolvedWaitTimeoutSeconds(.int(7200)), 7200)
    }

    func testAgentExploreStartSharesLifecycleWaitPolicy() throws {
        XCTAssertEqual(
            try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(nil),
            MCPTimeoutPolicy.agentLifecycleDefaultWaitSeconds
        )
        XCTAssertEqual(try AgentExploreMCPToolService.resolvedStartTimeoutSeconds(.double(900.5)), 900.5)
    }
}
