import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AntigravityLegacySessionFenceTests: XCTestCase {
    private enum IDs {
        static let workspace = UUID(uuidString: "A6710000-0000-0000-0000-000000000001")!
        static let tab = UUID(uuidString: "A6710000-0000-0000-0000-000000000002")!
        static let session = UUID(uuidString: "A6710000-0000-0000-0000-000000000003")!
    }

    private static let legacyModelRaw = "legacy-antigravity-acp-model"
    private static let legacyProviderSessionID = "legacy-antigravity-acp-session"
    private static let legacyRequest = "legacy request"
    private static let legacyResponse = "legacy response"

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let workspace: WorkspaceModel
        let workspaceManager: WorkspaceManagerViewModel
        let prompt: PromptViewModel
        let apiSettings: APISettingsViewModel
        let storageURL: URL
        let durableTranscript: AgentTranscript
    }

    func testHydratedLegacyAntigravitySessionReplaysHistoryWithoutForeignResumeHandle() async throws {
        try await withFixture { fixture in
            assertHydratedLegacyState(fixture)

            let message = fixture.viewModel.test_buildHeadlessAgentMessage(
                session: fixture.session,
                initialMessageForRun: "continue normally"
            )

            XCTAssertNil(message.resumeSessionID)
            XCTAssertTrue(message.userMessage.contains("<previous_conversation>"))
            XCTAssertTrue(message.userMessage.contains(Self.legacyRequest))
            XCTAssertTrue(message.userMessage.contains(Self.legacyResponse))
            XCTAssertTrue(message.userMessage.contains("<current_instruction>"))
            XCTAssertTrue(message.userMessage.contains("continue normally"))

            try await assertDurableLegacyStateUnchanged(fixture)
        }
    }

    func testHydratedLegacyAntigravityStagedHandoffBypassesHistoryWithoutForeignResumeHandle() async throws {
        try await withFixture { fixture in
            assertHydratedLegacyState(fixture)

            let handoffPayload = "<forked_session delivery_id=\"session-fence-red\">handoff sentinel</forked_session>"
            fixture.session.pendingHandoff.payload = handoffPayload
            let stagedMessage = fixture.viewModel.prependPendingHandoffIfNeeded(
                "continue from handoff",
                session: fixture.session
            )

            XCTAssertTrue(fixture.session.pendingHandoff.isStagedForSend)
            XCTAssertEqual(stagedMessage, handoffPayload + "\n\ncontinue from handoff")

            let message = fixture.viewModel.test_buildHeadlessAgentMessage(
                session: fixture.session,
                initialMessageForRun: stagedMessage
            )

            XCTAssertEqual(message.userMessage, stagedMessage)
            XCTAssertFalse(message.userMessage.contains("<previous_conversation>"))
            XCTAssertNil(message.resumeSessionID)

            try await assertDurableLegacyStateUnchanged(fixture)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityLegacySessionFenceTests-\(UUID().uuidString)", isDirectory: true)
        var viewModelForCleanup: AgentModeViewModel?
        var workspaceManagerForCleanup: WorkspaceManagerViewModel?
        var apiSettingsForCleanup: APISettingsViewModel?

        do {
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

            let workspace = WorkspaceModel(
                id: IDs.workspace,
                name: "Antigravity legacy session fence",
                repoPaths: [],
                customStoragePath: storageURL,
                ephemeralFlag: true,
                composeTabs: [
                    ComposeTabState(
                        id: IDs.tab,
                        name: "Session fence",
                        activeAgentSessionID: IDs.session
                    )
                ],
                activeComposeTabID: IDs.tab
            )
            let savedTranscript = AgentTranscriptIO.importLegacyItems([
                .user(Self.legacyRequest, sequenceIndex: 0),
                .assistant(Self.legacyResponse, sequenceIndex: 1)
            ])
            let savedAt = Date(timeIntervalSinceReferenceDate: 1000)
            let persistedSession = AgentSession(
                id: IDs.session,
                workspaceID: IDs.workspace,
                composeTabID: IDs.tab,
                name: "Legacy Antigravity session",
                savedAt: savedAt,
                items: [],
                transcript: savedTranscript,
                itemCount: 2,
                transcriptProjectionCounts: AgentTranscriptProjectionBuilder.projectionCounts(for: savedTranscript),
                lastUserMessageAt: savedAt,
                agentKind: AgentProviderKind.antigravity.rawValue,
                agentModel: Self.legacyModelRaw,
                lastRunState: AgentSessionRunState.idle.rawValue,
                providerSessionID: Self.legacyProviderSessionID,
                autoEditEnabled: true
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persistedSession,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 2
            )
            let initiallyLoaded = try await AgentSessionDataService.shared.loadAgentSession(id: IDs.session, for: workspace)
            let initiallyReloaded = try XCTUnwrap(initiallyLoaded)
            let durableTranscript = try XCTUnwrap(initiallyReloaded.transcript)
            XCTAssertEqual(
                initiallyReloaded.workingSourceItems().map(\.text),
                [Self.legacyRequest, Self.legacyResponse]
            )

            let workspaceFiles = WorkspaceFilesViewModel()
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            apiSettingsForCleanup = apiSettings
            let prompt = PromptViewModel(
                fileManager: workspaceFiles,
                apiSettingsViewModel: apiSettings,
                windowID: -671,
                settingsManager: WindowSettingsManager(windowID: -671)
            )
            let workspaceManager = WorkspaceManagerViewModel(
                fileManager: workspaceFiles,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
            workspaceManagerForCleanup = workspaceManager
            workspaceManager.workspaces = [workspace]
            workspaceManager.activeWorkspace = workspace

            let viewModel = AgentModeViewModel(
                testWindowID: -671,
                testWorkspacePath: storageURL.path,
                testWorkspaceDirectory: storageURL,
                applyEditsApprovalStore: ApplyEditsApprovalStore(),
                codexControllerFactory: { _, _, _, _, _, _ in
                    XCTFail("Codex controller factory must not be called")
                    return LifecycleNoopCodexController(recorder: LifecycleRecorder())
                },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpServerEnabler: { true }
            )
            viewModelForCleanup = viewModel
            viewModel.workspaceManager = workspaceManager
            viewModel.promptManager = prompt
            viewModel.test_setCurrentTabIDOverride(IDs.tab)

            let session = AgentModeViewModel.TabSession(tabID: IDs.tab)
            viewModel.test_installLiveSession(session)
            _ = try XCTUnwrap(
                viewModel.test_installPersistentSessionBinding(sessionID: IDs.session, on: session)
            )
            let hydratedSession = await viewModel.ensureSessionReady(tabID: IDs.tab)
            XCTAssertTrue(hydratedSession === session)

            return Fixture(
                viewModel: viewModel,
                session: hydratedSession,
                workspace: workspace,
                workspaceManager: workspaceManager,
                prompt: prompt,
                apiSettings: apiSettings,
                storageURL: storageURL,
                durableTranscript: durableTranscript
            )
        } catch {
            if let viewModelForCleanup {
                await viewModelForCleanup.prepareForWindowClose()
            }
            workspaceManagerForCleanup?.prepareForWindowClose()
            apiSettingsForCleanup?.prepareForWindowClose()
            try? FileManager.default.removeItem(at: storageURL)
            throw error
        }
    }

    private func assertHydratedLegacyState(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(fixture.session.hasLoadedPersistedState, file: file, line: line)
        XCTAssertEqual(fixture.session.activeAgentSessionID, IDs.session, file: file, line: line)
        XCTAssertEqual(fixture.session.selectedAgent, .antigravity, file: file, line: line)
        XCTAssertEqual(fixture.session.selectedModelRaw, Self.legacyModelRaw, file: file, line: line)
        XCTAssertEqual(fixture.session.providerSessionID, Self.legacyProviderSessionID, file: file, line: line)
        XCTAssertEqual(
            fixture.session.items.map(\.text),
            [Self.legacyRequest, Self.legacyResponse],
            file: file,
            line: line
        )
    }

    private func assertDurableLegacyStateUnchanged(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let loaded = try await AgentSessionDataService.shared.loadAgentSession(
            id: IDs.session,
            for: fixture.workspace
        )
        let reloaded = try XCTUnwrap(loaded, file: file, line: line)
        XCTAssertEqual(reloaded.agentModel, Self.legacyModelRaw, file: file, line: line)
        XCTAssertEqual(reloaded.transcript, fixture.durableTranscript, file: file, line: line)
        XCTAssertEqual(
            reloaded.workingSourceItems().map(\.text),
            [Self.legacyRequest, Self.legacyResponse],
            file: file,
            line: line
        )
    }

    private func cleanup(_ fixture: Fixture) async {
        await fixture.viewModel.prepareForWindowClose()
        fixture.workspaceManager.prepareForWindowClose()
        fixture.apiSettings.prepareForWindowClose()
        _ = fixture.prompt
        try? FileManager.default.removeItem(at: fixture.storageURL)
    }
}
