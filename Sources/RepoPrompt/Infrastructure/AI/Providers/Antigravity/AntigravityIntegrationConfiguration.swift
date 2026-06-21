import Foundation

/// Antigravity (`agy`) integration: manages the RepoPrompt MCP server entry inside agy's
/// HOME-level MCP config.
///
/// `agy` reads MCP servers from `~/.gemini/config/mcp_config.json` (HOME-level only;
/// project-local `.antigravitycli/mcp_config.json` is read but ignored — agy issue #60).
/// The schema is `{"mcpServers": {"<name>": {"command", "args", "env"}}}` (stdio); agy
/// preserves unknown fields on merge. We merge surgically (only our key), treat a missing or
/// zero-byte/garbage config as empty, and write atomically so existing user servers survive.
enum AntigravityIntegrationConfiguration {
    static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName

    struct PersistentMCPConfigResult {
        let configURL: URL
        let wasMCPServerAlreadyPresent: Bool
    }

    static func configDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    static func configURL() -> URL {
        configDirectoryURL().appendingPathComponent("mcp_config.json")
    }

    /// MCP entry in agy / Gemini stdio format: `{"command", "args", "env"?}`.
    static func mcpConfigDict(
        for configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "command": configuration.command,
            "args": configuration.args
        ]
        let environment = configuration.environmentDictionary
        if !environment.isEmpty {
            entry["env"] = environment
        }
        return entry
    }

    /// Pure merge: given the existing config file bytes, return the merged root with the
    /// RepoPrompt entry inserted and whether it was already present. A missing, zero-byte, or
    /// unparseable config is treated as empty. Extracted for testability (no filesystem).
    static func mergedRoot(
        existingData: Data?,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt
    ) -> (root: [String: Any], wasMCPServerAlreadyPresent: Bool) {
        var root: [String: Any] = [:]
        if let existingData, !existingData.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]
        {
            root = json
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let existingKeys = servers.keys.filter {
            $0.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }
        let wasMCPServerAlreadyPresent = !existingKeys.isEmpty
        for key in existingKeys {
            servers.removeValue(forKey: key)
        }
        servers[repoPromptMCPServerName] = mcpConfigDict(for: configuration)
        root["mcpServers"] = servers
        return (root, wasMCPServerAlreadyPresent)
    }

    /// Ensures agy's persistent MCP config contains the RepoPrompt MCP server.
    /// Idempotent: only the RepoPrompt entry is touched; all other servers are preserved.
    @discardableResult
    static func ensurePersistentMCPConfig() throws -> PersistentMCPConfigResult {
        let fm = FileManager.default
        let dirURL = configDirectoryURL()
        let configURL = configURL()
        try fm.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)

        let existingData = try? Data(contentsOf: configURL)
        let merged = mergedRoot(existingData: existingData)
        let wasMCPServerAlreadyPresent = merged.wasMCPServerAlreadyPresent

        let newData = try JSONSerialization.data(
            withJSONObject: merged.root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if existingData != newData {
            try newData.write(to: configURL, options: .atomic)
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

    /// Pure merge: given the existing config file bytes, return the root with every
    /// (case-insensitive) RepoPrompt entry removed and whether one was present. A missing,
    /// zero-byte, or unparseable config yields an empty root. Extracted for testability.
    static func rootRemovingRepoPrompt(
        existingData: Data?
    ) -> (root: [String: Any], wasMCPServerPresent: Bool)? {
        guard let existingData, !existingData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]
        else { return nil }

        var root = json
        guard var servers = root["mcpServers"] as? [String: Any] else {
            return (root, false)
        }
        let matchingKeys = servers.keys.filter {
            $0.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }
        guard !matchingKeys.isEmpty else { return (root, false) }
        for key in matchingKeys {
            servers.removeValue(forKey: key)
        }
        root["mcpServers"] = servers
        return (root, true)
    }

    /// Removes only the RepoPrompt MCP server entry from agy's config, preserving all other
    /// servers and unknown fields. Idempotent: a no-op when the entry is absent or the config
    /// is missing/garbage. Writes atomically.
    static func removeInstallEntry() {
        let configURL = configURL()
        let existingData = try? Data(contentsOf: configURL)
        guard let result = rootRemovingRepoPrompt(existingData: existingData),
              result.wasMCPServerPresent
        else { return }
        do {
            let newData = try JSONSerialization.data(
                withJSONObject: result.root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try newData.write(to: configURL, options: .atomic)
        } catch {
            return
        }
    }

    /// Whether agy's config already references a RepoPrompt MCP server (case-insensitive).
    static func configContainsRepoPrompt() -> Bool {
        guard let data = try? Data(contentsOf: configURL()), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else { return false }

        return servers.keys.contains {
            $0.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
        }
    }
}
