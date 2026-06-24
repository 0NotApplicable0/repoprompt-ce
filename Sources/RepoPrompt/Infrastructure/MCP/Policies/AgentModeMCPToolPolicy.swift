import Foundation

/// MCP tool policy for agent mode runs.
/// Controls which tools are restricted and which special tools are granted.
enum AgentModeMCPToolPolicy {
    /// Agent mode is tab-scoped, so advanced routing and the live oracle helper surface stay blocked.
    static let restrictedCapabilities: Set<MCPToolCapability> = [
        .routingAdvanced,
        .conversationHelper,
        .conversationSend
    ]

    static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

    /// Tools granted to legacy/generic agent mode runs (from MCPPolicyGatedTools).
    /// These enable user interaction, agent workflow control, and agent-only oracle recovery.
    static let grantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentReasoningControl,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)

    /// Tools granted to Claude native-style agent runs.
    /// Claude no longer relies on share_thoughts or wait_for_next_user_instruction,
    /// but it does use set_status to rename the active session.
    static let claudeNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let claudeNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: claudeNativeGrantedCapabilities)

    /// Tools granted to Codex native agent runs.
    /// Codex native still needs ask_user + set_status even though it doesn't use
    /// share_thoughts or wait_for_next_user_instruction.
    /// set_status is title-only; running status now comes from native reasoning summaries.
    static let codexNativeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let codexNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: codexNativeGrantedCapabilities)

    /// OpenCode ACP uses the Agent Mode app/session control surface.
    static let openCodeGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let openCodeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: openCodeGrantedCapabilities)

    /// Cursor ACP uses the same Agent Mode app/session control surface as OpenCode.
    static let cursorGrantedCapabilities: Set<MCPToolCapability> = [
        .userInteraction,
        .agentSessionControl,
        .agentConversationSend,
        .conversationLog
    ]

    static let cursorGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: cursorGrantedCapabilities)

    /// Tools granted to grok agent runs. grok is a headless one-shot CLI: it has no user to answer
    /// `ask_user`, so granting `userInteraction` only risks a headless deadlock if grok ever calls
    /// it. grok also does not use the agent conversation/oracle-log surface. Grant ONLY
    /// `agentSessionControl` (set_status) so grok can title its session without exposing blocking
    /// or unused interaction tools.
    static let grokGrantedCapabilities: Set<MCPToolCapability> = [
        .agentSessionControl
    ]

    static let grokGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grokGrantedCapabilities)

    /// Tools granted to Antigravity (agy) agent runs. Like grok, agy is a headless one-shot `--print`
    /// CLI with no user to answer `ask_user`, so granting `userInteraction` only risks a headless
    /// deadlock. agy surfaces tool cards from its native trajectory DB, not the MCP conversation/oracle
    /// surface. Grant ONLY `agentSessionControl` (set_status) so agy can title its session.
    static let antigravityGrantedCapabilities: Set<MCPToolCapability> = [
        .agentSessionControl
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
