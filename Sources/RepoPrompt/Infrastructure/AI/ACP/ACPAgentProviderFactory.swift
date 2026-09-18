import Foundation

enum ACPAgentProviderFactory {
    /// Retained for source compatibility; retired Grok Build never resolves credentials.
    typealias GrokAPIKeyProvider = @Sendable () async throws -> String?

    static func makeProvider(
        for agentKind: AgentProviderKind,
        modelString: String?,
        grokAPIKeyProvider _: GrokAPIKeyProvider = {
            try await KeyManager().getAPIKey(for: .grok)
        }
    ) async throws -> (any ACPAgentProvider)? {
        switch agentKind {
        case .openCode:
            OpenCodeACPAgentProvider(
                config: OpenCodeAgentConfig(
                    modelString: modelString,
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    toolProfile: .agentMode
                )
            )
        case .cursor:
            CursorACPAgentProvider(
                config: CursorAgentConfig(
                    enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                    modelString: modelString
                )
            )
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec, .antigravity, .grok, .grokBuild:
            nil
        }
    }
}
