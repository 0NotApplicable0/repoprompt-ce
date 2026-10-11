import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptSecureStorage
import RepoPromptSettingsCore
import XCTest

final class AgentAutomationTurnAuditTests: XCTestCase {
    func testSessionRoundTripJoinsAuditToExistingUsageTurnID() throws {
        let turnID = UUID()
        let audit = AgentAutomationTurnAudit(
            turnID: turnID,
            createdAt: Date(timeIntervalSince1970: 100),
            router: .init(
                configured: true,
                eligible: true,
                judgmentRequested: true,
                decision: .selected,
                chosenModelRaw: "gpt-6-sol",
                chosenEffortRaw: "medium",
                application: .turnAccepted
            ),
            autoEffort: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
            acceptedProviderRaw: "codexExec",
            acceptedModelRaw: "gpt-6-sol",
            acceptedEffortRaw: "low",
            providerTurnAccepted: true
        )
        let usage = AgentTokenUsagePersist(turnID: turnID, promptTokens: 12, completionTokens: 3)
        let session = AgentSession(
            providerTokenUsageByTurn: [usage],
            automationTurnAudit: [audit]
        )
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        XCTAssertEqual(decoded.automationTurnAudit, [audit])
        XCTAssertEqual(decoded.automationTurnAudit.first?.router.chosenEffortRaw, "medium")
        XCTAssertEqual(decoded.automationTurnAudit.first?.acceptedEffortRaw, "low")
        XCTAssertEqual(decoded.providerTokenUsageByTurn.first?.turnID, turnID)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("promptExcerpt"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("providerEffective"))
    }

    func testVersionOneAuditWithoutCodexDeliveryStillDecodes() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSelectedAudit())) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "codexDelivery")
        let decoded = try JSONDecoder().decode(
            AgentAutomationTurnAudit.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.codexDelivery)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testLegacySessionWithoutAuditDecodesAsEmpty() throws {
        let encoded = try JSONEncoder().encode(AgentSession())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "automationTurnAudit")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: legacy)
        XCTAssertTrue(decoded.automationTurnAudit.isEmpty)
    }

    func testCodexSteerAndQueuedFallbackSeparateLocalAndProviderAcceptance() {
        var audit = makeSelectedAudit()
        audit.recordCodexQueuedFallback()
        XCTAssertEqual(audit.codexDelivery, .queuedFallback)
        XCTAssertFalse(audit.providerDispatchAttempted)
        XCTAssertFalse(audit.providerTurnAccepted)

        audit.recordCodexDispatch(.fallbackStart)
        XCTAssertTrue(audit.providerDispatchAttempted)
        XCTAssertFalse(audit.providerTurnAccepted)
        audit.recordCodexStartAccepted(effortRaw: "high", autoEffortApplied: false)
        XCTAssertTrue(audit.providerTurnAccepted)
        XCTAssertEqual(audit.acceptedEffortRaw, "high")
        XCTAssertEqual(audit.autoEffort.application, .fallbackToManual)

        var steer = makeSelectedAudit()
        steer.recordCodexDispatch(.steer)
        steer.recordCodexSteerAccepted()
        XCTAssertEqual(steer.codexDelivery, .steer)
        XCTAssertTrue(steer.providerTurnAccepted)
        XCTAssertEqual(steer.router.application, .notObserved)
        XCTAssertEqual(steer.autoEffort.application, .notObserved)
    }

    func testManagedAuthReplayUpdatesPhysicalDispatchWithoutInventingEffectiveEffort() {
        var audit = makeSelectedAudit()
        audit.recordCodexDispatch(.start)
        audit.recordCodexDispatch(.managedAuthReplay)
        audit.recordCodexStartAccepted(effortRaw: "medium", autoEffortApplied: true)
        XCTAssertEqual(audit.codexDelivery, .managedAuthReplay)
        XCTAssertTrue(audit.providerTurnAccepted)
        XCTAssertEqual(audit.acceptedEffortRaw, "medium")
        XCTAssertEqual(audit.autoEffort.application, .turnAccepted)
    }

    func testClaudeAcceptedEffortFollowsAppliedControlOrManualFallback() {
        var applied = makeSelectedAudit()
        applied.autoEffort.application = .controlAccepted
        applied.recordClaudeTurnAccepted(autoEffortRaw: "high", manualEffortRaw: "low")
        XCTAssertEqual(applied.acceptedEffortRaw, "high")
        XCTAssertEqual(applied.autoEffort.application, .turnAccepted)

        var fallback = makeSelectedAudit()
        fallback.autoEffort.application = .controlAccepted
        fallback.recordClaudeTurnAccepted(autoEffortRaw: nil, manualEffortRaw: "low")
        XCTAssertEqual(fallback.acceptedEffortRaw, "low")
        XCTAssertEqual(fallback.autoEffort.application, .fallbackToManual)
        XCTAssertTrue(fallback.autoEffort.fallbackApplied)
    }

    func testDiscardedMCPJudgmentRetainsCallAndChoice() {
        let original = makeSelectedAudit().autoEffort
        let discarded = original.discardedAfterMCPReclassification()
        XCTAssertTrue(discarded.judgmentRequested)
        XCTAssertEqual(discarded.chosenEffortRaw, "high")
        XCTAssertTrue(discarded.fallbackApplied)
        XCTAssertEqual(discarded.application, .fallbackToManual)
    }

    @MainActor
    func testRemovingRejectedOptimisticUserTurnRemovesOnlyItsAudit() {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        let rejected = AgentChatItem.user("rejected", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(rejected)
        var audit = makeSelectedAudit()
        audit = AgentAutomationTurnAudit(
            turnID: rejected.id,
            createdAt: rejected.timestamp,
            router: audit.router,
            autoEffort: audit.autoEffort
        )
        session.appendAutomationAudit(audit)
        XCTAssertNotNil(session.removeItem(at: 0))
        XCTAssertTrue(session.automationTurnAudit.isEmpty)
    }

    private func makeSelectedAudit() -> AgentAutomationTurnAudit {
        AgentAutomationTurnAudit(
            turnID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            router: .init(
                configured: true, eligible: true, judgmentRequested: true,
                decision: .selected, chosenModelRaw: "gpt-6-sol", chosenEffortRaw: "medium"
            ),
            autoEffort: .init(
                configured: true, eligible: true, judgmentRequested: true,
                decision: .selected, chosenModelRaw: "gpt-6-sol", chosenEffortRaw: "high"
            ),
            acceptedEffortRaw: "low"
        )
    }

    func testAuditRetentionIsBoundedWithoutFabricatingUsage() {
        let records = (0 ..< 140).map { index in
            AgentAutomationTurnAudit(
                turnID: UUID(),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                router: .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled),
                autoEffort: .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible)
            )
        }
        let retained = AgentAutomationTurnAudit.retain(records)
        XCTAssertEqual(retained.count, AgentAutomationTurnAudit.retainedTurnLimit)
        XCTAssertEqual(retained.first?.turnID, records[12].turnID)
        XCTAssertFalse(retained.last?.providerTurnAccepted ?? true)
    }
}

@MainActor
final class AgentTaskRoutingDecisionLogTests: XCTestCase {
    private var tempRoot: URL!
    private let privacySentinel = "SENTINEL-TASK-TEXT-7f3a"
    private let secretSentinel = "dummy-placeholder-value"

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskRoutingDecisionLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Decision events

    func testModelStagePickWritesOneDecisionEvent() async throws {
        let fixture = try await makeJevFixture()
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "Implement the parser", surface: .general, logContext: context
        )
        XCTAssertNotNil(target)
        await fixture.log.flush()

        let rows = try fixture.rows()
        let modelRows = rows.filter { $0["stage"] as? String == "model" }
        XCTAssertEqual(modelRows.count, 1)
        let row = try XCTUnwrap(modelRows.first)
        XCTAssertEqual(row["event"] as? String, "decision")
        XCTAssertEqual(row["schema"] as? Int, 1)
        XCTAssertEqual(row["requestID"] as? String, context.requestID.uuidString)
        XCTAssertEqual(row["scope"] as? String, "subagent")
        XCTAssertEqual(row["outcome"] as? String, "selected")
        XCTAssertEqual(row["backend"] as? String, "jev")
        XCTAssertEqual(row["jevModel"] as? String, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(row["policyVersion"] as? String, JevRouterCredentialService.routingPolicyVersion)
        let candidates = try XCTUnwrap(row["candidates"] as? [[String: Any]])
        XCTAssertGreaterThan(candidates.count, 1)
        for candidate in candidates {
            XCTAssertNotNil(candidate["key"] as? String)
            XCTAssertNotNil(candidate["provider"] as? String)
            XCTAssertNotNil(candidate["model"] as? String)
            XCTAssertNotNil(candidate["modelParameters"] as? [Any])
        }
        let chosenKey = try XCTUnwrap(row["chosenKey"] as? String)
        XCTAssertTrue(candidates.contains { $0["key"] as? String == chosenKey })
        XCTAssertNotNil(row["chosenTarget"] as? [String: Any])
        let probabilities = try XCTUnwrap(row["probabilities"] as? [String: Double])
        XCTAssertEqual(Set(probabilities.keys), Set(candidates.compactMap { $0["key"] as? String }))
        XCTAssertEqual(try XCTUnwrap(row["confidence"] as? Double), 0.7, accuracy: 0.0001)
        XCTAssertEqual(row["inputTokens"] as? Int, 12)
        XCTAssertEqual(row["outputTokens"] as? Int, 4)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(row["latencyMs"] as? Double), 0)
        XCTAssertTrue(row.keys.contains("rationale"))
        XCTAssertTrue(row["rationale"] is NSNull)
    }

    func testEffortStagePickWritesOneDecisionEvent() async throws {
        let fixture = try await makeJevFixture()
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "Implement the parser", surface: .general, logContext: context
        )
        XCTAssertNotNil(target)
        await fixture.log.flush()

        let rows = try fixture.rows()
        XCTAssertEqual(rows.count(where: { $0["stage"] as? String == "model" }), 1)
        let effortRows = rows.filter { $0["stage"] as? String == "effort" }
        XCTAssertEqual(effortRows.count, 1)
        let row = try XCTUnwrap(effortRows.first)
        XCTAssertEqual(row["requestID"] as? String, context.requestID.uuidString)
        XCTAssertEqual(row["outcome"] as? String, "selected")
        let chosen = try XCTUnwrap(row["chosenTarget"] as? [String: Any])
        XCTAssertEqual(chosen["effort"] as? String, target?.reasoningEffortRaw)
        XCTAssertEqual(chosen["model"] as? String, target?.modelRaw)
    }

    func testAutoEffortJudgeWritesOneDecisionEvent() async throws {
        let fixture = try await makeJevFixture()
        fixture.store.setAutoEffortEnabled(true)
        let tabID = UUID()
        fixture.viewModel.test_setCurrentTabIDOverride(tabID)
        let session = fixture.viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5"

        let choice = await fixture.viewModel.chooseAutoEffortForUserTurn(
            text: "Review the cache layer \(privacySentinel) password=\(secretSentinel)",
            session: session,
            workflow: nil
        )
        XCTAssertTrue(choice.audit.judgmentRequested)
        await fixture.log.flush()

        let rows = try fixture.rows()
        let autoRows = rows.filter { $0["stage"] as? String == "autoEffort" }
        XCTAssertEqual(autoRows.count, 1)
        let row = try XCTUnwrap(autoRows.first)
        XCTAssertEqual(row["event"] as? String, "decision")
        XCTAssertEqual(row["outcome"] as? String, "selected")
        XCTAssertEqual(row["backend"] as? String, "jev")
        XCTAssertEqual(row["jevModel"] as? String, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(row["policyVersion"] as? String, JevAutoEffortJudge.policyVersion)
        XCTAssertNotNil(row["probabilities"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(row["confidence"] as? Double), 0.8, accuracy: 0.0001)
        XCTAssertEqual(row["inputTokens"] as? Int, 12)
        let bytes = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(bytes.contains(privacySentinel))
        XCTAssertFalse(bytes.contains(secretSentinel))
    }

    func testAbstentionFailureAndCancellationWriteDecisionEvents() async throws {
        // Model-stage abstention: only the reached stage writes.
        var scenario = try await makeStubFixture(.abstainModel)
        var rows = try await routeOnce(scenario)
        XCTAssertEqual(rows.map { $0["stage"] as? String }, ["model"])
        XCTAssertEqual(rows.first?["outcome"] as? String, "abstained")

        scenario = try await makeStubFixture(.failModel)
        rows = try await routeOnce(scenario)
        XCTAssertEqual(rows.map { $0["stage"] as? String }, ["model"])
        XCTAssertEqual(rows.first?["outcome"] as? String, "failed")
        XCTAssertEqual(rows.first?["failure"] as? String, "timeout")

        scenario = try await makeStubFixture(.cancelModel)
        rows = try await routeOnce(scenario, expectCancel: true)
        XCTAssertEqual(rows.map { $0["stage"] as? String }, ["model"])
        XCTAssertEqual(rows.first?["outcome"] as? String, "cancelled")

        scenario = try await makeStubFixture(.abstainEffort)
        rows = try await routeOnce(scenario)
        XCTAssertEqual(rows.map { $0["stage"] as? String }, ["model", "effort"])
        XCTAssertEqual(rows.map { $0["outcome"] as? String }, ["selected", "abstained"])
    }

    func testPreAnswerCoordinatorReturnsOmitJevMetadata() async throws {
        let request = AgentTaskRoutingRequest(
            requestID: UUID(), contractVersion: AgentTaskRoutingRequest.currentContractVersion,
            task: "Implement parser", scope: .subagent, customInstructions: nil,
            candidates: ["first", "last"].map {
                .init(opaqueKey: $0, roleLabels: [], targetDescription: $0, rubricVersion: "v1", rubric: "parser")
            }
        )
        let unavailable = StubRoutingBackend(mode: .notReady, id: .jev)
        let unavailableCoordinator = try AgentFreshTaskRoutingCoordinator(
            registry: AgentTaskRouterRegistry(registrations: [.init(backend: unavailable)])
        )
        let rejected = await unavailableCoordinator.routeTraced(backendID: .jev, request: request)
        XCTAssertEqual(rejected.outcome, .failed(category: .policyUnavailable, retryable: false, evidence: nil))
        XCTAssertNil(rejected.trace.jevModel)
        XCTAssertNil(rejected.trace.latencyMs)

        let pending = StubRoutingBackend(mode: .selectLast, id: .jev)
        pending.onRoute = { try? await Task.sleep(for: .seconds(30)) }
        let coordinator = try AgentFreshTaskRoutingCoordinator(
            registry: AgentTaskRouterRegistry(registrations: [.init(backend: pending)])
        )
        for cancellation in 0 ..< 3 {
            let task = Task { await coordinator.routeTraced(backendID: .jev, request: request) }
            try await AsyncTestWait.waitUntil("pending backend request", timeout: 5) {
                await pending.requests.count == cancellation + 1
            }
            let duplicate = await coordinator.routeTraced(backendID: .jev, request: request)
            XCTAssertEqual(duplicate.outcome, .failed(category: .invalidRequest, retryable: false, evidence: nil))
            XCTAssertNil(duplicate.trace.jevModel)
            XCTAssertNil(duplicate.trace.latencyMs)
            switch cancellation {
            case 0: await coordinator.cancel(requestID: request.requestID)
            case 1: await coordinator.cancelAll()
            default: task.cancel()
            }
            let cancelled = await task.value
            XCTAssertEqual(cancelled.outcome, .cancelled)
            XCTAssertNil(cancelled.trace.jevModel)
            XCTAssertNil(cancelled.trace.latencyMs)
        }
    }

    func testJevBackendIdentityWithoutAnswerEvidenceOmitsLogMetadata() async throws {
        for mode in [StubRoutingBackend.Mode.selectLast, .failModel, .cancelModel] {
            let fixture = try await makeStubFixture(mode, backendID: .jev)
            let rows = try await routeOnce(fixture, expectCancel: mode == .cancelModel)
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                XCTAssertEqual(row["backend"] as? String, "jev")
                XCTAssertTrue(row["jevModel"] is NSNull)
                XCTAssertTrue(row["policyVersion"] is NSNull)
            }
        }
    }

    func testAutoEffortNonAnswersOmitJevMetadata() async throws {
        for mode in [ModeJevClient.Mode.answer, .fail, .cancel] {
            let url = tempRoot.appendingPathComponent("auto-\(UUID().uuidString)/jev-decisions.jsonl")
            let log = AgentTaskRoutingDecisionLog(fileURL: url)
            let credentials = JevRouterCredentialService(
                secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
                client: ModeJevClient(mode: mode)
            )
            guard case .saved = await credentials.validateAndSave("secret-\(secretSentinel)", operationID: UUID()) else {
                throw NSError(domain: "AgentTaskRoutingDecisionLogTests", code: 3)
            }
            let context = AgentTaskRoutingRouteContext(requestID: UUID(), scope: .primarySession, log: log)
            let chosen = await AgentTaskRoutingJudgeLogging.currentTaskLocal.withValue(context) {
                await JevAutoEffortJudge(credentials: credentials).chooseEffort(
                    maskedTaskExcerpt: "Review the cache layer",
                    selectedModelID: "claude-opus-5-5",
                    builtInWorkflow: nil,
                    efforts: ["low", "medium", "high"]
                )
            }
            await log.flush()
            let rows = try Self.decodedRows(Data(contentsOf: url))
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["stage"] as? String, "autoEffort")
            XCTAssertEqual(row["backend"] as? String, "jev")
            switch mode {
            case .answer:
                XCTAssertEqual(chosen, "medium")
                XCTAssertEqual(row["outcome"] as? String, "selected")
                XCTAssertEqual(row["jevModel"] as? String, JevRouterCredentialService.pinnedModel)
                XCTAssertEqual(row["policyVersion"] as? String, JevAutoEffortJudge.policyVersion)
                XCTAssertEqual(try XCTUnwrap(row["confidence"] as? Double), 0.8, accuracy: 0.0001)
                XCTAssertEqual(row["inputTokens"] as? Int, 12)
                XCTAssertEqual((row["candidates"] as? [[String: Any]])?.count, 3)
            case .fail, .cancel:
                XCTAssertNil(chosen)
                XCTAssertEqual(row["outcome"] as? String, mode == .fail ? "failed" : "cancelled")
                XCTAssertTrue(row["jevModel"] is NSNull)
                XCTAssertTrue(row["policyVersion"] is NSNull)
            }
        }
    }

    func testLocalSingleCandidateWritesDecisionWithoutJevRequest() async throws {
        // One legitimate model candidate injected through the builder's existing modelOptions seam.
        let sonnet = AgentModelOption(
            rawValue: "claude-sonnet-5-5", displayName: "Claude Sonnet", description: nil,
            isPlaceholderDefault: false, isProviderDefault: false
        )
        let fixture = try await makeStubFixture(
            .selectLast,
            providers: [.claudeCode],
            candidateBuilder: {
                AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in provider == .claudeCode ? [sonnet] : [] })
            }
        )
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "Implement parser", surface: .general, logContext: context
        )
        XCTAssertEqual(target?.modelRaw, "claude-sonnet-5-5")
        await fixture.log.flush()
        let rows = try fixture.rows().filter { $0["requestID"] as? String == context.requestID.uuidString }
        let modelLocal = rows.filter { $0["stage"] as? String == "model" && $0["outcome"] as? String == "localSingleCandidate" }
        XCTAssertEqual(modelLocal.count, 1, "exactly one local model decision")
        let row = try XCTUnwrap(modelLocal.first)
        XCTAssertEqual(row["backend"] as? String, "local")
        XCTAssertEqual((row["candidates"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(row["chosenKey"] as? String, (row["candidates"] as? [[String: Any]])?.first?["key"] as? String)
        XCTAssertTrue(row["probabilities"] is NSNull)
        let requests = await fixture.backend.requests
        XCTAssertTrue(
            requests.allSatisfy { $0.decisionStage != .model },
            "The locally resolved model stage makes no Jev request"
        )
    }

    // MARK: - Applied events

    func testAgentRunStartWritesAppliedEvent() async throws {
        // Real AgentRunMCPToolService.start -> real AgentExternalMCPRunStarter -> real run pipeline
        // with a stubbed native controller (no live provider).
        let started = try await serviceStart(.run)
        let startedOutcome = try assertServiceJoin(started, scope: "subagent")
        XCTAssertNotEqual(startedOutcome, "rejected")
        XCTAssertEqual(
            startedOutcome,
            Self.appliedMatchesPick(started) ? "applied" : "fallback",
            "outcome follows the joined picked/applied targets"
        )

        // A fallback replaces the pick: the starter's dispatch seam changes the session model first.
        let replaced = try await serviceStart(.run, dispatch: Self.fallbackDispatch)
        XCTAssertEqual(try assertServiceJoin(replaced, scope: "subagent"), "fallback")

        // A rejected start (service start throws) has a null session id.
        let rejected = try await serviceStart(.run, failStart: true)
        XCTAssertEqual(try assertServiceJoin(rejected, scope: "subagent"), "rejected")
    }

    func testAgentExploreStartWritesAppliedEvent() async throws {
        // Real AgentExploreMCPToolService.start from an MCP-controlled non-explore caller session.
        let started = try await serviceStart(.explore)
        XCTAssertNotEqual(try assertServiceJoin(started, scope: "headless"), "rejected")
        let rejected = try await serviceStart(.explore, failStart: true)
        XCTAssertEqual(try assertServiceJoin(rejected, scope: "headless"), "rejected")
    }

    func testComposerSubmissionWritesAppliedEvent() async throws {
        let fixture = try await makeStubFixture(.selectLast)
        let tabID = UUID()
        fixture.viewModel.test_setCurrentTabIDOverride(tabID)
        let session = fixture.viewModel.session(for: tabID)
        let text = "Implement parser \(privacySentinel)"
        let claim = try routingClaim(viewModel: fixture.viewModel, session: session, text: text)

        let result = await fixture.viewModel.submitUserTurnAfterFreshTaskRouting(
            text: text, claim: claim, session: session, destinationTabID: tabID
        )
        XCTAssertEqual(result, .submitted)
        try await waitForAppliedRows(fixture, count: 1)
        let rows = try fixture.rows()
        let applied = rows.filter { $0["event"] as? String == "applied" }
        XCTAssertEqual(applied.count, 1, ".submitted alone never writes applied; the recorder settlement does")
        XCTAssertEqual(applied.first?["requestID"] as? String, claim.attempt.id.uuidString)
        XCTAssertEqual(applied.first?["scope"] as? String, "primarySession")
        XCTAssertTrue(rows.contains { $0["event"] as? String == "decision" && $0["requestID"] as? String == claim.attempt.id.uuidString })
        assertDecisionsPrecedeApplied(rows)
        let bytes = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(bytes.contains(privacySentinel))
    }

    func testComposerConflictAwaitsCancellationDecisionAndApplied() async throws {
        let storage = ReleasableAppendStorage()
        let url = tempRoot.appendingPathComponent("conflict-\(UUID().uuidString)/jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: url, storage: storage)
        let fixture = try await makeStubFixture(.selectLast, log: log, logURL: url)
        let viewModel = fixture.viewModel
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        let text = "Implement parser \(privacySentinel)"
        let claim = try routingClaim(viewModel: viewModel, session: session, text: text)
        // A different in-flight route owns the tab, so the real wrapper takes its conflict path.
        viewModel.freshTaskRoutingByTabID[tabID] = AgentModeViewModel.FreshTaskRoutingOwnership(
            requestID: UUID(),
            sourceTabID: tabID,
            destinationTabID: tabID,
            task: Task { AgentModeViewModel.StagedTaskRoutingResult(candidates: [], outcome: .cancelled) }
        )
        defer { viewModel.freshTaskRoutingByTabID.removeAll() }

        let completed = LockedCounter()
        // Holds the first physical write so the conflict path returns before it.
        storage.beforeActiveFileSize = {
            try? await AsyncTestWait.waitUntil("hold append until conflict completes", timeout: 10) { completed.value > 0 }
        }
        let submission = Task { @MainActor in
            let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
                text: text, claim: claim, session: session, destinationTabID: tabID
            )
            completed.increment()
            return result
        }
        try await AsyncTestWait.waitUntil("conflict submission returns", timeout: 10) { completed.value > 0 }
        let result = await submission.value
        XCTAssertEqual(result, .blocked(message: "Model routing is already in progress for this task."))
        let held = await log.snapshot()
        XCTAssertGreaterThan(held.admittedBytes, 0, "Cancelled decision is admitted before the conflict path returns")
        storage.release()

        let requestID = claim.attempt.id.uuidString
        try await AsyncTestWait.waitUntil("rejected applied row", timeout: 10) {
            await log.flush()
            return Self.decodedRows(storage.contents()).contains {
                $0["event"] as? String == "applied" && $0["requestID"] as? String == requestID
            }
        }
        await log.flush()
        let rows = Self.decodedRows(storage.contents()).filter { $0["requestID"] as? String == requestID }
        let decisions = rows.filter { $0["event"] as? String == "decision" }
        let applied = rows.filter { $0["event"] as? String == "applied" }
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?["outcome"] as? String, "cancelled")
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?["outcome"] as? String, "rejected")
        XCTAssertEqual(rows.count, 2, "No late, lost or duplicate rows")
        assertDecisionsPrecedeApplied(rows)
    }

    func testInnerAndOuterRejectionFinishOneAppliedEvent() async throws {
        let fixture = try await makeStubFixture(.staleModel)
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        do {
            _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "Go stale", surface: .general, logContext: context
            )
            XCTFail("Expected a stale routing error")
        } catch {
            // Outer catch of the permitted MCP caller.
            await context.finish(.rejected)
        }
        await fixture.log.flush()
        let applied = try fixture.rows().filter { $0["event"] as? String == "applied" }
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?["outcome"] as? String, "rejected")
        XCTAssertEqual(applied.first?["requestID"] as? String, context.requestID.uuidString)
    }

    func testStartOutcomeVariantsFinishOneAppliedEvent() async throws {
        let fixture = try await makeStubFixture(.selectLast)
        var contexts: [(AgentTaskRoutingRouteContext, String)] = []
        let variants: [(String, @MainActor (AgentRunStartOutcomeRecorder) -> Void)] = [
            ("rejected", { $0.record(codexOutcome: .preDispatchRejected(message: "no")) }),
            ("applied", { $0.record(codexOutcome: .sent) }),
            ("applied", { $0.recordAccepted() }),
            ("rejected", { $0.recordStartFailure(message: nil) })
        ]
        for (expected, drive) in variants {
            let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
            let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "variant", surface: .general, logContext: context
            )
            let recorder = AgentRunStartOutcomeRecorder()
            drive(recorder)
            await context.finish(AgentTaskRoutingStartSettlement(recorder: recorder, actual: target, sessionID: UUID()))
            // A second finish never adds a row.
            await context.finish(.rejected)
            contexts.append((context, expected))
        }
        await fixture.log.flush()
        let rows = try fixture.rows()
        for (context, expected) in contexts {
            let applied = rows.filter { $0["event"] as? String == "applied" && $0["requestID"] as? String == context.requestID.uuidString }
            XCTAssertEqual(applied.count, 1)
            XCTAssertEqual(applied.first?["outcome"] as? String, expected)
        }
        assertDecisionsPrecedeApplied(rows)
    }

    func testDelayedAppliedFinalizesAfter512InterleavedRoutes() async throws {
        let fixture = try await makeStubFixture(.selectLast)
        let delayed = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let delayedTarget = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "delayed", surface: .general, logContext: delayed
        )
        for index in 0 ..< 520 {
            let other = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
            _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "other \(index)", surface: .general, logContext: other
            )
            await other.finish(.rejected)
        }
        await delayed.finish(.accepted(actual: delayedTarget, sessionID: UUID()))
        await fixture.log.flush()
        let applied = try fixture.rows().filter {
            $0["event"] as? String == "applied" && $0["requestID"] as? String == delayed.requestID.uuidString
        }
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?["outcome"] as? String, "applied")
    }

    // MARK: - Privacy and rotation

    func testLogOmitsTaskTextAndSecrets() async throws {
        let fixture = try await makeJevFixture()
        fixture.store.setModelRouterCustomInstructions("Prefer \(privacySentinel) \(tempRoot.path)")
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "Fix \(privacySentinel) with key \(secretSentinel) in \(tempRoot.path)/file.swift",
            surface: .general,
            logContext: context
        )
        await context.finish(.rejected)
        await fixture.log.flush()
        let bytes = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertFalse(bytes.contains(privacySentinel))
        XCTAssertFalse(bytes.contains(secretSentinel))
        XCTAssertFalse(bytes.contains(tempRoot.path))
        for row in try fixture.rows() {
            XCTAssertTrue(row["rationale"] is NSNull || row["event"] as? String == "applied")
        }
    }

    func testLogRotatesAtSizeLimit() async throws {
        let url = tempRoot.appendingPathComponent("rotate/jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: url, maxBytes: 64 * 1024)
        for index in 0 ..< 400 {
            var draft = AgentTaskRoutingDecisionDraft(stage: .model, outcome: .failed)
            draft.failure = "transport-\(index)"
            let each = AgentTaskRoutingRouteContext(requestID: UUID(), scope: .subagent, log: log)
            await each.emitDecision(draft)
        }
        await log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(files, ["jev-decisions.jsonl", "jev-decisions.jsonl.1"])
        for name in files {
            let size = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(name)).count
            XCTAssertLessThanOrEqual(size, 64 * 1024 + 2048)
        }
        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.droppedCount, 0)
    }

    func testLogWriteFailureNeverBlocksOrFailsRouting() async throws {
        let errors = LockedCounter()
        let storage = FailingStorage()
        let url = tempRoot.appendingPathComponent("fail/jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(
            fileURL: url, storage: storage, errorSink: { _ in errors.increment() }
        )
        let fixture = try await makeStubFixture(.selectLast, log: log, logURL: url)
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "io failure", surface: .general, logContext: context
        )
        XCTAssertNotNil(target, "Routing result is unchanged by log failure")
        await context.finish(.accepted(actual: target, sessionID: UUID()))
        await log.flush()
        let snapshot = await log.snapshot()
        XCTAssertGreaterThan(snapshot.droppedCount, 0)
        XCTAssertEqual(errors.value, snapshot.droppedCount)
    }

    func testOversizedRowWrittenWholeWithAtMostTwoFiles() async throws {
        let url = tempRoot.appendingPathComponent("oversize/jev-decisions.jsonl")
        let maxBytes = 64 * 1024
        let log = AgentTaskRoutingDecisionLog(fileURL: url, maxBytes: maxBytes)
        let directory = url.deletingLastPathComponent()
        var lastLines: [Data] = []
        for delta in [-1, 0, 1] {
            let line = try encodedRow(paddedTo: maxBytes + delta, requestID: UUID())
            XCTAssertEqual(line.count, maxBytes + delta)
            await log.append(line)
            await log.flush()
            lastLines.append(line)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertLessThanOrEqual(files.count, 2)
            let active = try Data(contentsOf: url)
            XCTAssertEqual(active, line, "Oversized or boundary row is on disk whole and alone in the active file")
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: active.dropLast()) as? [String: Any])
        }
        let small = try encodedRow(paddedTo: 700, requestID: UUID())
        await log.append(small)
        await log.flush()
        XCTAssertEqual(try Data(contentsOf: url), small)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".1")), lastLines[2])
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.droppedCount, 0)
    }

    func testOversizedAdmissionTerminatesWithoutDeadlock() async throws {
        let budget = 10000
        @Sendable func row(_ tag: String, _ size: Int) -> Data {
            var text = tag + ":"
            text += String(repeating: "x", count: max(0, size - text.count - 1))
            return Data((text + "\n").utf8)
        }
        let storage = GatedStorage()
        let promotions = PromotionRecorder()
        let url = tempRoot.appendingPathComponent("fair/jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(
            fileURL: url, maxBytes: 64 * 1024 * 1024, admissionBudget: budget, storage: storage,
            onPromote: { bytes, admitted in promotions.record(bytes: bytes, admitted: admitted) }
        )
        let rowA = row("A", budget / 2)
        let rowO = row("O", budget * 2)
        await log.append(rowA) // fast path
        await storage.waitUntilAppendStarted()

        let oTask = Task { await log.append(rowO) }
        try await waitForSnapshot(log) { $0.waiterCount == 1 }
        let s1Task = Task { await log.append(row("s1", 100)) }
        try await waitForSnapshot(log) { $0.waiterCount == 2 }
        let s2Task = Task { await log.append(row("s2", 100)) }
        try await waitForSnapshot(log) { $0.waiterCount == 3 }
        let blocked = await log.snapshot()
        XCTAssertEqual(blocked.admittedBytes, rowA.count, "Small arrivals do not bypass the oversized head waiter")

        // The promotion hook starts s3 between promotion and the head's resume.
        let s3Holder = TaskHolder()
        promotions.onOversized = { s3Holder.task = Task { await log.append(row("s3", 100)) } }
        let cancelledTask = Task { await log.append(row("c", 100)) }
        try await waitForSnapshot(log) { $0.waiterCount == 4 }
        cancelledTask.cancel()

        storage.release()
        await oTask.value
        await s1Task.value
        await s2Task.value
        await cancelledTask.value
        await s3Holder.task?.value
        XCTAssertEqual(promotions.firstOversizedAdmitted, rowO.count, "O is reserved before its caller resumes")

        for index in 0 ..< 1000 {
            await log.append(row("n\(index)", 120))
        }
        await log.flush()
        let tags = String(decoding: storage.contents(), as: UTF8.self)
            .split(separator: "\n").map { String($0.split(separator: ":")[0]) }
        XCTAssertEqual(Array(tags.prefix(7)), ["A", "O", "s1", "s2", "c", "s3", "n0"])
        XCTAssertEqual(tags.count(where: { $0 == "c" }), 1, "A cancelled waiter is still logged exactly once")
        XCTAssertEqual(tags.count, 1006)
        XCTAssertEqual(Array(tags.suffix(1000)), (0 ..< 1000).map { "n\($0)" })
        let end = await log.snapshot()
        XCTAssertEqual(end.admittedBytes, 0)
        XCTAssertEqual(end.waiterCount, 0)
        XCTAssertEqual(end.droppedCount, 0)

        // Same schedule when every physical write fails: terminates, every row counted as dropped.
        let failing = AgentTaskRoutingDecisionLog(
            fileURL: url, admissionBudget: budget, storage: FailingStorage(), errorSink: { _ in }
        )
        let failingRows = [row("A", budget / 2), row("O", budget * 2), row("s1", 100), row("s2", 100)]
        await withTaskGroup(of: Void.self) { group in
            for item in failingRows {
                group.addTask { await failing.append(item) }
            }
        }
        await failing.flush()
        let failed = await failing.snapshot()
        XCTAssertEqual(failed.droppedCount, failingRows.count)
        XCTAssertEqual(failed.admittedBytes, 0)
        XCTAssertEqual(failed.waiterCount, 0)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let store: GlobalSettingsStore
        let log: AgentTaskRoutingDecisionLog
        let logURL: URL
        let backend: StubRoutingBackend

        func rows() throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
            return try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        }
    }

    private struct JevFixture {
        let viewModel: AgentModeViewModel
        let store: GlobalSettingsStore
        let log: AgentTaskRoutingDecisionLog
        let logURL: URL

        func rows() throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
            return try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        }
    }

    private func makeJevFixture() async throws -> JevFixture {
        let logURL = tempRoot.appendingPathComponent("jev-\(UUID().uuidString)/jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: logURL)
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            client: FakeJevClient()
        )
        guard case .saved = await credentials.validateAndSave("secret-\(secretSentinel)", operationID: UUID()) else {
            throw NSError(domain: "AgentTaskRoutingDecisionLogTests", code: 1)
        }
        let backend = JevTaskRouterBackend(credentialService: credentials)
        let runtime = try AgentTaskRouterRuntime(
            registrations: [.init(backend: backend, settings: JevTaskRouterBackend.settingsRegistration(controller: credentials))],
            decisionLog: log
        )
        try await AsyncTestWait.waitUntil("jev ready", timeout: 5) { runtime.isBackendReady(.jev) }
        let (viewModel, store) = try makeViewModel(runtime: runtime, backendID: .jev, providers: [.claudeCode, .codexExec])
        return JevFixture(viewModel: viewModel, store: store, log: log, logURL: logURL)
    }

    private func makeStubFixture(
        _ mode: StubRoutingBackend.Mode,
        backendID: AgentTaskRouterBackendID = AgentTaskRouterBackendID(rawValue: "log-stub"),
        providers: Set<AgentProviderKind> = [.claudeCode, .codexExec],
        candidateBuilder: (@MainActor () -> AgentTaskRoutingCandidateBuilder)? = nil,
        log injectedLog: AgentTaskRoutingDecisionLog? = nil,
        logURL injectedURL: URL? = nil
    ) async throws -> Fixture {
        let logURL = injectedURL ?? tempRoot.appendingPathComponent("stub-\(UUID().uuidString)/jev-decisions.jsonl")
        let log = injectedLog ?? AgentTaskRoutingDecisionLog(fileURL: logURL)
        let backend = StubRoutingBackend(mode: mode, id: backendID)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(backend: backend)], decisionLog: log)
        try await AsyncTestWait.waitUntil("stub ready", timeout: 5) { runtime.backendReadiness(backend.id) != nil }
        let (viewModel, store) = try makeViewModel(runtime: runtime, backendID: backend.id, providers: providers)
        if let candidateBuilder { runtime.candidateBuilderFactory = candidateBuilder }
        backend.onRoute = { [store] in
            if mode == .staleModel { await MainActor.run { store.setModelRouterEnabled(false) } }
        }
        return Fixture(viewModel: viewModel, store: store, log: log, logURL: logURL, backend: backend)
    }

    private func makeViewModel(
        runtime: AgentTaskRouterRuntime,
        backendID: AgentTaskRouterBackendID,
        providers: Set<AgentProviderKind>
    ) throws -> (AgentModeViewModel, GlobalSettingsStore) {
        let root = tempRoot.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentTaskRoutingDecisionLogTests.\(UUID())"))
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        store.enableModelRouterWithCurrentPolicy(
            backendID: backendID,
            roles: Set(AgentModelCatalog.TaskLabelKind.allCases),
            providers: providers
        )
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: providers.contains(.claudeCode),
            codexAvailable: providers.contains(.codexExec),
            openCodeAvailable: false
        )
        runtime.candidateBuilderFactory = {
            AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in
                guard providers.contains(provider) else { return [] }
                return AgentModelCatalog.options(for: provider, availability: availability)
            })
        }
        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Decision log test must not start Codex")
            },
            claudeControllerFactory: { _, _, _, _ in MonitorFakeNativeController() },
            headlessProviderFactory: { _, _, _, _, _ in UnsupportedHeadlessAgentProvider(reason: "test terminal") }
        )
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        return (viewModel, store)
    }

    private func routeOnce(_ fixture: Fixture, expectCancel: Bool = false) async throws -> [[String: Any]] {
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        do {
            _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "Implement parser", surface: .general, logContext: context
            )
            XCTAssertFalse(expectCancel)
        } catch {
            XCTAssertTrue(expectCancel)
        }
        await fixture.log.flush()
        // A cancelled route also finalizes its (rejected) application; decisions are asserted here.
        return try fixture.rows().filter { $0["event"] as? String == "decision" }
    }

    // MARK: Real MCP service fixtures

    private enum ServiceKind { case run, explore }

    private enum DecisionLogProviderRefused: Error { case refused }

    private struct ServiceStartResult {
        let rows: [[String: Any]]
        var applied: [[String: Any]] {
            rows.filter { $0["event"] as? String == "applied" }
        }

        var decisions: [[String: Any]] {
            rows.filter { $0["event"] as? String == "decision" }
        }
    }

    private static let fallbackDispatch: AgentExternalMCPRunStarter.DispatchInstruction = { sessionID, tabID, message, workflow, viewModel in
        if let session = viewModel.session(for: tabID, createIfNeeded: false) {
            session.selectedModelRaw += "-decision-log-probe"
        }
        return try await viewModel.mcpDispatchInstruction(
            sessionID: sessionID, text: message, allowStartingRun: true,
            workflow: workflow, preserveRoutedInitialEffort: true
        )
    }

    private static let failingStartRun: AgentRunMCPToolService.StartRun = { _, _, _, _, _, _, _, _, _, _, _, _ in
        throw MCPError.internalError("decision log test start failure")
    }

    private static func realStartRun(
        kind: ServiceKind,
        dispatch: AgentExternalMCPRunStarter.DispatchInstruction?
    ) -> AgentRunMCPToolService.StartRun {
        { target, message, metadata, viewModel, agentRaw, modelRaw, effort, taskLabelKind, workflow, parentID, oracleSource, preserve in
            switch kind {
            case .run:
                try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                    target: target, message: message, metadata: metadata, agentModeVM: viewModel,
                    agentRaw: agentRaw, modelRaw: modelRaw, reasoningEffortRaw: effort,
                    taskLabelKind: taskLabelKind, workflow: workflow, expectedParentSessionID: parentID,
                    oracleReviewSource: oracleSource, preserveRoutedInitialEffort: preserve,
                    dispatchInstruction: dispatch
                )
            case .explore:
                try await AgentExternalMCPRunStarter.startApplyingRequestBindingPolicy(
                    target: target, message: message, metadata: metadata,
                    bindCurrentRequestToTab: { _, _ in },
                    agentModeVM: viewModel, agentRaw: agentRaw, modelRaw: modelRaw, reasoningEffortRaw: effort,
                    taskLabelKind: taskLabelKind, workflow: workflow, preserveRoutedInitialEffort: preserve,
                    dispatchInstruction: dispatch
                )
            }
        }
    }

    private func serviceStart(
        _ kind: ServiceKind,
        dispatch: AgentExternalMCPRunStarter.DispatchInstruction? = nil,
        failStart: Bool = false
    ) async throws -> ServiceStartResult {
        let logURL = tempRoot.appendingPathComponent("svc-\(UUID().uuidString)/jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: logURL)
        let backend = StubRoutingBackend(mode: .selectLast)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(backend: backend)], decisionLog: log)
        try await AsyncTestWait.waitUntil("service router ready", timeout: 5) { runtime.backendReadiness(backend.id) != nil }
        let (_, store) = try makeViewModel(runtime: runtime, backendID: backend.id, providers: [.claudeCode, .codexExec])
        let window = try await makeServiceWindow()
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        window.agentModeViewModel.modelRouterSettingsStore = store
        window.agentModeViewModel.modelRouterRuntime = runtime
        let startRun: AgentRunMCPToolService.StartRun = failStart
            ? Self.failingStartRun
            : Self.realStartRun(kind: kind, dispatch: dispatch)
        let args: [String: Value] = [
            "op": .string("start"),
            "message": .string("Implement the parser and add tests"),
            "detach": .bool(true),
            "timeout": .int(0)
        ]
        do {
            switch kind {
            case .run:
                _ = try await makeRunService(window: window, startRun: startRun).execute(args: args)
            case .explore:
                let caller = try await makeExploreCaller(window: window)
                _ = try await makeExploreService(window: window, caller: caller, startRun: startRun).execute(args: args)
            }
            XCTAssertFalse(failStart, "A failing start must throw")
        } catch {
            XCTAssertTrue(failStart, "Service start failed unexpectedly: \(error)")
        }
        try await AsyncTestWait.waitUntil("service applied row", timeout: 20) {
            await log.flush()
            return Self.readRows(logURL).contains { $0["event"] as? String == "applied" }
        }
        await log.flush()
        return ServiceStartResult(rows: Self.readRows(logURL))
    }

    private static func appliedMatchesPick(_ result: ServiceStartResult) -> Bool {
        guard let row = result.applied.first, let picked = row["picked"] as? [String: Any] else { return false }
        return row["provider"] as? String == picked["provider"] as? String
            && row["model"] as? String == picked["model"] as? String
            && row["effort"] as? String == picked["effort"] as? String
    }

    private nonisolated static func readRows(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func assertServiceJoin(
        _ result: ServiceStartResult,
        scope: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        XCTAssertEqual(result.applied.count, 1, "exactly one applied row", file: file, line: line)
        let applied = try XCTUnwrap(result.applied.first, file: file, line: line)
        let requestID = try XCTUnwrap(applied["requestID"] as? String, file: file, line: line)
        XCTAssertEqual(applied["scope"] as? String, scope, file: file, line: line)
        XCTAssertFalse(result.decisions.isEmpty, file: file, line: line)
        XCTAssertTrue(
            result.decisions.allSatisfy { $0["requestID"] as? String == requestID },
            "every decision row joins the applied row by requestID", file: file, line: line
        )
        assertDecisionsPrecedeApplied(result.rows, file: file, line: line)
        let outcome = try XCTUnwrap(applied["outcome"] as? String, file: file, line: line)
        XCTAssertTrue(["applied", "fallback", "rejected"].contains(outcome), file: file, line: line)
        XCTAssertEqual(applied["sessionID"] is NSNull, outcome == "rejected", "sessionID is null exactly when rejected", file: file, line: line)
        return outcome
    }

    private func makeServiceWindow() async throws -> WindowState {
        let settings = GlobalSettingsStore.shared
        let previousAutoStart = settings.mcpAutoStart()
        settings.setMCPAutoStart(false, commit: false)
        defer { settings.setMCPAutoStart(previousAutoStart, commit: false) }
        // Deterministic hosted window: stubbed native controller and refused headless/ACP providers,
        // so a real run start reaches the existing pipeline seam without any live provider.
        let workspacePath = tempRoot.path
        let window = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let viewModel = AgentModeViewModel(
                    testWindowID: windowID,
                    testWorkspacePath: workspacePath,
                    codexControllerFactory: { _, _, _, _, _, _ in
                        preconditionFailure("Decision log test must not start Codex")
                    },
                    claudeControllerFactory: { _, _, _, _ in MonitorFakeNativeController() },
                    headlessProviderFactory: { _, _, _, _, _ in
                        AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
                    },
                    acpProviderFactory: { _, _ in throw DecisionLogProviderRefused.refused },
                    acpControllerFactory: { _, _ in throw DecisionLogProviderRefused.refused },
                    connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                    mcpRunRoutingCleaner: { _, _, _ in },
                    mcpServerEnabler: { true },
                    testMCPServer: server,
                    testWorkspaceFileContextStore: prompt.workspaceFileContextStore
                )
                viewModel.promptManager = prompt
                viewModel.workspaceManager = manager
                return viewModel
            },
            contextBuilderProviderFactory: { _, _, _, _ in
                AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
            }
        )
        WindowStatesManager.shared.registerWindowState(window)
        await window.workspaceManager.awaitInitialized()
        // Connected-provider fixture on this isolated window only.
        window.apiSettingsViewModel.isClaudeCodeConnected = true
        window.apiSettingsViewModel.isCodexConnected = true
        window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(
            verifiedProviders: [.claudeCode, .codexExec]
        )
        let workspace = window.workspaceManager.createWorkspace(
            name: "Decision log \(UUID().uuidString.prefix(8))",
            repoPaths: [FileManager.default.currentDirectoryPath],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace, saveState: false, reason: "decisionLogServiceStart"
        )
        guard let activeWorkspace = window.workspaceManager.activeWorkspace else {
            throw MCPError.internalError("Expected active ephemeral workspace")
        }
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeExploreCaller(window: WindowState) async throws -> (tabID: UUID, sessionID: UUID) {
        let sessionID = UUID()
        let session = await window.agentModeViewModel.ensureSessionReady(tabID: UUID())
        _ = window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session)
        try await window.agentModeViewModel.mcpActivateControlContext(
            forTabID: session.tabID,
            sessionID: sessionID,
            originatingConnectionID: nil,
            taskLabelKind: .pair,
            startPending: false
        )
        return (session.tabID, sessionID)
    }

    private func makeExploreService(
        window: WindowState,
        caller: (tabID: UUID, sessionID: UUID),
        startRun: @escaping AgentRunMCPToolService.StartRun
    ) -> AgentExploreMCPToolService {
        let windowID = window.windowID
        return AgentExploreMCPToolService(
            toolName: MCPWindowToolName.agentExplore,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "decision-log-test", windowID: windowID)
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in caller.tabID },
            resolveSpawnParentSessionID: { _, _ in caller.sessionID },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: startRun
        )
    }

    private func makeRunService(
        window: WindowState,
        startRun: @escaping AgentRunMCPToolService.StartRun
    ) -> AgentRunMCPToolService {
        let windowID = window.windowID
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "decision-log-test", windowID: windowID)
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in nil },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: startRun
        )
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let sourceTabID = try XCTUnwrap(workspace.activeComposeTabID ?? targetWindow.promptManager.activeComposeTabID)
            let selectionRevision = targetWindow.workspaceManager.selectionRevisionForMCP(
                workspaceID: workspace.id, tabID: sourceTabID
            )
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: .explicitWindowActiveCompose,
                windowID: targetWindow.windowID,
                workspaceID: workspace.id,
                tabID: sourceTabID,
                selectionRevision: selectionRevision,
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: nil,
                routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(),
                    sourceTabID: sourceTabID,
                    workspaceID: workspace.id,
                    sourceAgentSessionID: nil,
                    sourceAgentRunID: nil,
                    reason: .sourceCaptureFailed("Decision log test fixture")
                ))
            )
        }
        return service
    }

    private func routingClaim(
        viewModel: AgentModeViewModel,
        session: AgentModeViewModel.TabSession,
        text: String
    ) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
        let target = try XCTUnwrap(viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: text
        )
        guard case let .claimed(claim) = viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else {
            throw NSError(domain: "AgentTaskRoutingDecisionLogTests", code: 2)
        }
        return claim
    }

    private func waitForAppliedRows(_ fixture: Fixture, count: Int) async throws {
        try await AsyncTestWait.waitUntil("applied rows", timeout: 10) {
            await fixture.log.flush()
            return ((try? fixture.rows()) ?? []).count(where: { $0["event"] as? String == "applied" }) >= count
        }
    }

    private func waitForSnapshot(
        _ log: AgentTaskRoutingDecisionLog,
        _ predicate: @escaping (AgentTaskRoutingDecisionLog.Snapshot) -> Bool
    ) async throws {
        try await AsyncTestWait.waitUntil("log snapshot", timeout: 10) { await predicate(log.snapshot()) }
    }

    private func assertDecisionsPrecedeApplied(_ rows: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        var appliedSeen = Set<String>()
        for row in rows {
            guard let id = row["requestID"] as? String else { continue }
            if row["event"] as? String == "applied" {
                appliedSeen.insert(id)
            } else {
                XCTAssertFalse(appliedSeen.contains(id), "decision after applied for \(id)", file: file, line: line)
            }
        }
    }

    private static func decodedRows(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func encodedRow(paddedTo size: Int, requestID: UUID) throws -> Data {
        func line(pad: Int) throws -> Data {
            var draft = AgentTaskRoutingDecisionDraft(stage: .model, outcome: .failed)
            draft.failure = String(repeating: "p", count: pad)
            return try AgentTaskRoutingDecisionLog.encodeLine(
                AgentTaskRoutingDecisionEvent(requestID: requestID, sessionID: nil, scope: .subagent, draft: draft, timestamp: Date())
            )
        }
        let base = try line(pad: 0).count
        return try line(pad: size - base)
    }
}

// MARK: - Test doubles

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class TaskHolder: @unchecked Sendable {
    var task: Task<Void, Never>?
}

private final class PromotionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var firstOversizedAdmitted: Int?
    var onOversized: (@Sendable () -> Void)?

    func record(bytes: Int, admitted: Int) {
        lock.lock()
        let hook = bytes >= 20000 ? onOversized : nil
        if bytes >= 20000, firstOversizedAdmitted == nil { firstOversizedAdmitted = admitted }
        lock.unlock()
        hook?()
    }
}

private struct FailingStorage: AgentTaskRoutingDecisionLogStorage {
    func activeFileSize() async throws -> Int {
        throw CocoaError(.fileWriteNoPermission)
    }

    func append(_ data: Data) async throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    func rotate() async throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class GatedStorage: AgentTaskRoutingDecisionLogStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var started = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stored = Data()
    private let directory = FileManager.default.temporaryDirectory

    func release() {
        lock.lock()
        released = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    func waitUntilAppendStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func storedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }

    private func appendStored(_ data: Data) {
        lock.lock()
        stored.append(data)
        lock.unlock()
    }

    func activeFileSize() async throws -> Int {
        storedCount()
    }

    func append(_ data: Data) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started = true
            let starters = startWaiters
            startWaiters.removeAll()
            if released {
                lock.unlock()
                starters.forEach { $0.resume() }
                continuation.resume()
            } else {
                gateWaiters.append(continuation)
                lock.unlock()
                starters.forEach { $0.resume() }
            }
        }
        appendStored(data)
    }

    func rotate() async throws {}

    func contents() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private actor StubRoutingBackend: AgentTaskRouterBackend {
    enum Mode { case selectLast, abstainModel, failModel, cancelModel, abstainEffort, staleModel, notReady }
    nonisolated let id: AgentTaskRouterBackendID
    nonisolated let displayName = "Log stub"
    nonisolated(unsafe) var onRoute: (@Sendable () async -> Void)?
    let mode: Mode
    private(set) var requests: [AgentTaskRoutingRequest] = []

    init(mode: Mode, id: AgentTaskRouterBackendID = AgentTaskRouterBackendID(rawValue: "log-stub")) {
        self.mode = mode
        self.id = id
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        mode == .notReady
            ? .needsConfiguration(generation: 1, reason: "No credentials")
            : .ready(generation: 1, policyVersion: "fake-v1")
    }

    func route(_ request: AgentTaskRoutingRequest) async -> AgentTaskRoutingBackendOutcome {
        requests.append(request)
        await onRoute?()
        let last = request.candidates[request.candidates.count - 1].opaqueKey
        switch (mode, request.decisionStage) {
        case (.abstainModel, .model): return .abstained(reason: "ambiguous", evidence: nil)
        case (.failModel, .model): return .failed(category: .timeout, retryable: true, evidence: nil)
        case (.cancelModel, .model): return .cancelled
        case (.abstainEffort, .effort): return .abstained(reason: "ambiguous", evidence: nil)
        default: return .selected(opaqueKey: last, evidence: nil)
        }
    }
}

private final class ReleasableAppendStorage: AgentTaskRoutingDecisionLogStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stored = Data()
    private var activeFileSizeHook: (@Sendable () async -> Void)?

    var beforeActiveFileSize: (@Sendable () async -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return activeFileSizeHook
        }
        set {
            lock.lock()
            activeFileSizeHook = newValue
            lock.unlock()
        }
    }

    var appendStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    private func appendStored(_ data: Data) {
        lock.lock()
        stored.append(data)
        lock.unlock()
    }

    func contents() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func activeFileSize() async throws -> Int {
        let hook = beforeActiveFileSize
        await hook?()
        return contents().count
    }

    func append(_ data: Data) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started = true
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
        appendStored(data)
    }

    func rotate() async throws {}
}

private actor ModeJevClient: JevRoutingClientProtocol {
    enum Mode { case answer, fail, cancel }
    private let mode: Mode
    private let base = FakeJevClient()

    init(mode: Mode) {
        self.mode = mode
    }

    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        await base.listModels(apiKey: apiKey, timeout: timeout)
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) async throws -> JevRoutingWireResponse {
        switch mode {
        case .answer: await base.judge(request: request, apiKey: apiKey, timeout: timeout)
        case .fail: throw JevRoutingClientError.timeout
        case .cancel: throw CancellationError()
        }
    }
}

private actor FakeJevClient: JevRoutingClientProtocol {
    func listModels(apiKey: String, timeout: Duration) -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(request: JevRoutingWireRequest, apiKey: String, timeout: Duration) -> JevRoutingWireResponse {
        let (questionID, question) = request.questions.first!
        let keys = question.criteria.keys.sorted()
        let chosen = questionID == "effort" ? (keys.contains("medium") ? "medium" : keys[0]) : keys[keys.count - 1]
        let isEffort = questionID == "effort"
        let top = isEffort ? 0.8 : 0.7
        let rest = keys.count > 1 ? (1 - top) / Double(keys.count - 1) : 0
        var probabilities: [String: Double] = [:]
        for key in keys {
            probabilities[key] = key == chosen ? top : rest
        }
        return .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: [questionID: .init(type: "choice", choice: chosen, probabilities: probabilities, confidence: top)],
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
    }
}
