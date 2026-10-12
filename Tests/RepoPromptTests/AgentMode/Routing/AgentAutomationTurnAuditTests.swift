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

    private typealias Fixture = RoutingStubFixture

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
        try await makeRoutingStubFixture(
            mode, tempRoot: tempRoot, backendID: backendID, providers: providers,
            candidateBuilder: candidateBuilder, log: injectedLog, logURL: injectedURL
        )
    }

    private func makeViewModel(
        runtime: AgentTaskRouterRuntime,
        backendID: AgentTaskRouterBackendID,
        providers: Set<AgentProviderKind>
    ) throws -> (AgentModeViewModel, GlobalSettingsStore) {
        try makeRoutingViewModel(tempRoot: tempRoot, runtime: runtime, backendID: backendID, providers: providers)
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

    private func waitForSnapshot(
        _ log: AgentTaskRoutingDecisionLog,
        _ predicate: @escaping (AgentTaskRoutingDecisionLog.Snapshot) -> Bool
    ) async throws {
        try await AsyncTestWait.waitUntil("log snapshot", timeout: 10) { await predicate(log.snapshot()) }
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

// MARK: - Shared composer and log helpers

@MainActor
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

private func waitForAppliedRows(_ fixture: RoutingStubFixture, count: Int) async throws {
    try await AsyncTestWait.waitUntil("applied rows", timeout: 10) {
        await fixture.log.flush()
        return ((try? fixture.rows()) ?? []).count(where: { $0["event"] as? String == "applied" }) >= count
    }
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
    /// Picks a candidate by descriptor identity (never position); `nil` falls back to the last candidate.
    nonisolated(unsafe) var chooseKey: (@Sendable (AgentTaskRoutingRequest) -> String?)?
    /// Evidence scores for the chosen key; `nil` keeps the evidence-free default.
    private var scoresFor: (@Sendable (AgentTaskRoutingRequest, String) -> [String: Double]?)?
    let mode: Mode
    private(set) var requests: [AgentTaskRoutingRequest] = []

    func setScoresFor(_ scoring: (@Sendable (AgentTaskRoutingRequest, String) -> [String: Double]?)?) {
        scoresFor = scoring
    }

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
        default:
            let key = chooseKey?(request) ?? last
            let evidence = scoresFor?(request, key).map {
                AgentTaskRoutingDecisionEvidence(
                    policyVersion: nil, confidence: nil, scores: $0, inputTokens: nil, outputTokens: nil, reasonCode: nil
                )
            }
            return .selected(opaqueKey: key, evidence: evidence)
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

private struct RoutingStubFixture {
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

@MainActor
private func makeRoutingStubFixture(
    _ mode: StubRoutingBackend.Mode,
    tempRoot: URL,
    backendID: AgentTaskRouterBackendID = AgentTaskRouterBackendID(rawValue: "log-stub"),
    providers: Set<AgentProviderKind> = [.claudeCode, .codexExec],
    candidateBuilder: (@MainActor () -> AgentTaskRoutingCandidateBuilder)? = nil,
    log injectedLog: AgentTaskRoutingDecisionLog? = nil,
    logURL injectedURL: URL? = nil,
    explorationAdvisor injectedAdvisor: AgentTaskRoutingExplorationAdvisor? = nil
) async throws -> RoutingStubFixture {
    let logURL = injectedURL ?? tempRoot.appendingPathComponent("stub-\(UUID().uuidString)/jev-decisions.jsonl")
    let log = injectedLog ?? AgentTaskRoutingDecisionLog(fileURL: logURL)
    let backend = StubRoutingBackend(mode: mode, id: backendID)
    let explorationAdvisor = injectedAdvisor ?? AgentTaskRoutingExplorationAdvisor(
        fileURL: tempRoot.appendingPathComponent("exploration-\(UUID().uuidString)/exploration-counters.json")
    )
    let runtime = try AgentTaskRouterRuntime(
        registrations: [.init(backend: backend)], decisionLog: log, explorationAdvisor: explorationAdvisor
    )
    try await AsyncTestWait.waitUntil("stub ready", timeout: 5) { runtime.backendReadiness(backend.id) != nil }
    let (viewModel, store) = try makeRoutingViewModel(
        tempRoot: tempRoot, runtime: runtime, backendID: backend.id, providers: providers
    )
    if let candidateBuilder { runtime.candidateBuilderFactory = candidateBuilder }
    backend.onRoute = { [store] in
        if mode == .staleModel { await MainActor.run { store.setModelRouterEnabled(false) } }
    }
    return RoutingStubFixture(viewModel: viewModel, store: store, log: log, logURL: logURL, backend: backend)
}

@MainActor
private func makeRoutingViewModel(
    tempRoot: URL,
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

@MainActor
final class AgentTaskRoutingMakerDiversityTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskRoutingMakerDiversityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testExclusionIsLoggedWithSource() async throws {
        let options = AgentTaskRoutingDiversityOptions(exclusions: [
            "openai": [.reviewDiversity, .excludeMakers],
            "anthropic": [.diverseFromSessions],
            "mystery": [.reviewDiversity, .diverseFromSessions, .excludeMakers]
        ])
        let expected: [String: [String]] = [
            "openai": ["exclude_makers", "review_diversity"],
            "anthropic": ["diverse_from_sessions"],
            "mystery": ["exclude_makers", "diverse_from_sessions", "review_diversity"]
        ]
        XCTAssertEqual(options.canonicalMakerExclusions, expected)
        XCTAssertEqual(AgentTaskRoutingDiversityOptions.none.canonicalMakerExclusions, [:])

        let fixture = try await makeRoutingStubFixture(.selectLast, tempRoot: tempRoot)
        let context = AgentTaskRoutingRouteContext(requestID: UUID(), scope: .subagent, log: fixture.log)
        await context.attachMakerExclusions(AgentTaskRoutingDiversityOptions.none.canonicalMakerExclusions)
        await context.attachMakerExclusions(options.canonicalMakerExclusions)
        await context.attachMakerExclusions(["xai": ["exclude_makers"]])
        for stage in [AgentTaskRoutingLogStage.model, .effort, .autoEffort] {
            await context.emitDecision(AgentTaskRoutingDecisionDraft(stage: stage, outcome: .selected))
        }
        await context.finish(.rejected)
        await fixture.log.flush()

        let rows = try fixture.rows()
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["decision", "decision", "decision", "applied"])
        let decisions = rows.filter { $0["event"] as? String == "decision" }
        XCTAssertEqual(decisions.compactMap { $0["stage"] as? String }, ["model", "effort", "autoEffort"])
        XCTAssertEqual(decisions[0]["makerExclusions"] as? [String: [String]], expected)
        for row in decisions.dropFirst() {
            XCTAssertTrue(row.keys.contains("makerExclusions"))
            XCTAssertTrue(row["makerExclusions"] is NSNull)
        }

        // Real routes: provenance reaches the actual model row; pre-route rows exist only with exclusions.
        let diversity = Self.excluding([.openai], source: .reviewDiversity)
        let routed = ["openai": ["review_diversity"]]

        let selected = try await makeDiversityFixture(.selectLast)
        selected.backend.chooseKey = Self.choose(model: "claude-sonnet")
        let selectedContext = try XCTUnwrap(selected.viewModel.makeRouteLogContext(scope: .subagent))
        let selectedResult = await route(selected, selectedContext, diversity: diversity)
        XCTAssertEqual(try selectedResult.get()?.agentRaw, AgentProviderKind.claudeCode.rawValue)
        let selectedRows = try await eventRows(selected, selectedContext).filter { $0["event"] as? String == "decision" }
        XCTAssertEqual(selectedRows.compactMap { $0["stage"] as? String }, ["model", "effort"])
        guard selectedRows.count == 2 else { return XCTFail("Expected model and effort rows") }
        XCTAssertEqual(selectedRows[0]["outcome"] as? String, "selected")
        XCTAssertEqual(selectedRows[0]["backend"] as? String, "log-stub")
        XCTAssertEqual(selectedRows[0]["makerExclusions"] as? [String: [String]], routed)
        XCTAssertTrue(selectedRows[1]["makerExclusions"] is NSNull)

        let baseline = Self.claudeBaseline
        for (mode, reason) in [(StubRoutingBackend.Mode.selectLast, "router_disabled"), (.notReady, "backend_not_ready")] {
            let withExclusions = try await makeDiversityFixture(mode)
            if mode == .selectLast { withExclusions.store.setModelRouterEnabled(false) }
            let context = try XCTUnwrap(withExclusions.viewModel.makeRouteLogContext(scope: .subagent))
            let result = await route(withExclusions, context, baseline: baseline, diversity: diversity)
            XCTAssertNil(try result.get(), reason)
            await context.finish(.accepted(actual: baseline, sessionID: nil))
            let rows = try await eventRows(withExclusions, context)
            XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["decision", "applied"], reason)
            guard rows.count == 2 else { return XCTFail("\(reason): expected one decision and one applied row") }
            XCTAssertEqual(rows[0]["stage"] as? String, "model", reason)
            XCTAssertEqual(rows[0]["outcome"] as? String, "failed", reason)
            XCTAssertEqual(rows[0]["failure"] as? String, "policyUnavailable", reason)
            XCTAssertEqual(rows[0]["reasonCode"] as? String, reason)
            XCTAssertEqual((rows[0]["candidates"] as? [Any])?.count, 0, reason)
            XCTAssertTrue(rows[0]["backend"] is NSNull, reason)
            XCTAssertEqual(rows[0]["makerExclusions"] as? [String: [String]], routed, reason)
            XCTAssertEqual(rows[1]["outcome"] as? String, "fallback", reason)
            let requested = await withExclusions.backend.requests
            XCTAssertTrue(requested.isEmpty, reason)

            let control = try await makeDiversityFixture(mode)
            if mode == .selectLast { control.store.setModelRouterEnabled(false) }
            let controlContext = try XCTUnwrap(control.viewModel.makeRouteLogContext(scope: .subagent))
            let controlResult = await route(control, controlContext, baseline: baseline, diversity: .none)
            XCTAssertNil(try controlResult.get(), reason)
            await controlContext.finish(.accepted(actual: baseline, sessionID: nil))
            let controlRows = try await eventRows(control, controlContext)
            XCTAssertTrue(controlRows.isEmpty, "\(reason): no exclusions, no pre-route row")
        }
    }

    func testEveryModelDefinitionHasAMaker() {
        let projection = AgentTaskRoutingCandidateBuilder().registeredTargetMakers
        let expectedMakers: [String: AgentTaskRoutingMaker] = [
            "gpt-luna": .openai,
            "gpt-5.6-terra": .openai,
            "gpt-sol": .openai,
            "gpt-6-astra": .openai,
            "claude-haiku": .anthropic,
            "claude-sonnet": .anthropic,
            "claude-opus": .anthropic,
            "claude-fable": .anthropic,
            "gemini-flash": .google,
            "gemini-pro": .google,
            "grok": .xai,
            "composer": .cursor,
            "cursor-grok": .xai
        ]
        XCTAssertEqual(projection.count, 13)
        XCTAssertEqual(Set(projection.keys), Set(expectedMakers.keys))
        XCTAssertEqual(projection.values.compactMap(\.self).count, 13)
        for (modelClass, maker) in expectedMakers {
            XCTAssertEqual(projection[modelClass] ?? nil, Optional(maker), modelClass)
        }

        func resolved(_ provider: AgentProviderKind, _ modelRaw: String) -> AgentTaskRoutingMaker? {
            let byProvider = AgentTaskRoutingMakerCatalog.maker(provider: provider, modelRaw: modelRaw)
            let byTarget = AgentTaskRoutingMakerCatalog.maker(
                for: AgentRoutingExecutableTarget(
                    agentRaw: provider.rawValue,
                    modelRaw: modelRaw,
                    reasoningEffortRaw: nil,
                    modelParameters: []
                )
            )
            XCTAssertEqual(byTarget, byProvider, "\(provider.rawValue) \(modelRaw)")
            return byProvider
        }

        let identities: [(AgentProviderKind, String, AgentTaskRoutingMaker?)] = [
            (.claudeCode, "opus", .anthropic),
            (.claudeCode, "default", .anthropic),
            (.claudeCode, "opus[1m]", .anthropic),
            (.claudeCode, "gpt-5", .anthropic),
            (.codexExec, "claude-opus", .openai),
            (.codexExec, "gpt-6-sol", .openai),
            (.grok, "composer-2.5", .xai),
            (.grok, "grok", .xai),
            (.cursor, "grok-4.7", .xai),
            (.cursor, "composer-2.5", .cursor),
            (.cursor, "cursor-grok", nil),
            (.cursor, "composer", nil),
            (.antigravity, "gemini-flash", .google),
            (.antigravity, "gemini-pro", .google),
            (.antigravity, "claude-sonnet", .anthropic),
            (.antigravity, "gpt-5", .openai),
            (.antigravity, "grok-4", .xai),
            (.antigravity, "composer-2.5", .cursor),
            (.cursor, "claude-haiku", .anthropic),
            (.cursor, "gpt-6", .openai),
            (.cursor, "gemini-flash", .google),
            (.cursor, "mystery", nil),
            (.antigravity, "unknown-family", nil),
            (.openCode, "claude-opus", nil),
            (.grokBuild, "grok-4", nil),
            (.devin, "gpt-5", nil),
            (.claudeCodeGLM, "claude-opus", nil),
            (.kimiCode, "claude-opus", nil),
            (.customClaudeCompatible, "claude-opus", nil)
        ]
        for (provider, modelRaw, maker) in identities {
            XCTAssertEqual(resolved(provider, modelRaw), maker, "\(provider.rawValue) \(modelRaw)")
        }
        XCTAssertNil(
            AgentTaskRoutingMakerCatalog.maker(
                for: AgentRoutingExecutableTarget(
                    agentRaw: "not-a-provider",
                    modelRaw: "claude-opus",
                    reasoningEffortRaw: nil,
                    modelParameters: []
                )
            )
        )
    }

    func testExcludedMakerIsRemovedBeforeJevRequest() async throws {
        let fixture = try await makeDiversityFixture(.selectLast)
        fixture.backend.chooseKey = Self.choose(model: "claude-sonnet")
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))

        let result = await route(fixture, context, diversity: Self.excluding([.openai]))

        let requests = await fixture.backend.requests
        let modelRequests = requests.filter { $0.decisionStage == .model }
        XCTAssertEqual(modelRequests.count, 1, "At least two allowed Claude models must still reach Jev")
        let request = try XCTUnwrap(modelRequests.first)
        XCTAssertGreaterThanOrEqual(request.candidates.count, 2)
        let rows = try await eventRows(fixture, context)
        let modelRow = try XCTUnwrap(rows.first { $0["stage"] as? String == "model" })
        let candidates = try XCTUnwrap(modelRow["candidates"] as? [[String: Any]])
        XCTAssertEqual(Set(candidates.compactMap { $0["key"] as? String }), Set(request.candidates.map(\.opaqueKey)))
        XCTAssertEqual(
            Set(candidates.compactMap { $0["provider"] as? String }),
            [AgentProviderKind.claudeCode.rawValue],
            "No codexExec candidate may reach the request"
        )
        XCTAssertEqual(try result.get()?.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(modelRow["makerExclusions"] as? [String: [String]], ["openai": ["exclude_makers"]])
    }

    func testSingleAllowedCandidateAppliesWithoutJevRequest() async throws {
        // Allowed Sonnet beside an excluded Codex peer: one model remains, no model request, one local effort row.
        let sonnet = try await makeDiversityFixture(.selectLast, claude: ["claude-sonnet-5-5"], codex: ["gpt-6.1-sol"])
        let sonnetContext = try XCTUnwrap(sonnet.viewModel.makeRouteLogContext(scope: .subagent))
        let sonnetResult = await route(sonnet, sonnetContext, diversity: Self.excluding([.openai]))
        let sonnetRequests = await sonnet.backend.requests
        XCTAssertTrue(sonnetRequests.allSatisfy { $0.decisionStage != .model }, "A lone allowed model makes no model request")
        XCTAssertTrue(sonnetRequests.allSatisfy { $0.decisionStage != .effort }, "A lone default effort makes no effort request")
        XCTAssertEqual(try sonnetResult.get()?.modelRaw, "claude-sonnet-5-5")
        let sonnetRows = try await eventRows(sonnet, sonnetContext).filter { $0["event"] as? String == "decision" }
        XCTAssertEqual(sonnetRows.compactMap { $0["stage"] as? String }, ["model", "effort"])
        guard sonnetRows.count == 2 else { return XCTFail("Expected local model and effort rows") }
        XCTAssertEqual(sonnetRows[0]["outcome"] as? String, "localSingleCandidate")
        XCTAssertEqual((sonnetRows[0]["candidates"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(sonnetRows[0]["makerExclusions"] as? [String: [String]], ["openai": ["exclude_makers"]])

        // Allowed Codex with several efforts beside an excluded Claude peer: still exactly one effort request.
        let codex = try await makeDiversityFixture(.selectLast, claude: ["claude-sonnet-5-5"], codex: ["gpt-6.1-sol"])
        codex.backend.chooseKey = Self.choose(effort: "high")
        let codexContext = try XCTUnwrap(codex.viewModel.makeRouteLogContext(scope: .subagent))
        let codexResult = await route(codex, codexContext, diversity: Self.excluding([.anthropic]))
        let codexRequests = await codex.backend.requests
        XCTAssertTrue(codexRequests.allSatisfy { $0.decisionStage != .model }, "A lone allowed model makes no model request")
        let effortRequests = codexRequests.filter { $0.decisionStage == .effort }
        XCTAssertEqual(effortRequests.count, 1, "Local model selection must still route effort")
        XCTAssertGreaterThan(try XCTUnwrap(effortRequests.first).candidates.count, 1)
        XCTAssertEqual(try codexResult.get()?.modelRaw, "gpt-6.1-sol-high")
        let codexRows = try await eventRows(codex, codexContext).filter { $0["event"] as? String == "decision" }
        XCTAssertEqual(codexRows.compactMap { $0["stage"] as? String }, ["model", "effort"])
        guard codexRows.count == 2 else { return XCTFail("Expected local model and effort rows") }
        XCTAssertEqual(codexRows[0]["outcome"] as? String, "localSingleCandidate")
        XCTAssertEqual(codexRows[1]["outcome"] as? String, "selected")
        XCTAssertTrue(codexRows[1]["makerExclusions"] is NSNull)
    }

    func testAllCandidatesExcludedFailsTyped() async throws {
        let diversity = Self.excluding(AgentTaskRoutingMaker.allCases)
        let fixture = try await makeDiversityFixture(.selectLast)
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))

        let result = await route(fixture, context, diversity: diversity)

        XCTAssertEqual(Self.routingError(result), .allCandidatesExcluded)
        await context.finish(.accepted(actual: Self.claudeBaseline, sessionID: nil))
        let rows = try await eventRows(fixture, context)
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["decision", "applied"])
        guard rows.count == 2 else { return XCTFail("Expected one decision and one applied row") }
        XCTAssertEqual(rows[0]["stage"] as? String, "model")
        XCTAssertEqual(rows[0]["outcome"] as? String, "failed")
        XCTAssertEqual(rows[0]["failure"] as? String, "allCandidatesExcluded")
        XCTAssertEqual((rows[0]["candidates"] as? [Any])?.count, 0)
        XCTAssertTrue(rows[0]["backend"] is NSNull)
        XCTAssertEqual(rows[0]["makerExclusions"] as? [String: [String]], diversity.canonicalMakerExclusions)
        XCTAssertEqual(rows[1]["outcome"] as? String, "rejected", "A caller's later settlement is harmless")
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty)

        // The existing build failure keeps its category, and a nil baseline still cannot be rescued.
        let empty = try await makeDiversityFixture(.selectLast, claude: [], codex: [])
        let emptyContext = try XCTUnwrap(empty.viewModel.makeRouteLogContext(scope: .subagent))
        let emptyResult = await route(empty, emptyContext, diversity: Self.excluding([.cursor]))
        XCTAssertEqual(Self.routingError(emptyResult), .fallbackDiversityExcluded)
        let emptyRows = try await eventRows(empty, emptyContext)
        XCTAssertEqual(emptyRows.compactMap { $0["event"] as? String }, ["decision", "applied"])
        guard emptyRows.count == 2 else { return XCTFail("Expected one decision and one applied row") }
        XCTAssertEqual(emptyRows[0]["failure"] as? String, "invalidRequest")
        XCTAssertEqual(emptyRows[1]["outcome"] as? String, "rejected")
    }

    func testFallbackNeverReturnsExcludedMaker() async throws {
        let codex = Self.codexBaseline
        let claude = Self.claudeBaseline
        let unknown = AgentRoutingExecutableTarget(
            agentRaw: AgentProviderKind.openCode.rawValue, modelRaw: "claude-opus-5-5", reasoningEffortRaw: nil, modelParameters: []
        )
        let scenarios: [FallbackScenario] = [
            .init(name: "allowed baseline, no usage swap", exclude: [.xai], baseline: claude, expectation: .retained),
            .init(
                name: "allowed baseline, allowed swap", exclude: [.cursor], baseline: codex,
                usage: .init(codexUsed: 95, claudeUsed: 10, swap: .claudeCode), expectation: .swapped(.claudeCode)
            ),
            .init(
                name: "allowed baseline, excluded swap", exclude: [.anthropic], baseline: codex,
                usage: .init(codexUsed: 95, claudeUsed: 10, swap: .claudeCode), expectation: .retained
            ),
            .init(
                name: "allowed Claude baseline, excluded Codex swap", exclude: [.openai], baseline: claude,
                usage: .init(codexUsed: 10, claudeUsed: 95, swap: .codexExec), expectation: .retained
            ),
            .init(
                name: "excluded baseline cannot be rescued by an allowed swap", exclude: [.openai], baseline: codex,
                usage: .init(codexUsed: 95, claudeUsed: 10, swap: .claudeCode), expectation: .denied
            ),
            .init(name: "excluded baseline, no swap", exclude: [.openai], baseline: codex, expectation: .denied),
            .init(
                name: "usage balance off keeps the proven baseline", exclude: [.cursor], baseline: codex, allowUsageBalance: false,
                usage: .init(codexUsed: 95, claudeUsed: 10, swap: .claudeCode), expectation: .retained
            ),
            .init(name: "nil baseline", exclude: [.cursor], baseline: nil, expectation: .denied),
            .init(name: "unknown-provider baseline", exclude: [.cursor], baseline: unknown, expectation: .denied),
            .init(name: "nil baseline, usage balance off", exclude: [.cursor], baseline: nil, allowUsageBalance: false, expectation: .denied),
            .init(
                name: "unknown-provider baseline, usage balance off", exclude: [.cursor], baseline: unknown,
                allowUsageBalance: false, expectation: .denied
            ),
            .init(
                name: "excluded baseline, usage balance off cannot bypass the fence", exclude: [.openai], baseline: codex,
                allowUsageBalance: false, usage: .init(codexUsed: 95, claudeUsed: 10, swap: .claudeCode), expectation: .denied
            )
        ]
        for mode in FallbackMode.allCases {
            for scenario in scenarios {
                try await assertFallback(mode, scenario)
            }
        }

        // Selected Jev route: the usage advisor sees only the filtered, allowed candidates.
        let usage = FallbackScenario.Usage(codexUsed: 10, claudeUsed: 95, swap: .codexExec)
        let control = try await makeDiversityFixture(.selectLast)
        control.backend.chooseKey = Self.choose(model: "claude-opus")
        enableUsage(control, usage)
        let controlContext = try XCTUnwrap(control.viewModel.makeRouteLogContext(scope: .subagent))
        let controlResult = await route(control, controlContext, diversity: .none)
        XCTAssertEqual(
            try controlResult.get()?.agentRaw, AgentProviderKind.codexExec.rawValue,
            "Without exclusions the advisor swaps Opus to its Codex peer, so the filtered run below is not vacuous"
        )

        let filtered = try await makeDiversityFixture(.selectLast)
        filtered.backend.chooseKey = Self.choose(model: "claude-opus")
        enableUsage(filtered, usage)
        let filteredContext = try XCTUnwrap(filtered.viewModel.makeRouteLogContext(scope: .subagent))
        let filteredResult = await route(filtered, filteredContext, diversity: Self.excluding([.openai]))
        XCTAssertEqual(try filteredResult.get()?.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(try filteredResult.get()?.modelRaw, "claude-opus-5-5")
        let filteredRequests = await filtered.backend.requests
        let modelRequest = try XCTUnwrap(filteredRequests.first { $0.decisionStage == .model })
        XCTAssertFalse(
            modelRequest.candidates.contains { $0.roleLabels.contains("gpt-6.1-sol") },
            "The excluded Codex peer never reaches the model request"
        )
    }

    // MARK: - Diversity fixtures

    private enum FallbackMode: CaseIterable {
        case disabled, notReady, abstain, fail

        var backendMode: StubRoutingBackend.Mode {
            switch self {
            case .disabled: .selectLast
            case .notReady: .notReady
            case .abstain: .abstainModel
            case .fail: .failModel
            }
        }
    }

    private struct FallbackScenario {
        enum Expectation: Equatable {
            case retained
            case swapped(AgentProviderKind)
            case denied
        }

        struct Usage {
            let codexUsed: Double
            let claudeUsed: Double
            let swap: AgentProviderKind
        }

        let name: String
        let exclude: [AgentTaskRoutingMaker]
        let baseline: AgentRoutingExecutableTarget?
        var allowUsageBalance = true
        var usage: Usage?
        let expectation: Expectation
    }

    private static let claudeBaseline = AgentRoutingExecutableTarget(
        agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: "claude-opus-5-5", reasoningEffortRaw: nil, modelParameters: []
    )
    private static let codexBaseline = AgentRoutingExecutableTarget(
        agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: "gpt-6.1-sol-high", reasoningEffortRaw: nil, modelParameters: []
    )

    private static func excluding(
        _ makers: [AgentTaskRoutingMaker],
        source: AgentTaskRoutingDiversityOptions.ExclusionSource = .excludeMakers
    ) -> AgentTaskRoutingDiversityOptions {
        AgentTaskRoutingDiversityOptions(exclusions: Dictionary(uniqueKeysWithValues: makers.map { ($0.rawValue, [source]) }))
    }

    /// Selects by descriptor identity (tier or effort label), never by candidate position.
    private static func choose(model: String? = nil, effort: String? = nil) -> @Sendable (AgentTaskRoutingRequest) -> String? {
        { request in
            let label = request.decisionStage == .model ? model : effort.map { "effort:\($0)" }
            guard let label else { return nil }
            return request.candidates.first { $0.roleLabels == [label] }?.opaqueKey
        }
    }

    private static func routingError(
        _ result: Result<AgentRoutingExecutableTarget?, Error>
    ) -> AgentModeViewModel.GlobalModelRoutingError? {
        guard case let .failure(error) = result else { return nil }
        return error as? AgentModeViewModel.GlobalModelRoutingError
    }

    private func makeDiversityFixture(
        _ mode: StubRoutingBackend.Mode,
        claude: [String] = ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"],
        codex: [String] = ["gpt-5.6-terra", "gpt-6.1-sol"]
    ) async throws -> RoutingStubFixture {
        let options: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            switch provider {
            case .claudeCode:
                claude.map {
                    AgentModelOption(rawValue: $0, displayName: $0, description: nil, isPlaceholderDefault: false, isProviderDefault: false)
                }
            case .codexExec:
                codex.map {
                    AgentModelOption(
                        rawValue: $0, displayName: $0, description: nil, isPlaceholderDefault: false, isProviderDefault: false,
                        supportedReasoningEfforts: [.low, .medium, .high]
                    )
                }
            default:
                []
            }
        }
        return try await makeRoutingStubFixture(
            mode, tempRoot: tempRoot, candidateBuilder: { AgentTaskRoutingCandidateBuilder(modelOptions: options) }
        )
    }

    /// Usage snapshots follow `AgentComposerSubmissionAttemptTests.testUsageBalancingRoutesFreshComposerAndSubagentWithoutJev`.
    private func enableUsage(_ fixture: RoutingStubFixture, _ usage: FallbackScenario.Usage) {
        fixture.store.setUsageBalancingEnabled(true)
        let advisor = AgentUsageBalancer()
        fixture.viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date()
        let reset = now.addingTimeInterval(18000).timeIntervalSince1970
        for (provider, used) in [(AgentProviderKind.codexExec, usage.codexUsed), (.claudeCode, usage.claudeUsed)] {
            let record = ClaudeCLIUsageRecord(version: 1, receivedAt: now, windows: ["five_hour": .init(used: used, resetsAt: reset)])
            advisor.update(record.snapshot(profileID: "diversity-test"), provider: provider.rawValue)
        }
    }

    private func route(
        _ fixture: RoutingStubFixture,
        _ context: AgentTaskRoutingRouteContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        baseline: AgentRoutingExecutableTarget? = nil,
        allowUsageBalance: Bool = true,
        diversity: AgentTaskRoutingDiversityOptions
    ) async -> Result<AgentRoutingExecutableTarget?, Error> {
        do {
            return try await .success(fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "Implement parser", surface: surface, baseline: baseline,
                allowUsageBalance: allowUsageBalance, logContext: context, diversity: diversity
            ))
        } catch {
            return .failure(error)
        }
    }

    private func eventRows(_ fixture: RoutingStubFixture, _ context: AgentTaskRoutingRouteContext) async throws -> [[String: Any]] {
        await fixture.log.flush()
        return try fixture.rows().filter { $0["requestID"] as? String == context.requestID.uuidString }
    }

    private func assertFallback(_ mode: FallbackMode, _ scenario: FallbackScenario) async throws {
        let label = "\(mode)/\(scenario.name)"
        let diversity = Self.excluding(scenario.exclude)
        let fixture = try await makeDiversityFixture(mode.backendMode)
        if mode == .disabled { fixture.store.setModelRouterEnabled(false) }
        if let usage = scenario.usage, let baseline = scenario.baseline {
            enableUsage(fixture, usage)
            let swap = fixture.viewModel.localUsageDecision(basedOn: baseline, scope: .subagent, surface: .headless)
            XCTAssertEqual(swap?.candidate.target.agentRaw, usage.swap.rawValue, "\(label): the usage swap must be available")
        }
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))

        let result = await route(
            fixture, context, surface: .headless, baseline: scenario.baseline,
            allowUsageBalance: scenario.allowUsageBalance, diversity: diversity
        )

        var settled: AgentRoutingExecutableTarget?
        switch scenario.expectation {
        case .retained:
            XCTAssertNil(try result.get(), label)
            settled = scenario.baseline
        case let .swapped(provider):
            let target = try XCTUnwrap(result.get(), label)
            XCTAssertEqual(target.agentRaw, provider.rawValue, label)
            settled = target
        case .denied:
            XCTAssertEqual(Self.routingError(result), .fallbackDiversityExcluded, label)
        }
        let before = try await eventRows(fixture, context)
        let decisions = before.filter { $0["event"] as? String == "decision" }
        XCTAssertEqual(decisions.count, 1, "\(label): exactly one model row")
        let row = try XCTUnwrap(decisions.first, label)
        XCTAssertEqual(row["stage"] as? String, "model", label)
        XCTAssertEqual(row["makerExclusions"] as? [String: [String]], diversity.canonicalMakerExclusions, label)
        let requests = await fixture.backend.requests
        switch mode {
        case .disabled, .notReady:
            XCTAssertTrue(requests.isEmpty, label)
            XCTAssertEqual(row["outcome"] as? String, "failed", label)
            XCTAssertEqual(
                row["failure"] as? String, scenario.expectation == .denied ? "fallbackDiversityExcluded" : "policyUnavailable", label
            )
            if scenario.expectation != .denied {
                XCTAssertEqual(row["reasonCode"] as? String, mode == .disabled ? "router_disabled" : "backend_not_ready", label)
            }
            XCTAssertEqual((row["candidates"] as? [Any])?.count, 0, label)
            XCTAssertTrue(row["backend"] is NSNull, label)
        case .abstain:
            XCTAssertEqual(requests.count(where: { $0.decisionStage == .model }), 1, label)
            XCTAssertEqual(row["outcome"] as? String, "abstained", label)
            XCTAssertEqual(row["backend"] as? String, "log-stub", label)
        case .fail:
            XCTAssertEqual(requests.count(where: { $0.decisionStage == .model }), 1, label)
            XCTAssertEqual(row["outcome"] as? String, "failed", label)
            XCTAssertEqual(row["failure"] as? String, "timeout", label)
            XCTAssertEqual(row["backend"] as? String, "log-stub", label)
        }

        // A later accepted settlement can never replace what the route already settled.
        await context.finish(.accepted(actual: settled, sessionID: nil))
        let after = try await eventRows(fixture, context)
        XCTAssertEqual(after.compactMap { $0["event"] as? String }, ["decision", "applied"], label)
        let applied = try XCTUnwrap(after.last, label)
        XCTAssertEqual(applied["outcome"] as? String, scenario.expectation == .denied ? "rejected" : "fallback", label)
        if scenario.expectation != .denied {
            XCTAssertTrue(applied["picked"] is NSNull, label)
            XCTAssertEqual(applied["model"] as? String, settled?.modelRaw, label)
        }
    }
}

private final class ExplorationErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }
}

private struct ExplorationCounterFile: Decodable {
    let schema: Int
    let counters: [String: UInt64]
}

@MainActor
final class AgentTaskRoutingExplorationTests: XCTestCase {
    private var tempRoot: URL!
    private let ordered = ["a", "b", "c"]
    private let scores: [String: Double] = ["a": 0.6, "b": 0.25, "c": 0.15]

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTaskRoutingExplorationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testLevelsExploreAtFixedPositions() async throws {
        let expected: [AgentRoutingRandomness: [Int]] = [
            .off: [], .low: [10, 30], .medium: [5, 15, 25, 35], .high: [3, 8, 13, 18, 23, 28, 33, 38]
        ]
        for counter in 1 ... 40 {
            XCTAssertEqual(AgentTaskRoutingExplorationAdvisor.position(counter: UInt64(counter)), (counter - 1) % 20 + 1)
        }
        for (level, positions) in expected {
            let exploring = (1 ... 40).filter {
                AgentTaskRoutingExplorationAdvisor.exploringPositions(for: level)
                    .contains(AgentTaskRoutingExplorationAdvisor.position(counter: UInt64($0)))
            }
            XCTAssertEqual(exploring, positions, level.rawValue)
        }

        let runnerUp = AgentTaskRoutingExplorationAdvisor.runnerUp
        XCTAssertEqual(runnerUp("a", ordered, scores), "b")
        XCTAssertEqual(runnerUp("a", ["a", "c", "b"], ["a": 0.6, "b": 0.2, "c": 0.2]), "c")
        XCTAssertEqual(runnerUp("a", ["a", "b", "c"], ["a": 0.6, "b": 0.2, "c": 0.2]), "b")
        XCTAssertNil(runnerUp("a", ordered, nil))
        XCTAssertNil(runnerUp("a", ordered, ["a": 0.6, "b": 0.4]), "missing key")
        XCTAssertNil(runnerUp("a", ordered, ["a": 0.6, "b": 0.2, "c": 0.1, "d": 0.1]), "extra key")
        XCTAssertNil(runnerUp("a", ordered, ["a": 0.6, "b": .nan, "c": 0.1]))
        XCTAssertNil(runnerUp("a", ordered, ["a": 0.6, "b": .infinity, "c": 0.1]))
        XCTAssertNil(runnerUp("a", ordered, ["a": 1.5, "b": 0.2, "c": 0.1]))
        XCTAssertNil(runnerUp("a", ordered, ["a": 0.6, "b": -0.1, "c": 0.1]))
        XCTAssertNil(runnerUp("a", ordered, ["a": 0.4, "b": 0.4, "c": 0.2]), "tied top")
        XCTAssertNil(runnerUp("b", ordered, scores), "chosen is not the maximum")
        XCTAssertNil(runnerUp("a", ["a"], ["a": 1]), "single candidate")
        XCTAssertNil(runnerUp("a", ["a", "a", "b"], ["a": 0.6, "b": 0.4]), "duplicate keys")
        XCTAssertNil(runnerUp("z", ordered, scores), "chosen not a candidate")

        let url = tempRoot.appendingPathComponent("levels/exploration-counters.json")
        for (level, positions) in expected {
            let advisor = AgentTaskRoutingExplorationAdvisor(fileURL: nil)
            for counter in 1 ... 20 {
                let record = await advisor.decide(
                    scope: .primarySession, randomness: level, chosenKey: "a", orderedKeys: ordered, scores: scores
                )
                let exploring = positions.contains(counter)
                XCTAssertEqual(record.kind, exploring ? .exploration : .none, "\(level.rawValue)#\(counter)")
                XCTAssertEqual(record.appliedKey, exploring ? "b" : "a", "\(level.rawValue)#\(counter)")
                XCTAssertEqual(record.originalKey, "a")
                XCTAssertEqual(record.randomness, level.rawValue)
                XCTAssertEqual(record.counter, UInt64(counter))
                XCTAssertEqual(record.position, counter)
                XCTAssertFalse(record.durable, "nil file is in-memory only")
            }
        }
        let advisor = AgentTaskRoutingExplorationAdvisor(fileURL: url)
        var kinds: [AgentTaskRoutingExplorationRecord.Kind] = []
        for _ in 1 ... 10 {
            let record = await advisor.decide(
                scope: .subagent, randomness: .low, chosenKey: "a", orderedKeys: ordered, scores: nil
            )
            kinds.append(record.kind)
            XCTAssertEqual(record.appliedKey, "a", "invalid evidence never invents a runner-up")
            XCTAssertTrue(record.durable)
        }
        XCTAssertEqual(kinds.last, .explorationUnavailable)
        XCTAssertEqual(kinds.dropLast(), Array(repeating: .none, count: 9)[...])
        let primary = await advisor.decide(
            scope: .primarySession, randomness: .low, chosenKey: "a", orderedKeys: ordered, scores: scores
        )
        XCTAssertEqual(primary.counter, 1, "scopes count independently")

        // Real routes: the same positions pick the runner-up for the shipped caller, per scope.
        for (level, positions) in [(AgentRoutingRandomness.medium, [5, 15]), (.high, [3, 8, 13, 18])] {
            let fixture = try await makeExplorationFixture(randomness: level)
            await configure(fixture, pick: "claude-opus", runnerUp: "claude-sonnet")
            for counter in 1 ... 20 {
                let route = try await routeSubagent(fixture)
                let exploring = positions.contains(counter)
                XCTAssertEqual(route.target?.modelRaw, exploring ? Self.sonnet : Self.opus, "\(level.rawValue)#\(counter)")
                try expectOverride(
                    route.rows, kind: exploring ? "exploration" : "none", randomness: level.rawValue, counter: counter
                )
            }
            let issued = try await explorationAdvisor(of: fixture).counter(for: .subagent)
            XCTAssertEqual(issued, 20, level.rawValue)
        }
        let interleavedURL = counterURL()
        try seed(["primarySession": 8, "subagent": 8], at: interleavedURL)
        let interleaved = try await makeExplorationFixture(url: interleavedURL, randomness: .low, hosted: true)
        await configure(interleaved, pick: "claude-opus", runnerUp: "claude-sonnet")
        for counter in 9 ... 11 {
            let exploring = counter == 10
            let composer = try await routeComposer(interleaved)
            XCTAssertEqual(composer.session.selectedModelRaw, exploring ? Self.sonnet : Self.opus, "primary#\(counter)")
            try expectOverride(composer.rows, kind: exploring ? "exploration" : "none", randomness: "low", counter: counter)
            let subagent = try await routeSubagent(interleaved)
            XCTAssertEqual(subagent.target?.modelRaw, exploring ? Self.sonnet : Self.opus, "subagent#\(counter)")
            try expectOverride(subagent.rows, kind: exploring ? "exploration" : "none", randomness: "low", counter: counter)
        }
    }

    func testOffNeverExplores() async throws {
        let fixture = try await makeExplorationFixture(randomness: .off)
        await configure(fixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        for counter in 1 ... 20 {
            let route = try await routeSubagent(fixture)
            XCTAssertEqual(route.target?.modelRaw, Self.opus, "off#\(counter)")
            try expectOverride(route.rows, kind: "none", randomness: "off", counter: counter)
        }
        let issued = try await explorationAdvisor(of: fixture).counter(for: .subagent)
        XCTAssertEqual(issued, 20, "Off still counts")

        let primaryURL = counterURL()
        let primary = try await makeExplorationFixture(url: primaryURL, randomness: .off, hosted: true)
        await configure(primary, pick: "claude-opus", runnerUp: "claude-sonnet")
        for stored in [2, 4, 7, 9, 12, 14, 17] {
            try seed(["primarySession": UInt64(stored)], at: primaryURL)
            let composer = try await routeComposer(primary)
            XCTAssertEqual(composer.session.selectedModelRaw, Self.opus, "off after \(stored)")
            try expectOverride(composer.rows, kind: "none", randomness: "off", counter: stored + 1)
        }

        // Switching Off -> Low continues the count: the tenth counted decision explores.
        let switching = try await makeExplorationFixture(randomness: .off)
        await configure(switching, pick: "claude-opus", runnerUp: "claude-sonnet")
        for _ in 1 ... 9 {
            _ = try await routeSubagent(switching)
        }
        switching.store.setRandomness(.low)
        let tenth = try await routeSubagent(switching)
        XCTAssertEqual(tenth.target?.modelRaw, Self.sonnet)
        try expectOverride(tenth.rows, kind: "exploration", randomness: "low", counter: 10)
    }

    func testExplorationAppliesJevRunnerUp() async throws {
        let fixture = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
        await configure(fixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        let target = try await routeSubagent(fixture).target
        XCTAssertEqual(target?.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(target?.modelRaw, Self.sonnet, "position 10 applies Jev's runner-up")

        // Tied second place goes to the earliest surviving builder-ordered candidate.
        let tied = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
        tied.backend.chooseKey = Self.pick("claude-opus")
        await tied.backend.setScoresFor(Self.scores(["claude-sonnet": 0.2, "claude-haiku": 0.2]))
        let tiedTarget = try await routeSubagent(tied).target
        let tiedRequests = await tied.backend.requests
        let tiedOrder = try XCTUnwrap(tiedRequests.first { $0.decisionStage == .model }).candidates.compactMap(\.roleLabels.first)
        let earliest = try XCTUnwrap(tiedOrder.first { $0 == "claude-sonnet" || $0 == "claude-haiku" })
        XCTAssertEqual(tiedTarget?.modelRaw, earliest == "claude-sonnet" ? Self.sonnet : Self.haiku)

        // A maker excluded before Jev is never the runner-up; the logged exclusions stay on the exploring row.
        let excluded = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
        await configure(excluded, pick: "claude-opus", runnerUp: "claude-haiku")
        let excludedRoute = try await routeSubagent(excluded, diversity: AgentTaskRoutingDiversityOptions(exclusions: ["openai": [.excludeMakers]]))
        let excludedRequests = await excluded.backend.requests
        let excludedCandidates = try XCTUnwrap(excludedRequests.first { $0.decisionStage == .model }).candidates
        XCTAssertFalse(excludedCandidates.contains { $0.roleLabels.contains { $0.hasPrefix("gpt") } })
        XCTAssertEqual(excludedRoute.target?.modelRaw, Self.haiku)
        XCTAssertEqual(try modelRow(excludedRoute.rows)["makerExclusions"] as? [String: [String]], ["openai": ["exclude_makers"]])
        try expectOverride(excludedRoute.rows, kind: "exploration", randomness: "low", counter: 10)

        // Normal effort routing then resolves the explored model's own advertised efforts.
        let codex = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
        await configure(codex, pick: "gpt-6.1-sol", runnerUp: "gpt-5.6-terra", effort: "high")
        let codexTarget = try await routeSubagent(codex).target
        XCTAssertEqual(codexTarget?.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertEqual(codexTarget?.modelRaw, "gpt-5.6-terra-high")
        let codexRequests = await codex.backend.requests
        let effortRequest = try XCTUnwrap(codexRequests.first { $0.decisionStage == .effort })
        XCTAssertEqual(Set(effortRequest.candidates.compactMap(\.roleLabels.first)), ["effort:low", "effort:provider-default", "effort:medium", "effort:high"])

        // An abstained effort stage keeps the explored model at its provider default, not Jev's pick.
        let abstained = try await makeExplorationFixture(.abstainEffort, stored: ["subagent": 9], randomness: .low)
        await configure(abstained, pick: "gpt-6.1-sol", runnerUp: "gpt-5.6-terra")
        let abstainedTarget = try await routeSubagent(abstained).target
        XCTAssertEqual(abstainedTarget?.modelRaw, "gpt-5.6-terra")

        // The shipped composer applies the same runner-up to the session.
        let composerURL = counterURL()
        try seed(["primarySession": 9], at: composerURL)
        let composerFixture = try await makeExplorationFixture(url: composerURL, randomness: .low, hosted: true)
        await configure(composerFixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        let composer = try await routeComposer(composerFixture)
        XCTAssertEqual(composer.session.selectedAgent, .claudeCode)
        XCTAssertEqual(composer.session.selectedModelRaw, Self.sonnet)
        let audit = try XCTUnwrap(composer.session.automationTurnAudit.last?.router)
        XCTAssertEqual(audit.chosenModelRaw, Self.sonnet)
        XCTAssertNil(audit.usageBalancingReason)
    }

    func testExplorationSkipsUsageBalancing() async throws {
        let claudeOpus = AgentRoutingExecutableTarget(
            agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: Self.opus, reasoningEffortRaw: nil, modelParameters: []
        )
        // Subagent: Claude is near its limit, so a non-exploring Claude pick swaps to its Codex peer.
        let control = try await makeExplorationFixture(randomness: .low)
        await configure(control, pick: "claude-opus", runnerUp: "claude-sonnet")
        enableUsage(control, codexUsed: 10, claudeUsed: 95)
        let peer = try XCTUnwrap(control.viewModel.localUsageDecision(basedOn: claudeOpus, scope: .subagent, surface: .general))
        XCTAssertEqual(peer.candidate.target.agentRaw, AgentProviderKind.codexExec.rawValue)
        XCTAssertNotNil(peer.reason)
        let swapped = try await routeSubagent(control)
        XCTAssertEqual(swapped.target?.agentRaw, AgentProviderKind.codexExec.rawValue, "non-exploring starts keep usage balancing")
        try expectOverride(swapped.rows, kind: "none", randomness: "low", counter: 1)

        let exploring = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
        await configure(exploring, pick: "claude-opus", runnerUp: "claude-sonnet")
        enableUsage(exploring, codexUsed: 10, claudeUsed: 95)
        let kept = try await routeSubagent(exploring)
        XCTAssertEqual(kept.target?.agentRaw, AgentProviderKind.claudeCode.rawValue)
        XCTAssertEqual(kept.target?.modelRaw, Self.sonnet, "exploring keeps the runner-up")
        try expectOverride(kept.rows, kind: "exploration", randomness: "low", counter: 10)

        // Composer: Codex is near its limit, so a non-exploring Codex pick swaps to Claude.
        let composerURL = counterURL()
        let composerControl = try await makeExplorationFixture(url: composerURL, randomness: .low, hosted: true)
        await configure(composerControl, pick: "gpt-6.1-sol", runnerUp: "claude-sonnet")
        enableUsage(composerControl, codexUsed: 95, claudeUsed: 10)
        let balanced = try await routeComposer(composerControl)
        XCTAssertEqual(balanced.session.selectedAgent, .claudeCode)
        let balancedAudit = try XCTUnwrap(balanced.session.automationTurnAudit.last?.router)
        XCTAssertNotNil(balancedAudit.usageBalancingReason)

        let exploringURL = counterURL()
        try seed(["primarySession": 9], at: exploringURL)
        let composerExploring = try await makeExplorationFixture(url: exploringURL, randomness: .low, hosted: true)
        await configure(composerExploring, pick: "gpt-6.1-sol", runnerUp: "claude-sonnet")
        enableUsage(composerExploring, codexUsed: 95, claudeUsed: 10)
        let explored = try await routeComposer(composerExploring)
        XCTAssertEqual(explored.session.selectedAgent, .claudeCode)
        XCTAssertEqual(explored.session.selectedModelRaw, Self.sonnet)
        let exploredAudit = try XCTUnwrap(explored.session.automationTurnAudit.last?.router)
        XCTAssertNil(exploredAudit.usageBalancingReason)
        XCTAssertEqual(exploredAudit.decision, .selected)
        let applied = try XCTUnwrap(explored.rows.last { $0["event"] as? String == "applied" })
        XCTAssertEqual(applied["outcome"] as? String, "applied")
        try expectOverride(explored.rows, kind: "exploration", randomness: "low", counter: 10)
    }

    func testSingleCandidateAndFailuresDoNotAdvanceCounter() async throws {
        func assertUncounted(
            _ fixture: RoutingStubFixture, _ label: String, rows: [[String: Any]], url: URL, stage: String = "model",
            outcome: String? = nil
        ) async throws {
            let issued = try await explorationAdvisor(of: fixture).counter(for: .subagent)
            XCTAssertEqual(issued, 0, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), label)
            let row = try XCTUnwrap(rows.first { $0["event"] as? String == "decision" && $0["stage"] as? String == stage }, label)
            XCTAssertTrue(row.keys.contains("override"), label)
            XCTAssertTrue(row["override"] is NSNull, label)
            if let outcome { XCTAssertEqual(row["outcome"] as? String, outcome, label) }
        }
        let claudeBaseline = AgentRoutingExecutableTarget(
            agentRaw: AgentProviderKind.claudeCode.rawValue, modelRaw: Self.opus, reasoningEffortRaw: nil, modelParameters: []
        )
        let single = counterURL()
        let singleFixture = try await makeExplorationFixture(url: single, randomness: .low, claude: [Self.opus], codex: [])
        await configure(singleFixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        let singleRoute = try await routeSubagent(singleFixture)
        try await assertUncounted(singleFixture, "single", rows: singleRoute.rows, url: single, outcome: "localSingleCandidate")

        for (label, mode, outcome) in [
            ("abstain", StubRoutingBackend.Mode.abstainModel, "abstained"), ("fail", .failModel, "failed"), ("cancel", .cancelModel, "cancelled")
        ] {
            let url = counterURL()
            let fixture = try await makeExplorationFixture(mode, url: url, randomness: .low)
            await configure(fixture, pick: "claude-opus", runnerUp: "claude-sonnet")
            let route = try await routeSubagent(fixture)
            XCTAssertEqual(route.error, mode == .cancelModel ? AgentModeViewModel.GlobalModelRoutingError.cancelled : nil, label)
            try await assertUncounted(fixture, label, rows: route.rows, url: url, outcome: outcome)
        }

        let invalidURL = counterURL()
        let invalid = try await makeExplorationFixture(url: invalidURL, randomness: .low)
        invalid.backend.chooseKey = { _ in "not-a-candidate-key" }
        let invalidRoute = try await routeSubagent(invalid)
        try await assertUncounted(invalid, "invalid key", rows: invalidRoute.rows, url: invalidURL, outcome: "failed")

        let excludedURL = counterURL()
        let excluded = try await makeExplorationFixture(url: excludedURL, randomness: .low)
        await configure(excluded, pick: "claude-opus", runnerUp: "claude-sonnet")
        let everyMaker = AgentTaskRoutingDiversityOptions(
            exclusions: Dictionary(uniqueKeysWithValues: AgentTaskRoutingMaker.allCases.map {
                ($0.rawValue, Set([AgentTaskRoutingDiversityOptions.ExclusionSource.excludeMakers]))
            })
        )
        let excludedRoute = try await routeSubagent(excluded, diversity: everyMaker)
        XCTAssertEqual(excludedRoute.error, .allCandidatesExcluded)
        try await assertUncounted(excluded, "all excluded", rows: excludedRoute.rows, url: excludedURL, outcome: "failed")

        let nonJevURL = counterURL()
        let nonJev = try await makeExplorationFixture(
            url: nonJevURL, randomness: .low, backendID: AgentTaskRouterBackendID(rawValue: "log-stub")
        )
        await configure(nonJev, pick: "claude-opus", runnerUp: "claude-sonnet")
        let nonJevRoute = try await routeSubagent(nonJev)
        XCTAssertEqual(nonJevRoute.target?.modelRaw, Self.opus)
        try await assertUncounted(nonJev, "non-Jev selected", rows: nonJevRoute.rows, url: nonJevURL, outcome: "selected")

        // Disabled and not-ready routes: only the diversity fence writes a (null-override) failed row.
        let fenced = AgentTaskRoutingDiversityOptions(exclusions: ["openai": [.excludeMakers]])
        for (label, mode) in [("disabled", StubRoutingBackend.Mode.selectLast), ("not ready", .notReady)] {
            let withFence = counterURL()
            let fenceFixture = try await makeExplorationFixture(mode, url: withFence, randomness: .low)
            if mode == .selectLast { fenceFixture.store.setModelRouterEnabled(false) }
            let fenceRoute = try await routeSubagent(fenceFixture, diversity: fenced, baseline: claudeBaseline)
            try await assertUncounted(fenceFixture, "\(label) with exclusions", rows: fenceRoute.rows, url: withFence, outcome: "failed")

            let withoutFence = counterURL()
            let plain = try await makeExplorationFixture(mode, url: withoutFence, randomness: .low)
            if mode == .selectLast { plain.store.setModelRouterEnabled(false) }
            let plainRoute = try await routeSubagent(plain, baseline: claudeBaseline)
            XCTAssertTrue(plainRoute.rows.filter { $0["event"] as? String == "decision" }.isEmpty, "\(label) without exclusions")
            let plainIssued = try await explorationAdvisor(of: plain).counter(for: .subagent)
            XCTAssertEqual(plainIssued, 0, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: withoutFence.path), label)
        }

        // Counted selections: one route is one count, whatever the later stages do.
        let countedURL = counterURL()
        let counted = try await makeExplorationFixture(url: countedURL, randomness: .low)
        await configure(counted, pick: "claude-opus", runnerUp: "claude-sonnet")
        _ = try await routeSubagent(counted)
        let countedIssued = try await explorationAdvisor(of: counted).counter(for: .subagent)
        XCTAssertEqual(countedIssued, 1)
        XCTAssertEqual(readCounters(countedURL)?.counters, ["subagent": 1])

        let effortFixture = try await makeExplorationFixture(.abstainEffort, randomness: .low)
        await configure(effortFixture, pick: "gpt-6.1-sol", runnerUp: "gpt-5.6-terra")
        let effortRoute = try await routeSubagent(effortFixture)
        let effortRequests = await effortFixture.backend.requests
        XCTAssertEqual(effortRequests.count(where: { $0.decisionStage == .effort }), 1, "the effort stage ran and abstained")
        XCTAssertNotNil(effortRoute.target)
        let effortIssued = try await explorationAdvisor(of: effortFixture).counter(for: .subagent)
        XCTAssertEqual(effortIssued, 1)

        let stale = try await makeExplorationFixture(.staleModel, randomness: .low)
        await configure(stale, pick: "claude-opus", runnerUp: "claude-sonnet")
        let staleRoute = try await routeSubagent(stale)
        XCTAssertEqual(staleRoute.error, .stale)
        let staleIssued = try await explorationAdvisor(of: stale).counter(for: .subagent)
        XCTAssertEqual(staleIssued, 1, "selected, then stale: the count stays consumed")

        // A coordinator cancellation before any selection is never counted.
        let cancelURL = counterURL()
        let cancelled = try await makeExplorationFixture(url: cancelURL, randomness: .low)
        await configure(cancelled, pick: "claude-opus", runnerUp: "claude-sonnet")
        let cancelContext = try XCTUnwrap(cancelled.viewModel.makeRouteLogContext(scope: .subagent))
        let coordinator = try XCTUnwrap(cancelled.viewModel.modelRouterRuntime).coordinator
        let requestID = cancelContext.requestID
        cancelled.backend.onRoute = { await coordinator.cancel(requestID: requestID) }
        do {
            _ = try await cancelled.viewModel.routeSubagentTargetIfEnabled(
                task: "Implement parser", surface: .general, logContext: cancelContext
            )
            XCTFail("A cancelled route throws")
        } catch {
            XCTAssertEqual(error as? AgentModeViewModel.GlobalModelRoutingError, .cancelled)
        }
        let cancelIssued = try await explorationAdvisor(of: cancelled).counter(for: .subagent)
        XCTAssertEqual(cancelIssued, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelURL.path))
    }

    func testCounterPersistsWithoutSettingsRevisionChange() async throws {
        let fixture = try await makeRoutingStubFixture(.selectLast, tempRoot: tempRoot)
        let revision = fixture.store.modelRouterSettingsRevision
        let errors = ExplorationErrorLog()
        let sink: @Sendable (String) -> Void = { errors.append($0) }
        func decide(
            _ advisor: AgentTaskRoutingExplorationAdvisor, _ scope: AgentTaskRoutingScope = .primarySession
        ) async -> AgentTaskRoutingExplorationRecord {
            await advisor.decide(scope: scope, randomness: .off, chosenKey: "a", orderedKeys: ordered, scores: scores)
        }

        // Fresh nested URL: nothing pre-created; first use builds parent, data and sidecar.
        let url = tempRoot.appendingPathComponent("fresh/nested/dir/exploration-counters.json")
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let first = await decide(AgentTaskRoutingExplorationAdvisor(fileURL: url, errorSink: sink))
        XCTAssertEqual(first.counter, 1)
        XCTAssertTrue(first.durable)
        XCTAssertEqual(readCounters(url)?.schema, 1)
        XCTAssertEqual(readCounters(url)?.counters, ["primarySession": 1])
        for file in [url, lockURL] {
            let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? Int
            XCTAssertEqual(mode, 0o600, file.lastPathComponent)
        }
        let second = await decide(AgentTaskRoutingExplorationAdvisor(fileURL: url, errorSink: sink))
        XCTAssertEqual(second.counter, 2, "a new advisor reads the latest file")
        XCTAssertTrue(second.durable)
        let restarted = AgentTaskRoutingExplorationAdvisor(fileURL: url, errorSink: sink)
        let third = await decide(restarted)
        XCTAssertEqual(third.counter, 3)
        let sub = await decide(restarted, .subagent)
        XCTAssertEqual(sub.counter, 1)
        XCTAssertEqual(readCounters(url)?.counters, ["primarySession": 3, "subagent": 1])
        let ownFloor = await restarted.counter(for: .primarySession)
        XCTAssertEqual(ownFloor, 3)
        XCTAssertEqual(errors.messages, [])

        // In-memory only.
        let memory = AgentTaskRoutingExplorationAdvisor(fileURL: nil)
        let memoryFirst = await decide(memory)
        let memorySecond = await decide(memory)
        XCTAssertEqual([memoryFirst.counter, memorySecond.counter], [1, 2])
        XCTAssertFalse(memoryFirst.durable)

        // A newer schema is never overwritten.
        let futureURL = tempRoot.appendingPathComponent("future/exploration-counters.json")
        let futureBytes = Data(#"{"schema":2,"counters":{"primarySession":5},"extra":1}"#.utf8)
        writeBytes(futureBytes, to: futureURL)
        let futureErrors = ExplorationErrorLog()
        let future = AgentTaskRoutingExplorationAdvisor(fileURL: futureURL, errorSink: { futureErrors.append($0) })
        let futureFirst = await decide(future)
        let futureSecond = await decide(future)
        XCTAssertEqual([futureFirst.counter, futureSecond.counter], [1, 2])
        XCTAssertFalse(futureFirst.durable)
        XCTAssertEqual(try? Data(contentsOf: futureURL), futureBytes)
        XCTAssertEqual(futureErrors.messages.count, 1, "one error per failure window")

        // Malformed content is quarantined under the lock, then reset.
        for (index, bad) in [
            "not json", #"{"schema":1,"counters":{"primarySession":-1}}"#,
            #"{"schema":1,"counters":{"primarySession":"x"}}"#, #"{"schema":0,"counters":{}}"#
        ].enumerated() {
            let corruptURL = tempRoot.appendingPathComponent("corrupt-\(index)/exploration-counters.json")
            writeBytes(Data("older".utf8), to: URL(fileURLWithPath: corruptURL.path + ".corrupt"))
            writeBytes(Data(bad.utf8), to: corruptURL)
            let corruptErrors = ExplorationErrorLog()
            let record = await decide(AgentTaskRoutingExplorationAdvisor(
                fileURL: corruptURL, errorSink: { corruptErrors.append($0) }
            ))
            XCTAssertEqual(record.counter, 1, bad)
            XCTAssertTrue(record.durable, bad)
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: corruptURL.path + ".corrupt")), Data(bad.utf8), bad)
            XCTAssertEqual(readCounters(corruptURL)?.counters, ["primarySession": 1], bad)
            XCTAssertEqual(corruptErrors.messages.count, 1, bad)
        }

        // Unusable storage degrades to the advisor's own floor and never throws.
        let blocker = tempRoot.appendingPathComponent("regular-file")
        writeBytes(Data("file".utf8), to: blocker)
        let blockedURL = blocker.appendingPathComponent("nested/exploration-counters.json")
        let blockedErrors = ExplorationErrorLog()
        let blocked = AgentTaskRoutingExplorationAdvisor(fileURL: blockedURL, errorSink: { blockedErrors.append($0) })
        let blockedFirst = await decide(blocked)
        let blockedSecond = await decide(blocked)
        XCTAssertEqual([blockedFirst.counter, blockedSecond.counter], [1, 2])
        XCTAssertFalse(blockedFirst.durable)
        XCTAssertEqual(blockedErrors.messages.count, 1)
        XCTAssertEqual(try? Data(contentsOf: blocker), Data("file".utf8))
        let lockDirURL = tempRoot.appendingPathComponent("lock-dir/exploration-counters.json")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: lockDirURL.path + ".lock"), withIntermediateDirectories: true
        )
        let lockDir = await decide(AgentTaskRoutingExplorationAdvisor(fileURL: lockDirURL, errorSink: sink))
        XCTAssertEqual(lockDir.counter, 1)
        XCTAssertFalse(lockDir.durable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirURL.path))
        let maxURL = tempRoot.appendingPathComponent("max/exploration-counters.json")
        let maxBytes = Data(#"{"schema":1,"counters":{"primarySession":18446744073709551615}}"#.utf8)
        writeBytes(maxBytes, to: maxURL)
        let overflow = await decide(AgentTaskRoutingExplorationAdvisor(fileURL: maxURL, errorSink: sink))
        XCTAssertEqual(overflow.counter, UInt64.max)
        XCTAssertFalse(overflow.durable)
        XCTAssertEqual(try? Data(contentsOf: maxURL), maxBytes)
        XCTAssertGreaterThanOrEqual(errors.messages.count, 2)

        // Two advisors sharing one file: the stale one still sees the latest value.
        let sharedURL = tempRoot.appendingPathComponent("shared/exploration-counters.json")
        writeBytes(Data(#"{"schema":1,"counters":{"primarySession":9,"subagent":4,"zzUnknown":7}}"#.utf8), to: sharedURL)
        let sharedA = AgentTaskRoutingExplorationAdvisor(fileURL: sharedURL, errorSink: sink)
        let sharedB = AgentTaskRoutingExplorationAdvisor(fileURL: sharedURL, errorSink: sink)
        let sharedCounters = await [decide(sharedA).counter, decide(sharedA).counter, decide(sharedB).counter]
        XCTAssertEqual(sharedCounters, [10, 11, 12])
        XCTAssertEqual(readCounters(sharedURL)?.counters, ["primarySession": 12, "subagent": 4, "zzUnknown": 7])

        // Concurrent advisors, both scopes interleaved.
        let busyURL = tempRoot.appendingPathComponent("busy/exploration-counters.json")
        let busyA = AgentTaskRoutingExplorationAdvisor(fileURL: busyURL, errorSink: sink)
        let busyB = AgentTaskRoutingExplorationAdvisor(fileURL: busyURL, errorSink: sink)
        let results = await withTaskGroup(of: (Int, AgentTaskRoutingScope, AgentTaskRoutingExplorationRecord).self) { group in
            for index in 0 ..< 50 {
                for (owner, advisor) in [(0, busyA), (1, busyB)] {
                    let scope: AgentTaskRoutingScope = (index + owner) % 2 == 0 ? .primarySession : .subagent
                    group.addTask {
                        await (owner, scope, advisor.decide(
                            scope: scope, randomness: .off, chosenKey: "a", orderedKeys: ["a", "b", "c"],
                            scores: ["a": 0.6, "b": 0.25, "c": 0.15]
                        ))
                    }
                }
            }
            var collected: [(Int, AgentTaskRoutingScope, AgentTaskRoutingExplorationRecord)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        XCTAssertEqual(results.count, 100)
        XCTAssertTrue(results.allSatisfy(\.2.durable), "no contention degradation in the exact run")
        for scope in [AgentTaskRoutingScope.primarySession, .subagent] {
            XCTAssertEqual(results.filter { $0.1 == scope }.map(\.2.counter).sorted(), Array(1 ... 50), scope.rawValue)
            for (owner, advisor) in [(0, busyA), (1, busyB)] {
                let issued = results.filter { $0.0 == owner && $0.1 == scope }.map(\.2.counter)
                let floor = await advisor.counter(for: scope)
                XCTAssertEqual(floor, issued.max() ?? 0, "own floor tracks the highest issued value")
            }
        }
        XCTAssertEqual(readCounters(busyURL)?.counters, ["primarySession": 50, "subagent": 50])

        await assertHeldLockDegradesAndRecovers(sink: sink)

        // Runtime seam: designated default is in-memory; an injected advisor is used as given.
        let bare = try AgentTaskRouterRuntime(
            registrations: [.init(backend: StubRoutingBackend(mode: .selectLast))],
            decisionLog: AgentTaskRoutingDecisionLog(fileURL: tempRoot.appendingPathComponent("bare/jev-decisions.jsonl"))
        )
        let bareRecord = await decide(bare.explorationAdvisor)
        XCTAssertEqual(bareRecord.counter, 1)
        XCTAssertFalse(bareRecord.durable, "default runtime advisor never persists")
        let injected = AgentTaskRoutingExplorationAdvisor(fileURL: nil)
        let injectedFixture = try await makeRoutingStubFixture(.selectLast, tempRoot: tempRoot, explorationAdvisor: injected)
        XCTAssertTrue(injectedFixture.viewModel.modelRouterRuntime?.explorationAdvisor === injected)
        let isolated = try XCTUnwrap(fixture.viewModel.modelRouterRuntime?.explorationAdvisor)
        let isolatedRecord = await decide(isolated)
        XCTAssertTrue(isolatedRecord.durable, "fixture default is an isolated temp file")
        XCTAssertEqual(
            Array(AgentTaskRoutingExplorationAdvisor.defaultFileURL().pathComponents.suffix(3)),
            ["RepoPrompt CE", "ModelRouter", "exploration-counters.json"]
        )
        XCTAssertEqual(fixture.store.modelRouterSettingsRevision, revision, "advancing never touches router settings")

        // Routed counts leave the router settings untouched, never reach the real HOME and survive a restart.
        let homeStamp = Self.modificationDate(AgentTaskRoutingExplorationAdvisor.defaultFileURL())
        let routedURL = counterURL()
        let knownSettings = settingsFiles()
        let routed = try await makeExplorationFixture(url: routedURL, randomness: .off, hosted: true)
        await configure(routed, pick: "claude-opus", runnerUp: "claude-sonnet")
        var settingsURL: URL?
        for _ in 0 ..< 100 where settingsURL == nil {
            settingsURL = settingsFiles().subtracting(knownSettings).first
            if settingsURL == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let settingsFile = try XCTUnwrap(settingsURL, "the fixture settings file exists before routing")
        let settingsBytes = try Data(contentsOf: settingsFile)
        let settingsRevision = routed.store.modelRouterSettingsRevision
        for _ in 1 ... 3 {
            _ = try await routeSubagent(routed)
        }
        _ = try await routeComposer(routed)
        _ = try await routed.viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .general)
        let routedAdvisor = try explorationAdvisor(of: routed)
        let nilLogCount = await routedAdvisor.counter(for: .subagent)
        XCTAssertEqual(nilLogCount, 4, "a route with no log context still counts")
        XCTAssertEqual(readCounters(routedURL)?.counters, ["primarySession": 1, "subagent": 4])
        XCTAssertEqual(routed.store.modelRouterSettingsRevision, settingsRevision)
        XCTAssertEqual(try Data(contentsOf: settingsFile), settingsBytes, "counting never rewrites the settings JSON")
        let reopened = try await makeExplorationFixture(url: routedURL, randomness: .off)
        await configure(reopened, pick: "claude-opus", runnerUp: "claude-sonnet")
        try await expectOverride(routeSubagent(reopened).rows, kind: "none", randomness: "off", counter: 5)

        // Unusable storage still routes a valid pick and marks the count non-durable.
        let routedBlocker = tempRoot.appendingPathComponent("routed-regular-file")
        writeBytes(Data("file".utf8), to: routedBlocker)
        let blockedFixture = try await makeExplorationFixture(
            url: routedBlocker.appendingPathComponent("nested/exploration-counters.json"), randomness: .off
        )
        await configure(blockedFixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        let blockedRoute = try await routeSubagent(blockedFixture)
        XCTAssertEqual(blockedRoute.target?.modelRaw, Self.opus)
        try expectOverride(blockedRoute.rows, kind: "none", randomness: "off", counter: 1, durable: false)
        let futureRouted = counterURL()
        let futureData = Data(#"{"schema":2,"counters":{"subagent":5}}"#.utf8)
        writeBytes(futureData, to: futureRouted)
        let futureFixture = try await makeExplorationFixture(url: futureRouted, randomness: .off)
        await configure(futureFixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        let futureRoute = try await routeSubagent(futureFixture)
        XCTAssertEqual(futureRoute.target?.modelRaw, Self.opus)
        try expectOverride(futureRoute.rows, kind: "none", randomness: "off", counter: 1, durable: false)
        XCTAssertEqual(try Data(contentsOf: futureRouted), futureData)
        XCTAssertEqual(Self.modificationDate(AgentTaskRoutingExplorationAdvisor.defaultFileURL()), homeStamp)
    }

    func testExplorationOverrideIsLogged() async throws {
        let fixture = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
        await configure(fixture, pick: "claude-opus", runnerUp: "claude-sonnet")
        let route = try await routeSubagent(
            fixture, diversity: AgentTaskRoutingDiversityOptions(exclusions: ["openai": [.excludeMakers]])
        )
        let row = try modelRow(route.rows)
        let record = try overrideObject(route.rows)
        XCTAssertEqual(
            Set(record.keys), ["kind", "randomness", "counter", "position", "originalKey", "appliedKey", "durable"]
        )
        let requests = await fixture.backend.requests
        let request = try XCTUnwrap(requests.first { $0.decisionStage == .model })
        let opusKey = try candidateKey("claude-opus", in: request)
        XCTAssertEqual(record["originalKey"] as? String, opusKey)
        XCTAssertEqual(record["appliedKey"] as? String, try candidateKey("claude-sonnet", in: request))
        try expectOverride(route.rows, kind: "exploration", randomness: "low", counter: 10)
        XCTAssertEqual(row["chosenKey"] as? String, opusKey, "the Jev meaning of chosenKey is unchanged")
        XCTAssertEqual((row["chosenTarget"] as? [String: Any])?["model"] as? String, Self.opus)
        XCTAssertEqual(row["probabilities"] as? [String: Double], Self.scores(["claude-sonnet": 0.25])(request, opusKey))
        XCTAssertEqual(row["makerExclusions"] as? [String: [String]], ["openai": ["exclude_makers"]])
        XCTAssertEqual(row["backend"] as? String, "jev")
        let decisions = route.rows.filter { $0["event"] as? String == "decision" }
        XCTAssertEqual(Dictionary(grouping: decisions) { $0["stage"] as? String ?? "" }.mapValues(\.count), ["model": 1, "effort": 1])
        let applied = try XCTUnwrap(route.rows.first { $0["event"] as? String == "applied" })
        XCTAssertEqual(applied["outcome"] as? String, "applied")
        XCTAssertEqual((applied["picked"] as? [String: Any])?["model"] as? String, Self.sonnet)
        XCTAssertEqual(applied["requestID"] as? String, row["requestID"] as? String)
        assertDecisionsPrecedeApplied(route.rows)

        // Non-exploring positions and invalid evidence are visible as such.
        let none = try await makeExplorationFixture(randomness: .low)
        await configure(none, pick: "claude-opus", runnerUp: "claude-sonnet")
        try await expectOverride(routeSubagent(none).rows, kind: "none", randomness: "low", counter: 1)
        let invalidEvidence: [(String, (@Sendable (AgentTaskRoutingRequest, String) -> [String: Double]?)?)] = [
            ("nil", nil),
            ("missing key", { request, chosen in
                Self.scores(["claude-sonnet": 0.25])(request, chosen)?.filter { $0.key != request.candidates.last?.opaqueKey }
            }),
            ("tied top", Self.scores(["claude-sonnet": 0.6]))
        ]
        for (label, scoring) in invalidEvidence {
            let unavailable = try await makeExplorationFixture(stored: ["subagent": 9], randomness: .low)
            unavailable.backend.chooseKey = Self.pick("claude-opus")
            await unavailable.backend.setScoresFor(scoring)
            let unavailableRoute = try await routeSubagent(unavailable)
            XCTAssertEqual(unavailableRoute.target?.modelRaw, Self.opus, label)
            try expectOverride(unavailableRoute.rows, kind: "explorationUnavailable", randomness: "low", counter: 10)
        }

        // Every other emitted model-adjacent row carries the key as null.
        let codex = try await makeExplorationFixture(randomness: .low)
        await configure(codex, pick: "gpt-6.1-sol", runnerUp: "gpt-5.6-terra", effort: "high")
        let codexRoute = try await routeSubagent(codex)
        let effortRow = try XCTUnwrap(codexRoute.rows.first { $0["stage"] as? String == "effort" })
        XCTAssertEqual(effortRow["outcome"] as? String, "selected")
        XCTAssertTrue(effortRow.keys.contains("override") && effortRow["override"] is NSNull)
        let local = try await makeExplorationFixture(randomness: .low, claude: [Self.opus], codex: [])
        let localRoute = try await routeSubagent(local)
        XCTAssertTrue(localRoute.rows.filter { $0["event"] as? String == "decision" }.allSatisfy { $0["override"] is NSNull })
        XCTAssertEqual(localRoute.rows.compactMap { $0["outcome"] as? String }.first, "localSingleCandidate")
        for mode in [StubRoutingBackend.Mode.abstainModel, .failModel, .cancelModel] {
            let other = try await makeExplorationFixture(mode, stored: ["subagent": 9], randomness: .low)
            await configure(other, pick: "claude-opus", runnerUp: "claude-sonnet")
            let otherRoute = try await routeSubagent(other)
            let otherRow = try modelRow(otherRoute.rows)
            XCTAssertTrue(otherRow.keys.contains("override") && otherRow["override"] is NSNull, "\(mode)")
        }
        let nonJev = try await makeExplorationFixture(
            stored: ["subagent": 9], randomness: .low, backendID: AgentTaskRouterBackendID(rawValue: "log-stub")
        )
        await configure(nonJev, pick: "claude-opus", runnerUp: "claude-sonnet")
        let nonJevRoute = try await routeSubagent(nonJev)
        let nonJevRow = try modelRow(nonJevRoute.rows)
        XCTAssertEqual(nonJevRow["outcome"] as? String, "selected")
        XCTAssertTrue(nonJevRow.keys.contains("override") && nonJevRow["override"] is NSNull)
        let autoContext = AgentTaskRoutingRouteContext(requestID: UUID(), scope: .subagent, log: fixture.log)
        await autoContext.emitDecision(AgentTaskRoutingDecisionDraft(stage: .autoEffort, outcome: .selected))
        await autoContext.finish(.rejected)
        await fixture.log.flush()
        let autoRow = try XCTUnwrap(fixture.rows().first { $0["stage"] as? String == "autoEffort" })
        XCTAssertTrue(autoRow.keys.contains("override") && autoRow["override"] is NSNull)

        // A degraded counter is still logged, marked non-durable.
        let blocker = tempRoot.appendingPathComponent("logged-regular-file")
        writeBytes(Data("file".utf8), to: blocker)
        let degraded = try await makeExplorationFixture(
            url: blocker.appendingPathComponent("nested/exploration-counters.json"), randomness: .low
        )
        await configure(degraded, pick: "claude-opus", runnerUp: "claude-sonnet")
        try await expectOverride(routeSubagent(degraded).rows, kind: "none", randomness: "low", counter: 1, durable: false)
    }

    // MARK: - Routed seam helpers

    private static let opus = "claude-opus-5-5"
    private static let sonnet = "claude-sonnet-5-5"
    private static let haiku = "claude-haiku-4-5"

    private struct SubagentRoute {
        let result: Result<AgentRoutingExecutableTarget?, Error>
        let rows: [[String: Any]]

        var target: AgentRoutingExecutableTarget? {
            (try? result.get()) ?? nil
        }

        var error: AgentModeViewModel.GlobalModelRoutingError? {
            guard case let .failure(error) = result else { return nil }
            return error as? AgentModeViewModel.GlobalModelRoutingError
        }
    }

    private struct ComposerRoute {
        let session: AgentModeViewModel.TabSession
        let rows: [[String: Any]]
    }

    private func explorationAdvisor(of fixture: RoutingStubFixture) throws -> AgentTaskRoutingExplorationAdvisor {
        try XCTUnwrap(fixture.viewModel.modelRouterRuntime?.explorationAdvisor)
    }

    private func counterURL() -> URL {
        tempRoot.appendingPathComponent("counters-\(UUID().uuidString)/exploration-counters.json")
    }

    private func seed(_ counters: [String: UInt64], at url: URL) throws {
        try writeBytes(JSONSerialization.data(withJSONObject: ["schema": 1, "counters": counters]), to: url)
    }

    private func settingsFiles() -> Set<URL> {
        let entries = (try? FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)) ?? []
        return Set(
            entries.filter { $0.lastPathComponent.hasPrefix("settings-") }
                .map { $0.appendingPathComponent("globalSettings.json") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func configure(_ fixture: RoutingStubFixture, pick: String, runnerUp: String?, effort: String? = nil) async {
        fixture.backend.chooseKey = Self.pick(pick, effort: effort)
        await fixture.backend.setScoresFor(runnerUp.map { Self.scores([$0: 0.25]) })
    }

    private func candidateKey(_ label: String, in request: AgentTaskRoutingRequest) throws -> String {
        try XCTUnwrap(request.candidates.first { $0.roleLabels == [label] }?.opaqueKey)
    }

    private func routeSubagent(
        _ fixture: RoutingStubFixture,
        diversity: AgentTaskRoutingDiversityOptions = .none,
        baseline: AgentRoutingExecutableTarget? = nil
    ) async throws -> SubagentRoute {
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let result: Result<AgentRoutingExecutableTarget?, Error>
        do {
            result = try await .success(fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "Implement parser", surface: .general, baseline: baseline, logContext: context, diversity: diversity
            ))
        } catch {
            result = .failure(error)
        }
        if case let .success(target) = result, let target {
            await context.finish(.accepted(actual: target, sessionID: nil))
        } else {
            await context.finish(.rejected)
        }
        await fixture.log.flush()
        let id = context.requestID.uuidString
        return try SubagentRoute(result: result, rows: fixture.rows().filter { $0["requestID"] as? String == id })
    }

    /// The shipped composer entry on a fresh tab; the tab's session ends on the routed (Claude) target.
    private func routeComposer(_ fixture: RoutingStubFixture) async throws -> ComposerRoute {
        let viewModel = fixture.viewModel
        await fixture.log.flush()
        let appliedBefore = try fixture.rows().count(where: { $0["event"] as? String == "applied" })
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        let session = viewModel.session(for: tabID)
        _ = viewModel.test_installPersistentSessionBinding(sessionID: UUID(), on: session)
        let claim = try routingClaim(viewModel: viewModel, session: session, text: "Implement parser")
        let result = await viewModel.submitUserTurnAfterFreshTaskRouting(
            text: "Implement parser", claim: claim, session: session, destinationTabID: tabID
        )
        XCTAssertEqual(result, .submitted)
        try await waitForAppliedRows(fixture, count: appliedBefore + 1)
        let id = claim.attempt.id.uuidString
        let rows = try fixture.rows().filter { $0["requestID"] as? String == id }
        assertDecisionsPrecedeApplied(rows)
        return ComposerRoute(session: session, rows: rows)
    }

    private func modelRow(_ rows: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(
            rows.first { $0["event"] as? String == "decision" && $0["stage"] as? String == "model" },
            "model decision row", file: file, line: line
        )
    }

    private func overrideObject(_ rows: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(modelRow(rows, file: file, line: line)["override"] as? [String: Any], "override object", file: file, line: line)
    }

    private func expectOverride(
        _ rows: [[String: Any]], kind: String, randomness: String, counter: Int, durable: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let record = try overrideObject(rows, file: file, line: line)
        XCTAssertEqual(record["kind"] as? String, kind, file: file, line: line)
        XCTAssertEqual(record["randomness"] as? String, randomness, file: file, line: line)
        XCTAssertEqual(record["counter"] as? Int, counter, file: file, line: line)
        XCTAssertEqual(record["position"] as? Int, (counter - 1) % 20 + 1, file: file, line: line)
        XCTAssertEqual(record["durable"] as? Bool, durable, file: file, line: line)
        XCTAssertEqual(
            record["appliedKey"] as? String == record["originalKey"] as? String, kind != "exploration", file: file, line: line
        )
    }

    /// Usage snapshots follow `AgentComposerSubmissionAttemptTests.testUsageBalancingRoutesFreshComposerAndSubagentWithoutJev`.
    private func enableUsage(_ fixture: RoutingStubFixture, codexUsed: Double, claudeUsed: Double) {
        fixture.store.setUsageBalancingEnabled(true)
        let balancer = AgentUsageBalancer()
        fixture.viewModel.modelRouterRuntime?.usageBalancer = balancer
        let now = Date()
        let reset = now.addingTimeInterval(18000).timeIntervalSince1970
        for (provider, used) in [(AgentProviderKind.codexExec, codexUsed), (.claudeCode, claudeUsed)] {
            let record = ClaudeCLIUsageRecord(version: 1, receivedAt: now, windows: ["five_hour": .init(used: used, resetsAt: reset)])
            balancer.update(record.snapshot(profileID: "exploration-test"), provider: provider.rawValue)
        }
    }

    /// Picks models and efforts by descriptor identity (label), never by position.
    private static func pick(_ model: String, effort: String? = nil) -> @Sendable (AgentTaskRoutingRequest) -> String? {
        { request in
            let label = request.decisionStage == .model ? model : effort.map { "effort:\($0)" }
            return request.candidates.first { $0.roleLabels == [label ?? ""] }?.opaqueKey
        }
    }

    /// Chosen key 0.6, each labelled candidate its given score, everything else 0.
    private nonisolated static func scores(_ labelled: [String: Double]) -> @Sendable (AgentTaskRoutingRequest, String) -> [String: Double]? {
        { request, chosen in
            guard request.decisionStage == .model else { return nil }
            return Dictionary(uniqueKeysWithValues: request.candidates.map {
                ($0.opaqueKey, $0.opaqueKey == chosen ? 0.6 : ($0.roleLabels.first.flatMap { labelled[$0] } ?? 0))
            })
        }
    }

    private func makeExplorationFixture(
        _ mode: StubRoutingBackend.Mode = .selectLast,
        url injectedURL: URL? = nil,
        stored: [String: UInt64] = [:],
        randomness: AgentRoutingRandomness,
        hosted: Bool = false,
        backendID: AgentTaskRouterBackendID = .jev,
        claude: [String] = ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"],
        codex: [String] = ["gpt-5.6-terra", "gpt-6.1-sol"]
    ) async throws -> RoutingStubFixture {
        let url = injectedURL ?? counterURL()
        if !stored.isEmpty { try seed(stored, at: url) }
        let options: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            switch provider {
            case .claudeCode:
                claude.map {
                    AgentModelOption(rawValue: $0, displayName: $0, description: nil, isPlaceholderDefault: false, isProviderDefault: false)
                }
            case .codexExec:
                codex.map {
                    AgentModelOption(
                        rawValue: $0, displayName: $0, description: nil, isPlaceholderDefault: false, isProviderDefault: false,
                        supportedReasoningEfforts: [.low, .medium, .high]
                    )
                }
            default:
                []
            }
        }
        let fixture = try await makeRoutingStubFixture(
            mode, tempRoot: tempRoot, backendID: backendID,
            candidateBuilder: { AgentTaskRoutingCandidateBuilder(modelOptions: options) },
            explorationAdvisor: AgentTaskRoutingExplorationAdvisor(fileURL: url)
        )
        fixture.store.setRandomness(randomness)
        guard hosted else { return fixture }
        return try await hostInWindow(fixture)
    }

    /// Re-hosts a stub fixture's store, runtime and log in an isolated WindowState so the composer's real run
    /// start reaches the stubbed native controller (same pattern as `makeServiceWindow`, no live provider).
    private func hostInWindow(_ fixture: RoutingStubFixture) async throws -> RoutingStubFixture {
        let settings = GlobalSettingsStore.shared
        let previousAutoStart = settings.mcpAutoStart()
        settings.setMCPAutoStart(false, commit: false)
        defer { settings.setMCPAutoStart(previousAutoStart, commit: false) }
        let workspacePath = tempRoot.path
        let window = WindowState(
            agentModeViewModelFactory: { windowID, prompt, manager, server in
                let viewModel = AgentModeViewModel(
                    testWindowID: windowID,
                    testWorkspacePath: workspacePath,
                    codexControllerFactory: { _, _, _, _, _, _ in
                        preconditionFailure("Exploration test must not start Codex")
                    },
                    claudeControllerFactory: { _, _, _, _ in MonitorFakeNativeController() },
                    headlessProviderFactory: { _, _, _, _, _ in
                        AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1)
                    },
                    acpProviderFactory: { _, _ in throw MCPError.internalError("ACP must not start") },
                    acpControllerFactory: { _, _ in throw MCPError.internalError("ACP must not start") },
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
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
        }
        await window.workspaceManager.awaitInitialized()
        window.apiSettingsViewModel.isClaudeCodeConnected = true
        window.apiSettingsViewModel.isCodexConnected = true
        window.apiSettingsViewModel.test_completeContextBuilderProviderValidation(
            verifiedProviders: [.claudeCode, .codexExec]
        )
        let workspace = window.workspaceManager.createWorkspace(
            name: "Exploration \(UUID().uuidString.prefix(8))", repoPaths: [workspacePath], ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "explorationComposer")
        guard let activeWorkspace = window.workspaceManager.activeWorkspace else {
            throw MCPError.internalError("Expected active ephemeral workspace")
        }
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        window.agentModeViewModel.modelRouterSettingsStore = fixture.store
        window.agentModeViewModel.modelRouterRuntime = fixture.viewModel.modelRouterRuntime
        return RoutingStubFixture(
            viewModel: window.agentModeViewModel, store: fixture.store, log: fixture.log, logURL: fixture.logURL,
            backend: fixture.backend
        )
    }

    private func assertHeldLockDegradesAndRecovers(sink: @escaping @Sendable (String) -> Void) async {
        let url = tempRoot.appendingPathComponent("held/exploration-counters.json")
        let advisor = AgentTaskRoutingExplorationAdvisor(fileURL: url, errorSink: sink)
        let seed = await advisor.decide(
            scope: .primarySession, randomness: .off, chosenKey: "a", orderedKeys: ordered, scores: scores
        )
        XCTAssertEqual(seed.counter, 1)
        let descriptor = open(url.path + ".lock", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return XCTFail("sidecar lock was not created") }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let before = try? Data(contentsOf: url)
        let started = ContinuousClock.now
        let degraded = await advisor.decide(
            scope: .primarySession, randomness: .off, chosenKey: "a", orderedKeys: ordered, scores: scores
        )
        let waited = started.duration(to: .now)
        XCTAssertEqual(degraded.counter, 2)
        XCTAssertFalse(degraded.durable)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(200), "waited for the contention deadline")
        XCTAssertEqual(try? Data(contentsOf: url), before, "a timed-out turn never writes")
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let recovered = await advisor.decide(
            scope: .primarySession, randomness: .off, chosenKey: "a", orderedKeys: ordered, scores: scores
        )
        XCTAssertEqual(recovered.counter, 3, "recovery exceeds the file and the advisor's own non-durable value")
        XCTAssertTrue(recovered.durable)
        XCTAssertEqual(readCounters(url)?.counters, ["primarySession": 3])
    }

    private func readCounters(_ url: URL) -> ExplorationCounterFile? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("missing counter file \(url.lastPathComponent)")
            return nil
        }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ExplorationCounterFile.self, from: $0) }
    }

    private func writeBytes(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            XCTFail("fixture write failed: \(error)")
        }
    }
}
