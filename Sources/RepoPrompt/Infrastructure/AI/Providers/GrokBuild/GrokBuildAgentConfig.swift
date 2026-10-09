import Foundation

/// Configuration for prompt-only Grok Build Chat and Oracle requests.
struct GrokBuildAgentConfig {
    /// Process-local MCP import isolation shared by Grok's ACP and one-shot launch adapters.
    static let importIsolationEnvironment: [String: String] = [
        "GROK_CLAUDE_MCPS_ENABLED": "0",
        "GROK_CURSOR_MCPS_ENABLED": "0"
    ]

    /// Disable Grok-owned background features for host-managed Agent Mode and model polling.
    static let managedBackgroundFeatureEnvironment: [String: String] = [
        "GROK_MEMORY": "0",
        "GROK_SUBAGENTS": "0",
        "GROK_WORKFLOWS": "0",
        "GROK_AUTO_WAKE": "0"
    ]

    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    // Retained for existing callers; prompt-only requests expose no RepoPrompt tools.
    let includeRepoPromptMCPServer: Bool
    let alwaysApproveTools: Bool
    /// Optional API key supplied by the caller; nil leaves authentication to the CLI.
    let apiKey: String?
    /// Process-local background-feature policy. Empty leaves the ACP caller's background
    /// policy unchanged (Context Builder); managed callers opt in explicitly.
    /// One-shot is a separate path that never reads this field.
    let backgroundFeatureEnvironment: [String: String]

    init(
        commandName: String = "grok",
        additionalPathHints: [String] = CLIPathHints.grokBuild,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        alwaysApproveTools: Bool = false,
        apiKey: String? = nil,
        backgroundFeatureEnvironment: [String: String] = [:]
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.alwaysApproveTools = alwaysApproveTools
        self.apiKey = apiKey
        self.backgroundFeatureEnvironment = backgroundFeatureEnvironment
    }
}
