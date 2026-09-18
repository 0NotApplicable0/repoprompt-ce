import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AntigravityHeadlessBoundaryTests: XCTestCase {
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
