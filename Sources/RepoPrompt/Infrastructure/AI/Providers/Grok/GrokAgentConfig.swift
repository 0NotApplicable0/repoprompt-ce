import Foundation

/// Configuration for the headless Grok (`grok`) CLI agent provider.
///
/// Mirrors `CodexExecAgentConfig`: a small value type describing how to launch the `grok`
/// binary. Authentication is the user's responsibility — a prior interactive `grok login`
/// sign-in (OAuth, stored under `~/.grok/auth.json`) is required and RepoPrompt injects no
/// credentials (Pattern 1, identical to Codex / default Claude Code).
struct GrokAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    /// Value passed verbatim to `grok --model`. `grok` accepts the model id it prints from
    /// `grok models` (e.g. `grok-build`, `grok-composer-2.5-fast`); the live picker forwards
    /// the selected label as-is. `nil` (or `"default"`) omits the flag and lets `grok` pick
    /// its default; `grok` silently falls back to its default for unrecognized values, so this
    /// is permissive.
    let modelString: String?
    /// When true, the provider confines writes to the working directory by passing
    /// `--sandbox workspace` (conservative managed default). Both permission modes still pass
    /// `--permission-mode bypassPermissions` so RepoPrompt MCP tool calls run headlessly
    /// without stalling on approval prompts.
    let useSandbox: Bool
    /// When true, the provider grants Full Access: `--permission-mode bypassPermissions` with
    /// no sandbox. Takes precedence over `useSandbox` — the two are mutually exclusive.
    let dangerouslySkipPermissions: Bool
    let enableDebugLogging: Bool

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.grok,
        modelString: String? = nil,
        useSandbox: Bool = true,
        dangerouslySkipPermissions: Bool = false,
        enableDebugLogging: Bool = false
    ) {
        self.commandName = commandName ?? "grok"
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.useSandbox = useSandbox
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
        self.enableDebugLogging = enableDebugLogging
    }
}
