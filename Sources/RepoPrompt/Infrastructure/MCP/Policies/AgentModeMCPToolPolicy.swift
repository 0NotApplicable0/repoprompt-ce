import Foundation
import RepoPromptDomainRuntime

/// App provider-kind adapter over the canonical domain-runtime client policy.
enum AgentModeMCPToolPolicy {
    static let restrictedCapabilities = MCPClientToolPolicyCatalog.agentModeRestrictedCapabilities
    static let restrictedTools = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

    static let grantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeGenericEngineer)
        .grantedCapabilities
    static let grantedTools = MCPToolCapabilities.toolNames(for: grantedCapabilities)

    static let claudeNativeGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeClaudeEngineer)
        .grantedCapabilities
    static let claudeNativeGrantedTools = MCPToolCapabilities.toolNames(for: claudeNativeGrantedCapabilities)

    static let codexNativeGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeCodexEngineer)
        .grantedCapabilities
    static let codexNativeGrantedTools = MCPToolCapabilities.toolNames(for: codexNativeGrantedCapabilities)

    static let openCodeGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeOpenCodeEngineer)
        .grantedCapabilities
    static let openCodeGrantedTools = MCPToolCapabilities.toolNames(for: openCodeGrantedCapabilities)

    static let cursorGrantedCapabilities = MCPClientToolPolicyCatalog
        .classification(for: .agentModeCursorEngineer)
        .grantedCapabilities
    static let cursorGrantedTools = MCPToolCapabilities.toolNames(for: cursorGrantedCapabilities)

    /// Tools granted to grok agent runs. grok is a headless one-shot CLI: it has no user to answer
    /// `ask_user`, so granting `userInteraction` only risks a headless deadlock if grok ever calls
    /// it. grok also does not use the agent conversation/oracle-log surface. Grant ONLY
    /// `statusPublication` (set_status) so grok can title its session without exposing blocking
    /// or unused interaction tools.
    static let grokGrantedCapabilities: Set<MCPToolCapability> = [
        .statusPublication
    ]

    static let grokGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grokGrantedCapabilities)

    /// Tools granted to Antigravity (agy) agent runs. Like grok, agy is a headless one-shot `--print`
    /// CLI with no user to answer `ask_user`, so granting `userInteraction` only risks a headless
    /// deadlock. agy surfaces tool cards from its native trajectory DB, not the MCP conversation/oracle
    /// surface. Grant ONLY `statusPublication` (set_status) so agy can title its session.
    static let antigravityGrantedCapabilities: Set<MCPToolCapability> = [
        .statusPublication
    ]

    static let antigravityGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: antigravityGrantedCapabilities)

    static func grantedTools(forAgent agent: AgentProviderKind) -> Set<String> {
        switch agent {
        case .codexExec:
            codexNativeGrantedTools
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            claudeNativeGrantedTools
        case .openCode:
            openCodeGrantedTools
        case .cursor:
            cursorGrantedTools
        case .antigravity:
            antigravityGrantedTools
        case .grok:
            grokGrantedTools
        }
    }
}
