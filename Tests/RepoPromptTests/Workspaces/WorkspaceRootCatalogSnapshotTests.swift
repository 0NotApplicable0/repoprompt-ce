import Foundation
@testable import RepoPromptApp
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptSecureStorage
import XCTest

#if DEBUG
    final class WorkspaceRootCatalogSnapshotTests: XCTestCase {
        func testDW22IgnoreDirectoryPrefixesArePreparedOncePerOutcome() {
            IgnoreDebugMetricsRecorder.setRecordingEnabledForTesting(true)
            defer { IgnoreDebugMetricsRecorder.resetRecordingEnabledForTesting() }

            let patterns = (0 ..< 16).map { "never\($0)*/cache/" }.joined(separator: "\n")
            let rules = GitignoreCompiler.compile(content: patterns)
            IgnoreDebugMetricsRecorder.reset()

            let path = (0 ..< 32).map { "d\($0)" }.joined(separator: "/") + "/file.swift"
            XCTAssertEqual(rules.outcome(for: path, isDirectory: false), .noMatch)

            var metrics = IgnoreDebugMetricsRecorder.snapshot()
            XCTAssertEqual(metrics.outcomeEvaluationCount, 1)
            XCTAssertEqual(metrics.patternMatchAttemptCount, 16)
            XCTAssertEqual(metrics.directoryCandidatePrefixRequestCount, 512)
            XCTAssertEqual(
                metrics.directoryCandidatePrefixBuildCount,
                32,
                "directory candidate prefixes must be prepared once per outcome per layer"
            )

            let cases: [(
                name: String,
                content: String,
                path: String,
                isDirectory: Bool,
                outcome: CompiledIgnoreRules.MatchOutcome,
                requests: Int,
                builds: Int
            )] = [
                ("prefilter miss", "cache/", "d0/file.swift", false, .noMatch, 0, 0),
                ("first ancestor", "d0/", "d0/d1/file.swift", false, .ignore, 1, 1),
                ("directory self", "cache/", "d0/cache", true, .ignore, 2, 2)
            ]
            for testCase in cases {
                let caseRules = GitignoreCompiler.compile(content: testCase.content)
                IgnoreDebugMetricsRecorder.reset()
                XCTAssertEqual(
                    caseRules.outcome(for: testCase.path, isDirectory: testCase.isDirectory),
                    testCase.outcome,
                    testCase.name
                )
                metrics = IgnoreDebugMetricsRecorder.snapshot()
                XCTAssertEqual(metrics.directoryCandidatePrefixRequestCount, testCase.requests, testCase.name)
                XCTAssertEqual(metrics.directoryCandidatePrefixBuildCount, testCase.builds, testCase.name)
            }

            let freshRules = GitignoreCompiler.compile(content: "never*/cache/")
            IgnoreDebugMetricsRecorder.reset()
            XCTAssertEqual(freshRules.outcome(for: "a/b/file.swift", isDirectory: false), .noMatch)
            XCTAssertEqual(freshRules.outcome(for: "c/d/file.swift", isDirectory: false), .noMatch)
            metrics = IgnoreDebugMetricsRecorder.snapshot()
            XCTAssertEqual(metrics.outcomeEvaluationCount, 2)
            XCTAssertEqual(metrics.directoryCandidatePrefixRequestCount, 4)
            XCTAssertEqual(metrics.directoryCandidatePrefixBuildCount, 4)
        }

        @MainActor
        func testDW22IgnorePrefixReusePreservesHydratedCatalogAndSelection() async throws {
            let rootURL = try makeTemporaryRoot(name: "IgnorePrefixReuse")
            try writeFixture(
                """
                /anchored/
                cache/
                generated/**
                !generated/keep.swift
                """,
                to: ".gitignore",
                in: rootURL
            )
            try writeFixture("Temp/\n!Temp/Keep.swift\n", to: "Sources/.gitignore", in: rootURL)
            try writeFixture("let rootKeep = true\n", to: "RootKeep.swift", in: rootURL)
            try writeFixture("let hidden = true\n", to: "anchored/Hidden.swift", in: rootURL)
            try writeFixture("let cached = true\n", to: "src/cache/Hidden.swift", in: rootURL)
            try writeFixture("let generated = true\n", to: "generated/Drop.swift", in: rootURL)
            try writeFixture("let generatedKeep = true\n", to: "generated/keep.swift", in: rootURL)
            try writeFixture(
                "let selectedValue = 42\nlet unselectedValue = 0\n",
                to: "Sources/Visible.swift",
                in: rootURL
            )
            try writeFixture("let nestedDrop = true\n", to: "Sources/Temp/Drop.swift", in: rootURL)
            try writeFixture("let nestedKeep = true\n", to: "Sources/Temp/Keep.swift", in: rootURL)

            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let files = WorkspaceFilesViewModel()
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: files,
                apiSettingsViewModel: apiSettings,
                windowID: -1,
                settingsManager: WindowSettingsManager(windowID: -1)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: files,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
            manager.workspaces = [source, target]
            manager.activeWorkspace = source
            addTeardownBlock {
                await prompt.tokenCountingViewModel.stopTokenCountUpdateTimer()
                await files.unloadAllRootFolders()
            }

            let result = await manager.switchWorkspace(to: target, saveState: false, reason: "ignore-prefix-reuse-test")
            XCTAssertTrue(result.didSwitch)
            let snapshot = try await manager.awaitWorkspaceRootCatalogSnapshot(
                workspaceID: target.id,
                timeout: .seconds(5)
            )
            let root = try XCTUnwrap(snapshot.primaryRoots.first)
            let filePaths = await files.workspaceFileContextStore.files(inRoot: root.id)
                .map(\.standardizedRelativePath)
                .filter { $0.hasSuffix(".swift") }
            XCTAssertEqual(
                filePaths,
                ["RootKeep.swift", "Sources/Temp/Keep.swift", "Sources/Visible.swift", "generated/keep.swift"]
            )
            let folderPaths = await files.workspaceFileContextStore.folders(inRoot: root.id)
                .map(\.standardizedRelativePath)
                .filter { !$0.isEmpty }
                .sorted()
            XCTAssertEqual(folderPaths, ["Sources", "Sources/Temp", "generated", "src"])

            let discovered = Set(filePaths)
            XCTAssertEqual(
                [
                    "anchored/Hidden.swift": discovered.contains("anchored/Hidden.swift"),
                    "src/cache/Hidden.swift": discovered.contains("src/cache/Hidden.swift"),
                    "generated/Drop.swift": discovered.contains("generated/Drop.swift"),
                    "generated/keep.swift": discovered.contains("generated/keep.swift"),
                    "Sources/Temp/Drop.swift": discovered.contains("Sources/Temp/Drop.swift"),
                    "Sources/Temp/Keep.swift": discovered.contains("Sources/Temp/Keep.swift")
                ],
                [
                    "anchored/Hidden.swift": false,
                    "src/cache/Hidden.swift": false,
                    "generated/Drop.swift": false,
                    "generated/keep.swift": true,
                    "Sources/Temp/Drop.swift": false,
                    "Sources/Temp/Keep.swift": true
                ]
            )

            let rootRules = GitignoreCompiler.compile(
                content: "/anchored/\ncache/\ngenerated/**\n!generated/keep.swift\n"
            )
            XCTAssertEqual(rootRules.outcome(for: "anchored/Hidden.swift", isDirectory: false), .ignore)
            XCTAssertEqual(rootRules.outcome(for: "src/cache/Hidden.swift", isDirectory: false), .ignore)
            XCTAssertEqual(rootRules.outcome(for: "generated/Drop.swift", isDirectory: false), .ignore)
            XCTAssertEqual(rootRules.outcome(for: "generated/keep.swift", isDirectory: false), .allow)
            let nestedRules = GitignoreCompiler.compile(
                content: "Temp/\n!Temp/Keep.swift\n",
                directoryPath: "Sources"
            )
            XCTAssertEqual(nestedRules.outcome(for: "Sources/Temp/Drop.swift", isDirectory: false), .ignore)
            XCTAssertEqual(nestedRules.outcome(for: "Sources/Temp/Keep.swift", isDirectory: false), .allow)

            let selectedPath = rootURL.appendingPathComponent("Sources/Visible.swift").standardizedFileURL.path
            let ranges = [LineRange(start: 1, end: 1, description: "selected value")]
            await files.applyStoredSelection(StoredSelection(
                selectedPaths: [selectedPath],
                slices: [selectedPath: ranges],
                codemapAutoEnabled: false
            ))
            let selection = files.snapshotSelection()
            XCTAssertEqual(selection.selectedPaths, [selectedPath])
            XCTAssertEqual(selection.slices, [selectedPath: ranges])
            let selectedFileValue = await files.findFile(atPath: "Sources/Visible.swift")
            let selectedFile = try XCTUnwrap(selectedFileValue)
            let selectedContentValue = await selectedFile.latestContent
            let selectedContent = try XCTUnwrap(selectedContentValue)
            XCTAssertEqual(selectedContent, "let selectedValue = 42\nlet unselectedValue = 0\n")
            let assembly = SliceAssemblyBuilder.build(from: selectedContent, ranges: ranges)
            XCTAssertEqual(assembly.combinedText, "let selectedValue = 42\n")

            await prompt.tokenCountingViewModel.forceImmediateRecount()
            let expectedTokens = TokenCalculationService.estimateTokens(for: assembly.combinedText)
            XCTAssertGreaterThan(expectedTokens, 0)
            XCTAssertEqual(prompt.totalTokenCountFilesOnly, expectedTokens)
            XCTAssertEqual(prompt.fileTokenInfo[selectedFile.id]?.count, expectedTokens)
        }

        @MainActor
        func testPostActivationWindowTimesOutInsteadOfReturningEmptyConfiguredSnapshot() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogHeld")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                await gate.hold()
            }

            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-test")
            }
            await gate.waitUntilHeld()
            XCTAssertEqual(manager.activeWorkspaceID, target.id)

            do {
                _ = try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .milliseconds(20)
                )
                XCTFail("Configured workspace must not publish an empty snapshot while hydration is held")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .readinessTimedOut)
            }

            await gate.release()
            let switchResult = await switchTask.value
            XCTAssertTrue(switchResult.didSwitch)
            let snapshot = try await manager.awaitWorkspaceRootCatalogSnapshot(
                workspaceID: target.id,
                timeout: .seconds(1)
            )
            let storeRoots = await manager.fileManager.workspaceFileContextStore.roots()
                .filter { $0.kind == .primaryWorkspace }

            XCTAssertEqual(snapshot.configuredRootPaths, [rootURL.standardizedFileURL.path])
            XCTAssertEqual(snapshot.primaryRoots.map(\.id), storeRoots.map(\.id))
            XCTAssertEqual(snapshot.primaryRoots.map(\.standardizedFullPath), [rootURL.standardizedFileURL.path])
        }

        @MainActor
        func testCancelledCatalogWaitRemovesOnlyItsWaiter() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogCancelled")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                await gate.hold()
            }
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-cancel-test")
            }
            await gate.waitUntilHeld()
            let cancelledWait = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(30)
                )
            }
            let survivingWait = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(30)
                )
            }
            await Task.yield()
            await Task.yield()

            cancelledWait.cancel()
            do {
                _ = try await cancelledWait.value
                XCTFail("Cancelled waiter must throw")
            } catch is CancellationError {
                // Expected.
            }
            await gate.release()
            _ = await switchTask.value
            let survivingSnapshot = try await survivingWait.value
            XCTAssertEqual(survivingSnapshot.workspaceID, target.id)
            XCTAssertEqual(manager.workspaceSearchReadinessWaiterCountForTesting, 0)
        }

        @MainActor
        func testAdditionalLoadedPrimaryRootIsRejectedAsInconsistent() async throws {
            let configuredRoot = try makeTemporaryRoot(name: "CatalogConfigured")
            let extraRoot = try makeTemporaryRoot(name: "CatalogExtra")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [configuredRoot.path])
            let manager = makeManager(workspaces: [source, target], active: source)

            let result = await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-mismatch-test")
            XCTAssertTrue(result.didSwitch)
            _ = try await manager.fileManager.workspaceFileContextStore.loadRoot(path: extraRoot.path)

            do {
                _ = try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(1)
                )
                XCTFail("An additional primary root must invalidate exact catalog authority")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .inconsistentRootProjection)
            }
        }

        @MainActor
        func testGenerationInvalidationSupersedesPendingCatalogWait() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogSuperseded")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootHydrationWillSpawnHandlerForTesting { workspaceID in
                guard workspaceID == target.id else { return }
                await gate.hold()
            }
            let switchTask = Task { @MainActor in
                await manager.switchWorkspace(to: target, saveState: false, reason: "catalog-supersede-test")
            }
            await gate.waitUntilHeld()
            let waitTask = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(30)
                )
            }
            await Task.yield()
            await Task.yield()

            await manager.cancelCurrentWorkspaceSwitchAndReturnToSystem()
            do {
                _ = try await waitTask.value
                XCTFail("Invalidating the hydration generation must supersede the pending snapshot")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .readinessSuperseded)
            }
            XCTAssertEqual(manager.workspaceSearchReadinessWaiterCountForTesting, 0)

            await gate.release()
            _ = await switchTask.value
        }

        @MainActor
        func testGenerationInvalidationAfterRootCaptureUsesCatalogErrorTaxonomy() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogPostWaitSuperseded")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let result = await manager.switchWorkspace(
                to: target,
                saveState: false,
                reason: "catalog-post-wait-supersede-test"
            )
            XCTAssertTrue(result.didSwitch)
            manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting {
                manager.republishReadyRootCatalogWithNextGenerationForTesting()
            }
            addTeardownBlock { @MainActor in
                manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting(nil)
            }

            do {
                _ = try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(1)
                )
                XCTFail("Post-wait readiness invalidation must supersede the catalog snapshot")
            } catch let error as WorkspaceRootCatalogSnapshotError {
                XCTAssertEqual(error, .readinessSuperseded)
            } catch {
                XCTFail("Catalog snapshot must not leak an unrelated readiness error: \(error)")
            }
        }

        @MainActor
        func testCancellationAfterRootCaptureDoesNotPublishCatalogSnapshot() async throws {
            let rootURL = try makeTemporaryRoot(name: "CatalogPostCaptureCancellation")
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Target", repoPaths: [rootURL.path])
            let manager = makeManager(workspaces: [source, target], active: source)
            let result = await manager.switchWorkspace(
                to: target,
                saveState: false,
                reason: "catalog-post-capture-cancellation-test"
            )
            XCTAssertTrue(result.didSwitch)
            let gate = RootHydrationSuspensionGate()
            manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting {
                await gate.hold()
            }
            addTeardownBlock { @MainActor in
                manager.setWorkspaceRootCatalogDidCaptureRootsHandlerForTesting(nil)
                await gate.release()
            }

            let snapshotTask = Task { @MainActor in
                try await manager.awaitWorkspaceRootCatalogSnapshot(
                    workspaceID: target.id,
                    timeout: .seconds(1)
                )
            }
            await gate.waitUntilHeld()
            snapshotTask.cancel()
            await gate.release()

            do {
                _ = try await snapshotTask.value
                XCTFail("Cancellation after root capture must not publish a catalog snapshot")
            } catch is CancellationError {
                // Expected.
            }
        }

        @MainActor
        func testGenuinelyRootlessWorkspaceProducesSuccessfulEmptySnapshot() async throws {
            let source = WorkspaceModel(name: "Source", repoPaths: [])
            let target = WorkspaceModel(name: "Rootless", repoPaths: [])
            let manager = makeManager(workspaces: [source, target], active: source)

            let result = await manager.switchWorkspace(to: target, saveState: false, reason: "rootless-test")
            XCTAssertTrue(result.didSwitch)
            let snapshot = try await manager.awaitWorkspaceRootCatalogSnapshot(
                workspaceID: target.id,
                timeout: .seconds(1)
            )

            XCTAssertTrue(snapshot.isGenuinelyRootless)
            XCTAssertEqual(snapshot.configuredRootPaths, [])
            XCTAssertEqual(snapshot.primaryRoots, [])
        }

        func testDW22CatalogPathIndexDoesNotResolveRelativeFilenameURLs() {
            let rootID = UUID()
            let entries = (0 ..< 128).map { index in
                makeCatalogEntry(
                    rootID: rootID,
                    rootPath: "/tmp/dw22-catalog-root",
                    relativePath: "dir\(index % 8)/file\(index).swift"
                )
            }
            let identity = WorkspaceSearchRootPathIndexIdentity(
                rootID: rootID,
                lifetimeID: UUID(),
                topologyGeneration: 1
            )

            let observer = WorkspaceFileSearchCatalogBuildObserver()
            let index = WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(observer) {
                WorkspaceSearchRootPathIndex(identity: identity, rootPath: "/tmp/dw22-catalog-root", entries: entries)
            }
            var snapshot = observer.snapshot()
            XCTAssertEqual(
                snapshot.filenameURLInputCount,
                0,
                "catalog filename derivation must take final components from path bytes without URL work"
            )
            XCTAssertEqual(
                snapshot.relativeFilenameURLInputCount,
                0,
                "catalog filename derivation must not resolve relative composite search keys"
            )

            let overlayObserver = WorkspaceFileSearchCatalogBuildObserver()
            let overlay = WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(overlayObserver) {
                index.applyingPatch(identity: identity, entries: entries, changedFileIDs: [entries[0].id])
            }
            XCTAssertEqual(overlay.buildKind, .overlay)
            snapshot = overlayObserver.snapshot()
            XCTAssertEqual(snapshot.filenameURLInputCount, 0)
            XCTAssertEqual(snapshot.relativeFilenameURLInputCount, 0)
        }

        func testDW22CatalogFilenameMetadataPreservesLegacyCandidatesAndRetainedReaders() {
            let rootID = UUID()
            let rootPath = "/tmp/dw22-guard-root"
            let other = (rootID: UUID(), rootPath: "/tmp/dw22-guard-other")
            let cafe = "caf\u{e9}/re\u{301}sume\u{301}.txt"
            var entries = [
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "dir with space/a b.swift"),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "100%/50%25 off.txt"),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "hash#dir/file#1.md"),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: cafe),
                makeCatalogEntry(
                    rootID: rootID,
                    rootPath: rootPath,
                    relativePath: "labels/x.swift",
                    name: "Different Name",
                    displayPath: "Root\nLabel/x.swift"
                ),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "nl/line\nbreak.txt"),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "dots/..."),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "single/a"),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "one/dup.swift"),
                makeCatalogEntry(rootID: rootID, rootPath: rootPath, relativePath: "two/dup.swift"),
                makeCatalogEntry(
                    rootID: other.rootID,
                    rootPath: other.rootPath,
                    relativePath: "one/dup.swift"
                ),
                makeCatalogEntry(
                    rootID: rootID,
                    rootPath: rootPath,
                    relativePath: "linked/sym.swift",
                    fullPath: "/tmp/dw22-guard-link/real dir/sym.swift"
                )
            ]
            XCTAssertNotEqual(entries[11].standardizedFullPath, rootPath + "/" + entries[11].standardizedRelativePath)

            let catalogIndex = PathSearchIndex(catalogEntries: entries)
            let legacyIndex = PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            XCTAssertEqual(catalogIndex.count, entries.count)
            for (offset, entry) in entries.enumerated() {
                let legacy = URL(fileURLWithPath: entry.pathSearchIndexKey).lastPathComponent
                XCTAssertEqual(catalogIndex.filename(at: offset), legacy, entry.displayPath)
                XCTAssertEqual(catalogIndex.filename(at: offset), legacyIndex.filename(at: offset), entry.displayPath)
                XCTAssertEqual(
                    URL(fileURLWithPath: entry.standardizedFullPath, isDirectory: false).lastPathComponent,
                    legacy,
                    entry.displayPath
                )
                XCTAssertEqual(catalogIndex.path(at: offset), entry.pathSearchIndexKey)
            }
            XCTAssertEqual(catalogIndex.filename(at: 6), "...")
            XCTAssertEqual(catalogIndex.filename(at: 7), "a")
            XCTAssertEqual(catalogIndex.filename(at: 5), "line\nbreak.txt")
            XCTAssertNil(catalogIndex.filename(at: entries.count))
            XCTAssertEqual(PathSearchIndex(catalogEntries: []).count, 0)
            XCTAssertNil(PathSearchIndex(catalogEntries: []).filename(at: 0))

            let queries = ["", "a", "dup", "swift", "txt", "sym", "x", "line", "...", "50", "zzz-no-match"]
            for query in queries {
                for limit in [1, 3, 300] {
                    XCTAssertEqual(
                        catalogIndex.searchSynchronously(query, limit: limit),
                        legacyIndex.searchSynchronously(query, limit: limit),
                        "query=\(query) limit=\(limit)"
                    )
                }
            }

            let identity = WorkspaceSearchRootPathIndexIdentity(rootID: rootID, lifetimeID: UUID(), topologyGeneration: 1)
            let first = WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            assertRootSearchMatchesOracle(first, entries: entries, queries: queries)

            let renamed = makeCatalogEntry(
                rootID: rootID,
                rootPath: rootPath,
                relativePath: "moved/dup.swift",
                id: entries[8].id
            )
            entries[8] = renamed
            let second = first.applyingPatch(identity: identity, entries: entries, changedFileIDs: [renamed.id])
            XCTAssertEqual(second.buildKind, .overlay)
            assertRootSearchMatchesOracle(second, entries: entries, queries: queries)
            assertRootSearchMatchesOracle(
                first,
                entries: Array(entries.enumerated().map { offset, entry in
                    offset == 8 ? makeCatalogEntry(
                        rootID: rootID,
                        rootPath: rootPath,
                        relativePath: "one/dup.swift",
                        id: entry.id
                    ) : entry
                }),
                queries: queries
            )
        }

        func testDW22CatalogBinaryComparisonUsesContiguousUTF8InsteadOfScalarPairs() {
            let shared = [UInt8](repeating: UInt8(ascii: "a"), count: 4096)
            let lhs = String(decoding: shared + [UInt8(ascii: "a")], as: UTF8.self)
            let rhs = String(decoding: shared + [UInt8(ascii: "b")], as: UTF8.self)
            XCTAssertEqual(lhs.utf8.withContiguousStorageIfAvailable { $0.count }, 4097)
            XCTAssertEqual(rhs.utf8.withContiguousStorageIfAvailable { $0.count }, 4097)

            let observer = WorkspaceFileSearchCatalogBuildObserver(recordBinaryComparisonWorkForTesting: true)
            let result = WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(observer) {
                WorkspaceFileContextStore.compareUTF8Binary(lhs, rhs)
            }
            let snapshot = observer.snapshot()
            XCTAssertEqual(result, .orderedAscending)
            XCTAssertEqual(
                snapshot.storeScalarUTF8BytePairCount,
                0,
                "catalog comparison must not iterate a shared UTF-8 prefix byte pair by byte pair"
            )
            XCTAssertEqual(
                snapshot.contiguousUTF8MemcmpCallCount,
                1,
                "the native catalog comparison must use the existing contiguous byte comparator"
            )

            let defaultObserver = WorkspaceFileSearchCatalogBuildObserver()
            _ = WorkspaceFileSearchDebugContext.$catalogBuildObserver.withValue(defaultObserver) {
                WorkspaceFileContextStore.compareUTF8Binary(lhs, rhs)
            }
            XCTAssertEqual(defaultObserver.snapshot().storeScalarUTF8BytePairCount, 0)
            XCTAssertEqual(defaultObserver.snapshot().contiguousUTF8MemcmpCallCount, 0)
        }

        func testDW22CatalogBinaryComparisonPreservesHistoricalByteOrderAndRetainedCatalogs() async throws {
            let composed = "caf\u{e9}"
            let decomposed = "cafe\u{301}"
            XCTAssertEqual(composed, decomposed)
            XCTAssertEqual(
                WorkspaceFileContextStore.compareUTF8Binary(composed, decomposed),
                Self.byteOracle(Array(composed.utf8), Array(decomposed.utf8))
            )
            XCTAssertNotEqual(WorkspaceFileContextStore.compareUTF8Binary(composed, decomposed), .orderedSame)

            let samples = [
                "", "a", "ab", "abc", "Ab", "aB", "a/b", "a/b/c", "a-b", "a.b", "a\nb", "a\0b", "a\0",
                composed, decomposed, "\u{1F600}", "z\u{1F600}", "\u{4E2D}\u{6587}", "\u{FF}",
                String(repeating: "x", count: 600) + "a", String(repeating: "x", count: 600) + "b",
                String(repeating: "x", count: 600)
            ]
            var variants: [String] = []
            for sample in samples {
                variants.append(sample)
                variants.append(NSString(string: sample) as String)
                let utf16 = Array(sample.utf16)
                variants.append(utf16.withUnsafeBufferPointer {
                    NSString(characters: $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, length: utf16.count) as String
                })
            }
            for lhs in variants {
                for rhs in variants {
                    XCTAssertEqual(
                        WorkspaceFileContextStore.compareUTF8Binary(lhs, rhs),
                        Self.byteOracle(Array(lhs.utf8), Array(rhs.utf8)),
                        "lhs=\(Array(lhs.utf8).prefix(8)) rhs=\(Array(rhs.utf8).prefix(8))"
                    )
                }
            }

            let rootA = try makeTemporaryRoot(name: "BinaryOrderA")
            let rootB = try makeTemporaryRoot(name: "BinaryOrderB")
            for relative in ["B.swift", "a.swift", "dir/x.swift", "dir-x.swift", "dir.x.swift", "one/dup.swift"] {
                try writeFixture("let v = 1\n", to: relative, in: rootA)
            }
            for relative in ["one/dup.swift", "a.swift", "Z.swift"] {
                try writeFixture("let v = 2\n", to: relative, in: rootB)
            }

            let store = WorkspaceFileContextStore()
            let recordA = try await store.loadRoot(path: rootA.path)
            _ = try await store.loadRoot(path: rootB.path)
            let first = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            assertCatalogOrder(first)
            XCTAssertEqual(first.files.count, 9)

            _ = try await store.createFile(rootID: recordA.id, relativePath: "dir/y.swift", content: "let v = 3\n")
            let second = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
            assertCatalogOrder(second)
            XCTAssertEqual(second.files.count, 10)
            assertCatalogOrder(first)
            XCTAssertEqual(first.files.count, 9)
            for index in first.rootPathIndexes + second.rootPathIndexes {
                let candidates = index.search("swift", limit: 300)
                for pair in zip(candidates, candidates.dropFirst()) where pair.0.score == pair.1.score {
                    XCTAssertNotEqual(
                        Self.byteOracle(Array(pair.0.tieBreakKey.utf8), Array(pair.1.tieBreakKey.utf8)),
                        .orderedDescending
                    )
                }
            }
        }

        private static func byteOracle(_ lhs: [UInt8], _ rhs: [UInt8]) -> ComparisonResult {
            var index = 0
            while index < lhs.count, index < rhs.count {
                if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending }
                index += 1
            }
            if lhs.count == rhs.count { return .orderedSame }
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }

        private func assertCatalogOrder(
            _ snapshot: WorkspaceSearchCatalogSnapshot,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let expected = snapshot.files.sorted { lhs, rhs in
                let byPath = Self.byteOracle(Array(lhs.standardizedFullPath.utf8), Array(rhs.standardizedFullPath.utf8))
                if byPath != .orderedSame { return byPath == .orderedAscending }
                return Self.byteOracle(Array(lhs.id.uuidString.utf8), Array(rhs.id.uuidString.utf8)) == .orderedAscending
            }
            XCTAssertEqual(snapshot.files.map(\.id), expected.map(\.id), file: file, line: line)
            XCTAssertEqual(snapshot.entries.map(\.id), expected.map(\.id), file: file, line: line)
        }

        private func assertRootSearchMatchesOracle(
            _ index: WorkspaceSearchRootPathIndex,
            entries: [WorkspaceSearchCatalogEntry],
            queries: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let oracle = PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            for query in queries {
                for limit in [1, 3, 300] {
                    let expected = oracle.searchSynchronously(query, limit: limit)
                    let actual = index.search(query, limit: limit)
                    XCTAssertEqual(
                        actual.map(\.entry.id),
                        expected.map { entries[$0.index].id },
                        "query=\(query) limit=\(limit)",
                        file: file,
                        line: line
                    )
                    XCTAssertEqual(
                        actual.map(\.tieBreakKey),
                        expected.map(\.tieBreakKey),
                        file: file,
                        line: line
                    )
                    XCTAssertEqual(actual.map(\.score), expected.map(\.score), file: file, line: line)
                }
            }
        }

        private func makeCatalogEntry(
            rootID: UUID,
            rootPath: String,
            relativePath: String,
            name: String? = nil,
            displayPath: String? = nil,
            fullPath: String? = nil,
            id: UUID = UUID()
        ) -> WorkspaceSearchCatalogEntry {
            let root = WorkspaceRootRecord(id: rootID, name: URL(fileURLWithPath: rootPath).lastPathComponent, fullPath: rootPath)
            let file = WorkspaceFileRecord(
                id: id,
                rootID: rootID,
                name: name ?? (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                fullPath: fullPath ?? rootPath + "/" + relativePath,
                parentFolderID: nil
            )
            return WorkspaceSearchCatalogEntry(file: file, root: root, displayPath: displayPath)
        }

        @MainActor
        private func makeManager(
            workspaces: [WorkspaceModel],
            active: WorkspaceModel
        ) -> WorkspaceManagerViewModel {
            let files = WorkspaceFilesViewModel()
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            let prompt = PromptViewModel(
                fileManager: files,
                apiSettingsViewModel: apiSettings,
                windowID: -1,
                settingsManager: WindowSettingsManager(windowID: -1)
            )
            let manager = WorkspaceManagerViewModel(
                fileManager: files,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
            manager.workspaces = workspaces
            manager.activeWorkspace = active
            return manager
        }

        private func writeFixture(_ content: String, to relativePath: String, in root: URL) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        private func makeTemporaryRoot(name: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            return root
        }
    }

    private actor RootHydrationSuspensionGate {
        private var held = false
        private var released = false
        private var heldWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            held = true
            let waiters = heldWaiters
            heldWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilHeld() async {
            guard !held else { return }
            await withCheckedContinuation { heldWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
#endif
