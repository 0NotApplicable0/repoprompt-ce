import Foundation

/// Configuration for prompt-only Grok Build Chat and Oracle requests.
struct GrokBuildAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    let enableDebugLogging: Bool
    let modelString: String?
    // Retained for existing callers; prompt-only requests expose no RepoPrompt tools.
    let includeRepoPromptMCPServer: Bool
    let alwaysApproveTools: Bool
    /// Optional API key supplied by the caller; nil leaves authentication to the CLI.
    let apiKey: String?

    init(
        commandName: String = "grok",
        additionalPathHints: [String] = CLIPathHints.grokBuild,
        enableDebugLogging: Bool = false,
        modelString: String? = nil,
        includeRepoPromptMCPServer: Bool = true,
        alwaysApproveTools: Bool = false,
        apiKey: String? = nil
    ) {
        self.commandName = commandName
        self.additionalPathHints = additionalPathHints
        self.enableDebugLogging = enableDebugLogging
        self.modelString = modelString
        self.includeRepoPromptMCPServer = includeRepoPromptMCPServer
        self.alwaysApproveTools = alwaysApproveTools
        self.apiKey = apiKey
    }
}
