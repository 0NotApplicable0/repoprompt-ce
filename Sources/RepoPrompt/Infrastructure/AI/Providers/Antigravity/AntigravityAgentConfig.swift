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
    /// When true, pass `--sandbox` to restrict terminal access. This does not scope or approve
    /// MCP calls; headless tool approval is controlled independently below.
    let useSandbox: Bool
    /// When true, pass `--dangerously-skip-permissions` to auto-approve all native and MCP tool
    /// requests. Headless `agy` cannot prompt for confirmation, but this remains an explicit opt-in
    /// because it also approves globally configured third-party MCP servers.
    let dangerouslySkipPermissions: Bool
    /// False for MCP-started Safe Managed runs. agy's global MCP config and persisted grants cannot
    /// currently be isolated per run, so pretending to provide that boundary would be unsafe.
    let supportsHeadlessRun: Bool
    let enableDebugLogging: Bool
    /// How many times to auto-resume after agy's headless `--print` mode hits its hardcoded
    /// ~5-minute / 1494-poll cap (`printmode.go`). Each resume re-invokes `agy --print
    /// --conversation <id>` on the same conversation with a fresh poll budget, letting a long
    /// multi-tool run finish across budgets. `0` disables resume (detect-and-report only — the
    /// prior behavior). Bounded so a never-converging task cannot loop forever.
    let maxPrintResumes: Int

    init(
        commandName: String? = nil,
        additionalPathHints: [String] = CLIPathHints.antigravity,
        modelString: String? = nil,
        useSandbox: Bool = true,
        dangerouslySkipPermissions: Bool = false,
        supportsHeadlessRun: Bool = true,
        enableDebugLogging: Bool = false,
        maxPrintResumes: Int = 6
    ) {
        self.commandName = commandName ?? "agy"
        self.additionalPathHints = additionalPathHints
        self.modelString = modelString
        self.useSandbox = useSandbox
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
        self.supportsHeadlessRun = supportsHeadlessRun
        self.enableDebugLogging = enableDebugLogging
        self.maxPrintResumes = max(0, maxPrintResumes)
    }
}
