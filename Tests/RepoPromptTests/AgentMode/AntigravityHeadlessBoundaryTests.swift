import CryptoKit
import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AntigravityHeadlessBoundaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private let availability = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: false,
        codexAvailable: false,
        openCodeAvailable: false,
        cursorAvailable: false,
        antigravityAvailable: true,
        grokAvailable: false,
        grokBuildAvailable: false
    )

    @MainActor
    func testCatalogAndDiscoveryIncludeAntigravityOnGeneralAndHeadlessSurfaces() throws {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        let modelID = "gemini-test-model"
        let displayName = "Gemini Test Model"
        registry.test_setModels([.init(id: modelID, displayName: displayName)])

        for surface: AgentModelCatalog.AgentSelectionSurface in [.general, .headless] {
            XCTAssertEqual(
                AgentModelCatalog.selectableAgents(availability: availability, surface: surface)
                    .count(where: { $0 == .antigravity }),
                1
            )
            let discovered = try XCTUnwrap(
                AgentModelCatalog.discoveryAgents(availability: availability, surface: surface)
                    .first { $0.agent == .antigravity }
            )
            XCTAssertTrue(discovered.available)
            XCTAssertEqual(discovered.models.count(where: { $0.id == modelID }), 1)
            XCTAssertEqual(discovered.models.first { $0.id == modelID }?.name, displayName)
        }
    }

    @MainActor
    func testHeadlessExplicitAndStoredRoleSelectionsPreserveAntigravity() throws {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        let model = "gemini-test-model"
        registry.test_setModels([.init(id: model, displayName: "Gemini Test Model")])

        let direct = try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)",
            availability: availability,
            surface: .headless
        )
        XCTAssertEqual(direct.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertEqual(direct.modelRaw, model)

        let settingsStore = AgentModelsProfileRoleDefaultsStore(overrides: nil)
        MCPAgentRoleDefaultsService.setSelection(
            .init(agent: .antigravity, modelRaw: model),
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
        XCTAssertFalse(effective.overrideUnavailable)
        XCTAssertEqual(effective.effective.agent, .antigravity)
        XCTAssertEqual(effective.effective.modelRaw, model)

        for modelID: String? in ["explore", nil] {
            let resolved = try AgentMCPSelectionResolver.resolve(
                modelID: modelID,
                defaultTaskLabel: .explore,
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
            XCTAssertEqual(resolved.agentRaw, AgentProviderKind.antigravity.rawValue)
            XCTAssertEqual(resolved.modelRaw, model)
        }

        let unavailable = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false,
            cursorAvailable: false,
            antigravityAvailable: false,
            grokAvailable: false,
            grokBuildAvailable: false
        )
        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)",
            availability: unavailable,
            surface: .headless
        )) { error in
            guard case let MCPError.invalidParams(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, "Agent 'antigravity' is currently unavailable.")
        }
    }

    func testHeadlessFactoryCreatesAntigravityProviderAndSafeManagedFailsBeforeLaunch() async {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .antigravity,
            modelString: "gemini-placeholder",
            antigravityPermissionLevel: .safeManagedUnavailable
        )
        XCTAssertTrue(provider is AntigravityAgentProvider)
        XCTAssertFalse(provider is CodexExecAgentProvider)
        XCTAssertFalse(provider is OpenCodeACPHeadlessAgentProvider)
        XCTAssertFalse(provider is CursorACPHeadlessAgentProvider)

        do {
            _ = try await provider.streamAgentMessage(AgentMessage(userMessage: "test"), runID: UUID())
            XCTFail("Expected Safe Managed execution to fail before launch")
        } catch let AIProviderError.invalidConfiguration(detail) {
            XCTAssertEqual(detail, AntigravityAgentProvider.safeManagedUnavailableMessage)
            XCTAssertTrue(detail.contains("Safe Managed"))
            XCTAssertTrue(detail.contains("Custom per provider"))
            XCTAssertTrue(detail.contains("Inherit provider settings"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await provider.dispose()
    }
}

final class AgentMCPSelectionResolverTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try WorkspaceTestProcessSandbox.validate()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private let openCodeOnly = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.openCode)
    private let globalModel = "rolepin/global"
    private let workspaceModel = "rolepin/workspace"
    private let interactiveModel = "rolepin-interactive"

    @MainActor
    func testRecommendationlessPinsUseEffectiveWorkspaceProfileAndParameters() throws {
        try withFixture { settings in
            let workspaceID = UUID()
            let globalProfile = profile(settings, model: globalModel, effort: "high")
            let workspaceProfile = profile(settings, model: workspaceModel, effort: "low")
            settings.setGlobalAgentModelsProfile(globalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
            settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

            for label in ["global", "workspace", "inherited"] {
                let targetID: UUID? = label == "global" ? nil : workspaceID
                let expectedModel = label == "workspace" ? workspaceModel : globalModel
                let surface: AgentModelCatalog.AgentSelectionSurface = label == "inherited" ? .headless : .general
                if label == "inherited" {
                    settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
                    XCTAssertEqual(settings.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides?["pair"], "openCode:\(workspaceModel)")
                }
                let effectiveProfile = settings.effectiveAgentModelsProfile(workspaceID: targetID)
                let parameters = try XCTUnwrap(effectiveProfile.mcpAgentRoleModelParameters?["pair"], label)
                XCTAssertEqual(parameters, [parameter(model: expectedModel, effort: label == "workspace" ? "low" : "high")], label)
                let pin = try XCTUnwrap(MCPAgentRoleDefaultsService.executableStoredSelection(
                    for: .pair, overrides: effectiveProfile.mcpAgentRoleOverrides,
                    roleModelParameters: effectiveProfile.mcpAgentRoleModelParameters, availability: openCodeOnly
                ), label)
                XCTAssertEqual(pin.selection.agent, .openCode, label)
                XCTAssertEqual(pin.selection.modelRaw, expectedModel, label)
                XCTAssertEqual(pin.modelParameters, parameters, label)
                XCTAssertNil(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: openCodeOnly, workspaceID: targetID), label)

                for modelID: String? in ["pair", nil] {
                    do {
                        let result = try AgentMCPSelectionResolver.resolve(
                            modelID: modelID, defaultTaskLabel: .pair, availability: openCodeOnly,
                            workspaceID: targetID, surface: surface
                        )
                        assertSelection(result, agent: .openCode, model: expectedModel, role: .pair, parameters: parameters, label: "\(label), modelID=\(modelID ?? "omitted")")
                    } catch {
                        XCTFail("\(label), modelID=\(modelID ?? "omitted"): executable pin was rejected: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    func testIneligiblePinOnlyCandidatesPreserveExistingFallback() throws {
        try withFixture { settings in
            let globalProfile = profile(settings, model: globalModel, effort: "high")
            settings.setGlobalAgentModelsProfile(globalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            let workspaceID = UUID()
            let cases: [(String, String?, AgentModelCatalog.AvailabilityContext, AgentModelCatalog.AgentSelectionSurface)] = [
                ("missing workspace role", nil, openCodeOnly, .general),
                ("malformed pin", "not-a-compound-id", openCodeOnly, .general),
                ("unavailable provider", "openCode:\(globalModel)", .none, .general),
                ("missing catalog model", "openCode:rolepin/missing", openCodeOnly, .general)
            ]
            for (label, override, availability, surface) in cases {
                var candidate = globalProfile
                candidate.mcpAgentRoleOverrides = override.map { ["pair": $0] } ?? [:]
                settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: candidate)
                settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
                XCTAssertEqual(settings.globalAgentModelsProfile().mcpAgentRoleOverrides?["pair"], "openCode:\(globalModel)", label)
                XCTAssertNil(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: availability, workspaceID: workspaceID), label)
                let effectiveProfile = settings.effectiveAgentModelsProfile(workspaceID: workspaceID)
                let pin = MCPAgentRoleDefaultsService.executableStoredSelection(
                    for: .pair, overrides: effectiveProfile.mcpAgentRoleOverrides,
                    roleModelParameters: effectiveProfile.mcpAgentRoleModelParameters, availability: availability
                )
                XCTAssertNil(pin, label)
                let omitted = try AgentMCPSelectionResolver.resolve(
                    modelID: nil, defaultTaskLabel: .pair, availability: availability,
                    workspaceID: workspaceID, surface: surface
                )
                assertSelection(omitted, agent: nil, model: nil, role: nil, label: label)
                XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
                    modelID: "pair", availability: availability, workspaceID: workspaceID, surface: surface
                ), label) { error in
                    switch error {
                    case let MCPError.invalidParams(message):
                        XCTAssertEqual(message, "No available agent/model for task label 'pair'.", label)
                    default:
                        XCTFail("\(label): unexpected error \(error)")
                    }
                }
            }
            // The fork's Antigravity CLI runs headless, so one valid pin resolves on both surfaces.
            var antigravityPin = globalProfile
            antigravityPin.mcpAgentRoleOverrides = ["pair": "antigravity:\(interactiveModel)"]
            settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: antigravityPin)
            for surface in [AgentModelCatalog.AgentSelectionSurface.general, .headless] {
                let resolved = try AgentMCPSelectionResolver.resolve(
                    modelID: nil, defaultTaskLabel: .pair, availability: .none.assumingAvailable(.antigravity),
                    workspaceID: workspaceID, surface: surface
                )
                assertSelection(resolved, agent: .antigravity, model: interactiveModel, role: .pair, label: "antigravity pin on \(surface)")
            }
        }
    }

    @MainActor
    func testExistingSelectionPrecedenceAndNonRoleBehaviorRemainUnchanged() throws {
        try withFixture { settings in
            settings.setGlobalAgentModelsProfile(profile(settings, model: globalModel, effort: "high"), contextBuilderWriteIntent: .preserveExistingOwnership)
            let provided = try AgentMCPSelectionResolver.resolve(
                modelID: "pair", availability: openCodeOnly,
                roleSelectionProvider: { _, _ in .init(agent: .openCode, modelRaw: self.workspaceModel) }
            )
            assertSelection(provided, agent: .openCode, model: workspaceModel, role: .pair, label: "provider precedence")

            let noDefault = try AgentMCPSelectionResolver.resolve(modelID: nil, availability: openCodeOnly)
            assertSelection(noDefault, agent: nil, model: nil, role: nil, label: "no default")
            let compound = try AgentMCPSelectionResolver.resolve(modelID: "openCode:\(workspaceModel)", availability: openCodeOnly)
            assertSelection(compound, agent: .openCode, model: workspaceModel, role: nil, label: "compound ID")

            let recommendedAvailability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.codexExec)
            let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: recommendedAvailability))
            XCTAssertTrue(effective.hasStoredOverride)
            XCTAssertTrue(effective.overrideUnavailable)
            XCTAssertEqual(effective.effective.agent, .codexExec)
            XCTAssertEqual(effective.modelParameters, [])
            let fallback = try AgentMCPSelectionResolver.resolve(modelID: "pair", availability: recommendedAvailability)
            assertSelection(fallback, agent: effective.effective.agent, model: effective.effective.modelRaw, role: .pair, label: "existing unavailable-pin recommendation")
        }
    }

    @MainActor
    private func withFixture(_ body: (GlobalSettingsStore) throws -> Void) throws {
        let settings = GlobalSettingsStore.shared
        let originalProfile = settings.globalAgentModelsProfile()
        let registry = AgentACPModelRegistry.shared
        defer {
            settings.setGlobalAgentModelsProfile(originalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            registry.test_reset(providerID: .openCode)
            registry.test_reset(providerID: .antigravity)
        }
        registry.test_reset(providerID: .openCode)
        registry.test_reset(providerID: .antigravity)
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [globalModel, workspaceModel].map {
                    AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: $0 == globalModel)
                },
                currentModelRaw: globalModel
            ), for: .openCode
        )
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: interactiveModel, displayName: interactiveModel, description: nil, isDefault: true)],
                currentModelRaw: interactiveModel
            ), for: .antigravity
        )
        try body(settings)
    }

    @MainActor
    private func profile(_ settings: GlobalSettingsStore, model: String, effort: String) -> AgentModelsSettingsProfile {
        var result = settings.globalAgentModelsProfile()
        result.mcpAgentRoleOverrides = ["pair": "openCode:\(model)"]
        result.mcpAgentRoleModelParameters = ["pair": [parameter(model: model, effort: effort)]]
        return result
    }

    private func parameter(model: String, effort: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(providerID: .openCode, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: effort)
    }

    private func assertSelection(
        _ result: AgentMCPSelectionResolver.ResolvedSelection,
        agent: AgentProviderKind?, model: String?, role: AgentModelCatalog.TaskLabelKind?,
        parameters: [ACPModelParameterSelection] = [], label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.agentRaw, agent?.rawValue, label, file: file, line: line)
        XCTAssertEqual(result.modelRaw, model, label, file: file, line: line)
        XCTAssertEqual(result.taskLabelKind, role, label, file: file, line: line)
        XCTAssertEqual(result.modelParameterSelections, parameters, label, file: file, line: line)
        XCTAssertFalse(result.usageBalancingEligible, label, file: file, line: line)
    }
}
