import Foundation
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

@MainActor
final class AgentTaskRoutingCandidateBuilderProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private static let providers: Set<AgentProviderKind> = [.codexExec, .claudeCode, .antigravity, .grok, .cursor]
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
    private static let expectedIdentities = [
        "codexExec:gpt-6-luna", "codexExec:gpt-5.6-terra", "codexExec:gpt-6.1-sol", "codexExec:gpt-6-astra",
        "claudeCode:claude-haiku-4-5", "claudeCode:claude-sonnet-5-5", "claudeCode:claude-opus-5-5", "claudeCode:claude-fable-5-1",
        "antigravity:gemini-3.8-flash", "antigravity:gemini-3.1-pro", "grok:grok-4.7", "cursor:composer-2.5"
    ]

    private func availability(grok: Bool = true) -> AgentModelCatalog.AvailabilityContext {
        .init(
            claudeCodeAvailable: true, codexAvailable: true, openCodeAvailable: true,
            cursorAvailable: true, antigravityAvailable: true, grokAvailable: grok,
            grokBuildAvailable: true, devinAvailable: true,
            zaiConfigured: true, kimiConfigured: true, customClaudeCompatibleConfigured: true
        )
    }

    private func builder() -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(cursorThinking: { _ in nil }, modelOptions: { provider, _ in
            (Self.catalogs[provider] ?? []).map {
                AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false)
            }
        })
    }

    private func models(
        _ builder: AgentTaskRoutingCandidateBuilder,
        availability: AgentModelCatalog.AvailabilityContext
    ) throws -> [AgentTaskRoutingCandidateBuilder.Candidate] {
        try builder.build(
            allowedProviders: AgentTaskRoutingCandidateBuilder.availableProviders(availability: availability),
            availability: availability
        )
    }

    private func identity(_ candidate: AgentTaskRoutingCandidateBuilder.Candidate) -> String {
        "\(candidate.target.agentRaw):\(candidate.target.modelRaw)"
    }

    func testAllFiveProvidersContributeTheirFamilies() throws {
        let availability = availability()
        XCTAssertEqual(AgentTaskRoutingCandidateBuilder.availableProviders(availability: availability), Self.providers)
        let candidates = try models(builder(), availability: availability)
        XCTAssertEqual(candidates.map(identity), Self.expectedIdentities)
        XCTAssertTrue(candidates.allSatisfy { $0.target.reasoningEffortRaw == nil && $0.target.modelParameters.isEmpty })
        let newFamilies = candidates.filter { ["antigravity", "grok", "cursor"].contains($0.target.agentRaw) }
        XCTAssertEqual(newFamilies.map(\.utilityTier), ["gemini-flash", "gemini-pro", "grok", "composer"])
        for candidate in newFamilies {
            XCTAssertNil(candidate.usagePeerClass)
            XCTAssertEqual(candidate.usageModelAliases, [candidate.target.modelRaw])
            XCTAssertFalse(AgentTaskRoutingCandidateBuilder.isPaidFast(candidate.target))
        }
    }

    func testFrontierWithAllClassesStaysWithinTwelveCandidates() throws {
        let candidates = try models(builder(), availability: availability())
        XCTAssertEqual(candidates.count, 12)
        XCTAssertLessThanOrEqual(candidates.count, AgentTaskRoutingEnvelopeBuilder.maximumCandidates)
        XCTAssertEqual(Set(candidates.map(identity)), Set(Self.expectedIdentities))
        XCTAssertNoThrow(try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(), text: "Review this change", decisionStage: .model, candidates: candidates.map(\.descriptor)
        ))
    }

    func testCursorGrokIsFallbackOnlyWhenGrokCLIUnavailable() throws {
        let builder = builder()
        let fallback = try models(builder, availability: availability(grok: false)).filter { $0.target.modelRaw == "grok-4.7" }
        XCTAssertEqual(fallback.map(identity), ["cursor:grok-4.7"])
        let both = try models(builder, availability: availability()).filter { $0.target.modelRaw == "grok-4.7" }
        XCTAssertEqual(both.map(identity), ["grok:grok-4.7"])
    }

    func testProviderLimitSelectsOnlyThatNewProvider() throws {
        let availability = availability()
        let available = AgentTaskRoutingCandidateBuilder.availableProviders(availability: availability)
        for provider in [AgentProviderKind.cursor, .antigravity, .grok] {
            for surface in [AgentModelCatalog.AgentSelectionSurface.general, .headless] {
                let allowed = AgentTaskRoutingCandidateBuilder.providers(preferring: provider, from: available)
                XCTAssertEqual(allowed, [provider])
                let candidates = try builder().build(allowedProviders: allowed, availability: availability, surface: surface)
                XCTAssertEqual(Set(candidates.map(\.target.agentRaw)), [provider.rawValue])
            }
        }
    }

    func testAntigravityEffortStageUsesAdvertisedSuffixes() throws {
        let builder = builder()
        let availability = availability()
        let candidates = try models(builder, availability: availability)
        for (base, expected) in [
            ("gemini-3.8-flash", ["gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low"]),
            ("gemini-3.1-pro", ["gemini-3.1-pro-high", "gemini-3.1-pro-low"])
        ] {
            let selected = try XCTUnwrap(candidates.first { $0.target.agentRaw == "antigravity" && $0.target.modelRaw == base })
            let efforts = try builder.buildEfforts(for: selected, availability: availability)
            XCTAssertEqual(efforts.map(\.target.modelRaw), expected)
            XCTAssertEqual(efforts.map(\.descriptor.roleLabels), expected.map { ["effort:\($0.split(separator: "-").last!)"] })
            XCTAssertTrue(efforts.allSatisfy { $0.target.agentRaw == "antigravity" && $0.target.reasoningEffortRaw == nil && $0.target.modelParameters.isEmpty })
        }
    }

    func testCursorEffortStageUsesAdvertisedModelParameter() throws {
        let definitions: [String: ACPModelParameterDefinition] = [
            "grok-4.7": .init(
                kind: .thinking, configID: "reasoning_effort", displayName: "Reasoning effort",
                choices: ["low", "medium", "high", "xhigh"].map { .init(rawValue: $0, displayName: $0) },
                currentValueRaw: "medium"
            ),
            "grok-4.6": .init(
                kind: .thinking, configID: "effort", displayName: "Effort",
                choices: ["low", "high"].map { .init(rawValue: $0, displayName: $0) },
                currentValueRaw: "low"
            )
        ]
        let builder = AgentTaskRoutingCandidateBuilder(
            cursorThinking: { definitions[$0] },
            modelOptions: { provider, _ in
                let raws = (Self.catalogs[provider] ?? []) + (provider == .cursor ? ["grok-4.6"] : [])
                return raws.map { AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false) }
            }
        )
        let availability = availability(grok: false)
        let fallback = try XCTUnwrap(models(builder, availability: availability).first { identity($0) == "cursor:grok-4.7" })
        for (raw, configID, values) in [
            ("grok-4.7", "reasoning_effort", ["low", "medium", "high", "xhigh"]),
            ("grok-4.6", "effort", ["low", "high"])
        ] {
            let selected = AgentTaskRoutingCandidateBuilder.Candidate(
                opaqueKey: fallback.opaqueKey, utilityTier: fallback.utilityTier,
                target: .init(agentRaw: "cursor", modelRaw: raw, reasoningEffortRaw: nil, modelParameters: []),
                descriptor: fallback.descriptor, usagePeerClass: nil
            )
            let efforts = try builder.buildEfforts(for: selected, availability: availability)
            XCTAssertEqual(efforts.map(\.target.modelRaw), Array(repeating: raw, count: values.count))
            XCTAssertEqual(efforts.map(\.descriptor.roleLabels), values.map { ["effort:\($0)"] })
            XCTAssertEqual(efforts.map(\.target.modelParameters), values.map { value in
                [ACPModelParameterSelection(providerID: .cursor, baseModelRaw: raw, kind: .thinking, configID: configID, valueRaw: value)]
            })
            XCTAssertTrue(efforts.allSatisfy { $0.target.reasoningEffortRaw == nil })
            XCTAssertFalse(efforts.contains { AgentTaskRoutingCandidateBuilder.isPaidFast($0.target) })
        }
    }

    func testModelWithoutEffortControlHasOneProviderDefaultTarget() throws {
        let builder = builder()
        let availability = availability()
        let candidates = try models(builder, availability: availability)
        for expected in ["grok:grok-4.7", "cursor:composer-2.5"] {
            let selected = try XCTUnwrap(candidates.first { identity($0) == expected })
            let efforts = try builder.buildEfforts(for: selected, availability: availability)
            XCTAssertEqual(efforts.count, 1)
            XCTAssertEqual(efforts.map(identity), [expected])
            XCTAssertEqual(efforts.map(\.descriptor.roleLabels), [["effort:provider-default"]])
            XCTAssertTrue(efforts.allSatisfy { $0.target.reasoningEffortRaw == nil && $0.target.modelParameters.isEmpty })
            XCTAssertThrowsError(try AgentTaskRoutingEnvelopeBuilder().build(
                requestID: UUID(), text: "Review this change", decisionStage: .effort, candidates: efforts.map(\.descriptor)
            )) { error in
                XCTAssertEqual(error as? AgentTaskRoutingEnvelopeBuilder.Rejection, .invalidCandidateCount)
            }
        }
    }
}

@MainActor
final class AgentTaskRoutingProviderAvailabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private enum Subject: CaseIterable {
        case cursor
        case antigravity
        case grok

        var kind: AgentProviderKind {
            switch self {
            case .cursor: .cursor
            case .antigravity: .antigravity
            case .grok: .grok
            }
        }

        var expectedIdentities: [String] {
            switch self {
            case .cursor: ["cursor:composer-2.5", "cursor:grok-4.7"]
            case .antigravity: ["antigravity:gemini-3.8-flash", "antigravity:gemini-3.1-pro"]
            case .grok: ["grok:grok-4.7"]
            }
        }
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let coordinator: AntigravityConnectionCoordinator
        let viewModel: APISettingsViewModel

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private static let connectionHintKey = "AntigravityCLIConnected"
    private static let catalogs: [AgentProviderKind: [String]] = [
        .antigravity: [
            "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low", "gemini-3.7-flash-high",
            "gemini-3.1-pro-high", "gemini-3.1-pro-low", "claude-opus-5-5-high", "gpt-oss-120b-medium"
        ],
        .grok: ["grok-4.7", "grok-4.6"],
        .cursor: ["composer-2.5", "grok-4.7", "claude-opus-5-5", "gemini-3.8-flash", "kimi-k3"]
    ]

    private func makeFixture() throws -> Fixture {
        let suiteName = "AgentTaskRoutingProviderAvailabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let notificationCenter = NotificationCenter()
        let coordinator = AntigravityConnectionCoordinator(notificationCenter: notificationCenter, userDefaults: defaults)
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            antigravityConnectionCoordinator: coordinator,
            notificationCenter: notificationCenter
        )
        viewModel.isClaudeCodeConnected = false
        viewModel.isCodexConnected = false
        viewModel.isOpenCodeConnected = false
        viewModel.isCursorConnected = false
        viewModel.isGrokConnected = false
        viewModel.test_resetContextBuilderProviderValidation()
        return Fixture(suiteName: suiteName, defaults: defaults, coordinator: coordinator, viewModel: viewModel)
    }

    private func markConnectedWithoutVerification(_ subject: Subject, in fixture: Fixture) {
        switch subject {
        case .cursor: fixture.viewModel.isCursorConnected = true
        case .grok: fixture.viewModel.isGrokConnected = true
        case .antigravity: fixture.defaults.set(true, forKey: Self.connectionHintKey)
        }
    }

    private func verifyAndConnect(_ subject: Subject, in fixture: Fixture) async throws {
        switch subject {
        case .cursor:
            fixture.viewModel.isCursorConnected = true
            fixture.viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.cursor])
        case .grok:
            fixture.viewModel.isGrokConnected = true
            fixture.viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.grok])
        case .antigravity:
            try await publishAntigravity(isConnected: true, in: fixture)
        }
    }

    private func disconnect(_ subject: Subject, in fixture: Fixture) async throws {
        switch subject {
        case .cursor:
            fixture.viewModel.isCursorConnected = false
            fixture.viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [])
        case .grok:
            fixture.viewModel.isGrokConnected = false
            fixture.viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [])
        case .antigravity:
            try await publishAntigravity(isConnected: false, in: fixture)
        }
    }

    private func publishAntigravity(isConnected: Bool, in fixture: Fixture) async throws {
        let generation = await fixture.coordinator.beginManualMutation()
        _ = await fixture.coordinator.publishIfCurrent(
            generation: generation,
            isConnected: isConnected,
            errorMessage: nil,
            hasOwnedMCPEntry: isConnected
        )
        let viewModel = fixture.viewModel
        try await AsyncTestWait.waitUntil("Antigravity routing availability is \(isConnected)") {
            viewModel.isAntigravityConnected == isConnected
                && viewModel.modelRouterAvailabilityContext.antigravityAvailable == isConnected
        }
    }

    private func routedIdentities(_ viewModel: APISettingsViewModel) throws -> [String] {
        let availability = viewModel.modelRouterAvailabilityContext
        let builder = AgentTaskRoutingCandidateBuilder(cursorThinking: { _ in nil }, modelOptions: { provider, _ in
            (Self.catalogs[provider] ?? []).map {
                AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false)
            }
        })
        let candidates = try builder.build(
            allowedProviders: AgentTaskRoutingCandidateBuilder.availableProviders(availability: availability),
            availability: availability
        )
        return candidates.map { "\($0.target.agentRaw):\($0.target.modelRaw)" }
    }

    private func assertExcluded(_ viewModel: APISettingsViewModel) {
        XCTAssertThrowsError(try routedIdentities(viewModel)) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .noAvailableTargets)
        }
    }

    func testConnectedButUnverifiedProviderIsExcluded() throws {
        for subject in Subject.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            markConnectedWithoutVerification(subject, in: fixture)
            XCTAssertFalse(fixture.viewModel.isAntigravityConnected)
            assertExcluded(fixture.viewModel)
        }
    }

    func testVerifiedProviderIsIncluded() async throws {
        for subject in Subject.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try await verifyAndConnect(subject, in: fixture)
            XCTAssertEqual(try routedIdentities(fixture.viewModel), subject.expectedIdentities)
        }
    }

    func testDisconnectRemovesProvider() async throws {
        for subject in Subject.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try await verifyAndConnect(subject, in: fixture)
            XCTAssertEqual(try routedIdentities(fixture.viewModel), subject.expectedIdentities)
            try await disconnect(subject, in: fixture)
            assertExcluded(fixture.viewModel)
        }
    }

    func testReconnectRestoresProvider() async throws {
        for subject in Subject.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try await verifyAndConnect(subject, in: fixture)
            try await disconnect(subject, in: fixture)
            assertExcluded(fixture.viewModel)
            try await verifyAndConnect(subject, in: fixture)
            XCTAssertEqual(try routedIdentities(fixture.viewModel), subject.expectedIdentities)
        }
    }
}
