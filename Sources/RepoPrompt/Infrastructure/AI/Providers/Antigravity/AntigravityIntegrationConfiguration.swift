import Darwin
import Foundation
import RepoPromptShared

/// Antigravity (`agy`) integration: manages the RepoPrompt MCP server entry inside agy's
/// HOME-level MCP config.
///
/// `agy` reads MCP servers from `~/.gemini/config/mcp_config.json` (HOME-level only;
/// project-local `.antigravitycli/mcp_config.json` is read but ignored — agy issue #60).
/// The schema is `{"mcpServers": {"<name>": {"command", "args", "env"}}}` (stdio).
/// Existing user configuration is authoritative: RepoPrompt updates or removes an entry only
/// when both its shared ownership marker and the random token embedded in the live entry agree.
enum AntigravityIntegrationConfiguration {
    static let repoPromptMCPServerName = RepoPromptMCPServerConfiguration.defaultServerName
    static let ownershipEnvironmentKey = "REPOPROMPT_CE_ANTIGRAVITY_OWNER_TOKEN"

    private static let ownershipMarkerVersion = 2
    private static let ownershipMarkerFileName = "antigravity-mcp-ownership.json"
    private static let integrationLockFileName = "antigravity-mcp-ownership.lock"
    private static let integrationLock = NSLock()

    enum MutationIntent: Equatable {
        /// User explicitly chose Connect in Settings. This is the only authority that may replace
        /// the exact legacy RepoPrompt entry written by older CE builds.
        case explicitConnect
        /// Provider preparation may verify or reuse current state, but never claim or switch a
        /// tokenless legacy entry to another RepoPrompt build. The sole ownership-journal mutation
        /// it may perform is exact recovery of an already-prepared journal after an interrupted
        /// Connect. That recovery never writes Antigravity's config.
        case discovery
    }

    struct IntegrationPaths {
        let configURL: URL
        let ownershipMarkerURL: URL
        let lockURL: URL
        let lockTimeoutSeconds: TimeInterval

        init(
            configURL: URL,
            ownershipMarkerURL: URL,
            lockURL: URL,
            lockTimeoutSeconds: TimeInterval = 1
        ) {
            self.configURL = configURL
            self.ownershipMarkerURL = ownershipMarkerURL
            self.lockURL = lockURL
            self.lockTimeoutSeconds = lockTimeoutSeconds
        }
    }

    typealias ConfigWriter = (
        _ root: [String: Any],
        _ destinationURL: URL,
        _ expectedSourceData: Data?
    ) throws -> Void

    enum ConfigurationError: LocalizedError {
        case emptyDocument
        case malformedJSON(String)
        case duplicateJSONKeys
        case rootIsNotObject
        case invalidMCPServersShape
        case missingUsableRepoPromptEntry
        case conflictingRepoPromptEntries([String])
        case repoPromptEntryRequiresReconnect([String])
        case configChangedDuringUpdate(path: String)
        case unsafeConfigFile(path: String)
        case unreadableConfig(path: String, reason: String)
        case unwritableConfig(path: String, reason: String)
        case ownershipStoreBusy(path: String)
        case invalidOwnershipStore(path: String)
        case malformedOwnershipStore(path: String)
        case unsupportedOwnershipStoreVersion(path: String, version: Int)
        case unreadableOwnershipStore(path: String, reason: String)
        case unwritableOwnershipStore(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .emptyDocument:
                return "Antigravity's MCP config is empty. Repair or remove the zero-byte file, then reconnect."
            case let .malformedJSON(reason):
                return "Antigravity's MCP config is not valid JSON (\(reason)). Repair it, then reconnect."
            case .duplicateJSONKeys:
                return "Antigravity's MCP config contains duplicate JSON object keys. Repair the ambiguous entries, then reconnect; no configuration was changed."
            case .rootIsNotObject:
                return "Antigravity's MCP config must contain a top-level JSON object. Repair it, then reconnect."
            case .invalidMCPServersShape:
                return "Antigravity's MCP config has an invalid `mcpServers` value; it must be a JSON object. Repair it, then reconnect."
            case .missingUsableRepoPromptEntry:
                return "Antigravity's MCP config does not contain a usable RepoPrompt MCP entry. Reconnect to repair it."
            case let .conflictingRepoPromptEntries(names):
                let joinedNames = names.sorted().joined(separator: ", ")
                return "Antigravity's MCP config already contains a conflicting RepoPrompt entry (\(joinedNames)). Rename or remove that entry, then reconnect."
            case let .repoPromptEntryRequiresReconnect(names):
                let joinedNames = names.sorted().joined(separator: ", ")
                return "Antigravity's MCP entry (\(joinedNames)) points to another RepoPrompt CE build. Click Connect to switch the global agy integration to this app."
            case let .configChangedDuringUpdate(path):
                return "Antigravity's MCP config at \(path) changed while RepoPrompt was preparing an update. No changes were written; reconnect and try again."
            case let .unsafeConfigFile(path):
                return "Antigravity's MCP config at \(path) is a symbolic link or special file. RepoPrompt left it unchanged; replace it with a regular file, then try again."
            case let .unreadableConfig(path, reason):
                return "Antigravity's MCP config at \(path) could not be read (\(reason)). Check its permissions, then reconnect."
            case let .unwritableConfig(path, reason):
                return "Antigravity's MCP config at \(path) could not be updated (\(reason)). Check its permissions, then reconnect."
            case let .ownershipStoreBusy(path):
                return "Another RepoPrompt instance is updating Antigravity's MCP integration at \(path). Wait a moment, then reconnect."
            case let .invalidOwnershipStore(path):
                return "RepoPrompt's Antigravity ownership store at \(path) is not a safe regular file. Repair or remove it, then reconnect."
            case let .malformedOwnershipStore(path):
                return "RepoPrompt's Antigravity ownership journal at \(path) is not valid. It was preserved to avoid losing ownership or restore state; repair it or explicitly remove it, then reconnect."
            case let .unsupportedOwnershipStoreVersion(path, version):
                return "RepoPrompt's Antigravity ownership store at \(path) uses version \(version), which this app cannot safely update. Use the RepoPrompt build that created it or update this app; no integration state was changed."
            case let .unreadableOwnershipStore(path, reason):
                return "RepoPrompt's Antigravity ownership store at \(path) could not be read (\(reason)). Check its permissions, then reconnect."
            case let .unwritableOwnershipStore(path, reason):
                return "RepoPrompt's Antigravity ownership store at \(path) could not be updated (\(reason)). Check its permissions, then reconnect."
            }
        }
    }

    struct OwnershipMarker {
        enum Phase: String, Equatable {
            case prepared
            case installed
        }

        let phase: Phase
        let token: String
        let entry: [String: Any]
        /// Exact pre-write source snapshot while `phase == .prepared`. This makes a crash before
        /// the config replacement distinguishable from one after it.
        let previousEntry: [String: Any]?
        /// Exact tokenless legacy entry displaced by an explicit Connect. Forget restores it only
        /// while the installed tokenized entry is still byte-for-byte equivalent to this marker.
        let displacedEntry: [String: Any]?

        init(
            phase: Phase = .installed,
            token: String,
            entry: [String: Any],
            previousEntry: [String: Any]? = nil,
            displacedEntry: [String: Any]? = nil
        ) {
            self.phase = phase
            self.token = token
            self.entry = entry
            self.previousEntry = previousEntry
            self.displacedEntry = displacedEntry
        }
    }

    struct PersistentMCPConfigResult {
        let configURL: URL
        let wasMCPServerAlreadyPresent: Bool
        let isEntryOwnedByRepoPrompt: Bool
        let ownershipMarkerData: Data?
    }

    struct ConnectionObservation: Equatable {
        let configValidationFailureMessage: String?
        let hasRecordedOwnershipMarker: Bool

        var isConfigValid: Bool {
            configValidationFailureMessage == nil
        }
    }

    struct MergeResult {
        let root: [String: Any]
        let wasMCPServerAlreadyPresent: Bool
        let shouldWrite: Bool
        let ownershipMarker: OwnershipMarker?

        var isEntryOwnedByRepoPrompt: Bool {
            ownershipMarker != nil
        }
    }

    enum OwnedRemovalDecision {
        case remove(root: [String: Any])
        case restore(root: [String: Any])
        case entryAbsent
        case preserveChangedEntry
    }

    enum OwnedRemovalResult: Equatable {
        case removed
        case restoredPreviousEntry
        case noOwnedEntry
        case entryAbsent
        case preservedChangedEntry
    }

    static func configDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    static func configURL() -> URL {
        configDirectoryURL().appendingPathComponent("mcp_config.json")
    }

    /// Debug and release builds have distinct UserDefaults domains but share agy's HOME config.
    /// Keep the ownership authority in the flavor-neutral RepoPrompt CE MCP directory so either
    /// build can validate and deliberately switch the single global integration.
    static func integrationPaths(fileManager: FileManager = .default) -> IntegrationPaths {
        let sharedDirectory = MCPFilesystemIdentity.repoPromptCE(.release)
            .configDirectoryURL(fileManager: fileManager)
        return IntegrationPaths(
            configURL: configURL(),
            ownershipMarkerURL: sharedDirectory.appendingPathComponent(ownershipMarkerFileName),
            lockURL: sharedDirectory.appendingPathComponent(integrationLockFileName)
        )
    }

    /// MCP entry in agy / Gemini stdio format: `{"command", "args", "env"?}`.
    /// RepoPrompt-created entries include a random ownership token in the documented `env` map.
    static func mcpConfigDict(
        for configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        ownershipToken: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "command": configuration.command,
            "args": configuration.args
        ]
        var environment = configuration.environmentDictionary
        if let ownershipToken {
            environment[ownershipEnvironmentKey] = ownershipToken
        }
        if !environment.isEmpty {
            entry["env"] = environment
        }
        return entry
    }

    /// Decodes the shared versioned ownership journal. Invalid payloads never grant mutation or
    /// deletion authority.
    static func decodedOwnershipMarker(_ data: Data?) -> OwnershipMarker? {
        let allowedTopLevelKeys: Set = [
            "version", "phase", "token", "entry", "previousEntry", "displacedEntry"
        ]
        guard let data, !data.isEmpty,
              (try? JSONDuplicateKeyScanner.containsDuplicateKeys(in: data)) == false,
              let object = try? JSONSerialization.jsonObject(with: data),
              let marker = object as? [String: Any],
              Set(marker.keys).isSubset(of: allowedTopLevelKeys),
              let version = marker["version"] as? Int,
              version == ownershipMarkerVersion,
              let phaseRaw = marker["phase"] as? String,
              let phase = OwnershipMarker.Phase(rawValue: phaseRaw),
              let token = marker["token"] as? String,
              UUID(uuidString: token) != nil,
              let entry = marker["entry"] as? [String: Any],
              ownershipToken(in: entry) == token
        else { return nil }

        let previousEntry: [String: Any]?
        if let rawPreviousEntry = marker["previousEntry"] {
            guard phase == .prepared,
                  let object = rawPreviousEntry as? [String: Any]
            else { return nil }
            previousEntry = object
        } else {
            previousEntry = nil
        }

        let displacedEntry: [String: Any]?
        if let rawDisplacedEntry = marker["displacedEntry"] {
            guard let object = rawDisplacedEntry as? [String: Any],
                  ownershipToken(in: object) == nil
            else { return nil }
            displacedEntry = object
        } else {
            displacedEntry = nil
        }

        return OwnershipMarker(
            phase: phase,
            token: token,
            entry: entry,
            previousEntry: previousEntry,
            displacedEntry: displacedEntry
        )
    }

    static func encodedOwnershipMarker(_ marker: OwnershipMarker) throws -> Data {
        var object: [String: Any] = [
            "version": ownershipMarkerVersion,
            "phase": marker.phase.rawValue,
            "token": marker.token,
            "entry": marker.entry
        ]
        if let previousEntry = marker.previousEntry {
            object["previousEntry"] = previousEntry
        }
        if let displacedEntry = marker.displacedEntry {
            object["displacedEntry"] = displacedEntry
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private struct LoadedOwnershipState {
        let data: Data?
        let marker: OwnershipMarker?
    }

    /// Reads the shared journal without letting an older build erase a future or malformed schema.
    /// Invalid bytes cannot grant authority, but they may be the only surviving ownership and
    /// displaced-entry record, so every operation fails closed and preserves them byte-for-byte.
    private static func loadOwnershipState(at url: URL) throws -> LoadedOwnershipState {
        let data = try readOwnershipMarkerData(at: url)
        guard let data else {
            return LoadedOwnershipState(data: nil, marker: nil)
        }

        // Foundation collapses duplicate keys. Never let an ambiguous journal select the value
        // that grants config-mutation authority, even when its selected `version` looks current.
        do {
            guard try !JSONDuplicateKeyScanner.containsDuplicateKeys(in: data) else {
                throw ConfigurationError.malformedOwnershipStore(path: url.path)
            }
        } catch {
            throw ConfigurationError.malformedOwnershipStore(path: url.path)
        }

        if let declaredVersion = declaredOwnershipMarkerVersion(in: data),
           declaredVersion != ownershipMarkerVersion
        {
            throw ConfigurationError.unsupportedOwnershipStoreVersion(
                path: url.path,
                version: declaredVersion
            )
        }

        guard let marker = decodedOwnershipMarker(data) else {
            throw ConfigurationError.malformedOwnershipStore(path: url.path)
        }
        return LoadedOwnershipState(data: data, marker: marker)
    }

    private static func declaredOwnershipMarkerVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let marker = object as? [String: Any]
        else { return nil }
        return marker["version"] as? Int
    }

    /// Pure merge used by install/discovery. `nil` means the file is genuinely missing. Every
    /// present document must be a valid object with an object-shaped `mcpServers` field.
    ///
    /// Functional equality and ownership are intentionally separate. A pre-existing unmarked
    /// entry, or an orphan-token entry left by a crash before the shared marker was installed,
    /// can remain usable without RepoPrompt adopting or later removing it. Trusted ownership
    /// requires the canonical key, installed journal phase, matching token, and exact snapshot.
    static func mergedRoot(
        existingData: Data?,
        ownershipMarker: OwnershipMarker? = nil,
        newOwnershipToken: String = UUID().uuidString,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        intent: MutationIntent = .explicitConnect,
        managedCommandIsRecognized: (String) -> Bool = isRecognizedManagedCommand
    ) throws -> MergeResult {
        var root = try decodedRoot(existingData: existingData)
        let desiredUnownedEntry = mcpConfigDict(for: configuration)

        let existingServers = root["mcpServers"]
        var servers: [String: Any]
        if let existingServers {
            guard let object = existingServers as? [String: Any] else {
                throw ConfigurationError.invalidMCPServersShape
            }
            servers = object
        } else {
            servers = [:]
        }

        let matchingKeys = servers.keys.filter(isRepoPromptServerName)
        guard matchingKeys.count <= 1 else {
            throw ConfigurationError.conflictingRepoPromptEntries(matchingKeys)
        }

        guard let matchingKey = matchingKeys.first else {
            // Provider preparation is validation-only. agy's config is global to every CLI run,
            // so creating or claiming an entry requires the user's explicit Connect action.
            guard intent == .explicitConnect else {
                throw ConfigurationError.missingUsableRepoPromptEntry
            }
            let token = normalizedOwnershipToken(newOwnershipToken)
            let entry = mcpConfigDict(for: configuration, ownershipToken: token)
            let marker = OwnershipMarker(token: token, entry: entry)
            servers[repoPromptMCPServerName] = entry
            root["mcpServers"] = servers
            return MergeResult(
                root: root,
                wasMCPServerAlreadyPresent: false,
                shouldWrite: true,
                ownershipMarker: marker
            )
        }

        guard let currentEntry = servers[matchingKey] as? [String: Any] else {
            throw ConfigurationError.conflictingRepoPromptEntries(matchingKeys)
        }

        let trustedMarker: OwnershipMarker? = if matchingKey == repoPromptMCPServerName,
                                                 let ownershipMarker,
                                                 ownershipMarker.phase == .installed,
                                                 ownershipToken(in: currentEntry) == ownershipMarker.token,
                                                 jsonObjectsEqual(currentEntry, ownershipMarker.entry)
        {
            ownershipMarker
        } else {
            nil
        }

        if let trustedMarker {
            let desiredOwnedEntry = mcpConfigDict(
                for: configuration,
                ownershipToken: trustedMarker.token
            )
            if jsonObjectsEqual(currentEntry, desiredOwnedEntry) {
                return MergeResult(
                    root: root,
                    wasMCPServerAlreadyPresent: true,
                    shouldWrite: false,
                    ownershipMarker: trustedMarker
                )
            }

            guard intent == .explicitConnect else {
                throw ConfigurationError.repoPromptEntryRequiresReconnect(matchingKeys)
            }

            servers[matchingKey] = desiredOwnedEntry
            root["mcpServers"] = servers
            return MergeResult(
                root: root,
                wasMCPServerAlreadyPresent: true,
                shouldWrite: true,
                ownershipMarker: OwnershipMarker(
                    token: trustedMarker.token,
                    entry: desiredOwnedEntry,
                    // Debug/release switches update the shared owned projection, but they never
                    // consume the exact legacy snapshot displaced by the first explicit Connect.
                    // Keeping it makes crash recovery and a later Forget lossless in every flavor.
                    displacedEntry: trustedMarker.displacedEntry
                )
            )
        }

        if functionallyMatchesDesired(currentEntry, desiredEntry: desiredUnownedEntry) {
            return MergeResult(
                root: root,
                wasMCPServerAlreadyPresent: true,
                shouldWrite: false,
                ownershipMarker: nil
            )
        }

        // A valid but mismatched installed marker means user or external state changed after the
        // last owned write. Do not reinterpret that value as legacy and overwrite it.
        guard ownershipMarker == nil else {
            throw ConfigurationError.conflictingRepoPromptEntries(matchingKeys)
        }

        let canMigrateLegacy = matchingKey == repoPromptMCPServerName
            && isMigratableLegacyEntry(
                currentEntry,
                desiredEntry: desiredUnownedEntry,
                managedCommandIsRecognized: managedCommandIsRecognized
            )
        guard canMigrateLegacy else {
            throw ConfigurationError.conflictingRepoPromptEntries(matchingKeys)
        }
        guard intent == .explicitConnect else {
            throw ConfigurationError.repoPromptEntryRequiresReconnect(matchingKeys)
        }

        let token = normalizedOwnershipToken(newOwnershipToken)
        let entry = mcpConfigDict(for: configuration, ownershipToken: token)
        servers[matchingKey] = entry
        root["mcpServers"] = servers
        return MergeResult(
            root: root,
            wasMCPServerAlreadyPresent: true,
            shouldWrite: true,
            ownershipMarker: OwnershipMarker(
                token: token,
                entry: entry,
                displacedEntry: currentEntry
            )
        )
    }

    /// Ensures agy's persistent MCP config contains a functional RepoPrompt MCP server entry.
    /// User configuration alone is never interpreted as proof that RepoPrompt owns an entry.
    /// Discovery never writes agy's config or rewrites an installed ownership journal. It may
    /// exactly recover a prepared journal left by an interrupted explicit Connect.
    @discardableResult
    static func ensurePersistentMCPConfig(
        intent: MutationIntent = .discovery,
        paths: IntegrationPaths = integrationPaths(),
        newOwnershipToken: String = UUID().uuidString,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        managedCommandIsRecognized: (String) -> Bool = isRecognizedManagedCommand,
        configWriter: ConfigWriter? = nil
    ) throws -> PersistentMCPConfigResult {
        let writeConfig: ConfigWriter = configWriter ?? { root, destinationURL, expectedSourceData in
            try writeRoot(
                root,
                to: destinationURL,
                expectedSourceData: expectedSourceData
            )
        }

        return try withIntegrationTransaction(paths: paths) {
            let existingData = try readExistingConfig(at: paths.configURL)
            var loadedOwnership = try loadOwnershipState(at: paths.ownershipMarkerURL)
            var ownershipMarker = loadedOwnership.marker

            if let marker = ownershipMarker, marker.phase == .prepared {
                let recovered = try recoverPreparedMarker(
                    marker,
                    existingData: existingData,
                    markerURL: paths.ownershipMarkerURL
                )
                ownershipMarker = recovered.marker
                loadedOwnership = LoadedOwnershipState(
                    data: recovered.data,
                    marker: recovered.marker
                )
            }

            let merged = try mergedRoot(
                existingData: existingData,
                ownershipMarker: ownershipMarker,
                newOwnershipToken: newOwnershipToken,
                configuration: configuration,
                intent: intent,
                managedCommandIsRecognized: managedCommandIsRecognized
            )

            let finalMarkerData: Data?
            if merged.shouldWrite, let marker = merged.ownershipMarker {
                let preparedMarker = try OwnershipMarker(
                    phase: .prepared,
                    token: marker.token,
                    entry: marker.entry,
                    previousEntry: canonicalRepoPromptEntry(in: existingData),
                    displacedEntry: marker.displacedEntry
                )
                try writeOwnershipMarkerData(
                    encodedOwnershipMarker(preparedMarker),
                    to: paths.ownershipMarkerURL
                )

                do {
                    try writeConfig(
                        merged.root,
                        paths.configURL,
                        existingData
                    )
                    let installedMarker = OwnershipMarker(
                        phase: .installed,
                        token: marker.token,
                        entry: marker.entry,
                        displacedEntry: marker.displacedEntry
                    )
                    let installedData = try encodedOwnershipMarker(installedMarker)
                    try writeOwnershipMarkerData(installedData, to: paths.ownershipMarkerURL)
                    finalMarkerData = installedData
                } catch {
                    let writeError = error
                    let observedData: Data?
                    do {
                        observedData = try readExistingConfig(at: paths.configURL)
                    } catch {
                        // The prepared journal is the only safe authority while the post-error
                        // config state cannot be observed. Leave it intact for the next recovery.
                        throw writeError
                    }

                    let recovered = try recoverPreparedMarker(
                        preparedMarker,
                        existingData: observedData,
                        markerURL: paths.ownershipMarkerURL
                    )
                    guard let recoveredMarker = recovered.marker,
                          recoveredMarker.phase == .installed,
                          recoveredMarker.token == marker.token,
                          jsonObjectsEqual(recoveredMarker.entry, marker.entry)
                    else {
                        // The write failed before replacement or a third-party value won the race.
                        // Recovery already restored the prior authority or relinquished ownership.
                        throw writeError
                    }
                    // The writer reported a late failure after the target was observably installed.
                    // The observed target plus recovered journal is complete success, not a retryable
                    // pre-mutation failure.
                    finalMarkerData = recovered.data
                }
            } else if intent == .discovery {
                // Discovery may have reconciled a prepared WAL record above, but it never
                // canonicalizes or relinquishes an installed journal merely because live config
                // is usable or externally changed. Those ownership mutations require Connect or
                // Forget, where the user has explicitly authorized persistent state changes.
                finalMarkerData = loadedOwnership.data
            } else if let marker = merged.ownershipMarker {
                let installedMarker = OwnershipMarker(
                    phase: .installed,
                    token: marker.token,
                    entry: marker.entry,
                    displacedEntry: marker.displacedEntry
                )
                finalMarkerData = try encodedOwnershipMarker(installedMarker)
                if finalMarkerData != loadedOwnership.data {
                    try writeOwnershipMarkerData(finalMarkerData, to: paths.ownershipMarkerURL)
                }
            } else {
                finalMarkerData = nil
                if loadedOwnership.data != nil {
                    try writeOwnershipMarkerData(nil, to: paths.ownershipMarkerURL)
                }
            }

            return PersistentMCPConfigResult(
                configURL: paths.configURL,
                wasMCPServerAlreadyPresent: merged.wasMCPServerAlreadyPresent,
                isEntryOwnedByRepoPrompt: merged.isEntryOwnedByRepoPrompt,
                ownershipMarkerData: finalMarkerData
            )
        }
    }

    /// Pure removal decision. Removal is allowed only for the canonical entry RepoPrompt wrote,
    /// and only while its live token and full value still exactly match the ownership marker.
    static func removalDecision(
        existingData: Data?,
        ownershipMarker: OwnershipMarker
    ) throws -> OwnedRemovalDecision {
        guard let existingData else { return .entryAbsent }
        var root = try decodedRoot(existingData: existingData)

        guard let existingServers = root["mcpServers"] else { return .entryAbsent }
        guard var servers = existingServers as? [String: Any] else {
            throw ConfigurationError.invalidMCPServersShape
        }

        let matchingKeys = servers.keys.filter(isRepoPromptServerName)
        guard ownershipMarker.phase == .installed,
              matchingKeys.count == 1,
              matchingKeys[0] == repoPromptMCPServerName,
              let currentEntry = servers[repoPromptMCPServerName] as? [String: Any],
              ownershipToken(in: currentEntry) == ownershipMarker.token,
              jsonObjectsEqual(currentEntry, ownershipMarker.entry)
        else {
            return matchingKeys.isEmpty ? .entryAbsent : .preserveChangedEntry
        }

        if let displacedEntry = ownershipMarker.displacedEntry {
            servers[repoPromptMCPServerName] = displacedEntry
            root["mcpServers"] = servers
            return .restore(root: root)
        }

        servers.removeValue(forKey: repoPromptMCPServerName)
        root["mcpServers"] = servers
        return .remove(root: root)
    }

    /// Whether a valid shared marker remains. This intentionally includes a prepared journal so
    /// Settings keeps Forget available after an interrupted Connect.
    static func hasRecordedOwnershipMarker(
        paths: IntegrationPaths = integrationPaths()
    ) -> Bool {
        do {
            return try withIntegrationTransaction(paths: paths) {
                try loadOwnershipState(at: paths.ownershipMarkerURL).data != nil
            }
        } catch {
            // Busy, unreadable, invalid, or future-version stores still represent state that needs
            // user attention. Do not hide Forget/retry merely because this read could not validate it.
            return fileIdentity(atPath: paths.ownershipMarkerURL.path) != nil
        }
    }

    /// Removes or restores only an unchanged entry proven by the shared marker. Files that
    /// changed, are invalid, or cannot be read are never overwritten; Forget still relinquishes
    /// the stale marker so a later attempt cannot delete newly adopted user state.
    static func removeOwnedInstallEntry(
        paths: IntegrationPaths = integrationPaths(),
        configWriter: ConfigWriter? = nil
    ) throws -> OwnedRemovalResult {
        let writeConfig: ConfigWriter = configWriter ?? { root, destinationURL, expectedSourceData in
            try writeRoot(
                root,
                to: destinationURL,
                expectedSourceData: expectedSourceData
            )
        }

        return try withIntegrationTransaction(paths: paths) {
            let existingData = try readExistingConfig(at: paths.configURL)
            let loadedOwnership = try loadOwnershipState(at: paths.ownershipMarkerURL)
            guard var ownershipMarker = loadedOwnership.marker else {
                return .noOwnedEntry
            }

            if ownershipMarker.phase == .prepared {
                let recovered = try recoverPreparedMarker(
                    ownershipMarker,
                    existingData: existingData,
                    markerURL: paths.ownershipMarkerURL
                )
                guard let recoveredMarker = recovered.marker else {
                    return .noOwnedEntry
                }
                ownershipMarker = recoveredMarker
            }

            func writeRemovalTarget(_ root: [String: Any]) throws {
                do {
                    try writeConfig(root, paths.configURL, existingData)
                } catch {
                    let writeError = error
                    let observedRoot: [String: Any]
                    do {
                        guard let observedData = try readExistingConfig(at: paths.configURL) else {
                            throw writeError
                        }
                        observedRoot = try decodedRoot(existingData: observedData)
                    } catch {
                        // The ownership journal remains authoritative unless the complete intended
                        // target can be observed after a writer reports failure.
                        throw writeError
                    }
                    guard jsonObjectsEqual(observedRoot, root) else {
                        throw writeError
                    }
                    // The writer failed after committing the exact removal/restoration target.
                    // Treat the durable mutation as success so Forget can relinquish ownership.
                }
            }

            let result: OwnedRemovalResult
            switch try removalDecision(
                existingData: existingData,
                ownershipMarker: ownershipMarker
            ) {
            case let .remove(root):
                try writeRemovalTarget(root)
                result = .removed
            case let .restore(root):
                try writeRemovalTarget(root)
                result = .restoredPreviousEntry
            case .entryAbsent:
                result = .entryAbsent
            case .preserveChangedEntry:
                result = .preservedChangedEntry
            }
            // Clear authority only after a successful mutation, or after proving that the owned
            // snapshot is already absent/changed. Ambiguous read/write failures retain the journal
            // so an explicit retry can still restore a displaced legacy entry.
            try writeOwnershipMarkerData(nil, to: paths.ownershipMarkerURL)
            return result
        }
    }

    /// Strict startup/discovery gate. The document must already contain the current build's usable
    /// entry; a legacy or other-flavor entry requires explicit Connect and is never switched here.
    static func configDataContainsUsableRepoPrompt(
        _ existingData: Data?,
        ownershipMarker: OwnershipMarker? = nil,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        managedCommandIsRecognized: (String) -> Bool = isRecognizedManagedCommand
    ) -> Bool {
        (try? validateUsableRepoPromptConfig(
            existingData,
            ownershipMarker: ownershipMarker,
            configuration: configuration,
            managedCommandIsRecognized: managedCommandIsRecognized
        )) != nil
    }

    /// Actionable startup validation over the live config. Unlike the boolean availability gate,
    /// this preserves why a cached connection became unusable so Settings can guide recovery.
    static func configValidationFailureMessage(
        paths: IntegrationPaths = integrationPaths(),
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        managedCommandIsRecognized: (String) -> Bool = isRecognizedManagedCommand
    ) -> String? {
        connectionObservation(
            paths: paths,
            configuration: configuration,
            managedCommandIsRecognized: managedCommandIsRecognized
        ).configValidationFailureMessage
    }

    /// Reads live config validity and the shared ownership journal under one integration
    /// transaction. It may reconcile an exact prepared ownership journal left by an interrupted
    /// Connect, but never writes agy's config. Startup callers use this immediately before
    /// publication so config drift after an earlier CLI probe cannot combine stale validity with a
    /// newer ownership observation.
    static func connectionObservation(
        paths: IntegrationPaths = integrationPaths(),
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        managedCommandIsRecognized: (String) -> Bool = isRecognizedManagedCommand
    ) -> ConnectionObservation {
        do {
            return try withIntegrationTransaction(paths: paths) {
                let existingData = try readExistingConfig(at: paths.configURL)
                var ownershipState = try loadOwnershipState(at: paths.ownershipMarkerURL)
                if let prepared = ownershipState.marker, prepared.phase == .prepared {
                    let recovered = try recoverPreparedMarker(
                        prepared,
                        existingData: existingData,
                        markerURL: paths.ownershipMarkerURL
                    )
                    ownershipState = LoadedOwnershipState(
                        data: recovered.data,
                        marker: recovered.marker
                    )
                }
                return ConnectionObservation(
                    configValidationFailureMessage: configValidationFailureMessage(
                        for: existingData,
                        ownershipMarker: ownershipState.marker,
                        configuration: configuration,
                        managedCommandIsRecognized: managedCommandIsRecognized
                    ),
                    hasRecordedOwnershipMarker: ownershipState.data != nil
                )
            }
        } catch {
            // A failed transaction can never establish a usable connection. Preserve Forget/retry
            // visibility when a journal file still exists, even if it is busy or malformed.
            return ConnectionObservation(
                configValidationFailureMessage: error.localizedDescription,
                hasRecordedOwnershipMarker: fileIdentity(
                    atPath: paths.ownershipMarkerURL.path
                ) != nil
            )
        }
    }

    static func configValidationFailureMessage(
        for existingData: Data?,
        ownershipMarker: OwnershipMarker? = nil,
        configuration: RepoPromptMCPServerConfiguration = .repoPrompt,
        managedCommandIsRecognized: (String) -> Bool = isRecognizedManagedCommand
    ) -> String? {
        do {
            try validateUsableRepoPromptConfig(
                existingData,
                ownershipMarker: ownershipMarker,
                configuration: configuration,
                managedCommandIsRecognized: managedCommandIsRecognized
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func validateUsableRepoPromptConfig(
        _ existingData: Data?,
        ownershipMarker: OwnershipMarker?,
        configuration: RepoPromptMCPServerConfiguration,
        managedCommandIsRecognized: (String) -> Bool
    ) throws {
        guard let existingData else {
            throw ConfigurationError.missingUsableRepoPromptEntry
        }
        let result = try mergedRoot(
            existingData: existingData,
            ownershipMarker: ownershipMarker,
            configuration: configuration,
            intent: .discovery,
            managedCommandIsRecognized: managedCommandIsRecognized
        )
        guard result.wasMCPServerAlreadyPresent, !result.shouldWrite else {
            throw ConfigurationError.missingUsableRepoPromptEntry
        }
    }

    static func configContainsRepoPrompt(
        paths: IntegrationPaths = integrationPaths()
    ) -> Bool {
        configValidationFailureMessage(paths: paths) == nil
    }

    /// Pure compare seam for the read/merge/re-read guard. Missing and present-empty are distinct.
    static func sourceDataMatches(expected: Data?, current: Data?) -> Bool {
        expected == current
    }

    private static func decodedRoot(existingData: Data?) throws -> [String: Any] {
        guard let existingData else { return [:] }
        guard !existingData.isEmpty else { throw ConfigurationError.emptyDocument }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: existingData, options: [.fragmentsAllowed])
        } catch {
            throw ConfigurationError.malformedJSON(error.localizedDescription)
        }
        let containsDuplicateKeys: Bool
        do {
            containsDuplicateKeys = try JSONDuplicateKeyScanner.containsDuplicateKeys(in: existingData)
        } catch {
            throw ConfigurationError.malformedJSON(
                "The document's JSON byte encoding could not be validated safely."
            )
        }
        if containsDuplicateKeys {
            throw ConfigurationError.duplicateJSONKeys
        }
        guard let root = object as? [String: Any] else {
            throw ConfigurationError.rootIsNotObject
        }
        return root
    }

    private static func normalizedOwnershipToken(_ proposedToken: String) -> String {
        if let uuid = UUID(uuidString: proposedToken) {
            return uuid.uuidString
        }
        return UUID().uuidString
    }

    private static func ownershipToken(in entry: [String: Any]) -> String? {
        guard let environment = entry["env"] as? [String: Any],
              let token = environment[ownershipEnvironmentKey] as? String,
              UUID(uuidString: token) != nil
        else { return nil }
        return token
    }

    private static func functionallyMatchesDesired(
        _ currentEntry: [String: Any],
        desiredEntry: [String: Any]
    ) -> Bool {
        var normalizedEntry = currentEntry
        if var environment = normalizedEntry["env"] as? [String: Any],
           environment[ownershipEnvironmentKey] != nil
        {
            guard ownershipToken(in: normalizedEntry) != nil else { return false }
            environment.removeValue(forKey: ownershipEnvironmentKey)
            if environment.isEmpty {
                normalizedEntry.removeValue(forKey: "env")
            } else {
                normalizedEntry["env"] = environment
            }
        }
        return jsonObjectsEqual(normalizedEntry, desiredEntry)
    }

    /// Exact pre-token CE writer shape. A familiar key or basename alone never grants migration
    /// authority; explicit Connect must also opt into the replacement in `mergedRoot`.
    private static func isMigratableLegacyEntry(
        _ currentEntry: [String: Any],
        desiredEntry: [String: Any],
        managedCommandIsRecognized: (String) -> Bool
    ) -> Bool {
        guard Set(currentEntry.keys) == Set(["command", "args"]),
              Set(desiredEntry.keys) == Set(["command", "args"]),
              let currentCommand = currentEntry["command"] as? String,
              let desiredCommand = desiredEntry["command"] as? String,
              currentCommand != desiredCommand,
              let currentArgs = currentEntry["args"] as? [Any],
              let desiredArgs = desiredEntry["args"] as? [Any],
              currentArgs.isEmpty,
              desiredArgs.isEmpty,
              managedCommandIsRecognized(currentCommand),
              managedCommandIsRecognized(desiredCommand)
        else { return false }
        return true
    }

    private static func isRecognizedManagedCommand(_ command: String) -> Bool {
        ManagedCLIPathPolicy.isRecognizedCECommand(
            command,
            currentBundledCLIPath: Bundle.main.url(forAuxiliaryExecutable: "repoprompt-mcp")?.path
        )
    }

    private static func canonicalRepoPromptEntry(in existingData: Data?) throws -> [String: Any]? {
        guard existingData != nil else { return nil }
        let root = try decodedRoot(existingData: existingData)
        guard let rawServers = root["mcpServers"] else { return nil }
        guard let servers = rawServers as? [String: Any] else {
            throw ConfigurationError.invalidMCPServersShape
        }
        guard let rawEntry = servers[repoPromptMCPServerName] else { return nil }
        guard let entry = rawEntry as? [String: Any] else {
            throw ConfigurationError.conflictingRepoPromptEntries([repoPromptMCPServerName])
        }
        return entry
    }

    private struct RecoveredMarkerState {
        let marker: OwnershipMarker?
        let data: Data?
    }

    /// Resolves a write-ahead record after interruption. Only exact source/target snapshots are
    /// interpreted; any third value is preserved as a user/external edit and loses ownership.
    private static func recoverPreparedMarker(
        _ marker: OwnershipMarker,
        existingData: Data?,
        markerURL: URL
    ) throws -> RecoveredMarkerState {
        // A malformed or ambiguous live document is not evidence that the pre-write state is
        // absent. Propagate the decode error and retain the prepared journal—the only copy of a
        // displaced legacy entry—until the user repairs the config and retries.
        let currentEntry = try canonicalRepoPromptEntry(in: existingData)
        if let currentEntry,
           ownershipToken(in: currentEntry) == marker.token,
           jsonObjectsEqual(currentEntry, marker.entry)
        {
            let installed = OwnershipMarker(
                phase: .installed,
                token: marker.token,
                entry: marker.entry,
                displacedEntry: marker.displacedEntry
            )
            let data = try encodedOwnershipMarker(installed)
            try writeOwnershipMarkerData(data, to: markerURL)
            return RecoveredMarkerState(marker: installed, data: data)
        }

        if let previousEntry = marker.previousEntry,
           let currentEntry,
           jsonObjectsEqual(currentEntry, previousEntry)
        {
            if ownershipToken(in: previousEntry) == marker.token {
                let installed = OwnershipMarker(
                    phase: .installed,
                    token: marker.token,
                    entry: previousEntry,
                    displacedEntry: marker.displacedEntry
                )
                let data = try encodedOwnershipMarker(installed)
                try writeOwnershipMarkerData(data, to: markerURL)
                return RecoveredMarkerState(marker: installed, data: data)
            }
            try writeOwnershipMarkerData(nil, to: markerURL)
            return RecoveredMarkerState(marker: nil, data: nil)
        }

        if marker.previousEntry == nil, currentEntry == nil {
            try writeOwnershipMarkerData(nil, to: markerURL)
            return RecoveredMarkerState(marker: nil, data: nil)
        }

        try writeOwnershipMarkerData(nil, to: markerURL)
        return RecoveredMarkerState(marker: nil, data: nil)
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t

        var isRegularFile: Bool {
            mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }
    }

    private static func withIntegrationTransaction<T>(
        paths: IntegrationPaths,
        _ body: () throws -> T
    ) throws -> T {
        integrationLock.lock()
        defer { integrationLock.unlock() }

        let directoryURL = paths.lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ConfigurationError.unwritableOwnershipStore(
                path: directoryURL.path,
                reason: error.localizedDescription
            )
        }

        let descriptor = Darwin.open(
            paths.lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ConfigurationError.invalidOwnershipStore(path: paths.lockURL.path)
        }
        defer { Darwin.close(descriptor) }

        guard fchmod(descriptor, mode_t(0o600)) == 0,
              let descriptorIdentity = fileIdentity(forDescriptor: descriptor),
              descriptorIdentity.isRegularFile,
              descriptorIdentity.owner == getuid(),
              fileIdentity(atPath: paths.lockURL.path) == descriptorIdentity
        else {
            throw ConfigurationError.invalidOwnershipStore(path: paths.lockURL.path)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + max(paths.lockTimeoutSeconds, 0)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN,
                  ProcessInfo.processInfo.systemUptime < deadline
            else {
                throw ConfigurationError.ownershipStoreBusy(path: paths.lockURL.path)
            }
            usleep(10000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func fileIdentity(atPath path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            owner: info.st_uid,
            mode: info.st_mode
        )
    }

    private static func fileIdentity(forDescriptor descriptor: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return FileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            owner: info.st_uid,
            mode: info.st_mode
        )
    }

    private static func readOwnershipMarkerData(at url: URL) throws -> Data? {
        guard let identity = fileIdentity(atPath: url.path) else { return nil }
        guard identity.isRegularFile, identity.owner == getuid() else {
            throw ConfigurationError.invalidOwnershipStore(path: url.path)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ConfigurationError.unreadableOwnershipStore(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func writeOwnershipMarkerData(_ data: Data?, to url: URL) throws {
        if let existing = fileIdentity(atPath: url.path),
           !existing.isRegularFile || existing.owner != getuid()
        {
            throw ConfigurationError.invalidOwnershipStore(path: url.path)
        }

        do {
            if let data {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                guard let written = fileIdentity(atPath: url.path),
                      written.isRegularFile,
                      written.owner == getuid()
                else {
                    throw ConfigurationError.invalidOwnershipStore(path: url.path)
                }
            } else if fileIdentity(atPath: url.path) != nil {
                try FileManager.default.removeItem(at: url)
            }
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.unwritableOwnershipStore(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func writeRoot(
        _ root: [String: Any],
        to destinationURL: URL,
        expectedSourceData: Data?
    ) throws {
        let newData: Data
        do {
            newData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw ConfigurationError.unwritableConfig(
                path: destinationURL.path,
                reason: error.localizedDescription
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let currentData = try readExistingConfig(at: destinationURL)
            guard sourceDataMatches(expected: expectedSourceData, current: currentData) else {
                throw ConfigurationError.configChangedDuringUpdate(path: destinationURL.path)
            }
            try newData.write(to: destinationURL, options: .atomic)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.unwritableConfig(
                path: destinationURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func readExistingConfig(at url: URL) throws -> Data? {
        if let identity = fileIdentity(atPath: url.path), !identity.isRegularFile {
            // `Data.write(options: .atomic)` replaces a symlink at the destination path instead of
            // updating its target. Fail closed before either Connect or Forget can destroy a
            // user-managed dotfiles link (or interact with a FIFO/device).
            throw ConfigurationError.unsafeConfigFile(path: url.path)
        }
        do {
            return try Data(contentsOf: url)
        } catch let cocoaError as CocoaError where cocoaError.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw ConfigurationError.unreadableConfig(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func isRepoPromptServerName(_ name: String) -> Bool {
        name.compare(repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
    }

    private static func jsonObjectsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
    }
}
