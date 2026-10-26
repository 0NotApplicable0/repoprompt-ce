import Darwin
import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptShared
import XCTest

final class AgentReasoningStatusStreamTests: XCTestCase {
    // MARK: - statusPreview

    func testStatusPreviewCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(AgentReasoningStatusStream.statusPreview(from: "  Reading\n the  file \t"), "Reading the file")
    }

    func testStatusPreviewEmptyReturnsNil() {
        XCTAssertNil(AgentReasoningStatusStream.statusPreview(from: ""))
        XCTAssertNil(AgentReasoningStatusStream.statusPreview(from: "   \n\t "))
    }

    func testStatusPreviewKeepsTrailingPortionWhenLong() {
        let preview = AgentReasoningStatusStream.statusPreview(from: String(repeating: "a", count: 200), limit: 50)
        XCTAssertEqual(preview?.count, 51) // leading "…" + 50 trailing chars
        XCTAssertEqual(preview?.hasPrefix("…"), true)
    }

    // MARK: - withReasoningStatus decorator

    private func makeUpstream(_ events: [AIStreamResult]) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func collect(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async throws -> [AIStreamResult] {
        var out: [AIStreamResult] = []
        for try await event in stream {
            out.append(event)
        }
        return out
    }

    func testInjectsStatusAfterReasoningAndPassesOriginalsThrough() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "reasoning", text: nil, reasoning: "Reading the file"),
            AIStreamResult(type: "content", text: "done"),
            AIStreamResult(type: "message_stop", text: nil)
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        // The reasoning event passes through and a `status` is injected right after it.
        XCTAssertEqual(out.map(\.type), ["reasoning", "status", "content", "message_stop"])
        XCTAssertEqual(out[1].text, "Reading the file")
    }

    func testNoStatusWhenNoReasoning() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "content", text: "hello"),
            AIStreamResult(type: "message_stop", text: nil)
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        XCTAssertEqual(out.map(\.type), ["content", "message_stop"])
    }

    func testReasoningAccumulatesAcrossDeltas() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "reasoning", text: nil, reasoning: "Read"),
            AIStreamResult(type: "reasoning", text: nil, reasoning: "ing X")
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        let statuses = out.filter { $0.type == "status" }.map(\.text)
        XCTAssertEqual(statuses, ["Read", "Reading X"])
    }

    func testBufferResetsAfterContent() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "reasoning", text: nil, reasoning: "first thought"),
            AIStreamResult(type: "content", text: "answer"),
            AIStreamResult(type: "reasoning", text: nil, reasoning: "second thought")
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        let statuses = out.filter { $0.type == "status" }.map(\.text)
        // Second status reflects only the post-content reasoning, not the accumulated first.
        XCTAssertEqual(statuses, ["first thought", "second thought"])
    }
}

final class HeadlessProviderStreamTaskAuthorityTests: XCTestCase {
    private actor EventLog {
        private(set) var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }
    }

    private actor Barrier {
        private(set) var isPaused = false
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            isPaused = true
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testReplacementWaitsForExactPredecessorCleanupBeforeLaunching() async throws {
        let authority = HeadlessProviderStreamTaskAuthority()
        let cleanupBarrier = Barrier()
        let log = EventLog()

        let first = await authority.start(onDiscarded: {}) {
            await log.append("first-started")
            await cleanupBarrier.pause()
            await log.append("first-cleaned")
        }
        let firstHandle = try XCTUnwrap(first)
        do {
            try await AsyncTestWait.waitUntil("first headless producer started") {
                await log.events == ["first-started"]
            }
        } catch {
            await cleanupBarrier.release()
            firstHandle.task.cancel()
            await firstHandle.task.value
            throw error
        }

        let second = await authority.start(onDiscarded: {}) {
            await log.append("second-started")
        }
        let secondHandle = try XCTUnwrap(second)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let eventsBeforeCleanup = await log.events
        XCTAssertEqual(eventsBeforeCleanup, ["first-started"])

        await cleanupBarrier.release()
        await firstHandle.task.value
        await secondHandle.task.value

        let finalEvents = await log.events
        XCTAssertEqual(finalEvents, ["first-started", "first-cleaned", "second-started"])
    }

    func testReplacementWaitsForCancellationObservedCleanupBeforeLaunching() async throws {
        let authority = HeadlessProviderStreamTaskAuthority()
        let cleanupBarrier = Barrier()
        let log = EventLog()

        let first = await authority.start(onDiscarded: {}) {
            await log.append("first-started")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                await log.append("first-cancel-observed")
            }
            await cleanupBarrier.pause()
            await log.append("first-cleaned")
        }
        let firstHandle = try XCTUnwrap(first)
        do {
            try await AsyncTestWait.waitUntil("first headless producer started before cancellation") {
                await log.events == ["first-started"]
            }
        } catch {
            firstHandle.task.cancel()
            await cleanupBarrier.release()
            await firstHandle.task.value
            throw error
        }

        let second = await authority.start(onDiscarded: {}) {
            await log.append("second-started")
        }
        let secondHandle = try XCTUnwrap(second)
        do {
            try await AsyncTestWait.waitUntil("first headless producer entered structured cancellation cleanup") {
                await cleanupBarrier.isPaused
            }
        } catch {
            await cleanupBarrier.release()
            await firstHandle.task.value
            await secondHandle.task.value
            throw error
        }

        let eventsDuringCleanup = await log.events
        XCTAssertEqual(eventsDuringCleanup, ["first-started", "first-cancel-observed"])

        await cleanupBarrier.release()
        await firstHandle.task.value
        await secondHandle.task.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["first-started", "first-cancel-observed", "first-cleaned", "second-started"]
        )
    }

    func testDisposalCancelsAndJoinsAllRetainedTasksAndRejectsRestart() async throws {
        let authority = HeadlessProviderStreamTaskAuthority()
        let log = EventLog()

        let producer = await authority.start(onDiscarded: {}) {
            await log.append("started")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            await log.append("cleaned")
        }
        let producerHandle = try XCTUnwrap(producer)
        do {
            try await AsyncTestWait.waitUntil("headless producer started before disposal") {
                await log.events == ["started"]
            }
        } catch {
            producerHandle.task.cancel()
            await producerHandle.task.value
            throw error
        }

        let disposalTasks = await authority.beginDisposal()
        for task in disposalTasks {
            await task.value
        }
        let replacement = await authority.start(onDiscarded: {}) {
            await log.append("unexpected-restart")
        }

        let events = await log.events
        XCTAssertEqual(events, ["started", "cleaned"])
        XCTAssertNil(replacement)
    }

    func testTerminationCancelsOnlyCapturedProducerAndIgnoresNormalFinish() async {
        let firstProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let replacementProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }

        HeadlessProviderStreamTaskAuthority.handleTermination(.cancelled, producerTask: firstProducer)
        XCTAssertTrue(firstProducer.isCancelled)
        XCTAssertFalse(replacementProducer.isCancelled)

        HeadlessProviderStreamTaskAuthority.handleTermination(
            .finished(nil),
            producerTask: replacementProducer
        )
        XCTAssertFalse(replacementProducer.isCancelled)

        replacementProducer.cancel()
        await firstProducer.value
        await replacementProducer.value
    }
}

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

/// agy surfaces native tools (`view_file`, `run_command`, …) whose args use PascalCase keys
/// (`AbsolutePath`, `CommandLine`). These fall through `AgentToolCardRenderSummary.build` to the
/// generic native handler, which must expose the specific argument as the card subtitle so the card
/// says WHICH file / WHAT command — not just the humanized tool name.
final class AntigravityNativeToolCardTests: XCTestCase {
    private func card(_ tool: String, _ args: [String: Any]) -> AgentToolCardRenderSummary? {
        AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: tool, statusWord: "success", rawObject: args, argsObject: args
        )
    }

    func testViewFileCardShowsAbsolutePath() throws {
        let c = try XCTUnwrap(card("view_file", ["AbsolutePath": "/Users/dev/x.swift", "toolSummary": "View x.swift"]))
        XCTAssertEqual(c.title, "View File")
        XCTAssertEqual(c.subtitle, "/Users/dev/x.swift")
    }

    func testRunCommandCardShowsCommandLine() throws {
        let c = try XCTUnwrap(card("run_command", ["CommandLine": "git diff --name-only main", "Cwd": "/x", "toolSummary": "Run git diff"]))
        XCTAssertEqual(c.title, "Run Command")
        XCTAssertEqual(c.subtitle, "git diff --name-only main")
    }

    func testNativeToolFallsBackToToolSummaryWhenNoSpecificArg() throws {
        let c = try XCTUnwrap(card("some_native_tool", ["toolSummary": "Did a thing"]))
        XCTAssertEqual(c.subtitle, "Did a thing")
    }
}

/// Contract: Antigravity agent-mode MCP policies are held until their run settles, other
/// agent-mode policies still age out at their TTL, and concurrent same-client policies are matched
/// by each run's expected agent PID.
final class MCPPolicySettlementTests: XCTestCase {
    func testSameClientAntigravityPoliciesMatchByRunPID() async throws {
        #if DEBUG
            let manager = ServerNetworkManager(
                domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost
            )
            let clientName = AgentProviderKind.antigravityMCPClientID
            let windowID = 987_655
            let runA = UUID()
            let runB = UUID()
            let childA = try Self.launchSleeper()
            defer { Self.stop(childA) }
            let childB = try Self.launchSleeper()
            defer { Self.stop(childB) }
            await manager.registerExpectedAgentPID(childA.processIdentifier, for: clientName, runID: runA)
            await manager.registerExpectedAgentPID(childB.processIdentifier, for: clientName, runID: runB)
            for runID in [runA, runB] {
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    oneShot: true,
                    reason: "MCPPolicySettlementTests",
                    ttl: 60,
                    tabID: UUID(),
                    runID: runID,
                    purpose: .agentModeRun,
                    requiresExpectedAgentPID: true,
                    prunesOnlyAfterSettlement: true
                )
            }
            let connectionID = UUID()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: SettlementTestConnection(),
                pendingClientID: clientName
            )

            let started = Date()
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(childB.processIdentifier),
                pidGateTimeout: 2.0,
                requireRunRouting: false
            )
            let elapsed = Date().timeIntervalSince(started)

            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.runID, runB)
            XCTAssertLessThan(elapsed, 1.0, "B's helper must not wait out the 2 s unmatched hold")
            let remaining = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(remaining.contains { $0.runID == runA })
            XCTAssertFalse(remaining.contains { $0.runID == runB })

            await manager.clearExpectedAgentPID(childA.processIdentifier, for: clientName, runID: runA)
            await manager.clearExpectedAgentPID(childB.processIdentifier, for: clientName, runID: runB)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runA)
            await manager.removeConnection(connectionID)
        #endif
    }

    func testSettlementHoldAuthority() {
        let antigravity = AgentProviderKind.antigravityMCPClientID
        XCTAssertTrue(MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: antigravity, purpose: .agentModeRun))
        XCTAssertTrue(MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: antigravity, purpose: .discoverRun))
        XCTAssertFalse(MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: antigravity, purpose: .unknown))
        for other in [
            AgentProviderKind.codexMCPClientID,
            AgentProviderKind.claudeMCPClientID,
            AgentProviderKind.grokMCPClientID
        ] {
            XCTAssertFalse(
                MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: other, purpose: .agentModeRun),
                other
            )
            XCTAssertTrue(
                MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: other, purpose: .discoverRun),
                other
            )
        }
    }

    func testAgentModeDefaultInstallerHoldsAntigravityPolicyPastTTL() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let windowID = 987_654
            let antigravityRunID = UUID()
            let codexRunID = UUID()
            let claudeRunID = UUID()
            addTeardownBlock {
                for (clientName, runID) in [
                    (AgentProviderKind.antigravityMCPClientID, antigravityRunID),
                    (AgentProviderKind.codexMCPClientID, codexRunID),
                    (AgentProviderKind.claudeMCPClientID, claudeRunID)
                ] {
                    await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
                }
            }
            for (clientName, runID) in [
                (AgentProviderKind.antigravityMCPClientID, antigravityRunID),
                (AgentProviderKind.codexMCPClientID, codexRunID),
                (AgentProviderKind.claudeMCPClientID, claudeRunID)
            ] {
                await AgentModeViewModel.defaultConnectionPolicyInstaller(
                    clientName: clientName,
                    windowID: windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    oneShot: true,
                    reason: "MCPPolicySettlementTests",
                    ttl: 0.05,
                    tabID: UUID(),
                    runID: runID,
                    additionalTools: nil,
                    purpose: .agentModeRun
                )
            }
            try await Task.sleep(nanoseconds: 300_000_000)

            let antigravityRows = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.antigravityMCPClientID)
            let codexRows = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.codexMCPClientID)
            let claudeRows = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.claudeMCPClientID)
            XCTAssertTrue(
                antigravityRows.contains { $0.runID == antigravityRunID },
                "An Antigravity agent-mode policy must survive past its TTL until the run settles"
            )
            XCTAssertFalse(
                codexRows.contains { $0.runID == codexRunID },
                "A Codex agent-mode policy must still age out at its TTL"
            )
            XCTAssertFalse(
                claudeRows.contains { $0.runID == claudeRunID },
                "A Claude agent-mode policy must still age out at its TTL"
            )

            await manager.revokeClientConnectionPolicy(
                for: AgentProviderKind.antigravityMCPClientID,
                windowID: windowID,
                runID: antigravityRunID
            )
            let afterRevoke = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.antigravityMCPClientID)
            XCTAssertFalse(afterRevoke.contains { $0.runID == antigravityRunID })
        #endif
    }

    private static func launchSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private static func stop(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }
}

#if DEBUG
    private actor SettlementTestConnection: MCPServerConnection {
        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
        func stop() async {}
        func abortForExecutionWatchdog(context _: MCPExecutionWatchdogTerminalContext) async {}
        func notifyToolListChanged() async {}
        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}
        func sendProgress(
            tool _: String,
            kind _: RepoPromptProgressKind,
            stage _: String,
            message _: String
        ) async {}
    }
#endif
