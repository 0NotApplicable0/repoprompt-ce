import Foundation

enum MCPClientIdentity {
    private static let separatorCharacters = CharacterSet(charactersIn: " -_./")

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(separatorCharacters.contains)
    }

    /// Whether `normalized` begins with `token` as a whole leading identity token: either exactly
    /// `token`, or `token` immediately followed by a separator (e.g. `grok` in
    /// "grok-shell-RepoPromptCE"). Unlike `matchesFamily`, this tolerates a trailing WORD suffix —
    /// grok's MCP client announces itself as "grok-shell-<server>", whose server-name suffix
    /// `matchesFamily` rejects (it only tolerates numeric/`v` version suffixes). Used to keep grok's
    /// announced name in the grok family so its agent-mode run policy (keyed on "grok-client") binds.
    private static func hasLeadingToken(_ normalized: String, _ token: String) -> Bool {
        guard normalized.hasPrefix(token) else { return false }
        let rest = normalized.dropFirst(token.count)
        guard let next = rest.first else { return true }
        return isSeparator(next)
    }

    private static func matchesFamily(_ normalized: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        var remainder = normalized[...]
        for (index, token) in tokens.enumerated() {
            guard remainder.hasPrefix(token) else { return false }
            remainder.removeFirst(token.count)
            guard index < tokens.count - 1 else { continue }
            while let next = remainder.first, isSeparator(next) {
                remainder.removeFirst()
            }
        }

        guard !remainder.isEmpty else { return true }
        guard let boundary = remainder.first, isSeparator(boundary) else { return false }
        while let next = remainder.first, isSeparator(next) {
            remainder.removeFirst()
        }
        guard let suffixStart = remainder.first else { return true }
        return suffixStart.isNumber || suffixStart == "v"
    }

    static func canonicalFamilyID(_ raw: String?) -> String? {
        guard let normalized = normalized(raw) else { return nil }
        if matchesFamily(normalized, tokens: ["claude", "code"]) { return "claude-code" }
        if matchesFamily(normalized, tokens: ["codex", "mcp", "client"]) { return "codex-mcp-client" }
        // NOTE: The gemini-cli family is matched BEFORE antigravity intentionally. Antigravity
        // (`agy`) is Gemini-derived and may announce a `gemini*` clientInfo.name over MCP, which
        // would canonicalize here to gemini-cli. That is fine: RepoPrompt does not rely on agy's
        // announced name for routing — it uses PID-based routing keyed on the explicit
        // "antigravity-client" hint (see AgentRuntimeProviderService.antigravityMCPClientID and
        // AntigravityAgentProvider's expected-PID registration). The explicit "antigravity-client"
        // ID is matched by its own antigravity branch below, so RepoPrompt's own client hint is
        // never misclassified as gemini-cli.
        if matchesFamily(normalized, tokens: ["gemini", "cli", "mcp", "client"])
            || matchesFamily(normalized, tokens: ["gemini", "cli"])
        {
            return "gemini-cli-mcp-client"
        }
        if matchesFamily(normalized, tokens: ["cursor", "mcp", "client"])
            || matchesFamily(normalized, tokens: ["cursor", "agent"])
            || matchesFamily(normalized, tokens: ["cursor"])
        {
            return "cursor"
        }
        // Grok Build presents `grok-shell-<injected server name>` (e.g.
        // `grok-shell-RepoPromptCE`); `matchesFamily` only admits numeric/version suffixes,
        // so this family needs a literal prefix branch with a separator-boundary check
        // (`grok-shellx` must not match).
        if normalized == "grok-shell" || normalized.hasPrefix("grok-shell-") {
            return "grok-shell"
        }
        if matchesFamily(normalized, tokens: ["claude", "ai"]) { return "claude-ai" }
        if matchesFamily(normalized, tokens: ["antigravity", "client"])
            || matchesFamily(normalized, tokens: ["antigravity"])
        {
            return "antigravity-client"
        }
        if matchesFamily(normalized, tokens: ["grok", "client"])
            || matchesFamily(normalized, tokens: ["grok"])
            || hasLeadingToken(normalized, "grok")
        {
            return "grok-client"
        }
        if matchesFamily(normalized, tokens: ["repoprompt", "cli"]) { return "repoprompt-cli" }
        return nil
    }

    static func storageKey(_ raw: String?) -> String? {
        canonicalFamilyID(raw) ?? normalized(raw)
    }

    static func sameFamily(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsFamily = canonicalFamilyID(lhs),
              let rhsFamily = canonicalFamilyID(rhs)
        else {
            return false
        }
        return lhsFamily == rhsFamily
    }

    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsNormalized = normalized(lhs),
              let rhsNormalized = normalized(rhs)
        else {
            return false
        }
        if lhsNormalized == rhsNormalized {
            return true
        }
        return sameFamily(lhsNormalized, rhsNormalized)
    }

    static func isHeadlessAgentClient(_ raw: String?) -> Bool {
        guard let family = canonicalFamilyID(raw) else { return false }
        switch family {
        case "claude-code", "codex-mcp-client", "gemini-cli-mcp-client", "cursor", "antigravity-client",
             "grok-client":
            return true
        default:
            return false
        }
    }
}
