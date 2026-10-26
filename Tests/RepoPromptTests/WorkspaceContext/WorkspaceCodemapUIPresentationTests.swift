import Combine
@testable import RepoPromptApp
import RepoPromptFileSystem
import XCTest

@MainActor
final class WorkspaceCodemapUIPresentationTests: XCTestCase {
    func testCurrentMarkerRequiresRenderablePresentationIdentity() throws {
        let file = makeFileViewModel(name: "Marker.swift")
        let entry = try makePresentationEntry(file: file)

        XCTAssertFalse(PromptFileEntry(file: file, codemap: nil, ranges: nil).isCodemap)
        XCTAssertTrue(PromptFileEntry(file: file, codemap: entry, ranges: nil).isCodemap)
        XCTAssertEqual(entry.fileID, file.id)
    }

    func testPreviewPayloadUsesImmutableLogicalPathAndText() throws {
        let file = makeFileViewModel(name: "Preview.swift")
        let entry = try makePresentationEntry(file: file)
        let originalText = entry.text
        let originalLogicalPath = entry.logicalPath.displayPath

        XCTAssertEqual(entry.text, originalText)
        XCTAssertEqual(entry.logicalPath.displayPath, originalLogicalPath)
        XCTAssertFalse(entry.logicalPath.displayPath.contains(file.rootFolderPath))
    }

    func testPreviewRevokesWhenRenderableFileIdentityIsGone() async {
        let manager = WorkspaceFilesViewModel()

        let disposition = await manager.codemapPreview(for: UUID())

        XCTAssertEqual(disposition, .revoked)
    }

    // The obsolete plain-folder "typed unavailable" preview contract was removed with non-Git
    // Code Map support. Positive preview coverage for a plain on-disk root now lives in
    // `CodemapAutomaticSelectionGraphNativeTests`
    // `.testFilesystemTSAndTSXCodeMapsUseCurrentBytesWithoutGitOrManifestAccess`, which asserts a
    // rendered entry containing the actual current symbols instead of an unavailability reason.

    private func makeFileViewModel(name: String) -> FileViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCodemapUIPresentationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FileViewModel(
            file: File(
                name: name,
                path: root.appendingPathComponent(name).path,
                modificationDate: Date(timeIntervalSince1970: 1000)
            ),
            rootPath: root.path,
            rootIdentifier: UUID(),
            rootFolderPath: root.path,
            fileSystemService: nil
        )
    }

    private func makePresentationEntry(file: FileViewModel) throws -> WorkspaceCodemapUIPresentationEntry {
        let logicalPath = try XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
            rootDisplayName: "LogicalRoot",
            standardizedRelativePath: file.name
        ))
        return WorkspaceCodemapUIPresentationEntry(
            presentationID: UUID(),
            fileID: file.id,
            rootEpoch: WorkspaceCodemapRootEpoch(
                rootID: file.rootIdentifier,
                rootLifetimeID: UUID()
            ),
            logicalPath: logicalPath,
            text: SwiftFixtureSource.emptyStruct("RenderedPreview", trailingNewline: false),
            tokenCount: 7
        )
    }
}

/// Content edits keep the path-match index, and token recounts stay one running plus one pending.
@MainActor
final class WorkspacePathMatchChurnTests: XCTestCase {
    /// Drives a content-only applied-index event through the projected view model and a token
    /// recount that resolves the selected path. The path-match index must stay cached.
    func testContentOnlyChangeKeepsPathMatchIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePathMatchChurnTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("App.swift")
        try "struct App { let id: Int }\n".write(to: source, atomically: true, encoding: .utf8)
        let store = WorkspaceFileContextStore()
        let files = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let tokens = TokenCountingViewModel()
        addTeardownBlock {
            await tokens.stopTokenCountUpdateTimer()
            await files.unloadAllRootFolders()
            try? FileManager.default.removeItem(at: root)
        }
        try await waitUntil {
            let counts = await store.streamContinuationCountsForTesting()
            return counts.appliedIndex >= 1
        }

        let workspace = WorkspaceModel(name: "PathMatchChurn", repoPaths: [root.path])
        try await files.loadFolder(at: root, for: workspace)
        let rootID = try XCTUnwrap(files.rootFolders.first?.id)
        let primedSnapshot = await store.appliedIndexRootSnapshot(rootID: rootID)
        let primedGeneration = try XCTUnwrap(primedSnapshot?.generation)
        let projectedPrime = await files.debugWaitForAppliedIndexGeneration(
            rootID: rootID,
            targetGeneration: primedGeneration,
            deadline: ContinuousClock().now.advanced(by: .seconds(5))
        )
        XCTAssertTrue(projectedPrime)

        tokens.configure(
            fileManager: files,
            gitViewModel: GitViewModel(fileManager: files, refreshGitContexts: { _ in [] }),
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: {
                TokenCountingViewModel.TokenCalculationSettings(
                    fileTreeOption: .none,
                    codeMapUsage: .none,
                    filePathDisplayOption: .relative,
                    includeFilesInClipboard: false,
                    duplicateUserInstructionsAtTop: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    codeMapsGloballyDisabled: true
                )
            },
            getCopyContext: {
                TokenCountingViewModel.CopyContextSnapshot(
                    includeFiles: true,
                    includeUserPrompt: false,
                    includeMetaPrompts: false,
                    includeFileTree: false,
                    fileTreeMode: .none,
                    codeMapUsage: .none,
                    gitInclusion: .none,
                    duplicateUserInstructionsAtTop: false
                )
            },
            getStoredSelection: {
                StoredSelection(selectedPaths: ["App.swift"], codemapAutoEnabled: false)
            }
        )

        await tokens.forceImmediateRecount()
        let buildsAfterPrime = await store.pathMatchIndexBuildCountForTesting()
        XCTAssertGreaterThan(buildsAfterPrime, 0)
        await tokens.forceImmediateRecount()
        let buildsAfterSecondRecount = await store.pathMatchIndexBuildCountForTesting()
        XCTAssertEqual(buildsAfterSecondRecount, buildsAfterPrime)
        let startsAfterPrime = tokens.tokenCalculationStartCountForTesting()
        XCTAssertGreaterThanOrEqual(startsAfterPrime, 2)
        let resyncBeforeEdit = files.appliedIndexProjectionDiagnosticsSnapshot().canonicalResyncCount

        try "struct App { let renamed: Int }\n".write(to: source, atomically: true, encoding: .utf8)
        await store.replayObservedFileSystemDeltas(
            rootID: rootID,
            deltas: [.fileModified("App.swift", Date())]
        )
        let editedSnapshot = await store.appliedIndexRootSnapshot(rootID: rootID)
        let editedGeneration = try XCTUnwrap(editedSnapshot?.generation)
        XCTAssertGreaterThan(editedGeneration, primedGeneration)
        let projectedEdit = await files.debugWaitForAppliedIndexGeneration(
            rootID: rootID,
            targetGeneration: editedGeneration,
            deadline: ContinuousClock().now.advanced(by: .seconds(5))
        )
        XCTAssertTrue(projectedEdit)
        XCTAssertEqual(
            files.appliedIndexProjectionDiagnosticsSnapshot().canonicalResyncCount,
            resyncBeforeEdit
        )

        await tokens.forceImmediateRecount()
        let buildsAfterContentEdit = await store.pathMatchIndexBuildCountForTesting()
        XCTAssertEqual(buildsAfterContentEdit, buildsAfterPrime)
        XCTAssertGreaterThan(tokens.tokenCalculationStartCountForTesting(), startsAfterPrime)
    }

    func testTokenCountRequestsCoalesceDuringChurn() async throws {
        let files = WorkspaceFilesViewModel()
        let tokens = TokenCountingViewModel()
        let gate = TestReleaseFence(name: "token churn")
        addTeardownBlock {
            gate.release()
            await tokens.stopTokenCountUpdateTimer()
        }
        tokens.setBeforeTokenCalculationForTesting {
            await gate.enterAndWait()
        }
        tokens.configure(
            fileManager: files,
            gitViewModel: GitViewModel(fileManager: files, refreshGitContexts: { _ in [] }),
            getPromptText: { "" },
            getSelectedInstructionsText: { "" },
            getSettings: {
                TokenCountingViewModel.TokenCalculationSettings(
                    fileTreeOption: .none,
                    codeMapUsage: .none,
                    filePathDisplayOption: .relative,
                    includeFilesInClipboard: false,
                    duplicateUserInstructionsAtTop: false,
                    onlyIncludeRootsWithSelectedFiles: false,
                    codeMapsGloballyDisabled: true
                )
            },
            getCopyContext: { .default },
            getStoredSelection: { nil }
        )

        files.fileSystemChangedPublisher.send()
        try await waitUntil { tokens.tokenCalculationStartCountForTesting() >= 1 }
        XCTAssertEqual(tokens.tokenCalculationStartCountForTesting(), 1)
        for _ in 0 ..< 8 {
            files.fileSystemChangedPublisher.send()
        }
        gate.release()
        try await Task.sleep(for: .milliseconds(800))
        let starts = tokens.tokenCalculationStartCountForTesting()
        XCTAssertLessThanOrEqual(starts, 2, "Token recount starts=\(starts); bound is one running plus one pending")
        XCTAssertGreaterThanOrEqual(starts, 1)
    }

    private func waitUntil(
        _ condition: @MainActor () async -> Bool,
        timeoutSeconds: Double = 3
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}
