enum AgentTaskRoutingMakerCatalog {
    static func maker(for target: AgentRoutingExecutableTarget) -> AgentTaskRoutingMaker? {
        guard let provider = AgentProviderKind(rawValue: target.agentRaw) else { return nil }
        return maker(provider: provider, modelRaw: target.modelRaw)
    }

    static func maker(provider: AgentProviderKind, modelRaw: String) -> AgentTaskRoutingMaker? {
        switch provider {
        case .claudeCode:
            .anthropic
        case .codexExec:
            .openai
        case .grok:
            .xai
        case .antigravity, .cursor:
            knownFamily(modelRaw)
        case .openCode, .grokBuild, .devin, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            nil
        }
    }

    private static func knownFamily(_ modelRaw: String) -> AgentTaskRoutingMaker? {
        if modelRaw.hasPrefix("claude-") { return .anthropic }
        if modelRaw.hasPrefix("gpt-") { return .openai }
        if modelRaw.hasPrefix("gemini-") { return .google }
        if modelRaw.hasPrefix("grok-") { return .xai }
        if modelRaw.hasPrefix("composer-") { return .cursor }
        return nil
    }
}
