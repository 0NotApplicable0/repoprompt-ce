import Darwin
@testable import RepoPromptApp
import RepoPromptShared
import XCTest

final class AntigravityIntegrationConfigurationTests: XCTestCase {
    private enum FixtureError: Error {
        case injectedWriteFailure
    }

    private struct JSONEncodingFixture {
        let name: String
        let encoding: String.Encoding
        let byteOrderMark: [UInt8]
    }

    private var serverName: String {
        AntigravityIntegrationConfiguration.repoPromptMCPServerName
    }

    private var ownershipToken: String {
        "11111111-1111-1111-1111-111111111111"
    }

    func testMcpConfigDictHasStdioShape() {
        let dict = AntigravityIntegrationConfiguration.mcpConfigDict()
        XCTAssertNotNil(dict["command"] as? String)
        XCTAssertNotNil(dict["args"] as? [String])
        XCTAssertNil(dict["env"], "unowned entries must not receive provenance")
    }

    func testConfigPathIsHomeLevelGeminiConfig() {
        let path = AntigravityIntegrationConfiguration.configURL().path
        XCTAssertTrue(path.hasSuffix(".gemini/config/mcp_config.json"), path)
    }

    func testMergeIntoMissingConfigAddsOwnedServer() throws {
        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: nil,
            newOwnershipToken: ownershipToken
        )

        XCTAssertFalse(result.wasMCPServerAlreadyPresent)
        XCTAssertTrue(result.shouldWrite)
        XCTAssertTrue(result.isEntryOwnedByRepoPrompt)
        let servers = result.root["mcpServers"] as? [String: Any]
        let entry = servers?[serverName] as? [String: Any]
        let environment = entry?["env"] as? [String: Any]
        XCTAssertEqual(
            environment?[AntigravityIntegrationConfiguration.ownershipEnvironmentKey] as? String,
            ownershipToken.uppercased()
        )
    }

    func testMergePreservesExistingUserServers() throws {
        let existing = data([
            "mcpServers": ["other": ["command": "x", "args": []]]
        ])
        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: existing,
            newOwnershipToken: ownershipToken
        )

        XCTAssertFalse(result.wasMCPServerAlreadyPresent)
        let servers = result.root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["other"], "existing user server must be preserved")
        XCTAssertNotNil(servers?[serverName])
    }

    func testEquivalentPreExistingRepoPromptEntryIsPreservedAndNotAdopted() throws {
        let desiredEntry = AntigravityIntegrationConfiguration.mcpConfigDict()
        let existing = data(["mcpServers": [serverName: desiredEntry]])

        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: existing,
            newOwnershipToken: ownershipToken
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertFalse(result.shouldWrite)
        XCTAssertFalse(result.isEntryOwnedByRepoPrompt)
    }

    func testConflictingPreExistingRepoPromptEntryIsRejected() {
        let existing = data([
            "mcpServers": [serverName: ["command": "user-command", "args": []]]
        ])

        XCTAssertThrowsError(
            try AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)
        ) { error in
            guard case let AntigravityIntegrationConfiguration.ConfigurationError
                .conflictingRepoPromptEntries(names) = error
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(names, [self.serverName])
        }
    }

    func testCaseVariantRepoPromptEntryIsNotCanonicalizedOrAdopted() throws {
        let casedVariant = serverName.uppercased()
        XCTAssertNotEqual(casedVariant, serverName)
        let desiredEntry = AntigravityIntegrationConfiguration.mcpConfigDict()
        let existing = data(["mcpServers": [casedVariant: desiredEntry]])

        let result = try AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertFalse(result.shouldWrite)
        XCTAssertFalse(result.isEntryOwnedByRepoPrompt)
        let servers = result.root["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?[casedVariant])
        XCTAssertNil(servers?[serverName])
    }

    func testZeroByteConfigIsRejected() {
        XCTAssertThrowsError(
            try AntigravityIntegrationConfiguration.mergedRoot(existingData: Data())
        ) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.emptyDocument = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMalformedConfigIsRejected() {
        XCTAssertThrowsError(
            try AntigravityIntegrationConfiguration.mergedRoot(
                existingData: Data("not json {{{".utf8)
            )
        ) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.malformedJSON = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testExactAndEscapedDuplicateJSONKeysAreRejected() {
        let scenarios = [
            #"{"mcpServers":{"RepoPromptCE":{"command":"one","args":[]},"RepoPromptCE":{"command":"two","args":[]}}}"#,
            #"{"mcpServers":{"RepoPromptCE":{"command":"one","args":[]},"Repo\u0050romptCE":{"command":"two","args":[]}}}"#
        ]

        for rawJSON in scenarios {
            XCTAssertThrowsError(try AntigravityIntegrationConfiguration.mergedRoot(
                existingData: Data(rawJSON.utf8)
            )) { error in
                guard case AntigravityIntegrationConfiguration.ConfigurationError.duplicateJSONKeys = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testBOMAndWideEncodedConfigDocumentsRejectDuplicatesAndAcceptControls() {
        let duplicateJSON = #"{"mcpServers":{},"mcpServers":{}}"#
        let controlJSON = #"{"mcpServers":{},"untouched":"value"}"#

        for fixture in jsonEncodingFixtures {
            XCTAssertThrowsError(try AntigravityIntegrationConfiguration.mergedRoot(
                existingData: encodedJSON(duplicateJSON, as: fixture)
            ), fixture.name) { error in
                guard case AntigravityIntegrationConfiguration.ConfigurationError.duplicateJSONKeys = error
                else { return XCTFail("\(fixture.name): unexpected error: \(error)") }
            }

            do {
                let result = try AntigravityIntegrationConfiguration.mergedRoot(
                    existingData: encodedJSON(controlJSON, as: fixture),
                    newOwnershipToken: ownershipToken
                )
                XCTAssertEqual(result.root["untouched"] as? String, "value", fixture.name)
                XCTAssertTrue(result.shouldWrite, fixture.name)
            } catch {
                XCTFail("\(fixture.name): non-duplicate control was rejected: \(error)")
            }
        }
    }

    func testNonObjectRootAndWrongMCPServersShapeAreRejected() {
        let scenarios: [(Data, (Error) -> Bool)] = [
            (data(["not", "an", "object"]), { error in
                if case AntigravityIntegrationConfiguration.ConfigurationError.rootIsNotObject = error {
                    return true
                }
                return false
            }),
            (data(["mcpServers": ["not", "an", "object"]]), { error in
                if case AntigravityIntegrationConfiguration.ConfigurationError.invalidMCPServersShape = error {
                    return true
                }
                return false
            })
        ]

        for (input, matchesExpectedError) in scenarios {
            XCTAssertThrowsError(
                try AntigravityIntegrationConfiguration.mergedRoot(existingData: input)
            ) { error in
                XCTAssertTrue(matchesExpectedError(error), "unexpected error: \(error)")
            }
        }
    }

    func testMergePreservesUnknownTopLevelKeys() throws {
        let existing = data(["unknownKey": 123, "mcpServers": [:]])
        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: existing,
            newOwnershipToken: ownershipToken
        )
        XCTAssertEqual(result.root["unknownKey"] as? Int, 123)
    }

    func testMatchingLiveTokenAndSnapshotPersistOwnershipAcrossRestart() throws {
        let entry = ownedEntry()
        let persistedMarkerData = try AntigravityIntegrationConfiguration.encodedOwnershipMarker(
            marker(entry: entry)
        )
        let reloadedMarker = try XCTUnwrap(
            AntigravityIntegrationConfiguration.decodedOwnershipMarker(persistedMarkerData)
        )
        let existing = data(["mcpServers": [serverName: entry]])

        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: existing,
            ownershipMarker: reloadedMarker
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertFalse(result.shouldWrite)
        XCTAssertTrue(result.isEntryOwnedByRepoPrompt)
        XCTAssertEqual(result.ownershipMarker?.token, ownershipToken)
    }

    func testMatchingLiveTokenAndSnapshotAllowSafeConfigUpdate() throws {
        let previousConfiguration = RepoPromptMCPServerConfiguration(
            command: "/previous/repoprompt-mcp"
        )
        let previousEntry = AntigravityIntegrationConfiguration.mcpConfigDict(
            for: previousConfiguration,
            ownershipToken: ownershipToken
        )
        let existing = data(["mcpServers": [serverName: previousEntry]])

        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: existing,
            ownershipMarker: marker(entry: previousEntry)
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertTrue(result.shouldWrite)
        XCTAssertTrue(result.isEntryOwnedByRepoPrompt)
        let servers = result.root["mcpServers"] as? [String: Any]
        let updatedEntry = servers?[serverName] as? [String: Any]
        let updatedEnvironment = updatedEntry?["env"] as? [String: Any]
        XCTAssertEqual(
            updatedEntry?["command"] as? String,
            AntigravityIntegrationConfiguration.mcpConfigDict()["command"] as? String
        )
        XCTAssertEqual(
            updatedEnvironment?[AntigravityIntegrationConfiguration.ownershipEnvironmentKey] as? String,
            ownershipToken
        )
    }

    func testStaleSnapshotDoesNotAdoptIdenticalUnmarkedUserReplacement() throws {
        let staleEntry = ownedEntry()
        let userReplacement = AntigravityIntegrationConfiguration.mcpConfigDict()
        let existing = data(["mcpServers": [serverName: userReplacement]])

        let result = try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: existing,
            ownershipMarker: marker(entry: staleEntry)
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertFalse(result.shouldWrite)
        XCTAssertFalse(result.isEntryOwnedByRepoPrompt)
    }

    func testOrphanProvenanceTokenEntryRemainsUsableButUnowned() throws {
        let orphanEntry = ownedEntry()
        let existing = data(["mcpServers": [serverName: orphanEntry]])

        let result = try AntigravityIntegrationConfiguration.mergedRoot(existingData: existing)

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertFalse(result.shouldWrite)
        XCTAssertFalse(result.isEntryOwnedByRepoPrompt)
        XCTAssertTrue(
            AntigravityIntegrationConfiguration.configDataContainsUsableRepoPrompt(existing)
        )
    }

    func testCorruptOwnershipMarkerPayloadsDecodeAsUnowned() {
        let validTokenWrongEntry: [String: Any] = [
            "version": 2,
            "phase": "installed",
            "token": ownershipToken,
            "entry": AntigravityIntegrationConfiguration.mcpConfigDict()
        ]
        let mismatchedTokenEntry = ownedEntry(token: "22222222-2222-2222-2222-222222222222")
        let mismatchedToken: [String: Any] = [
            "version": 2,
            "phase": "installed",
            "token": ownershipToken,
            "entry": mismatchedTokenEntry
        ]
        let scenarios = [
            Data(),
            Data("not json {{{".utf8),
            data(["not", "an", "object"]),
            data(AntigravityIntegrationConfiguration.mcpConfigDict()),
            data(["version": 99, "phase": "installed", "token": ownershipToken, "entry": ownedEntry()]),
            data(["version": 2, "phase": "bogus", "token": ownershipToken, "entry": ownedEntry()]),
            data(validTokenWrongEntry),
            data(mismatchedToken)
        ]

        for markerData in scenarios {
            XCTAssertNil(
                AntigravityIntegrationConfiguration.decodedOwnershipMarker(markerData)
            )
        }
    }

    func testLoadingCorruptOwnershipMarkerFailsClosedAndPreservesBytes() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = Data("not json {{{".utf8)
        try corrupt.write(to: fixture.paths.ownershipMarkerURL)

        XCTAssertTrue(
            AntigravityIntegrationConfiguration.hasRecordedOwnershipMarker(paths: fixture.paths)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), corrupt)
        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths
        )) { error in
            guard case let AntigravityIntegrationConfiguration.ConfigurationError
                .malformedOwnershipStore(path) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, fixture.paths.ownershipMarkerURL.path)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), corrupt)
    }

    func testAmbiguousOwnershipJournalsFailClosedAndPreserveBytes() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = ownedEntry()
        let configData = data(["mcpServers": [serverName: entry]])
        try configData.write(to: fixture.paths.configURL)
        let entryJSON = try XCTUnwrap(String(data: data(entry), encoding: .utf8))
        let duplicateEntryJournal = Data("""
        {"version":2,"phase":"installed","token":"\(ownershipToken)","entry":\(entryJSON),"entry":\(entryJSON)}
        """.utf8)
        let unknownControlFieldJournal = data([
            "version": 2,
            "phase": "installed",
            "token": ownershipToken,
            "entry": entry,
            "futureRestorePolicy": "replace"
        ])

        for journalData in [duplicateEntryJournal, unknownControlFieldJournal] {
            try journalData.write(to: fixture.paths.ownershipMarkerURL, options: .atomic)

            XCTAssertNil(AntigravityIntegrationConfiguration.decodedOwnershipMarker(journalData))
            XCTAssertThrowsError(
                try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths)
            ) { error in
                guard case AntigravityIntegrationConfiguration.ConfigurationError
                    .malformedOwnershipStore = error
                else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), configData)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), journalData)
        }
    }

    func testBOMAndWideEncodedOwnershipDocumentsFailClosedWithoutByteLoss() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = ownedEntry()
        let configData = data(["mcpServers": [serverName: entry]])
        try configData.write(to: fixture.paths.configURL)
        let entryJSON = try XCTUnwrap(String(data: data(entry), encoding: .utf8))
        let controlJSON = """
        {"version":2,"phase":"installed","token":"\(ownershipToken)","entry":\(entryJSON)}
        """
        let duplicateJSON = """
        {"version":2,"phase":"installed","token":"\(ownershipToken)","entry":\(entryJSON),"entry":\(entryJSON)}
        """

        for encoding in jsonEncodingFixtures {
            let controlData = encodedJSON(controlJSON, as: encoding)
            XCTAssertNotNil(
                AntigravityIntegrationConfiguration.decodedOwnershipMarker(controlData),
                "\(encoding.name): non-duplicate control was rejected"
            )

            let ambiguousData = encodedJSON(duplicateJSON, as: encoding)
            try ambiguousData.write(to: fixture.paths.ownershipMarkerURL, options: .atomic)
            XCTAssertNil(
                AntigravityIntegrationConfiguration.decodedOwnershipMarker(ambiguousData),
                "\(encoding.name): duplicate ownership keys must not grant authority"
            )
            XCTAssertThrowsError(
                try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths),
                encoding.name
            ) { error in
                guard case AntigravityIntegrationConfiguration.ConfigurationError
                    .malformedOwnershipStore = error
                else { return XCTFail("\(encoding.name): unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), configData, encoding.name)
            XCTAssertEqual(
                try Data(contentsOf: fixture.paths.ownershipMarkerURL),
                ambiguousData,
                "\(encoding.name): rejected ownership bytes must remain untouched"
            )
        }

        // Foundation currently treats the UTF-32 LE marker as an ambiguous UTF-16 LE prefix and
        // rejects the document. Keep that platform boundary fail-closed rather than accepting a
        // format the owning decoder cannot interpret consistently.
        let unsupportedUTF32LEBOM = JSONEncodingFixture(
            name: "UTF-32 LE BOM",
            encoding: .utf32LittleEndian,
            byteOrderMark: [0xFF, 0xFE, 0x00, 0x00]
        )
        let unsupportedData = encodedJSON(controlJSON, as: unsupportedUTF32LEBOM)
        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.mergedRoot(
            existingData: unsupportedData
        )) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.malformedJSON = error
            else { return XCTFail("Unexpected UTF-32 LE BOM config error: \(error)") }
        }
        try unsupportedData.write(to: fixture.paths.ownershipMarkerURL, options: .atomic)
        XCTAssertNil(AntigravityIntegrationConfiguration.decodedOwnershipMarker(unsupportedData))
        XCTAssertThrowsError(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths)
        ) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError
                .malformedOwnershipStore = error
            else { return XCTFail("Unexpected UTF-32 LE BOM ownership error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), configData)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), unsupportedData)
    }

    func testExplicitConnectMigratesRecognizedLegacyAndForgetRestoresIt() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Exercise the production recognizer with the exact historical CE user-space paths. The
        // reported failure used the release path while a debug build attempted to Connect.
        let releaseCommand = MCPFilesystemIdentity.repoPromptCE(.release).userSpaceCLIURL().path
        let debugCommand = MCPFilesystemIdentity.repoPromptCE(.debug).userSpaceCLIURL().path
        let legacyEntry: [String: Any] = ["command": releaseCommand, "args": []]
        let original = data(["mcpServers": [serverName: legacyEntry]])
        try original.write(to: fixture.paths.configURL)

        let result = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand)
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertTrue(result.isEntryOwnedByRepoPrompt)
        let marker = try XCTUnwrap(AntigravityIntegrationConfiguration.decodedOwnershipMarker(
            Data(contentsOf: fixture.paths.ownershipMarkerURL)
        ))
        XCTAssertEqual(marker.phase, .installed)
        XCTAssertTrue(jsonEqual(marker.displacedEntry, legacyEntry))

        XCTAssertEqual(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths),
            .restoredPreviousEntry
        )
        XCTAssertTrue(try jsonEqual(configEntry(at: fixture.paths.configURL), legacyEntry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testSharedMarkerAllowsExplicitDebugReleaseSwitchWithStableToken() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        try data([
            "mcpServers": [serverName: ["command": releaseCommand, "args": []]]
        ]).write(to: fixture.paths.configURL)

        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        )
        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: "22222222-2222-2222-2222-222222222222",
            configuration: RepoPromptMCPServerConfiguration(command: releaseCommand),
            managedCommandIsRecognized: recognized.contains
        )

        let marker = try XCTUnwrap(AntigravityIntegrationConfiguration.decodedOwnershipMarker(
            Data(contentsOf: fixture.paths.ownershipMarkerURL)
        ))
        XCTAssertEqual(marker.token, ownershipToken)
        XCTAssertTrue(jsonEqual(marker.displacedEntry, ["command": releaseCommand, "args": []]))
        XCTAssertEqual(try configEntry(at: fixture.paths.configURL)?["command"] as? String, releaseCommand)
        XCTAssertEqual(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths),
            .restoredPreviousEntry
        )
        XCTAssertTrue(try jsonEqual(
            configEntry(at: fixture.paths.configURL),
            ["command": releaseCommand, "args": []]
        ))
    }

    func testConcurrentInstallAndForgetSerializeMarkerAndConfigTransaction() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let legacyEntry: [String: Any] = ["command": releaseCommand, "args": []]
        let original = data(["mcpServers": [serverName: legacyEntry]])
        try original.write(to: fixture.paths.configURL)
        let recognized = Set([releaseCommand, debugCommand])
        let token = ownershipToken
        let harness = AntigravityIntegrationTransactionHarness()

        DispatchQueue.global().async {
            do {
                _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
                    intent: .explicitConnect,
                    paths: fixture.paths,
                    newOwnershipToken: token,
                    configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
                    managedCommandIsRecognized: recognized.contains,
                    configWriter: { root, destinationURL, _ in
                        harness.installWriterEntered.signal()
                        guard harness.allowInstallWrite.wait(timeout: .now() + 2) == .success else {
                            throw FixtureError.injectedWriteFailure
                        }
                        let encoded = try JSONSerialization.data(
                            withJSONObject: root,
                            options: [.sortedKeys, .withoutEscapingSlashes]
                        )
                        try encoded.write(to: destinationURL, options: .atomic)
                    }
                )
                harness.recordInstall(success: true, error: nil)
            } catch {
                harness.recordInstall(success: false, error: error)
            }
            harness.installFinished.signal()
        }

        guard harness.installWriterEntered.wait(timeout: .now() + 1) == .success else {
            harness.allowInstallWrite.signal()
            _ = harness.installFinished.wait(timeout: .now() + 2)
            return XCTFail("Connect did not reach its blocked config replacement")
        }

        DispatchQueue.global().async {
            harness.forgetStarted.signal()
            do {
                let result = try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(
                    paths: fixture.paths
                )
                harness.recordRemoval(result: result, error: nil)
            } catch {
                harness.recordRemoval(result: nil, error: error)
            }
            harness.forgetFinished.signal()
        }
        XCTAssertEqual(harness.forgetStarted.wait(timeout: .now() + 1), .success)

        let prematureForgetCompletion = harness.forgetFinished.wait(timeout: .now() + 0.1)
        XCTAssertEqual(
            prematureForgetCompletion,
            .timedOut,
            "Forget must wait until Connect has committed both config and installed journal state"
        )
        XCTAssertEqual(try? Data(contentsOf: fixture.paths.configURL), original)
        let preparedData = try Data(contentsOf: fixture.paths.ownershipMarkerURL)
        XCTAssertEqual(
            AntigravityIntegrationConfiguration.decodedOwnershipMarker(preparedData)?.phase,
            .prepared
        )

        harness.allowInstallWrite.signal()
        XCTAssertEqual(harness.installFinished.wait(timeout: .now() + 2), .success)
        if prematureForgetCompletion == .timedOut {
            XCTAssertEqual(harness.forgetFinished.wait(timeout: .now() + 2), .success)
        }

        let outcome = harness.snapshot()
        XCTAssertTrue(outcome.installSucceeded, outcome.installError ?? "Connect failed")
        XCTAssertEqual(outcome.removalResult, .restoredPreviousEntry, outcome.removalError ?? "Forget failed")
        XCTAssertTrue(try jsonEqual(configEntry(at: fixture.paths.configURL), legacyEntry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testExplicitConnectRejectsLegacyLookalikesWithoutMutation() throws {
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let caseVariant = serverName.uppercased()
        let scenarios: [(name: String, servers: [String: Any])] = [
            (
                "foreign command",
                [serverName: ["command": "/foreign/repoprompt_ce_cli", "args": []]]
            ),
            (
                "nonempty args",
                [serverName: ["command": releaseCommand, "args": ["--foreign"]]]
            ),
            (
                "environment",
                [serverName: ["command": releaseCommand, "args": [], "env": ["FOREIGN": "1"]]]
            ),
            (
                "extra field",
                [serverName: ["command": releaseCommand, "args": [], "timeout": 30]]
            ),
            (
                "case variant",
                [caseVariant: ["command": releaseCommand, "args": []]]
            ),
            (
                "duplicate case-insensitive keys",
                [
                    serverName: ["command": releaseCommand, "args": []],
                    caseVariant: ["command": debugCommand, "args": []]
                ]
            )
        ]

        for scenario in scenarios {
            let fixture = try makeIntegrationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let original = data(["mcpServers": scenario.servers])
            try original.write(to: fixture.paths.configURL)

            XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
                intent: .explicitConnect,
                paths: fixture.paths,
                configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
                managedCommandIsRecognized: recognized.contains
            ), scenario.name) { error in
                guard case AntigravityIntegrationConfiguration.ConfigurationError
                    .conflictingRepoPromptEntries = error
                else { return XCTFail("\(scenario.name): unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), original, scenario.name)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path),
                scenario.name
            )
        }
    }

    func testPreparedJournalBeforeFlavorSwitchRestoresPriorAuthorityAndLegacySnapshot() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let legacyEntry: [String: Any] = ["command": releaseCommand, "args": []]
        try data(["mcpServers": [serverName: legacyEntry]]).write(to: fixture.paths.configURL)

        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        )
        let debugEntry = try XCTUnwrap(configEntry(at: fixture.paths.configURL))
        let releaseTarget = AntigravityIntegrationConfiguration.mcpConfigDict(
            for: RepoPromptMCPServerConfiguration(command: releaseCommand),
            ownershipToken: ownershipToken
        )
        let interruptedSwitch = AntigravityIntegrationConfiguration.OwnershipMarker(
            phase: .prepared,
            token: ownershipToken,
            entry: releaseTarget,
            previousEntry: debugEntry,
            displacedEntry: legacyEntry
        )
        try AntigravityIntegrationConfiguration.encodedOwnershipMarker(interruptedSwitch)
            .write(to: fixture.paths.ownershipMarkerURL)

        XCTAssertNil(AntigravityIntegrationConfiguration.configValidationFailureMessage(
            paths: fixture.paths,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        ))
        let recovered = try XCTUnwrap(AntigravityIntegrationConfiguration.decodedOwnershipMarker(
            Data(contentsOf: fixture.paths.ownershipMarkerURL)
        ))
        XCTAssertEqual(recovered.phase, .installed)
        XCTAssertTrue(jsonEqual(recovered.entry, debugEntry))
        XCTAssertTrue(jsonEqual(recovered.displacedEntry, legacyEntry))

        XCTAssertEqual(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths),
            .restoredPreviousEntry
        )
        XCTAssertTrue(try jsonEqual(configEntry(at: fixture.paths.configURL), legacyEntry))
    }

    func testPreparedJournalAfterReplacementPromotesTargetAndPreservesLegacySnapshot() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let legacyEntry: [String: Any] = ["command": releaseCommand, "args": []]
        let target = AntigravityIntegrationConfiguration.mcpConfigDict(
            for: RepoPromptMCPServerConfiguration(command: debugCommand),
            ownershipToken: ownershipToken
        )
        try data(["mcpServers": [serverName: target]]).write(to: fixture.paths.configURL)
        let prepared = AntigravityIntegrationConfiguration.OwnershipMarker(
            phase: .prepared,
            token: ownershipToken,
            entry: target,
            previousEntry: legacyEntry,
            displacedEntry: legacyEntry
        )
        try AntigravityIntegrationConfiguration.encodedOwnershipMarker(prepared)
            .write(to: fixture.paths.ownershipMarkerURL)

        XCTAssertNil(AntigravityIntegrationConfiguration.configValidationFailureMessage(
            paths: fixture.paths,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        ))
        let recovered = try XCTUnwrap(AntigravityIntegrationConfiguration.decodedOwnershipMarker(
            Data(contentsOf: fixture.paths.ownershipMarkerURL)
        ))
        XCTAssertEqual(recovered.phase, .installed)
        XCTAssertTrue(jsonEqual(recovered.entry, target))
        XCTAssertTrue(jsonEqual(recovered.displacedEntry, legacyEntry))
    }

    func testPreparedJournalPreservesExternalEditAndRelinquishesOwnership() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previousEntry: [String: Any] = ["command": "/managed/repoprompt_ce_cli", "args": []]
        let target = ownedEntry()
        let externalEntry: [String: Any] = ["command": "/user/edited-command", "args": []]
        let externalData = data(["mcpServers": [serverName: externalEntry]])
        try externalData.write(to: fixture.paths.configURL)
        let prepared = AntigravityIntegrationConfiguration.OwnershipMarker(
            phase: .prepared,
            token: ownershipToken,
            entry: target,
            previousEntry: previousEntry,
            displacedEntry: previousEntry
        )
        try AntigravityIntegrationConfiguration.encodedOwnershipMarker(prepared)
            .write(to: fixture.paths.ownershipMarkerURL)

        XCTAssertNotNil(AntigravityIntegrationConfiguration.configValidationFailureMessage(paths: fixture.paths))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), externalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testConfigWriterFailureBeforeReplacementRestoresSourceState() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let original = data([
            "mcpServers": [serverName: ["command": releaseCommand, "args": []]]
        ])
        try original.write(to: fixture.paths.configURL)

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains,
            configWriter: { _, _, _ in throw FixtureError.injectedWriteFailure }
        )) { error in
            XCTAssertTrue(error is FixtureError)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testConfigWriterLateFailureReconcilesInstalledTarget() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let legacyEntry: [String: Any] = ["command": releaseCommand, "args": []]
        try data(["mcpServers": [serverName: legacyEntry]]).write(to: fixture.paths.configURL)

        let result = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains,
            configWriter: { root, destinationURL, _ in
                try self.data(root).write(to: destinationURL, options: .atomic)
                throw FixtureError.injectedWriteFailure
            }
        )

        XCTAssertTrue(result.isEntryOwnedByRepoPrompt)
        let marker = try XCTUnwrap(AntigravityIntegrationConfiguration.decodedOwnershipMarker(
            Data(contentsOf: fixture.paths.ownershipMarkerURL)
        ))
        XCTAssertEqual(marker.phase, .installed)
        XCTAssertTrue(jsonEqual(marker.displacedEntry, legacyEntry))
        XCTAssertEqual(try configEntry(at: fixture.paths.configURL)?["command"] as? String, debugCommand)
    }

    func testForgetRemovalWriterLateFailureReconcilesInstalledTarget() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = data([
            "preserved": true,
            "mcpServers": ["other": ["command": "other-command", "args": []]]
        ])
        try original.write(to: fixture.paths.configURL)
        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken
        )

        let result = try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(
            paths: fixture.paths,
            configWriter: { root, destinationURL, _ in
                try self.data(root).write(to: destinationURL, options: .atomic)
                throw FixtureError.injectedWriteFailure
            }
        )

        XCTAssertEqual(result, .removed)
        XCTAssertTrue(try jsonEqual(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.configURL)),
            JSONSerialization.jsonObject(with: original)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testForgetRestorationWriterLateFailureReconcilesInstalledTarget() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let original = data([
            "preserved": true,
            "mcpServers": [
                serverName: ["command": releaseCommand, "args": []],
                "other": ["command": "other-command", "args": []]
            ]
        ])
        try original.write(to: fixture.paths.configURL)
        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        )

        let result = try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(
            paths: fixture.paths,
            configWriter: { root, destinationURL, _ in
                try self.data(root).write(to: destinationURL, options: .atomic)
                throw FixtureError.injectedWriteFailure
            }
        )

        XCTAssertEqual(result, .restoredPreviousEntry)
        XCTAssertTrue(try jsonEqual(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.configURL)),
            JSONSerialization.jsonObject(with: original)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testForgetWriteFailureRetainsMarkerForSuccessfulRetry() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let recognized = Set([releaseCommand, debugCommand])
        let legacyEntry: [String: Any] = ["command": releaseCommand, "args": []]
        try data(["mcpServers": [serverName: legacyEntry]]).write(to: fixture.paths.configURL)
        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        )
        let installedData = try Data(contentsOf: fixture.paths.configURL)

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(
            paths: fixture.paths,
            configWriter: { _, _, _ in throw FixtureError.injectedWriteFailure }
        ))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), installedData)
        XCTAssertTrue(AntigravityIntegrationConfiguration.hasRecordedOwnershipMarker(paths: fixture.paths))

        XCTAssertEqual(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths),
            .restoredPreviousEntry
        )
        XCTAssertTrue(try jsonEqual(configEntry(at: fixture.paths.configURL), legacyEntry))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testFutureOwnershipJournalIsPreservedAcrossOperations() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = ownedEntry()
        let configData = data(["mcpServers": [serverName: entry]])
        let futureMarkerData = data([
            "version": 3,
            "phase": "installed",
            "token": ownershipToken,
            "entry": entry,
            "futureField": ["must": "survive"]
        ])
        try configData.write(to: fixture.paths.configURL)
        try futureMarkerData.write(to: fixture.paths.ownershipMarkerURL)

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths
        )) { error in
            guard case let AntigravityIntegrationConfiguration.ConfigurationError
                .unsupportedOwnershipStoreVersion(_, version) = error
            else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(version, 3)
        }
        XCTAssertNotNil(AntigravityIntegrationConfiguration.configValidationFailureMessage(paths: fixture.paths))
        XCTAssertTrue(AntigravityIntegrationConfiguration.hasRecordedOwnershipMarker(paths: fixture.paths))
        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), configData)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), futureMarkerData)
    }

    func testHeldSharedLockRejectsForgetWithoutHidingRetryState() throws {
        let fixture = try makeIntegrationFixture(lockTimeoutSeconds: 0.02)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try data(["mcpServers": [:]]).write(to: fixture.paths.configURL)
        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken
        )
        let originalConfig = try Data(contentsOf: fixture.paths.configURL)
        let originalMarker = try Data(contentsOf: fixture.paths.ownershipMarkerURL)

        let descriptor = Darwin.open(
            fixture.paths.lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return XCTFail("could not open fixture lock") }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(descriptor, LOCK_UN) }

        XCTAssertThrowsError(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths)
        ) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.ownershipStoreBusy = error
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), originalMarker)
        XCTAssertTrue(AntigravityIntegrationConfiguration.hasRecordedOwnershipMarker(paths: fixture.paths))
    }

    func testExplicitConnectRejectsSymlinkConfigWithoutReplacingIt() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let targetURL = fixture.root.appendingPathComponent("user-managed-mcp-config.json")
        let original = data([
            "mcpServers": ["user-server": ["command": "user-tool", "args": []]],
            "userSetting": true
        ])
        try original.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.configURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths
        )) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.unsafeConfigFile = error
            else { return XCTFail("unexpected error: \(error)") }
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.paths.configURL.path),
            targetURL.path
        )
        XCTAssertEqual(try Data(contentsOf: targetURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testForgetRejectsSymlinkConfigAndRetainsOwnershipForRetry() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try data(["mcpServers": [:]]).write(to: fixture.paths.configURL)
        _ = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths,
            newOwnershipToken: ownershipToken
        )
        let ownedConfig = try Data(contentsOf: fixture.paths.configURL)
        let ownershipJournal = try Data(contentsOf: fixture.paths.ownershipMarkerURL)
        let targetURL = fixture.root.appendingPathComponent("user-managed-mcp-config.json")
        try FileManager.default.moveItem(at: fixture.paths.configURL, to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.configURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(
            try AntigravityIntegrationConfiguration.removeOwnedInstallEntry(paths: fixture.paths)
        ) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.unsafeConfigFile = error
            else { return XCTFail("unexpected error: \(error)") }
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.paths.configURL.path),
            targetURL.path
        )
        XCTAssertEqual(try Data(contentsOf: targetURL), ownedConfig)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.ownershipMarkerURL),
            ownershipJournal,
            "Forget must retain authority when it cannot safely mutate the config"
        )
    }

    func testDiscoveryRequiresReconnectForRecognizedLegacyWithoutMutation() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let releaseCommand = "/managed/repoprompt_ce_cli"
        let debugCommand = "/managed/repoprompt_ce_cli_debug"
        let original = data([
            "mcpServers": [serverName: ["command": releaseCommand, "args": []]]
        ])
        try original.write(to: fixture.paths.configURL)
        let recognized = Set([releaseCommand, debugCommand])

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .discovery,
            paths: fixture.paths,
            configuration: RepoPromptMCPServerConfiguration(command: debugCommand),
            managedCommandIsRecognized: recognized.contains
        )) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError
                .repoPromptEntryRequiresReconnect = error
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testDiscoveryRejectsMissingEntryWithoutMutation() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = data([
            "mcpServers": ["user-server": ["command": "user-tool", "args": []]],
            "userSetting": true
        ])
        try original.write(to: fixture.paths.configURL)

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .discovery,
            paths: fixture.paths
        )) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError
                .missingUsableRepoPromptEntry = error
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.ownershipMarkerURL.path))
    }

    func testDiscoveryRecoversPreparedJournalWithoutWritingAgyConfig() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = ownedEntry()
        let original = data([
            "mcpServers": [serverName: entry],
            "userSetting": true
        ])
        let prepared = AntigravityIntegrationConfiguration.OwnershipMarker(
            phase: .prepared,
            token: ownershipToken,
            entry: entry
        )
        try original.write(to: fixture.paths.configURL)
        try AntigravityIntegrationConfiguration.encodedOwnershipMarker(prepared)
            .write(to: fixture.paths.ownershipMarkerURL)

        let result = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .discovery,
            paths: fixture.paths
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertTrue(result.isEntryOwnedByRepoPrompt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.configURL),
            original,
            "Discovery may recover the ownership WAL but must not rewrite agy's config"
        )
        let recovered = try XCTUnwrap(AntigravityIntegrationConfiguration.decodedOwnershipMarker(
            Data(contentsOf: fixture.paths.ownershipMarkerURL)
        ))
        XCTAssertEqual(recovered.phase, .installed)
        XCTAssertEqual(recovered.token, ownershipToken)
    }

    func testDiscoveryPreservesInstalledJournalWhenLiveEntryBecameUnowned() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unownedEntry = AntigravityIntegrationConfiguration.mcpConfigDict()
        let originalConfig = data([
            "mcpServers": [serverName: unownedEntry],
            "userSetting": true
        ])
        let owned = ownedEntry()
        let installed = AntigravityIntegrationConfiguration.OwnershipMarker(
            token: ownershipToken,
            entry: owned
        )
        let originalJournal = try AntigravityIntegrationConfiguration.encodedOwnershipMarker(installed)
        try originalConfig.write(to: fixture.paths.configURL)
        try originalJournal.write(to: fixture.paths.ownershipMarkerURL)

        let result = try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .discovery,
            paths: fixture.paths
        )

        XCTAssertTrue(result.wasMCPServerAlreadyPresent)
        XCTAssertFalse(result.isEntryOwnedByRepoPrompt)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), originalConfig)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.ownershipMarkerURL),
            originalJournal,
            "Only prepared-WAL recovery may persist during discovery"
        )
    }

    func testPreparedRecoveryPreservesJournalWhenLiveConfigIsMalformed() throws {
        let fixture = try makeIntegrationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let legacyEntry: [String: Any] = ["command": "/managed/repoprompt_ce_cli", "args": []]
        let prepared = AntigravityIntegrationConfiguration.OwnershipMarker(
            phase: .prepared,
            token: ownershipToken,
            entry: ownedEntry(),
            previousEntry: legacyEntry,
            displacedEntry: legacyEntry
        )
        let markerData = try AntigravityIntegrationConfiguration.encodedOwnershipMarker(prepared)
        let malformedConfig = Data("not json {{{".utf8)
        try markerData.write(to: fixture.paths.ownershipMarkerURL)
        try malformedConfig.write(to: fixture.paths.configURL)

        XCTAssertThrowsError(try AntigravityIntegrationConfiguration.ensurePersistentMCPConfig(
            intent: .explicitConnect,
            paths: fixture.paths
        )) { error in
            guard case AntigravityIntegrationConfiguration.ConfigurationError.malformedJSON = error
            else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.paths.configURL), malformedConfig)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.ownershipMarkerURL), markerData)
    }

    func testDiscoveryEnsurePreservesActionableFailureForProviderPreparation() throws {
        let expectedMessage = try XCTUnwrap(
            AntigravityIntegrationConfiguration.ConfigurationError.emptyDocument.errorDescription
        )

        let result = MCPIntegrationHelper.installAntigravityMCPEntry(
            intent: .discovery,
            ensureConfig: {
                throw AntigravityIntegrationConfiguration.ConfigurationError.emptyDocument
            }
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failureMessage, expectedMessage)
        XCTAssertEqual(
            AntigravityAgentProvider.mcpPreparationFailureMessage(for: result),
            expectedMessage
        )
    }

    // MARK: - Owned removal decisions

    func testMatchingLiveTokenAndSnapshotAllowSafeRemoval() throws {
        let entry = ownedEntry()
        let existing = data([
            "mcpServers": [
                serverName: entry,
                "other": ["command": "y", "args": []]
            ]
        ])

        let decision = try AntigravityIntegrationConfiguration.removalDecision(
            existingData: existing,
            ownershipMarker: marker(entry: entry)
        )
        guard case let .remove(root) = decision else {
            return XCTFail("expected unchanged owned entry to be removable")
        }
        let servers = root["mcpServers"] as? [String: Any]
        XCTAssertNil(servers?[serverName])
        XCTAssertNotNil(servers?["other"], "unrelated user server must be preserved")
    }

    func testRemovePreservesCaseVariantOrModifiedRepoPromptEntry() throws {
        let entry = ownedEntry()
        var modifiedEntry = entry
        modifiedEntry["command"] = "user-command"
        let scenarios = [
            data(["mcpServers": [serverName.uppercased(): entry]]),
            data(["mcpServers": [serverName: modifiedEntry]]),
            data(["mcpServers": [serverName: AntigravityIntegrationConfiguration.mcpConfigDict()]])
        ]

        for existing in scenarios {
            let decision = try AntigravityIntegrationConfiguration.removalDecision(
                existingData: existing,
                ownershipMarker: marker(entry: entry)
            )
            guard case .preserveChangedEntry = decision else {
                return XCTFail("a changed or externally replaced entry must be preserved")
            }
        }
    }

    func testRemoveOwnedRepoPromptPreservesUnknownTopLevelKeys() throws {
        let entry = ownedEntry()
        let existing = data([
            "unknownKey": 7,
            "mcpServers": [serverName: entry]
        ])

        let decision = try AntigravityIntegrationConfiguration.removalDecision(
            existingData: existing,
            ownershipMarker: marker(entry: entry)
        )
        guard case let .remove(root) = decision else {
            return XCTFail("expected unchanged owned entry to be removable")
        }
        XCTAssertEqual(root["unknownKey"] as? Int, 7)
    }

    func testRemoveOwnedRepoPromptAbsentEntryReportsAbsent() throws {
        let entry = ownedEntry()
        let scenarios: [Data?] = [
            nil,
            data(["mcpServers": ["other": ["command": "y", "args": []]]])
        ]

        for existing in scenarios {
            let decision = try AntigravityIntegrationConfiguration.removalDecision(
                existingData: existing,
                ownershipMarker: marker(entry: entry)
            )
            guard case .entryAbsent = decision else {
                return XCTFail("missing owned entry should be a no-op")
            }
        }
    }

    func testRemoveRejectsInvalidConfigInsteadOfOverwriting() {
        let entry = ownedEntry()
        let scenarios = [Data(), Data("not json {{{".utf8)]

        for existing in scenarios {
            XCTAssertThrowsError(
                try AntigravityIntegrationConfiguration.removalDecision(
                    existingData: existing,
                    ownershipMarker: marker(entry: entry)
                )
            )
        }
    }

    // MARK: - Startup and concurrent-source gates

    func testStartupConfigGateAcceptsMatchingUnmarkedAndProvenanceEntries() {
        let scenarios = [
            data(["mcpServers": [serverName: AntigravityIntegrationConfiguration.mcpConfigDict()]]),
            data(["mcpServers": [serverName: ownedEntry()]])
        ]

        for existing in scenarios {
            XCTAssertTrue(
                AntigravityIntegrationConfiguration.configDataContainsUsableRepoPrompt(existing)
            )
            XCTAssertNil(
                AntigravityIntegrationConfiguration.configValidationFailureMessage(for: existing)
            )
        }
    }

    func testStartupConfigGateRejectsMissingMalformedAndConflictingDocuments() {
        let scenarios: [Data?] = [
            nil,
            Data(),
            Data("not json {{{".utf8),
            data(["not", "an", "object"]),
            data(["mcpServers": ["not", "an", "object"]]),
            data([
                "mcpServers": [
                    serverName: AntigravityIntegrationConfiguration.mcpConfigDict(),
                    serverName.uppercased(): AntigravityIntegrationConfiguration.mcpConfigDict()
                ]
            ]),
            data(["mcpServers": [serverName: ["command": "other", "args": []]]])
        ]

        for existing in scenarios {
            XCTAssertFalse(
                AntigravityIntegrationConfiguration.configDataContainsUsableRepoPrompt(existing)
            )
            XCTAssertNotNil(
                AntigravityIntegrationConfiguration.configValidationFailureMessage(for: existing)
            )
        }
    }

    func testSourceDataGuardDistinguishesMissingEmptyAndChangedDocuments() {
        let original = Data("original".utf8)
        XCTAssertTrue(
            AntigravityIntegrationConfiguration.sourceDataMatches(
                expected: original,
                current: original
            )
        )
        XCTAssertTrue(
            AntigravityIntegrationConfiguration.sourceDataMatches(
                expected: nil,
                current: nil
            )
        )
        XCTAssertFalse(
            AntigravityIntegrationConfiguration.sourceDataMatches(
                expected: nil,
                current: Data()
            )
        )
        XCTAssertFalse(
            AntigravityIntegrationConfiguration.sourceDataMatches(
                expected: original,
                current: Data("changed".utf8)
            )
        )
    }

    private func ownedEntry(token: String? = nil) -> [String: Any] {
        AntigravityIntegrationConfiguration.mcpConfigDict(
            ownershipToken: token ?? ownershipToken
        )
    }

    private func marker(
        token: String? = nil,
        entry: [String: Any]
    ) -> AntigravityIntegrationConfiguration.OwnershipMarker {
        AntigravityIntegrationConfiguration.OwnershipMarker(
            token: token ?? ownershipToken,
            entry: entry
        )
    }

    private func data(_ object: Any) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            XCTFail("failed to encode test JSON: \(error)")
            return Data()
        }
    }

    private var jsonEncodingFixtures: [JSONEncodingFixture] {
        [
            JSONEncodingFixture(name: "UTF-8 BOM", encoding: .utf8, byteOrderMark: [0xEF, 0xBB, 0xBF]),
            JSONEncodingFixture(name: "UTF-16 BE BOM", encoding: .utf16BigEndian, byteOrderMark: [0xFE, 0xFF]),
            JSONEncodingFixture(name: "UTF-16 LE BOM", encoding: .utf16LittleEndian, byteOrderMark: [0xFF, 0xFE]),
            JSONEncodingFixture(
                name: "UTF-32 BE BOM",
                encoding: .utf32BigEndian,
                byteOrderMark: [0x00, 0x00, 0xFE, 0xFF]
            ),
            JSONEncodingFixture(name: "UTF-16 BE", encoding: .utf16BigEndian, byteOrderMark: []),
            JSONEncodingFixture(name: "UTF-16 LE", encoding: .utf16LittleEndian, byteOrderMark: []),
            JSONEncodingFixture(name: "UTF-32 BE", encoding: .utf32BigEndian, byteOrderMark: []),
            JSONEncodingFixture(name: "UTF-32 LE", encoding: .utf32LittleEndian, byteOrderMark: [])
        ]
    }

    private func encodedJSON(_ rawJSON: String, as fixture: JSONEncodingFixture) -> Data {
        guard let encoded = rawJSON.data(using: fixture.encoding) else {
            XCTFail("failed to encode \(fixture.name) test JSON")
            return Data()
        }
        var result = Data(fixture.byteOrderMark)
        result.append(encoded)
        return result
    }

    private func makeIntegrationFixture(
        lockTimeoutSeconds: TimeInterval = 1
    ) throws -> (
        root: URL,
        paths: AntigravityIntegrationConfiguration.IntegrationPaths
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-integration-\(UUID().uuidString)", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shared,
            withIntermediateDirectories: true
        )
        return (
            root,
            AntigravityIntegrationConfiguration.IntegrationPaths(
                configURL: root.appendingPathComponent("mcp_config.json"),
                ownershipMarkerURL: shared.appendingPathComponent("ownership.json"),
                lockURL: shared.appendingPathComponent("ownership.lock"),
                lockTimeoutSeconds: lockTimeoutSeconds
            )
        )
    }

    private func configEntry(at url: URL) throws -> [String: Any]? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        return servers[serverName] as? [String: Any]
    }

    private func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
        default:
            false
        }
    }
}

private final class AntigravityIntegrationTransactionHarness: @unchecked Sendable {
    struct Outcome {
        let installSucceeded: Bool
        let installError: String?
        let removalResult: AntigravityIntegrationConfiguration.OwnedRemovalResult?
        let removalError: String?
    }

    let installWriterEntered = DispatchSemaphore(value: 0)
    let allowInstallWrite = DispatchSemaphore(value: 0)
    let installFinished = DispatchSemaphore(value: 0)
    let forgetStarted = DispatchSemaphore(value: 0)
    let forgetFinished = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var installSucceeded = false
    private var installError: String?
    private var removalResult: AntigravityIntegrationConfiguration.OwnedRemovalResult?
    private var removalError: String?

    func recordInstall(success: Bool, error: Error?) {
        lock.withLock {
            installSucceeded = success
            installError = error?.localizedDescription
        }
    }

    func recordRemoval(
        result: AntigravityIntegrationConfiguration.OwnedRemovalResult?,
        error: Error?
    ) {
        lock.withLock {
            removalResult = result
            removalError = error?.localizedDescription
        }
    }

    func snapshot() -> Outcome {
        lock.withLock {
            Outcome(
                installSucceeded: installSucceeded,
                installError: installError,
                removalResult: removalResult,
                removalError: removalError
            )
        }
    }
}
