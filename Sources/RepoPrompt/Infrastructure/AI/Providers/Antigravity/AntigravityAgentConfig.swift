import Foundation

/// Configuration for the headless Antigravity (`agy`) CLI agent provider.
///
/// Mirrors `CodexExecAgentConfig`: a small value type describing how to launch the `agy`
/// binary. Authentication is the user's responsibility — a prior interactive `agy` sign-in
/// (Google OAuth, stored under `~/.gemini`) is required and RepoPrompt injects no
/// credentials (Pattern 1, identical to Codex / default Claude Code).
struct AntigravityAgentConfig {
    let commandName: String
    let additionalPathHints: [String]
    /// Value passed verbatim to `agy --model`. `agy` accepts the human-readable model *label*
    /// it prints from `agy models` (e.g. `Gemini 3.1 Pro (Low)`) — there is no separate slug,
    /// so the live picker's display label is forwarded as-is. `nil` lets `agy` pick its default;
    /// `agy` silently falls back to its default for unrecognized values, so this is permissive.
    let modelString: String?
    /// When true, pass `--sandbox` to restrict terminal access (conservative default).
    let useSandbox: Bool
    /// When true, pass `--dangerously-skip-permissions` to auto-approve all tool requests
    /// (Full Access). Takes precedence over `useSandbox` — the two flags are mutually exclusive.
    let dangerouslySkipPermissions: Bool
    let enableDebugLogging: Bool

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.antigravity,
        modelString: String? = nil,
        useSandbox: Bool = true,
        dangerouslySkipPermissions: Bool = false,
        enableDebugLogging: Bool = false
    ) {
        self.commandName = commandName ?? "agy"
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.useSandbox = useSandbox
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
        self.enableDebugLogging = enableDebugLogging
    }
}
