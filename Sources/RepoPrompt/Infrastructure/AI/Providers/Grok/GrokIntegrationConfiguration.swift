import Foundation

/// Grok (`grok`) integration: manages the RepoPrompt MCP server entry inside grok's
/// HOME-level MCP config.
///
/// `grok` reads MCP servers from `~/.grok/config.toml` (HOME-level), storing each server as a
/// TOML table `[mcp_servers.<name>]` with keys `command` (string), `enabled = true`, and
/// `startup_timeout_sec = 15`. We mutate surgically (only our `[mcp_servers.RepoPromptCE]`
/// section), treat a missing or zero-byte/garbage config as empty, and write atomically so
/// existing user servers and unknown content survive.
enum GrokIntegrationConfiguration {
    static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName

    /// grok confines each MCP server's startup to this many seconds; mirror the value grok's
    /// own `grok mcp add` writes so our entry behaves identically to user-added servers.
    static let startupTimeoutSeconds = 15

    struct PersistentMCPConfigResult {
        let configURL: URL
        let wasMCPServerAlreadyPresent: Bool
    }

    static func configDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    static func configURL() -> URL {
        configDirectoryURL().appendingPathComponent("config.toml")
    }

    /// The fully qualified TOML header for our MCP server section.
    static var sectionHeader: String {
        "[mcp_servers.\(repoPromptMCPServerName)]"
    }

    /// Escapes a value for a TOML basic (double-quoted) string. grok's `command` is a
    /// filesystem path, so only backslash and double-quote need handling in practice, but we
    /// also escape the control characters TOML forbids bare.
    static func escapeTOMLBasicString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }

    /// Renders the `[mcp_servers.RepoPromptCE]` section body (header + keys) in grok's TOML
    /// format. No trailing newline; callers join sections with blank lines.
    static func mcpSectionString(
        for configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> String {
        """
        \(sectionHeader)
        command = "\(escapeTOMLBasicString(configuration.command))"
        enabled = true
        startup_timeout_sec = \(startupTimeoutSeconds)
        """
    }

    /// Returns the line indices `[start, end)` spanning the `[mcp_servers.RepoPromptCE]`
    /// section: from its header line through the line before the next `[section]` header (any
    /// table or array-of-tables) or end of file. Returns `nil` when the section is absent.
    /// Case-insensitive on the server name segment to match grok's lookup behaviour.
    static func repoPromptSectionLineRange(in lines: [String]) -> Range<Int>? {
        var start: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            if start == nil {
                if headerMatchesRepoPrompt(trimmed) {
                    start = index
                }
            } else {
                // First table header after ours terminates the section — UNLESS it is a
                // descendant table of ours (e.g. `[mcp_servers.RepoPromptCE.env]`), which must be
                // removed/replaced together with the parent so no orphan child config is left.
                if headerIsRepoPromptDescendant(trimmed) { continue }
                return start! ..< index
            }
        }
        if let start {
            return start ..< lines.count
        }
        return nil
    }

    /// Whether a trimmed `[...]` header is a descendant table of our section
    /// (`[mcp_servers.RepoPromptCE.<...>]`), which belongs to our section for merge/removal so a
    /// child table is never orphaned when the parent section is replaced or removed.
    private static func headerIsRepoPromptDescendant(_ trimmedHeader: String) -> Bool {
        guard trimmedHeader.hasPrefix("["), trimmedHeader.hasSuffix("]"),
              !trimmedHeader.hasPrefix("[[")
        else { return false }
        let inner = String(trimmedHeader.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespaces)
        let components = inner.split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count >= 3, components[0] == "mcp_servers" else { return false }
        let name = unquoteTOMLKeySegment(components[1])
        return name.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
    }

    /// Whether a trimmed `[...]` TOML header line denotes our `mcp_servers.<name>` table,
    /// matching the server name case-insensitively while requiring an exact path otherwise.
    private static func headerMatchesRepoPrompt(_ trimmedHeader: String) -> Bool {
        guard trimmedHeader.hasPrefix("["), trimmedHeader.hasSuffix("]") else { return false }
        // Reject array-of-tables headers (`[[...]]`); our entry is a plain table.
        guard !trimmedHeader.hasPrefix("[[") else { return false }
        let inner = String(trimmedHeader.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespaces)
        let components = inner.split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 2, components[0] == "mcp_servers" else { return false }
        // Tolerate a quoted name segment (`"RepoPromptCE"`) as well as a bare one.
        let name = unquoteTOMLKeySegment(components[1])
        return name.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
    }

    /// Strips surrounding single or double quotes from a TOML key segment, if present.
    private static func unquoteTOMLKeySegment(_ segment: String) -> String {
        if segment.count >= 2,
           (segment.hasPrefix("\"") && segment.hasSuffix("\"")) ||
           (segment.hasPrefix("'") && segment.hasSuffix("'"))
        {
            return String(segment.dropFirst().dropLast())
        }
        return segment
    }

    /// Pure merge: given the existing config file text, return the merged content with the
    /// RepoPrompt section inserted (or replaced in place) and whether it was already present. A
    /// missing or empty config yields just our section. Extracted for testability (no
    /// filesystem). Other sections and freeform content are preserved verbatim.
    static func mergedContent(
        existingContent: String?,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> (content: String, wasMCPServerAlreadyPresent: Bool) {
        let section = mcpSectionString(for: configuration)

        guard let existingContent, !existingContent.isEmpty else {
            return (section + "\n", false)
        }

        var lines = splitPreservingTrailingNewline(existingContent)
        guard let range = repoPromptSectionLineRange(in: lines) else {
            // Append our section, separated from existing content by a blank line.
            var prefix = existingContent
            if !prefix.hasSuffix("\n") {
                prefix += "\n"
            }
            if !prefix.hasSuffix("\n\n") {
                prefix += "\n"
            }
            return (prefix + section + "\n", false)
        }

        // Replace the existing section's lines with the freshly rendered ones.
        let replacement = section.components(separatedBy: "\n")
        lines.replaceSubrange(range, with: replacement)
        var content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") {
            content += "\n"
        }
        return (content, true)
    }

    /// Splits text into lines for line-range edits. Drops a single trailing empty element
    /// produced by a terminating newline so re-joining with `"\n"` and re-adding the newline is
    /// stable.
    private static func splitPreservingTrailingNewline(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    /// Ensures grok's persistent MCP config contains the RepoPrompt MCP server.
    /// Idempotent: only the RepoPrompt section is touched; all other servers and content are
    /// preserved.
    @discardableResult
    static func ensurePersistentMCPConfig() throws -> PersistentMCPConfigResult {
        let fm = FileManager.default
        let dirURL = configDirectoryURL()
        let configURL = configURL()
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        let existingContent = (try? Data(contentsOf: configURL)).flatMap {
            String(data: $0, encoding: .utf8)
        }
        let merged = mergedContent(existingContent: existingContent)
        let wasMCPServerAlreadyPresent = merged.wasMCPServerAlreadyPresent

        if existingContent != merged.content {
            try Data(merged.content.utf8).write(to: configURL, options: .atomic)
        }

        return PersistentMCPConfigResult(
            configURL: configURL,
            wasMCPServerAlreadyPresent: wasMCPServerAlreadyPresent
        )
    }

    /// Discovery-time wrapper used by the provider's `prepare()` step.
    @discardableResult
    static func ensureServerForDiscovery() -> (success: Bool, wasAlreadyPresent: Bool) {
        do {
            let result = try ensurePersistentMCPConfig()
            return (true, result.wasMCPServerAlreadyPresent)
        } catch {
            return (false, false)
        }
    }

    /// Pure removal: given the existing config text, return the content with the RepoPrompt
    /// section removed and whether it was present. A missing, empty, or section-free config
    /// yields `nil`. Extracted for testability. Other sections and content are preserved.
    static func contentRemovingRepoPrompt(
        existingContent: String?
    ) -> (content: String, wasMCPServerPresent: Bool)? {
        guard let existingContent, !existingContent.isEmpty else { return nil }

        var lines = splitPreservingTrailingNewline(existingContent)
        guard let range = repoPromptSectionLineRange(in: lines) else {
            return (existingContent, false)
        }

        lines.removeSubrange(range)
        // Collapse the blank-line gap our section may have left behind, then trim trailing
        // blank lines so the file does not accumulate whitespace across reinstalls.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if lines.isEmpty {
            return ("", true)
        }
        return (lines.joined(separator: "\n") + "\n", true)
    }

    /// Removes only the RepoPrompt MCP server section from grok's config, preserving all other
    /// servers and content. Idempotent: a no-op when the section is absent or the config is
    /// missing/garbage. Writes atomically.
    static func removeInstallEntry() {
        let configURL = configURL()
        let existingContent = (try? Data(contentsOf: configURL)).flatMap {
            String(data: $0, encoding: .utf8)
        }
        guard let result = contentRemovingRepoPrompt(existingContent: existingContent),
              result.wasMCPServerPresent
        else { return }
        do {
            try Data(result.content.utf8).write(to: configURL, options: .atomic)
        } catch {
            return
        }
    }

    /// Whether grok's config already references a RepoPrompt MCP server (case-insensitive).
    static func configContainsRepoPrompt() -> Bool {
        guard let data = try? Data(contentsOf: configURL()), !data.isEmpty,
              let content = String(data: data, encoding: .utf8), !content.isEmpty
        else { return false }

        let lines = splitPreservingTrailingNewline(content)
        return repoPromptSectionLineRange(in: lines) != nil
    }
}
