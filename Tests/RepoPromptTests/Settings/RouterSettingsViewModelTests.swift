@testable import RepoPromptApp
import XCTest

@MainActor
final class RouterSettingsViewModelTests: XCTestCase {
    func testRapidConsentEditsAndExternalWritesPreserveLatestChoices() throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        viewModel.setRole(.explore, enabled: false)
        viewModel.setRole(.engineer, enabled: false)
        XCTAssertEqual(viewModel.eligibleRoles, [.pair, .design])
        XCTAssertEqual(Set(fixture.store.modelRouterConfiguration().candidateRoles), [.pair, .design])

        fixture.store.setModelRouterCandidateRoles([.design])
        viewModel.setRole(.explore, enabled: true)
        XCTAssertEqual(viewModel.eligibleRoles, [.explore, .design])

        fixture.store.setModelRouterAllowedProviders([.codexExec, .claudeCode])
        viewModel.setProvider(.codexExec, enabled: false)
        viewModel.setProvider(.claudeCode, enabled: false)
        XCTAssertTrue(viewModel.configuration.allowedProviders.isEmpty)
        XCTAssertTrue(fixture.store.modelRouterConfiguration().allowedProviders.isEmpty)
    }

    func testSelectingBackendImmediatelyClearsOldReadinessAndPreservesConsent() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.refresh()
        XCTAssertTrue(fixture.viewModel.readiness.isReady)
        fixture.viewModel.setRole(.explore, enabled: false)
        let roles = fixture.viewModel.eligibleRoles

        fixture.viewModel.selectBackend(.init(rawValue: "uninstalled"))
        XCTAssertEqual(fixture.viewModel.selectedBackendID?.rawValue, "uninstalled")
        XCTAssertFalse(fixture.viewModel.canEnable)
        XCTAssertNil(fixture.viewModel.backendSettingsPresentation)
        XCTAssertEqual(fixture.viewModel.eligibleRoles, roles)
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

        await fixture.viewModel.performBackendAction(.revalidateStoredSecret)

        XCTAssertEqual(
            fixture.viewModel.backendOperationFeedback,
            .succeeded("Key verified. Jev is ready.")
        )
    }

    private struct Fixture {
        let store: GlobalSettingsStore
        let viewModel: RouterSettingsViewModel
        let workspace: WorkspaceManagerViewModel
    }

    private func makeFixture(
        policyUnavailable: Bool = false,
        settingsController: (any AgentTaskRouterBackendSettingsController)? = nil
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
        let viewModel = RouterSettingsViewModel(settingsStore: store, runtime: runtime, apiSettingsViewModel: api, workspaceManager: workspace)
        return Fixture(store: store, viewModel: viewModel, workspace: workspace)
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
