import Foundation
import Logging

enum ClaudeCodeRuntimeVariant: String {
    case standard
    case glm
    case kimi
    case customCompatible

    var compatibleBackendID: ClaudeCodeCompatibleBackendID? {
        switch self {
        case .standard:
            nil
        case .glm:
            .glmZAI
        case .kimi:
            .kimi
        case .customCompatible:
            .custom
        }
    }

    var agentKind: AgentProviderKind {
        switch self {
        case .standard:
            .claudeCode
        case .glm:
            .claudeCodeGLM
        case .kimi:
            .kimiCode
        case .customCompatible:
            .customClaudeCompatible
        }
    }
}

/// Supported autonomous agent providers shared by Agent Mode and Context Builder runtimes.
enum AgentProviderKind: String, CaseIterable, Hashable {
    case claudeCode
    case codexExec
    case openCode
    case cursor
    case antigravity
    case grok
    case grokBuild
    case devin
    case claudeCodeGLM
    case kimiCode
    case customClaudeCompatible

    /// Retired raw identities remain decodable but never participate in active enumeration.
    static let allCases: [AgentProviderKind] = [
        .claudeCode, .codexExec, .openCode, .cursor, .antigravity, .grok, .devin,
        .claudeCodeGLM, .kimiCode, .customClaudeCompatible
    ]

    var preservesSavedSelection: Bool {
        self == .antigravity || self == .grok || self == .grokBuild
    }

    static let claudeMCPClientID = "claude-code"
    static let codexMCPClientID = "codex-mcp-client"
    static let openCodeMCPClientID = "opencode"
    static let cursorMCPClientID = "cursor"
    static let antigravityMCPClientID = "antigravity-client"
    static let grokMCPClientID = "grok-client"
    /// Devin's built-in Rust MCP client reports this exact initialize name.
    static let devinMCPClientID = "rmcp"
    /// Grok Build presents `grok-shell-<injected server name>` (e.g. `grok-shell-RepoPromptCE`)
    /// to MCP servers. The hint must equal that exact registered name: the pending run-scoped
    /// tab-context store keys are raw client names (no family canonicalization), so a
    /// family-only hint would never bind the run's frozen tab context. The canonical
    /// `grok-shell` family in `MCPClientIdentity` still covers family-level matching.
    static let grokBuildMCPClientID = "grok-shell-\(RepoPromptMCPServerConfiguration.defaultServerName)"

    var commandName: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude"
        case .codexExec:
            "codex"
        case .openCode:
            "opencode"
        case .cursor:
            "cursor-agent"
        case .antigravity:
            "agy"
        case .grok, .grokBuild:
            "grok"
        case .devin:
            "devin"
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codexExec:
            "Codex CLI"
        case .openCode:
            "OpenCode"
        case .cursor:
            "Cursor CLI"
        case .antigravity:
            "Antigravity CLI"
        case .grok:
            "Grok CLI"
        case .grokBuild:
            "Grok Build"
        case .devin:
            "Devin CLI"
        case .claudeCodeGLM:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI).normalizedDisplayName
        case .kimiCode:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .kimi).normalizedDisplayName
        case .customClaudeCompatible:
            ClaudeCodeCompatibleBackendStore.shared.config(for: .custom).normalizedDisplayName
        }
    }

    var mcpClientNameHint: String? {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            Self.claudeMCPClientID
        case .codexExec:
            Self.codexMCPClientID
        case .openCode:
            Self.openCodeMCPClientID
        case .cursor:
            Self.cursorMCPClientID
        case .grok:
            Self.grokMCPClientID
        case .grokBuild:
            Self.grokBuildMCPClientID
        case .antigravity:
            Self.antigravityMCPClientID
        case .devin:
            Self.devinMCPClientID
        }
    }

    var acpProviderID: ACPProviderID? {
        switch self {
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .devin:
            .devin
        case .claudeCode, .codexExec, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .antigravity, .grok, .grokBuild:
            nil
        }
    }

    var usesClaudeNativeRuntime: Bool {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            true
        case .codexExec, .openCode, .cursor, .antigravity, .grok, .grokBuild, .devin:
            false
        }
    }

    var usesClaudeTooling: Bool {
        usesClaudeNativeRuntime
    }

    var requiresExpectedPIDOwnedAgentModeMCPRouting: Bool {
        switch self {
        case .claudeCode, .codexExec, .openCode, .cursor, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .antigravity, .grok, .grokBuild, .devin:
            true
        }
    }

    var requiresPrePromptAgentModeMCPRouting: Bool {
        switch self {
        case .cursor, .grokBuild:
            false
        case .claudeCode, .codexExec, .openCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .antigravity, .grok, .devin:
            true
        }
    }

    /// Human-readable description for MCP discovery (list_agents).
    var agentDescription: String {
        switch self {
        case .claudeCode:
            return "Anthropic's Claude Code agent. Strong at general-purpose development, code understanding, architecture, and open-ended reasoning tasks."
        case .codexExec:
            return "OpenAI's Codex CLI agent. Optimized for tool-driven engineering workflows. Supports configurable reasoning effort levels per model."
        case .openCode:
            return "OpenCode ACP agent. Interactive Agent Mode uses RepoPrompt MCP tools; headless discovery/delegate runs use RepoPrompt's managed no-native-tools mode."
        case .cursor:
            return "Cursor CLI ACP agent. Uses Cursor's ACP runtime and injects RepoPrompt MCP tools through ACP session configuration."
        case .antigravity:
            return "Google's Antigravity CLI (agy), a Gemini-powered terminal coding agent. Runs headless one-shot prompts and uses RepoPrompt MCP tools."
        case .grok:
            return "xAI's Grok CLI (grok), a Grok-powered terminal coding agent. Runs headless one-shot prompts and uses RepoPrompt MCP tools."
        case .grokBuild:
            return "Retired Agent Mode provider. Grok Build remains available for Chat and Oracle; choose Grok CLI or another active provider for agent tasks."
        case .devin:
            return "Installed Devin ACP agent for Agent Mode, Context Builder, and delegated runs. RepoPrompt injects its MCP tools through an isolated configuration overlay."
        case .claudeCodeGLM:
            let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .glmZAI)
            if case let .claudeSlotMapping(mapping) = config.modelBehavior {
                let normalized = mapping.normalized
                return "Claude Code routed through the GLM integration. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
            }
            return "Claude Code routed through the GLM integration for teams using that provider configuration."
        case .kimiCode:
            return "Claude Code routed through Kimi's Claude-compatible coding backend. Uses Kimi's no-model launch behavior."
        case .customClaudeCompatible:
            let config = ClaudeCodeCompatibleBackendStore.shared.config(for: .custom)
            switch config.modelBehavior {
            case .noModel:
                return "Claude Code routed through a custom Claude-compatible backend using no model flag."
            case let .claudeSlotMapping(mapping):
                let normalized = mapping.normalized
                return "Claude Code routed through a custom Claude-compatible backend. Slots: Haiku → \(normalized.haiku), Sonnet → \(normalized.sonnet), Opus → \(normalized.opus)."
            }
        }
    }

    /// Stable runtime kind identifier for MCP discovery (list_agents).
    var runtimeKind: String {
        switch self {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            "claude_native"
        case .codexExec:
            "codex_native"
        case .openCode:
            "opencode_acp"
        case .cursor:
            "cursor_acp"
        case .antigravity:
            "antigravity_native"
        case .grok:
            "grok_native"
        case .grokBuild:
            "grok_build_acp"
        case .devin:
            "devin_acp"
        }
    }

    var claudeRuntimeVariant: ClaudeCodeRuntimeVariant? {
        switch self {
        case .claudeCode:
            .standard
        case .claudeCodeGLM:
            .glm
        case .kimiCode:
            .kimi
        case .customClaudeCompatible:
            .customCompatible
        case .codexExec, .openCode, .cursor, .antigravity, .grok, .grokBuild, .devin:
            nil
        }
    }
}

/// Factory/service responsible for instantiating provider runtimes.
final class AgentRuntimeProviderService {
    static let shared = AgentRuntimeProviderService()

    /// Enable debug logging for agent provider runtimes (enabled for debugging cancellation)
    static var enableDebugLogging = false
    private static let logger = Logger(label: "com.repoprompt.agent.runtime.provider")

    private init() {}

    private func rejectedModelProvider(for agent: AgentProviderKind, modelString: String?) -> HeadlessAgentProvider? {
        let model = modelString ?? AgentModel.defaultModel.rawValue
        guard !AgentModelCatalog.isValid(
            rawModel: model,
            for: agent,
            availability: .none.assumingAvailable(agent)
        ) else { return nil }
        return UnsupportedHeadlessAgentProvider(
            reason: "Model '\(model)' is unavailable for \(agent.displayName). Choose Default or a model from the provider's current model catalog. The saved selection has not been changed."
        )
    }

    /// Create a headless agent provider.
    /// - Parameters:
    ///   - agent: The provider kind to create
    ///   - modelString: Optional model string override
    ///   - runType: The type of run — determines CLI tool config
    /// - Note: MCP tool restrictions are handled via ServerNetworkManager connection policies,
    ///   not via CLI flags. Use installClientConnectionPolicy before starting the agent run.
    /// - Important: OpenCode and Cursor use their ACP runtimes for headless
    ///   discovery while keeping broader chat-provider wiring separate.
    func makeProvider(
        for agent: AgentProviderKind,
        modelString: String? = nil,
        runType: AgentRunType = .discover,
        workspacePath: String? = nil,
        antigravityPermissionLevel: AntigravityAgentToolPreferences.PermissionLevel? = nil,
        grokPermissionLevel: GrokAgentToolPreferences.PermissionLevel? = nil,
        modelParameterSelections: [ACPModelParameterSelection] = []
    ) -> HeadlessAgentProvider {
        if Self.enableDebugLogging {
            Self.logger.debug("Creating provider for agent: \(agent.displayName), model: \(modelString ?? "default"), runType: \(String(describing: runType))")
        }
        switch agent {
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            let runtimeVariant = agent.claudeRuntimeVariant ?? .standard
            let config: ClaudeCodeAgentConfig = .discovery(
                modelString: modelString,
                runtimeVariant: runtimeVariant,
                enableDebugLogging: Self.enableDebugLogging
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName,
                enableDebugLogging: Self.enableDebugLogging,
                captureStdoutTailBytes: 128 * 1024,
                captureStderrTailBytes: 256 * 1024,
                logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let runner = CLIProcessRunner(config: processConfig)
            let wrappedProvider = ClaudeCodeAgentProvider(runner: runner, config: config)
            let runtimeConfig = ClaudeCompatiblePluginBridge.runtimeConfig(from: config, mode: .discovery)
            if Self.enableDebugLogging {
                Self.logger.debug("Created ClaudeCompatibleHeadlessProviderAdapter")
            }
            return ClaudeCompatibleHeadlessProviderAdapter(
                runtimeConfig: runtimeConfig,
                wrappedProvider: wrappedProvider
            )
        case .codexExec:
            let config = CodexExecAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                fullAccess: CodexAgentToolPreferences.permissionLevel() == .fullAccess
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CodexExecAgentProvider")
            }
            return CodexExecAgentProvider(config: config)
        case .openCode:
            let config = OpenCodeAgentConfig(
                modelString: modelString,
                enableDebugLogging: Self.enableDebugLogging,
                toolProfile: .headless,
                modelParameterSelections: modelParameterSelections
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created OpenCodeACPHeadlessAgentProvider")
            }
            return OpenCodeACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .cursor:
            let config = CursorAgentConfig(
                enableDebugLogging: Self.enableDebugLogging,
                modelString: modelString,
                includeRepoPromptMCPServer: true,
                cleanupProjectMCPApproval: true
            )
            if Self.enableDebugLogging {
                Self.logger.debug("Created CursorACPHeadlessAgentProvider")
            }
            return CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        case .antigravity:
            // Real Agent Mode runs pass the session-resolved level (honoring Safe-Managed /
            // per-provider overrides); discovery / no-session callers omit it and fall back to
            // the user's global Antigravity permission preference.
            let permissionLevel = antigravityPermissionLevel ?? AntigravityAgentToolPreferences.permissionLevel()
            // Safe Managed must retain its pre-preparation rejection, even for an unknown model.
            if permissionLevel.supportsHeadlessRun,
               let rejection = rejectedModelProvider(for: agent, modelString: modelString)
            {
                return rejection
            }
            let config = AntigravityAgentConfig(
                modelString: modelString,
                useSandbox: permissionLevel.useSandbox,
                dangerouslySkipPermissions: permissionLevel.dangerouslySkipPermissions,
                supportsHeadlessRun: permissionLevel.supportsHeadlessRun,
                enableDebugLogging: Self.enableDebugLogging
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName,
                workingDirectory: workspacePath,
                enableDebugLogging: Self.enableDebugLogging,
                captureStdoutTailBytes: 0,
                captureStderrTailBytes: 256 * 1024,
                logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let runner = CLIProcessRunner(config: processConfig)
            if Self.enableDebugLogging {
                Self.logger.debug("Created AntigravityAgentProvider")
            }
            return AntigravityAgentProvider(runner: runner, config: config, workspacePath: workspacePath)
        case .grok:
            let permissionLevel = grokPermissionLevel ?? GrokAgentToolPreferences.permissionLevel()
            guard permissionLevel != .storedPermissionUnavailable else {
                return UnsupportedHeadlessAgentProvider(reason: permissionLevel.detailText)
            }
            if let rejection = rejectedModelProvider(for: agent, modelString: modelString) {
                return rejection
            }
            let config = GrokAgentConfig(
                modelString: modelString,
                useSandbox: permissionLevel.useSandbox,
                dangerouslySkipPermissions: permissionLevel.dangerouslySkipPermissions,
                enableDebugLogging: Self.enableDebugLogging
            )
            var processConfig = CLIProcessConfiguration(
                command: config.commandName,
                workingDirectory: workspacePath,
                enableDebugLogging: Self.enableDebugLogging,
                captureStdoutTailBytes: 0,
                captureStderrTailBytes: 256 * 1024,
                logStdinSampleBytes: 0
            )
            processConfig.ensureAdditionalPaths(config.additionalPathHints)
            let runner = CLIProcessRunner(config: processConfig)
            if Self.enableDebugLogging {
                Self.logger.debug("Created GrokAgentProvider")
            }
            return GrokAgentProvider(runner: runner, config: config, workspacePath: workspacePath)
        case .grokBuild:
            return UnsupportedHeadlessAgentProvider(
                reason: "Grok Build (grokBuild) is retired for Agent Mode and Context Builder. Choose Grok CLI or another active agent provider. Grok Build remains available for Chat and Oracle."
            )
        case .devin:
            return DevinACPHeadlessAgentProvider(
                config: DevinAgentConfig(
                    enableDebugLogging: Self.enableDebugLogging,
                    includeRepoPromptMCPServer: true,
                    modelString: modelString
                ),
                workspacePath: workspacePath
            )
        }
    }
}
