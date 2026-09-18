import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class RestoredCLISelectionCompatibilityTests: XCTestCase {
    @MainActor
    func testHeadlessCatalogExposesOnlyNativeGrokAndAntigravityWhenGrokBuildIsAdvertised() throws {
        let antigravityRegistry = AntigravityModelRegistry.shared
        let grokRegistry = GrokModelRegistry.shared
        antigravityRegistry.test_reset()
        grokRegistry.test_reset()
        defer {
            antigravityRegistry.test_reset()
            grokRegistry.test_reset()
        }

        let antigravityModel = "gemini-headless-test"
        let grokModel = "Grok Headless Test"
        antigravityRegistry.test_setModels([.init(id: antigravityModel, displayName: "Gemini Headless Test")])
        grokRegistry.test_setLabels([grokModel])

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            antigravityAvailable: true,
            grokAvailable: true,
            grokBuildAvailable: true,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        let selectable = AgentModelCatalog.selectableAgents(availability: availability, surface: .headless)
        XCTAssertEqual(selectable.count, 2)
        XCTAssertEqual(Set(selectable), [.antigravity, .grok])

        let discovered = AgentModelCatalog.discoveryAgents(availability: availability, surface: .headless)
        XCTAssertEqual(discovered.count(where: { $0.agent == .antigravity }), 1)
        XCTAssertEqual(discovered.count(where: { $0.agent == .grok }), 1)
        XCTAssertFalse(discovered.contains { $0.agent == .grokBuild })
        XCTAssertEqual(
            try XCTUnwrap(discovered.first { $0.agent == .antigravity })
                .models.count(where: { $0.id == antigravityModel }),
            1
        )
        XCTAssertEqual(
            try XCTUnwrap(discovered.first { $0.agent == .grok })
                .models.count(where: { $0.id == grokModel }),
            1
        )
    }

    func testPersistedRetiredGrokBuildSelectionPreservesExactLegacyModel() {
        let legacyModel = "legacy-custom-grok-build-model"
        let normalized = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.grokBuild.rawValue,
            modelRaw: legacyModel,
            availability: .none,
            surface: .headless
        )

        XCTAssertEqual(normalized.agent, .grokBuild)
        XCTAssertEqual(normalized.modelRaw, legacyModel)
    }

    @MainActor
    func testExplicitRetiredGrokBuildSelectionIsRejectedEvenWhenAdvertisedAvailable() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            antigravityAvailable: false,
            grokAvailable: false,
            grokBuildAvailable: true,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "grokBuild:default",
            availability: availability,
            surface: .headless
        )) { error in
            guard case let MCPError.invalidParams(detail) = error, let detail else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(
                detail.localizedCaseInsensitiveContains("unavailable")
                    || detail.localizedCaseInsensitiveContains("retired")
            )
        }
    }

    func testRetiredGrokBuildHasNoACPRouteAndFactoryIsUnsupported() {
        guard AgentProviderKind.grokBuild.acpProviderID == nil else {
            XCTFail("Retired GrokBuild must not retain an ACP route")
            return
        }

        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .grokBuild,
            modelString: "legacy-custom-grok-build-model"
        )
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)
    }

    @MainActor
    func testPersistedUnknownAntigravityModelIsPreservedButExplicitExecutionRejectsIt() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setModels([.init(id: "known-agy-model", displayName: "Known AGY Model")])

        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            antigravityAvailable: true,
            grokAvailable: false,
            grokBuildAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
        let savedModel = "saved-unknown-agy-model"
        let normalized = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.antigravity.rawValue,
            modelRaw: savedModel,
            availability: availability,
            surface: .headless
        )
        XCTAssertEqual(normalized.agent, .antigravity)
        XCTAssertEqual(normalized.modelRaw, savedModel)

        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .antigravity,
            modelString: savedModel,
            antigravityPermissionLevel: .managedDefault
        )
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)

        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(savedModel)",
            availability: availability,
            surface: .headless
        )) { error in
            guard case let MCPError.invalidParams(detail) = error, let detail else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains(savedModel))
        }
    }

    func testTaskLabelsDoNotSelectRetiredGrokBuildWhenItIsOnlyAdvertisedProvider() {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            antigravityAvailable: false,
            grokAvailable: false,
            grokBuildAvailable: true,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )

        for role in AgentModelCatalog.TaskLabelKind.allCases {
            XCTAssertNil(
                AgentModelCatalog.resolveTaskLabelKind(role, availability: availability),
                "Retired GrokBuild resolved task label \(role.rawValue)"
            )
        }
        XCTAssertTrue(AgentModelCatalog.discoveryTaskLabels(availability: availability).isEmpty)
    }

    @MainActor
    func testUnavailableStoredRoleRetainsRetiredSelectionAndResolverRejectsIt() throws {
        let availability = claudeOnlyAvailability()
        let settingsStore = AgentModelsProfileRoleDefaultsStore(overrides: nil)
        let saved = AgentModelCatalog.NormalizedAgentSelection(
            agent: .grokBuild,
            modelRaw: "legacy-custom-grok-build-model"
        )
        MCPAgentRoleDefaultsService.setSelection(
            saved,
            for: .explore,
            scope: .global,
            settingsStore: settingsStore
        )

        let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: availability,
            settingsStore: settingsStore
        ))
        XCTAssertTrue(effective.hasStoredOverride)
        XCTAssertTrue(effective.overrideUnavailable)
        XCTAssertEqual(effective.effective, saved)

        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "explore",
            availability: availability,
            roleSelectionProvider: { role, context in
                MCPAgentRoleDefaultsService.effectiveNormalizedSelection(
                    for: role,
                    availability: context,
                    settingsStore: settingsStore
                )
            },
            surface: .headless
        )) { error in
            guard case let MCPError.invalidParams(detail) = error, let detail else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains(AgentProviderKind.grokBuild.rawValue))
        }
    }

    @MainActor
    func testRoleSelectionCallbackCannotBypassRetiredProviderAvailability() {
        let saved = AgentModelCatalog.NormalizedAgentSelection(
            agent: .grokBuild,
            modelRaw: "legacy-custom-grok-build-model"
        )

        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "explore",
            availability: claudeOnlyAvailability(),
            roleSelectionProvider: { _, _ in saved },
            surface: .headless
        )) { error in
            guard case let MCPError.invalidParams(detail) = error, let detail else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains(AgentProviderKind.grokBuild.rawValue))
        }
    }

    @MainActor
    func testRoleWithoutStoredOverrideKeepsAutomaticRecommendation() throws {
        let availability = claudeOnlyAvailability()
        let settingsStore = AgentModelsProfileRoleDefaultsStore(overrides: nil)
        let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(
            for: .explore,
            availability: availability,
            settingsStore: settingsStore
        ))

        XCTAssertFalse(effective.hasStoredOverride)
        XCTAssertFalse(effective.overrideUnavailable)
        XCTAssertEqual(effective.effective, effective.recommended)

        let resolved = try AgentMCPSelectionResolver.resolve(
            modelID: "explore",
            availability: availability,
            roleSelectionProvider: { role, context in
                MCPAgentRoleDefaultsService.effectiveNormalizedSelection(
                    for: role,
                    availability: context,
                    settingsStore: settingsStore
                )
            },
            surface: .headless
        )
        XCTAssertEqual(resolved.agentRaw, effective.recommended.agent.rawValue)
        XCTAssertEqual(resolved.modelRaw, effective.recommended.modelRaw)
    }

    private func claudeOnlyAvailability() -> AgentModelCatalog.AvailabilityContext {
        AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: true,
            codexAvailable: false,
            openCodeAvailable: false,
            cursorAvailable: false,
            antigravityAvailable: false,
            grokAvailable: false,
            grokBuildAvailable: false,
            zaiConfigured: false,
            kimiConfigured: false,
            customClaudeCompatibleConfigured: false
        )
    }
}
