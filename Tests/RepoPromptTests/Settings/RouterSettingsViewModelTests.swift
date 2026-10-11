@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class RouterSettingsViewModelTests: XCTestCase {
    private static let catalogs: [AgentProviderKind: [String]] = [
        .codexExec: ["gpt-6-luna", "gpt-5.6-terra", "gpt-6.1-sol", "gpt-6-astra"],
        .claudeCode: ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"],
        .antigravity: [
            "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low", "gemini-3.7-flash-high",
            "gemini-3.1-pro-high", "gemini-3.1-pro-low", "claude-opus-5-5-high", "gpt-oss-120b-medium"
        ],
        .grok: ["grok-4.7", "grok-4.6"],
        .cursor: ["composer-2.5", "grok-4.7", "claude-opus-5-5", "gemini-3.8-flash", "kimi-k3"]
    ]

    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    func testAutomaticFrontierIgnoresLegacyRoleAndProviderSelections() async throws {
        let fixture = try makeFixture()
        fixture.store.setModelRouterCandidateRoles([])
        fixture.store.setModelRouterAllowedProviders([])

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.viewModel.policyCanBuildCandidates)
        XCTAssertGreaterThan(fixture.viewModel.distinctTargetCount, 1)
        XCTAssertTrue(fixture.viewModel.availableProviders.contains(.codexExec))
        XCTAssertTrue(fixture.viewModel.availableProviders.contains(.claudeCode))
    }

    func testSelectingBackendImmediatelyClearsOldReadinessAndPreservesConsent() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
        fixture.viewModel.setProviderLimit(.claudeCode, scope: .subagent)

        fixture.viewModel.selectBackend(.init(rawValue: "uninstalled"))
        XCTAssertEqual(fixture.viewModel.selectedBackendID?.rawValue, "uninstalled")
        XCTAssertFalse(fixture.viewModel.canEnable)
        XCTAssertNil(fixture.viewModel.backendSettingsPresentation)
        XCTAssertEqual(fixture.viewModel.providerLimit(for: .subagent), .claudeCode)
        await fixture.viewModel.refresh()
        guard case .temporarilyUnavailable = fixture.viewModel.readiness else {
            return XCTFail("Unknown backend must remain unavailable")
        }
    }

    func testReselectingSameBackendDoesNotInvalidateValidatedConfiguration() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        let configuration = fixture.viewModel.configuration
        try fixture.viewModel.selectBackend(XCTUnwrap(configuration.selectedBackendID))
        XCTAssertEqual(fixture.store.modelRouterConfiguration(), configuration)
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
    }

    func testSavedKeyVerificationPublishesExplicitSuccessFeedback() async throws {
        let controller = SettingsTestController(result: .succeeded("Key verified. Jev is ready."))
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.revalidateStoredSecret)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback,
            .succeeded("Key verified. Jev is ready.")
        )
    }

    func testFailedBackendActionReturnsFalseAndPublishesFeedback() async throws {
        let controller = SettingsTestController(result: .failed("Authentication failed."))
        let fixture = try makeFixture(settingsController: controller)
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.validateAndSaveSecret("candidate"))

        XCTAssertFalse(succeeded)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback, .failed("Authentication failed."))
    }

    func testSuccessfulStoredSecretRemovalDisablesRouter() async throws {
        let controller = SettingsTestController(result: .succeeded("Stored key removed."))
        let fixture = try makeFixture(settingsController: controller)
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.removeStoredSecret)

        XCTAssertTrue(succeeded)
        XCTAssertFalse(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertFalse(fixture.viewModel.configuration.enabled)
    }

    func testFailedStoredSecretRemovalPreservesRouterEnablementIntent() async throws {
        let controller = SettingsTestController(result: .failed("Removal failed."))
        let fixture = try makeFixture(settingsController: controller)
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        await fixture.viewModel.refresh()

        let succeeded = await fixture.viewModel.performBackendAction(.removeStoredSecret)

        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.configuration.enabled)
    }

    func testUnavailableSettingsControllerClearsBackendOperationProgress() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()

        await fixture.viewModel.performBackendAction(.revalidateStoredSecret)

        XCTAssertFalse(fixture.viewModel.isPerformingBackendOperation)
        XCTAssertEqual(fixture.viewModel.backendOperationFeedback, .idle)
    }

    func testScopedProviderLimitsAndCustomGuidancePersistThroughViewModel() throws {
        let fixture = try makeFixture()
        fixture.store.setModelRouterAllowedProviders([.codexExec, .claudeCode])

        fixture.viewModel.setProviderLimit(.codexExec, scope: .primarySession)
        fixture.viewModel.setProviderLimit(.claudeCode, scope: .subagent)
        XCTAssertTrue(fixture.viewModel.setCustomInstructions("  Prefer Claude Opus for execution.  "))

        let configuration = fixture.store.modelRouterConfiguration()
        XCTAssertEqual(configuration.primaryProvider, .codexExec)
        XCTAssertEqual(configuration.subagentProvider, .claudeCode)
        XCTAssertEqual(configuration.customInstructions, "Prefer Claude Opus for execution.")
        XCTAssertEqual(fixture.viewModel.providerLimit(for: .primarySession), .codexExec)
        XCTAssertEqual(fixture.viewModel.providerLimit(for: .subagent), .claudeCode)
    }

    func testCompletedProviderValidationWithNoAuthenticatedTargetsPreservesEnablementIntent() async throws {
        let fixture = try makeFixture(
            availability: .none,
            verifiedProviders: []
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.configuration.enabled)
        XCTAssertFalse(fixture.viewModel.canEnable)
    }

    func testUnavailableSubagentPreferenceDoesNotBlockAuthenticatedCodex() async throws {
        let fixture = try makeFixture(
            availability: AgentModelCatalog.AvailabilityContext(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false
            ),
            verifiedProviders: [.codexExec]
        )
        fixture.store.enableModelRouterWithCurrentPolicy(
            backendID: .jev,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: [.claudeCode, .codexExec]
        )
        fixture.viewModel.setProviderLimit(.codexExec, scope: .primarySession)
        fixture.viewModel.setProviderLimit(.claudeCode, scope: .subagent)

        await fixture.viewModel.refresh()

        XCTAssertTrue(fixture.store.modelRouterConfiguration().enabled)
        XCTAssertTrue(fixture.viewModel.canEnable)
        XCTAssertEqual(fixture.viewModel.availableProviders, [.codexExec])
        XCTAssertEqual(
            fixture.viewModel.unavailableProviderPreferences,
            [.init(scope: .subagent, provider: .claudeCode)]
        )
    }

    private func availability(
        claude: Bool = true,
        codex: Bool = true,
        cursor: Bool = false,
        antigravity: Bool = false,
        grok: Bool = false
    ) -> AgentModelCatalog.AvailabilityContext {
        .init(
            claudeCodeAvailable: claude, codexAvailable: codex, openCodeAvailable: false,
            cursorAvailable: cursor, antigravityAvailable: antigravity, grokAvailable: grok
        )
    }

    private func builder(for catalogs: [AgentProviderKind: [String]]) -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(cursorThinking: { _ in nil }, modelOptions: { provider, _ in
            (catalogs[provider] ?? []).map {
                AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false)
            }
        })
    }

    func testPreviewIncludesNewFamilyTargets() async throws {
        let five = availability(cursor: true, antigravity: true, grok: true)
        let fixture = try makeFixture(availability: five, candidateBuilder: { self.builder(for: Self.catalogs) })
        await fixture.viewModel.refresh()

        let ids = Set(fixture.viewModel.targetPreviews.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "antigravity:gemini-3.8-flash", "antigravity:gemini-3.1-pro", "grok:grok-4.7", "cursor:composer-2.5"
        ]))
        XCTAssertEqual(fixture.viewModel.distinctTargetCount, 12)

        let fiveWithoutGrok = availability(cursor: true, antigravity: true, grok: false)
        let fallbackFixture = try makeFixture(
            availability: fiveWithoutGrok,
            candidateBuilder: { self.builder(for: Self.catalogs) }
        )
        await fallbackFixture.viewModel.refresh()
        let fallbackIDs = Set(fallbackFixture.viewModel.targetPreviews.map(\.id))
        XCTAssertTrue(fallbackIDs.contains("cursor:grok-4.7"))
        XCTAssertFalse(fallbackIDs.contains("grok:grok-4.7"))

        let baseFixture = try makeFixture(availability: availability(), candidateBuilder: { self.builder(for: Self.catalogs) })
        await baseFixture.viewModel.refresh()
        XCTAssertFalse(baseFixture.viewModel.targetPreviews.contains {
            [.cursor, .antigravity, .grok].contains($0.provider)
        })

        let sentinelCatalogs: [AgentProviderKind: [String]] = [
            .antigravity: ["gemini-999999.104-flash-high"]
        ]
        var factoryInvocations = 0
        let sentinelFixture = try makeFixture(availability: five, candidateBuilder: {
            factoryInvocations += 1
            return self.builder(for: sentinelCatalogs)
        })
        await sentinelFixture.viewModel.refresh()
        XCTAssertGreaterThan(factoryInvocations, 0)
        XCTAssertEqual(Set(sentinelFixture.viewModel.targetPreviews.map(\.id)), ["antigravity:gemini-999999.104-flash"])
    }

    func testVisibleProvidersIncludeNewProvidersWhenAvailable() async throws {
        let five = availability(cursor: true, antigravity: true, grok: true)
        let fixture = try makeFixture(availability: five, candidateBuilder: { self.builder(for: Self.catalogs) })
        await fixture.viewModel.refresh()
        XCTAssertTrue(Set(fixture.viewModel.visibleProviders).isSuperset(of: [.cursor, .antigravity, .grok]))
        for provider in [AgentProviderKind.cursor, .antigravity, .grok] {
            XCTAssertTrue(fixture.viewModel.providerIsAvailable(provider))
            XCTAssertEqual(fixture.viewModel.providerPickerLabel(for: provider), provider.displayName)
        }

        let baseFixture = try makeFixture(availability: availability(), candidateBuilder: { self.builder(for: Self.catalogs) })
        await baseFixture.viewModel.refresh()
        for provider in [AgentProviderKind.cursor, .antigravity, .grok] {
            XCTAssertFalse(baseFixture.viewModel.providerIsAvailable(provider))
            XCTAssertEqual(
                baseFixture.viewModel.providerPickerLabel(for: provider),
                provider.displayName + " (authentication needed)"
            )
        }

        let sentinelCatalogs: [AgentProviderKind: [String]] = [
            .antigravity: ["gemini-999999.104-flash-high"]
        ]
        var factoryInvocations = 0
        let sentinelFixture = try makeFixture(availability: five, candidateBuilder: {
            factoryInvocations += 1
            return self.builder(for: sentinelCatalogs)
        })
        await sentinelFixture.viewModel.refresh()
        XCTAssertGreaterThan(factoryInvocations, 0)
        XCTAssertEqual(Set(sentinelFixture.viewModel.targetPreviews.map(\.id)), ["antigravity:gemini-999999.104-flash"])
    }

    func testRouterDescriptionNamesAllFiveProviders() async throws {
        let fixture = try makeFixture(
            availability: availability(cursor: true, antigravity: true, grok: true),
            candidateBuilder: { self.builder(for: Self.catalogs) }
        )
        await fixture.viewModel.refresh()
        for name in ["Claude Code", "Codex", "Cursor", "Antigravity", "Grok"] {
            XCTAssertTrue(fixture.viewModel.routerCandidatesDescription.contains(name))
        }
        XCTAssertFalse(fixture.viewModel.routerCandidatesDescription.contains("connected Claude Code and Codex catalogs"))
    }

    func testEmptyStateNamesAllFiveProviders() async throws {
        let fixture = try makeFixture(availability: .none, candidateBuilder: { self.builder(for: Self.catalogs) })
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.availableProviders.isEmpty)
        for text in [fixture.viewModel.routerEmptyStateText, fixture.viewModel.routerNoProviderDetail] {
            for name in ["Claude Code", "Codex", "Cursor", "Antigravity", "Grok"] {
                XCTAssertTrue(text.contains(name))
            }
            XCTAssertFalse(text.contains("Claude Code or Codex CLI"))
        }
    }

    func testUnavailableNewProviderIsMarkedAuthenticationNeeded() async throws {
        let fixture = try makeFixture(availability: availability(), candidateBuilder: { self.builder(for: Self.catalogs) })
        await fixture.viewModel.refresh()
        for provider in [AgentProviderKind.cursor, .antigravity, .grok] {
            XCTAssertTrue(fixture.viewModel.visibleProviders.contains(provider))
            XCTAssertFalse(fixture.viewModel.providerIsAvailable(provider))
            XCTAssertEqual(
                fixture.viewModel.providerPickerLabel(for: provider),
                provider.displayName + " (authentication needed)"
            )
        }
        XCTAssertFalse(fixture.viewModel.targetPreviews.contains { [.cursor, .antigravity, .grok].contains($0.provider) })
    }

    func testConnectedEmptyCatalogProviderRemainsAvailableUntilDisconnected() async throws {
        let antigravityOnly = availability(claude: false, codex: false, antigravity: true)
        let emptyBuilder = { self.builder(for: [AgentProviderKind: [String]]()) }
        let connected = try makeFixture(availability: antigravityOnly, candidateBuilder: emptyBuilder)
        connected.viewModel.setProviderLimit(.antigravity, scope: .primarySession)
        connected.viewModel.setProviderLimit(.antigravity, scope: .subagent)
        await connected.viewModel.refresh()
        XCTAssertTrue(connected.viewModel.targetPreviews.isEmpty)
        XCTAssertTrue(connected.viewModel.availableProviders.isEmpty)
        XCTAssertFalse(connected.viewModel.policyCanBuildCandidates)
        XCTAssertTrue(connected.viewModel.visibleProviders.contains(.antigravity))
        XCTAssertTrue(connected.viewModel.providerIsAvailable(.antigravity))
        XCTAssertEqual(connected.viewModel.providerPickerLabel(for: .antigravity), AgentProviderKind.antigravity.displayName)
        XCTAssertTrue(connected.viewModel.unavailableProviderPreferences.isEmpty)

        let disconnected = try makeFixture(availability: .none, candidateBuilder: emptyBuilder)
        disconnected.viewModel.setProviderLimit(.antigravity, scope: .primarySession)
        disconnected.viewModel.setProviderLimit(.antigravity, scope: .subagent)
        await disconnected.viewModel.refresh()
        XCTAssertTrue(disconnected.viewModel.targetPreviews.isEmpty)
        XCTAssertFalse(disconnected.viewModel.providerIsAvailable(.antigravity))
        XCTAssertEqual(
            disconnected.viewModel.providerPickerLabel(for: .antigravity),
            AgentProviderKind.antigravity.displayName + " (authentication needed)"
        )
        XCTAssertEqual(
            disconnected.viewModel.unavailableProviderPreferences,
            [
                .init(scope: .primarySession, provider: .antigravity),
                .init(scope: .subagent, provider: .antigravity)
            ]
        )
    }

    func testPreviewRebuildsWhenAntigravityCatalogNotificationPosts() async throws {
        let box = CatalogBox()
        let availability = availability(claude: false, codex: false, antigravity: true)
        let fixture = try makeFixture(availability: availability, candidateBuilder: {
            self.builder(for: box.catalogs)
        })
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.targetPreviews.isEmpty)

        box.catalogs = [.antigravity: ["gemini-3.8-flash-high"]]
        NotificationCenter.default.post(name: .antigravityModelsChanged, object: nil)
        try await AsyncTestWait.waitUntil("router Antigravity preview", timeout: 3) {
            await MainActor.run {
                fixture.viewModel.targetPreviews.contains { $0.id == "antigravity:gemini-3.8-flash" }
            }
        }
        XCTAssertTrue(fixture.viewModel.targetPreviews.contains { $0.id == "antigravity:gemini-3.8-flash" })
    }

    @MainActor private final class CatalogBox {
        var catalogs: [AgentProviderKind: [String]] = [:]
    }

    private struct Fixture {
        let store: GlobalSettingsStore
        let runtime: AgentTaskRouterRuntime
        let viewModel: RouterSettingsViewModel
        let workspace: WorkspaceManagerViewModel
    }

    private func makeFixture(
        policyUnavailable: Bool = false,
        settingsController: (any AgentTaskRouterBackendSettingsController)? = nil,
        availability: AgentModelCatalog.AvailabilityContext = .current,
        verifiedProviders: Set<AgentProviderKind>? = nil,
        candidateBuilder: (@MainActor () -> AgentTaskRoutingCandidateBuilder)? = nil
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RouterSettings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "RouterSettings.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        let backend = SettingsTestBackend(policyUnavailable: policyUnavailable)
        store.setModelRouterBackend(backend.id)
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager), keyManager: keyManager, loadStoredDataOnInit: false
        )
        if let verifiedProviders {
            api.test_completeContextBuilderProviderValidation(verifiedProviders: verifiedProviders)
        }
        addTeardownBlock { @MainActor in api.prepareForWindowClose() }
        let files = WorkspaceFilesViewModel()
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1919,
            settingsManager: WindowSettingsManager(windowID: -1919)
        )
        let workspace = WorkspaceManagerViewModel(fileManager: files, promptViewModel: prompt, performInitialWorkspaceActivation: false)
        let credentials = JevRouterCredentialService(secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let settings = settingsController.map {
            AgentTaskRouterBackendSettingsRegistration(
                presentation: .init(
                    title: "Jev by TypeSafe",
                    configurationDetail: "Test settings",
                    secretFieldLabel: "TypeSafe API key",
                    links: []
                ),
                controller: $0
            )
        } ?? (policyUnavailable ? JevTaskRouterBackend.settingsRegistration(controller: credentials) : nil)
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(backend: backend, settings: settings)
        ])
        if let candidateBuilder {
            runtime.candidateBuilderFactory = candidateBuilder
        }
        let viewModel = RouterSettingsViewModel(
            settingsStore: store,
            runtime: runtime,
            apiSettingsViewModel: api,
            workspaceManager: workspace,
            availabilityProvider: { availability }
        )
        return Fixture(store: store, runtime: runtime, viewModel: viewModel, workspace: workspace)
    }
}

private actor SettingsTestController: AgentTaskRouterBackendSettingsController {
    let result: AgentTaskRouterBackendSettingsActionResult

    init(result: AgentTaskRouterBackendSettingsActionResult) {
        self.result = result
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        .ready(generation: 1, policyVersion: "test-v1")
    }

    func readinessUpdates() -> AsyncStream<AgentTaskRouterBackendReadiness> {
        AsyncStream { continuation in
            continuation.yield(.ready(generation: 1, policyVersion: "test-v1"))
            continuation.finish()
        }
    }

    func perform(_ action: AgentTaskRouterBackendSettingsAction) -> AgentTaskRouterBackendSettingsActionResult {
        result
    }

    func bootstrapStoredConfigurationIfNeeded() {}
    func cancelAndAdvanceGeneration() {}
}

private struct SettingsTestBackend: AgentTaskRouterBackend {
    let policyUnavailable: Bool
    let id = AgentTaskRouterBackendID.jev
    let displayName = "Jev"

    func readinessSnapshot() async -> AgentTaskRouterBackendReadiness {
        policyUnavailable
            ? .policyUnavailable(generation: 0, reason: "Test backend is unavailable.")
            : .ready(generation: 1, policyVersion: "test-v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        .cancelled
    }
}
