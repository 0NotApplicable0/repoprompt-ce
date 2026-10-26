import Foundation
import Logging
import RepoPromptProcess
import RepoPromptSettingsCore

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
    /// - Important: ACP-backed providers use their shared one-shot bridge for
    ///   headless discovery while keeping broader chat-provider wiring separate.
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
                environmentFilter: ProviderEnvironmentFiltering.cliFilter(for: config.runtimeVariant.agentKind),
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
                cleanupProjectMCPApproval: true,
                modelOverrides: modelParameterSelections.map { .init(configID: $0.configID, valueRaw: $0.valueRaw) }
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
