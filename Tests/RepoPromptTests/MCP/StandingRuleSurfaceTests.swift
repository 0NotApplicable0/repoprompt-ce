import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

@MainActor
final class StandingRuleFactsProviderTests: XCTestCase {
    func testLiveRequestPresentationWouldProduceFacts() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let unstamped = makeFixture()
        let unstampedSession = try await unstamped.installController()
        let unstampedEndpoint = try XCTUnwrap(unstamped.endpoint)
        let unstampedRequest = try unstamped.runtime.requestScope(
            requesterSessionID: unstampedEndpoint.sessionID, requesterTabID: unstampedSession.tabID,
            kind: .directChildren(rootSessionID: unstampedEndpoint.sessionID, workspaceID: unstampedEndpoint.workspaceID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        XCTAssertNil(WindowStatesManager.shared.standingRuleFacts(for: unstampedRequest, in: [unstamped.window]))

        let fixture = makeFixture()
        let session = try await fixture.installController(startedBy: stamp)
        let endpoint = try XCTUnwrap(fixture.endpoint)
        let request = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID, requesterTabID: session.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: endpoint.workspaceID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        XCTAssertTrue(WindowStatesManager.shared.agentSessionLinkScopedObserverFacts(
            for: endpoint, in: fixture.window
        ).hasSession)
        XCTAssertNotNil(WindowStatesManager.shared.standingRuleFacts(for: request, in: [fixture.window]))
        XCTAssertEqual(facts(for: request, in: [fixture.window]), .init(starter: stamp, workspaceID: endpoint.workspaceID))
        XCTAssertNil(facts(for: request, in: [fixture.window])?.clientLabel)

        let named = makeFixture()
        let namedSession = try await named.installController(startedBy: stamp, clientLabel: "Claude Code")
        let namedEndpoint = try XCTUnwrap(named.endpoint)
        let namedRequest = try named.runtime.requestScope(
            requesterSessionID: namedEndpoint.sessionID, requesterTabID: namedSession.tabID,
            kind: .directChildren(rootSessionID: namedEndpoint.sessionID, workspaceID: namedEndpoint.workspaceID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), reason: nil, idempotencyKey: nil,
            requesterTitle: "Team lead title"
        ).get()
        XCTAssertEqual(facts(for: namedRequest, in: [named.window])?.clientLabel, "Claude Code")
        XCTAssertEqual(WindowStatesManager.shared.agentSessionLinkScopedObserverFacts(for: endpoint, in: fixture.window).startedBy, stamp)
    }

    func testRequestRequiresItsOwnTabWindowAndSession() async throws {
        let (fixture, _, request) = try await readyController()
        let tabID = try XCTUnwrap(request.requesterTabID)
        let windowID = try XCTUnwrap(request.requesterWindowID)
        let cases: [(String, UUID?, Int?, UUID)] = [
            ("nil tab", nil, windowID, request.requesterSessionID),
            ("nil window", tabID, nil, request.requesterSessionID),
            ("wrong window", tabID, windowID + 1, request.requesterSessionID),
            ("session mismatch", tabID, windowID, UUID())
        ]
        for (label, tab, window, session) in cases {
            XCTAssertNotNil(facts(for: request, in: [fixture.window]), label)
            let changed = DelegationScopeRequest(
                id: request.id, requesterSessionID: session, requesterTabID: tab, requesterWindowID: window,
                kind: request.kind, capabilities: request.capabilities, guardrails: request.guardrails,
                expiresInSeconds: request.expiresInSeconds, reason: request.reason,
                idempotencyKey: request.idempotencyKey, createdAt: request.createdAt
            )
            XCTAssertNil(facts(for: changed, in: [fixture.window]), label)
        }
    }

    func testReboundTabCannotBorrowAnotherQualifyingControllersStamp() async throws {
        let (fixture, session, request) = try await readyController()
        let stamp = try XCTUnwrap(session.mcpControlContext?.startedBy)
        XCTAssertNotNil(facts(for: request, in: [fixture.window]))
        let second = try await installSecondController(in: fixture.window, tabID: session.tabID, stamp: stamp)
        let secondEndpoint = try XCTUnwrap(fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: second.tabID))
        XCTAssertNotEqual(secondEndpoint.sessionID, request.requesterSessionID)
        XCTAssertTrue(OverseerAuthorizationEngine.admitsDirectChildrenConsentRequest(endpoint: secondEndpoint, window: fixture.window))
        let secondRequest = try makeRequest(in: fixture, for: secondEndpoint)
        XCTAssertEqual(facts(for: secondRequest, in: [fixture.window]), .init(starter: stamp, workspaceID: secondEndpoint.workspaceID))
        XCTAssertNil(facts(for: request, in: [fixture.window]))
    }

    func testDuplicateLoadedPresentationFailsClosed() async throws {
        let (fixture, session, request) = try await readyController()
        XCTAssertNotNil(facts(for: request, in: [fixture.window]))
        let other = makeFixture()
        other.window.agentModeViewModel.test_installLiveSession(session)
        XCTAssertNotNil(facts(for: request, in: [fixture.window]))
        XCTAssertNil(facts(for: request, in: [fixture.window, other.window]))
    }

    func testMissingOrMismatchedControlContextFailsClosed() async throws {
        for missing in [true, false] {
            let (fixture, session, request) = try await readyController()
            XCTAssertNotNil(facts(for: request, in: [fixture.window]))
            if missing {
                session.mcpControlContext = nil
            } else {
                let stamp = try XCTUnwrap(session.mcpControlContext?.startedBy)
                session.mcpControlContext = try await makeContext(sessionID: UUID(), stamp: stamp)
            }
            XCTAssertNil(facts(for: request, in: [fixture.window]), missing ? "no context" : "wrong context session")
        }
    }

    func testIneligibleControllerShapesFailClosed() async throws {
        for shape in ["parented", "overseer-created", "explore"] {
            let (fixture, session, request) = try await readyController()
            XCTAssertNotNil(facts(for: request, in: [fixture.window]), shape)
            switch shape {
            case "parented": session.parentSessionID = UUID()
            case "overseer-created": session.createdByOverseerSessionID = UUID()
            default:
                let stamp = try XCTUnwrap(session.mcpControlContext?.startedBy)
                session.mcpControlContext = try await makeContext(sessionID: request.requesterSessionID, stamp: stamp, task: .explore)
            }
            XCTAssertNil(facts(for: request, in: [fixture.window]), shape)
        }
    }

    func testDeletingAndDeletedControllerFailsClosed() async throws {
        let (fixture, _, request) = try await readyController()
        let registry = AgentSessionDeletionRegistry.shared
        XCTAssertNotNil(facts(for: request, in: [fixture.window]))
        let failed = try registry.beginDurableDeletion(sessionID: request.requesterSessionID)
        XCTAssertNil(facts(for: request, in: [fixture.window]))
        registry.didFailDurableDeletion(failed)
        XCTAssertNotNil(facts(for: request, in: [fixture.window]))
        let committed = try registry.beginDurableDeletion(sessionID: request.requesterSessionID)
        await registry.didCommitDurableDeletion(committed)
        XCTAssertTrue(registry.isPermanentlyDeleted(sessionID: request.requesterSessionID))
        XCTAssertNil(facts(for: request, in: [fixture.window]))
    }

    private func facts(for request: DelegationScopeRequest, in windows: [WindowState]) -> StandingRuleFacts? {
        WindowStatesManager.shared.standingRuleFacts(for: request, in: windows)
    }

    private func makeFixture() -> SessionAdminScopeLifecycleTests.Fixture {
        var windows: [WindowState] = []
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, windows: { windows })
        let fixture = SessionAdminScopeLifecycleTests.Fixture(runtime: runtime)
        windows = [fixture.window]
        addTeardownBlock { @MainActor in await fixture.window.tearDown() }
        return fixture
    }

    private func readyController() async throws -> (
        SessionAdminScopeLifecycleTests.Fixture, AgentModeViewModel.TabSession, DelegationScopeRequest
    ) {
        let fixture = makeFixture()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 7)
        let session = try await fixture.installController(startedBy: stamp)
        let endpoint = try XCTUnwrap(fixture.endpoint)
        return try (fixture, session, makeRequest(in: fixture, for: endpoint))
    }

    private func makeRequest(
        in fixture: SessionAdminScopeLifecycleTests.Fixture,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) throws -> DelegationScopeRequest {
        try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID, requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: endpoint.workspaceID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
    }

    private func installSecondController(
        in window: WindowState, tabID: UUID, stamp: StarterConnectionStamp
    ) async throws -> AgentModeViewModel.TabSession {
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspaceID)
        let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspaceID })
        let sessionID = UUID()
        if let tabIndex = window.workspaceManager.workspaces[index].composeTabs.firstIndex(where: { $0.id == tabID }) {
            window.workspaceManager.workspaces[index].composeTabs[tabIndex].activeAgentSessionID = sessionID
        } else {
            window.workspaceManager.workspaces[index].composeTabs.append(
                ComposeTabState(id: tabID, name: "Second controller", activeAgentSessionID: sessionID)
            )
        }
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        window.agentModeViewModel.test_installLiveSession(session)
        _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
        session.mcpControlContext = try await makeContext(sessionID: sessionID, stamp: stamp)
        return session
    }

    private func makeContext(
        sessionID: UUID, stamp: StarterConnectionStamp, task: AgentModelCatalog.TaskLabelKind = .pair
    ) async throws -> AgentModeViewModel.AgentMCPControlContext {
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        return .init(
            sessionID: sessionID, activationID: UUID(), registration: registration,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: stamp.connectionID, startedBy: stamp,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: stamp.connectionID),
            suppressUserNotifications: true, forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: false, taskLabelKind: task
        )
    }
}

@MainActor
final class StandingRuleSurfaceTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
    }

    private let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
    private let ruleLifetime: TimeInterval = 3600
    private let requestArguments: [String: Value] = [
        "op": .string("request_scope"), "kind": .string("direct_children"),
        "capabilities": .array([.string("observe")]),
        "guardrails": .object(["expires_in_seconds": .int(60)])
    ]

    private func makeFixture(withRule: Bool, clock: Clock = Clock()) async throws -> SessionAdminScopeLifecycleTests.Fixture {
        var windows: [WindowState] = []
        var workspace = UUID()
        let stamp = stamp
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral, now: { clock.date }, windows: { windows },
            standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspace) },
            isStarterLive: { $0 == stamp },
            starterGeneration: { connectionID in connectionID == stamp.connectionID ? stamp.lifecycleGeneration : nil }
        )
        let fixture = SessionAdminScopeLifecycleTests.Fixture(runtime: runtime)
        windows = [fixture.window]
        addTeardownBlock { @MainActor in await fixture.window.tearDown() }
        let session = try await fixture.installController(startedBy: stamp)
        session.hasLoadedPersistedState = true
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        workspace = try XCTUnwrap(fixture.endpoint).workspaceID
        if withRule {
            let rule = DelegationStandingRule(
                id: UUID(), createdAt: clock.date, expiresAt: clock.date.addingTimeInterval(ruleLifetime),
                starter: stamp, workspaceID: workspace, countedTLs: [], ruleGrants: [],
                stoppedAt: nil, replacedBy: nil, closedAt: nil
            )
            runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        }
        return fixture
    }

    private func expectedExpiry(_ clock: Clock) -> String {
        ISO8601DateFormatter().string(from: clock.date.addingTimeInterval(ruleLifetime))
    }

    private func assertRuleProvenance(_ value: [String: Value]?, expiry: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value?["settled_by"], .string("standing_rule"), "\(label): missing settled_by", file: file, line: line)
        XCTAssertEqual(value?["rule_expires_at"], .string(expiry), label, file: file, line: line)
        let guidance = value?["guidance"]?.stringValue ?? ""
        XCTAssertTrue(guidance.contains("Granted without a card under a standing rule your user set for this connection"), "\(label): \(guidance)", file: file, line: line)
        XCTAssertTrue(guidance.contains("ends no later than \(expiry)"), label, file: file, line: line)
        XCTAssertTrue(guidance.contains("link explicitly with this scope_id"), label, file: file, line: line)
        XCTAssertTrue(guidance.contains("request again with a new idempotency_key and an expires_in_seconds that ends before \(expiry)"), label, file: file, line: line)
    }

    private func assertNoRuleProvenance(_ value: [String: Value]?, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value?["settled_by"], label, file: file, line: line)
        XCTAssertNil(value?["rule_expires_at"], label, file: file, line: line)
        XCTAssertFalse((value?["guidance"]?.stringValue ?? "").contains("standing rule"), label, file: file, line: line)
    }

    func testMatchingRuleWouldSettleRequestAndExposeProvenance() async throws {
        let control = try await makeFixture(withRule: false).call(requestArguments)
        XCTAssertEqual(control["result"], .string("pending_user_approval"))
        XCTAssertNil(control["settled_by"])
        let witness = try await makeFixture(withRule: true).call(requestArguments)
        XCTAssertEqual(witness["result"], .string("granted"))
        XCTAssertEqual(witness["scope"]?.objectValue?["kind"], .string("direct_children"))
        XCTAssertEqual(witness["settled_by"], .string("standing_rule"), "missing settled_by")
    }

    func testRuleSettledRequestReportsProvenanceOnRequestAndEveryStatusRoute() async throws {
        let clock = Clock()
        let expiry = expectedExpiry(clock)
        let fixture = try await makeFixture(withRule: true, clock: clock)
        let granted = try await fixture.call(requestArguments)
        XCTAssertEqual(granted["result"], .string("granted"))
        assertRuleProvenance(granted, expiry: expiry, "request_scope")
        let requestID = try XCTUnwrap(granted["request_id"]?.stringValue)
        let scopeID = try XCTUnwrap(granted["scope_id"]?.stringValue)

        let byRequest = try await fixture.call(["op": .string("scope_status"), "request_id": .string(requestID)])
        XCTAssertEqual(byRequest["result"], .string("granted"))
        assertRuleProvenance(byRequest, expiry: expiry, "scope_status by request")

        let byScope = try await fixture.call(["op": .string("scope_status"), "scope_id": .string(scopeID)])
        XCTAssertEqual(byScope["result"], .string("ok"))
        assertRuleProvenance(byScope, expiry: expiry, "scope_status by scope")

        let list = try await fixture.call(["op": .string("scope_status")])
        let entries = try XCTUnwrap(list["scopes"]?.arrayValue)
        let entry = try XCTUnwrap(entries.first { $0.objectValue?["scope_id"]?.stringValue == scopeID }?.objectValue)
        assertRuleProvenance(entry, expiry: expiry, "scope_status list")
    }

    func testCardGrantReportsNoRuleProvenanceOnAnyRoute() async throws {
        let fixture = try await makeFixture(withRule: false)
        let pending = try await fixture.call(requestArguments)
        XCTAssertEqual(pending["result"], .string("pending_user_approval"))
        let requestID = try XCTUnwrap(pending["request_id"]?.stringValue)
        let record = try fixture.runtime.approve(requestID: XCTUnwrap(UUID(uuidString: requestID))).get()
        let scopeID = record.id.uuidString

        let byRequest = try await fixture.call(["op": .string("scope_status"), "request_id": .string(requestID)])
        XCTAssertEqual(byRequest["result"], .string("granted"))
        XCTAssertNotNil(byRequest["scope"])
        assertNoRuleProvenance(byRequest, "by request")
        let byScope = try await fixture.call(["op": .string("scope_status"), "scope_id": .string(scopeID)])
        XCTAssertEqual(byScope["result"], .string("ok"))
        assertNoRuleProvenance(byScope, "by scope")
        let list = try await fixture.call(["op": .string("scope_status")])
        let entry = try XCTUnwrap(list["scopes"]?.arrayValue?.first { $0.objectValue?["scope_id"]?.stringValue == scopeID }?.objectValue)
        assertNoRuleProvenance(entry, "list")
    }

    func testRequestPastRuleEndStaysPendingBesideInRuleControl() async throws {
        let fitsClock = Clock()
        let fits = try await makeFixture(withRule: true, clock: fitsClock)
        fitsClock.date = fitsClock.date.addingTimeInterval(ruleLifetime - 60)
        let inRule = try await fits.call(requestArguments)
        XCTAssertEqual(inRule["result"], .string("granted"), "control: the request ends exactly with the rule")

        let outlivesClock = Clock()
        let outlives = try await makeFixture(withRule: true, clock: outlivesClock)
        outlivesClock.date = outlivesClock.date.addingTimeInterval(ruleLifetime - 30)
        let past = try await outlives.call(requestArguments)
        XCTAssertEqual(past["result"], .string("pending_user_approval"))
        XCTAssertNil(past["settled_by"])
        XCTAssertNil(past["rule_expires_at"])
    }

    func testCreatingOneRuleLeavesAnotherRulesPendingRequestAloneBesideItsOwnSettledControl() async throws {
        let stampA = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let stampB = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspaceB = UUID()
        var windows: [WindowState] = []
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral, windows: { windows },
            standingRuleFacts: { request in
                guard case let .directChildren(_, workspace) = request.kind else { return nil }
                return .init(starter: workspace == workspaceB ? stampB : stampA, workspaceID: workspace)
            },
            isStarterLive: { $0 == stampA || $0 == stampB },
            starterGeneration: { connectionID in
                [stampA, stampB].first { $0.connectionID == connectionID }?.lifecycleGeneration
            }
        )
        let fixture = SessionAdminScopeLifecycleTests.Fixture(runtime: runtime)
        windows = [fixture.window]
        addTeardownBlock { @MainActor in await fixture.window.tearDown() }
        _ = try await fixture.installController()
        let endpoint = try XCTUnwrap(fixture.endpoint)

        let ruleB = DelegationStandingRule(
            id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(ruleLifetime),
            starter: stampB, workspaceID: workspaceB, countedTLs: [], ruleGrants: [],
            stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        runtime.debugInstallStandingRuleForTesting(ruleB, issuedScopeID: UUID())
        func pending(workspace: UUID, session: UUID, key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: session, requesterTabID: nil,
                kind: .directChildren(rootSessionID: session, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
                reason: nil, idempotencyKey: key
            ).get()
        }
        let otherRulesRequest = try pending(workspace: workspaceB, session: UUID(), key: "b")
        let ownRulesRequest = try pending(workspace: endpoint.workspaceID, session: UUID(), key: "a")
        let seed = try runtime.requestScope(
            requesterSessionID: endpoint.sessionID, requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: endpoint.workspaceID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
            reason: nil, idempotencyKey: "seed"
        ).get()

        XCTAssertNoThrow(try runtime.approve(
            requestID: seed.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID, standingRuleOptions: .init()
        ).get())

        if case .granted? = runtime.request(id: ownRulesRequest.id, requesterSessionID: ownRulesRequest.requesterSessionID)?.state {} else {
            XCTFail("control: the new rule's own same-stamp, same-workspace request settles")
        }
        XCTAssertEqual(
            runtime.request(id: otherRulesRequest.id, requesterSessionID: otherRulesRequest.requesterSessionID)?.state,
            .pending, "another rule's pending request is not settled by this creation"
        )
        XCTAssertEqual(runtime.rules.first { $0.id == ruleB.id }?.countedTLs, [], "the other rule's count is untouched")
        XCTAssertEqual(runtime.rules.count, 2)
    }

    func testSweepReusesCoveringGrantWithoutCountingOrRuleProvenanceBesideSettledControl() async throws {
        let fixture = try await makeFixture(withRule: false)
        let runtime = fixture.runtime
        let endpoint = try XCTUnwrap(fixture.endpoint)
        let teamLeadB = UUID()
        let teamLeadC = UUID()
        func pending(session: UUID, seconds: Int, key: String, tab: UUID? = nil) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: session, requesterTabID: tab,
                kind: .directChildren(rootSessionID: session, workspaceID: endpoint.workspaceID),
                capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: seconds,
                reason: nil, idempotencyKey: key
            ).get()
        }
        let covered = try pending(session: teamLeadB, seconds: 60, key: "p")
        let longer = try pending(session: teamLeadB, seconds: 600, key: "q")
        let free = try pending(session: teamLeadC, seconds: 60, key: "c")
        let seed = try pending(session: endpoint.sessionID, seconds: 60, key: "seed", tab: endpoint.tabID)

        let longerGrant = try runtime.approve(requestID: longer.id).get()
        XCTAssertEqual(runtime.request(id: covered.id, requesterSessionID: teamLeadB)?.state, .pending)

        XCTAssertNoThrow(try runtime.approve(
            requestID: seed.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID, standingRuleOptions: .init()
        ).get())

        let rule = try XCTUnwrap(runtime.rules.first)
        guard case let .granted(freeScope)? = runtime.request(id: free.id, requesterSessionID: teamLeadC)?.state else {
            return XCTFail("control: the new rule settles a same-stamp request no grant covers")
        }
        XCTAssertEqual(rule.countedTLs, [endpoint.sessionID, teamLeadC])
        XCTAssertEqual(rule.ruleGrants, [freeScope])
        XCTAssertEqual(
            runtime.request(id: covered.id, requesterSessionID: teamLeadB)?.state,
            .granted(scopeID: longerGrant.id), "the sweep reuses the live grant that already covers the request"
        )
        XCTAssertFalse(rule.countedTLs.contains(teamLeadB), "reuse consumes no team-lead budget")
        XCTAssertFalse(rule.ruleGrants.contains(longerGrant.id))
        XCTAssertNil(runtime.standingRuleProvenance(scopeID: longerGrant.id))
    }

    func testRuleGrantYieldsSameStandingEndorsementAndLinkAsCardGrant() async throws {
        struct Outcome: Equatable {
            var authorized: Bool
            var endorsed: Bool
            var directChild: Bool
        }
        func outcome(withRule: Bool) async throws -> Outcome {
            let fixture = try await makeFixture(withRule: withRule)
            let endpoint = try XCTUnwrap(fixture.endpoint)
            let controller = endpoint.sessionID, workspace = endpoint.workspaceID
            fixture.source.add(controller, parent: nil, workspace: workspace)
            let child = UUID()
            fixture.source.add(child, parent: controller, workspace: workspace)
            let reply = try await fixture.call(requestArguments.merging([
                "capabilities": .array([.string("observe"), .string("control"), .string("restructure")])
            ]) { $1 })
            let scopeID: UUID
            if withRule {
                XCTAssertEqual(reply["result"], .string("granted"))
                scopeID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(reply["scope_id"]?.stringValue)))
            } else {
                let requestID = try XCTUnwrap(try UUID(uuidString: XCTUnwrap(reply["request_id"]?.stringValue)))
                scopeID = try fixture.runtime.approve(requestID: requestID).get().id
            }
            let engine = fixture.runtime.authorization
            var authorized = false
            if case .authorized = engine.scopedObserverAuthorization(for: endpoint, window: fixture.window) { authorized = true }
            let tabID = UUID(), binding = UUID()
            let target = AgentSessionLinkEndpointCandidate(
                windowID: 2, workspaceID: workspace, tabID: tabID, sessionID: child,
                persistentBindingGeneration: binding, bindingTransitionGeneration: 1, isTopLevel: false,
                hasLoadedPersistedState: true, bindingTransitionInProgress: false, isClosing: false,
                isMCPControlled: false, isMCPOriginated: false, roleAllowsOutboundMonitoring: true,
                displayName: "Worker", providerDisplayName: nil, locationLabel: nil,
                restorationReadiness: .authoritative(
                    AgentSessionRestorationBindingToken(
                        bindingIdentity: AgentPersistentSessionBindingIdentity(tabID: tabID, sessionID: child, generation: binding),
                        bindingTransitionGeneration: 1
                    ), .persistedPayloadApplied
                ),
                parentSessionID: controller, createdByOverseerSessionID: nil
            )
            let endorsement = engine.authorizeScopedObserverLink(
                observer: endpoint, target: target, scopeID: scopeID, window: fixture.window,
                projector: SpawnProvenanceDelegationMembershipProjector(source: fixture.source)
            )
            let record = try XCTUnwrap(fixture.runtime.record(id: scopeID))
            var directChild = false
            if case .directChildren(controller, workspace) = record.grant.kind { directChild = true }
            return Outcome(authorized: authorized, endorsed: endorsement != nil, directChild: directChild)
        }
        let card = try await outcome(withRule: false)
        XCTAssertEqual(card, Outcome(authorized: true, endorsed: true, directChild: true), "card control")
        let rule = try await outcome(withRule: true)
        XCTAssertEqual(rule, card)
    }

    func testRequestScopeRejectsRuleKeysAndAppSettingsHasNoRuleKey() async throws {
        let fixture = try await makeFixture(withRule: false)
        let control = try await fixture.call(requestArguments)
        XCTAssertEqual(control["result"], .string("pending_user_approval"))

        for (label, args) in [
            ("top-level key", requestArguments.merging(["standing_rule": .bool(true)]) { $1 }),
            ("top-level duration", requestArguments.merging(["standing_rule_duration_seconds": .int(3600)]) { $1 }),
            ("guardrail key", requestArguments.merging(["guardrails": .object(["standing_rule": .bool(true)])]) { $1 })
        ] {
            do {
                _ = try await fixture.call(args)
                XCTFail("request_scope accepted \(label)")
            } catch {
                XCTAssertTrue(error is MCPError, label)
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StandingRuleSurface-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "StandingRuleSurface.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = GlobalSettingsStore(
            defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let listed = try await AppSettingsMCPService(store: store).handleForTesting(["op": .string("list")])
        let keys = try XCTUnwrap(listed.objectValue?["settings"]?.arrayValue).compactMap { $0.objectValue?["key"]?.stringValue }
        XCTAssertTrue(keys.contains("agent_mode.codex_usage_quota_enabled"), "catalog control")
        XCTAssertFalse(keys.contains { $0.localizedCaseInsensitiveContains("standing") || $0.localizedCaseInsensitiveContains("rule") })
    }

    func testFullAccessSettingsTextNoLongerClaimsNoCardsAppear() {
        let text = AgentPermissionsSettingsView.fullAccessDescription
        XCTAssertTrue(text.contains("Turn this off to revoke it immediately"), "existing text control")
        XCTAssertFalse(text.contains("No approval or confirmation cards appear"), text)
        XCTAssertTrue(text.contains("direct-child delegation still asks for consent"), text)
        XCTAssertTrue(text.contains("checkbox"), text)
    }
}

@MainActor
final class StandingRuleCardModelTests: XCTestCase {
    func testActiveRuleWithNoGrantWouldKeepSectionVisible() {
        XCTAssertTrue(DelegationActiveScopesSection.hasContent(
            scopes: [], standing: [UUID()], globalAutoApprove: false,
            persistenceStatusMessage: nil, continuityRecoveryOffers: []
        )) // live-scope/standing control
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let rule = DelegationStandingRule(
            id: UUID(),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            starter: stamp,
            workspaceID: UUID(),
            countedTLs: [],
            ruleGrants: [],
            stoppedAt: nil,
            replacedBy: nil,
            closedAt: nil
        )
        XCTAssertTrue(DelegationActiveScopesSection.hasContent(
            scopes: [], standing: [], globalAutoApprove: false, persistenceStatusMessage: nil,
            continuityRecoveryOffers: [], rules: [rule]
        ), "hasContent false")
    }

    private let connection = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!

    private func makeRule(
        grants: Set<UUID> = [], stoppedAt: Date? = nil, closedAt: Date? = nil, now: Date = Date(),
        clientLabel: String? = "Planner"
    ) -> DelegationStandingRule {
        DelegationStandingRule(
            id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(3600),
            starter: StarterConnectionStamp(connectionID: connection, lifecycleGeneration: 1),
            workspaceID: UUID(), countedTLs: [UUID(), UUID()], ruleGrants: grants,
            stoppedAt: stoppedAt, replacedBy: nil, closedAt: closedAt, clientLabel: clientLabel
        )
    }

    private func makeRow(
        _ rule: DelegationStandingRule, live: Set<UUID> = [], connectionLive: Bool = true, now: Date = Date()
    ) -> ActiveStandingRuleRowModel {
        ActiveStandingRuleRowModel(
            rule: rule, workspaceName: "Alpha", liveGrantIDs: live,
            connectionLive: connectionLive, now: now
        )
    }

    func testDisclosureNamesLabelConnectionTimeCountAndBulkValue() {
        let now = Date()
        let offer = StandingRuleOffer(ruleID: nil, clientLabel: "Planner", connectionPrefix: "abcdef01", replacesExisting: false)
        var model = StandingRuleCardModel(offer: offer, bulkThreshold: 7)
        XCTAssertFalse(model.isSelected)
        XCTAssertEqual(model.checkboxLabel, "Also approve direct-child requests from other team leads this MCP connection starts in this workspace")
        XCTAssertEqual(model.duration, 8 * 3600)
        XCTAssertEqual(model.maxTeamLeads, 10)
        model.duration = 4 * 3600
        model.maxTeamLeads = 25
        let text = model.disclosure(now: now)
        for needle in [
            "Planner", "abcdef01", "self-declared", "only while this connection stays open",
            StandingRuleCardModel.timeText(now.addingTimeInterval(4 * 3600)), "25 team leads", "over 7 items",
            "A request is approved automatically only if its whole requested lifetime ends before the rule does"
        ] {
            XCTAssertTrue(text.contains(needle), "\(needle): \(text)")
        }
        XCTAssertTrue(StandingRuleCardModel(offer: offer, bulkThreshold: 500).disclosure(now: now).contains("over 25 items"))
        let replacing = StandingRuleOffer(ruleID: UUID(), clientLabel: "Planner", connectionPrefix: "abcdef01", replacesExisting: true)
        XCTAssertEqual(StandingRuleCardModel(offer: replacing, bulkThreshold: 5).checkboxLabel, "Replace the standing rule for this connection")
    }

    func testSelfDeclaredNameAppearsInTheDisclosureAndTheRowWithAFallbackWhenUnknown() {
        let now = Date()
        func disclosure(_ label: String?) -> String {
            StandingRuleCardModel(
                offer: StandingRuleOffer(ruleID: nil, clientLabel: label, connectionPrefix: "abcdef01", replacesExisting: false),
                bulkThreshold: 5
            ).disclosure(now: now)
        }
        XCTAssertTrue(disclosure("Claude Code").contains("Started by “Claude Code” (connection abcdef01; the name is self-declared)."))
        XCTAssertTrue(disclosure(nil).contains("Started by “an MCP client” (connection abcdef01; the name is self-declared)."))
        let long = String(repeating: "x", count: 200)
        XCTAssertTrue(disclosure(long).contains("Started by “\(String(repeating: "x", count: 80))” (connection"))

        let named = makeRow(makeRule(now: now, clientLabel: "Claude Code"), now: now)
        XCTAssertTrue(named.title.contains("started by “Claude Code” (connection "), named.title)
        let unnamed = makeRow(makeRule(now: now, clientLabel: nil), now: now)
        XCTAssertTrue(unnamed.title.contains("started by “an MCP client” (connection "), unnamed.title)
        let truncated = makeRow(makeRule(now: now, clientLabel: long), now: now)
        XCTAssertTrue(truncated.title.contains("started by “\(String(repeating: "x", count: 80))” (connection "), truncated.title)
    }

    func testSelfDeclaredNameDropsControlAndFormatCharactersInTheDisclosureAndTheRow() {
        let now = Date()
        func disclosure(_ label: String?) -> String {
            StandingRuleCardModel(
                offer: StandingRuleOffer(ruleID: nil, clientLabel: label, connectionPrefix: "abcdef01", replacesExisting: false),
                bulkThreshold: 5
            ).disclosure(now: now)
        }
        let cases: [(declared: String, shown: String)] = [
            ("Claude Code", "Claude Code"),
            ("Claude\u{2028}Code", "ClaudeCode"),
            ("Claude\u{2029}Code", "ClaudeCode"),
            ("Claude\nCode\r\n", "ClaudeCode"),
            ("\u{202E}Claude Code\u{202C}", "Claude Code"),
            ("Claude\u{200B}\u{200D} Code", "Claude Code"),
            ("\u{200B}\u{202E}\u{2060}", StandingRuleCardModel.unknownClientLabel),
            ("  \n\t ", StandingRuleCardModel.unknownClientLabel)
        ]
        for (declared, shown) in cases {
            XCTAssertEqual(StandingRuleCardModel.displayClientLabel(declared), shown, declared.debugDescription)
            XCTAssertTrue(
                disclosure(declared).contains("Started by “\(shown)” (connection abcdef01; the name is self-declared)."),
                declared.debugDescription
            )
            let row = makeRow(makeRule(now: now, clientLabel: declared), now: now)
            XCTAssertTrue(row.title.contains("started by “\(shown)” (connection "), row.title)
        }
        XCTAssertEqual(StandingRuleCardModel.displayClientLabel(nil), StandingRuleCardModel.unknownClientLabel)
        XCTAssertEqual(
            StandingRuleCardModel.displayClientLabel("\u{200B}" + String(repeating: "x", count: 200)),
            String(repeating: "x", count: 80)
        )
    }

    func testPickerChoicesEqualDesignAndOptionsNeedTickAndAllCapabilities() {
        XCTAssertEqual(StandingRuleCardModel.durationChoices, [4 * 3600, 8 * 3600, 24 * 3600])
        XCTAssertEqual(StandingRuleCardModel.teamLeadChoices, [5, 10, 25, 50])
        let offer = StandingRuleOffer(ruleID: nil, clientLabel: "Planner", connectionPrefix: "abcdef01", replacesExisting: false)
        var model = StandingRuleCardModel(offer: offer, bulkThreshold: 9)
        let all = DomainDelegationScopeCapability.directChildrenPermitted
        XCTAssertNil(model.options(selectedCapabilities: all))
        model.isSelected = true
        XCTAssertEqual(model.options(selectedCapabilities: all), StandingRuleOptions(duration: 8 * 3600, maxTeamLeads: 10))
        XCTAssertNil(model.options(selectedCapabilities: [.observe]))
    }

    func testTickedBoxStillRoutesThroughTheRuleEntryWhenTheOfferHasSinceGone() {
        let offer = StandingRuleOffer(ruleID: nil, clientLabel: "Planner", connectionPrefix: "abcdef01", replacesExisting: false)
        let all = DomainDelegationScopeCapability.directChildrenPermitted
        var model = StandingRuleCardModel(offer: offer, bulkThreshold: 9)
        func route(_ model: StandingRuleCardModel?, capabilities: Set<DomainDelegationScopeCapability> = all, canApprove: Bool = true) -> StandingRuleCardModel.GrantRoute {
            StandingRuleCardModel.grantRoute(model: model, selectedCapabilities: capabilities, canApproveWithRule: canApprove)
        }
        XCTAssertEqual(route(model), .plain, "unticked box")
        model.isSelected = true
        model.duration = 4 * 3600
        XCTAssertEqual(route(model), .withRule(StandingRuleOptions(duration: 4 * 3600, maxTeamLeads: 10)))
        XCTAssertEqual(route(model, capabilities: [.observe]), .plain, "narrowed capabilities")
        XCTAssertEqual(route(model, canApprove: false), .plain, "no rule entry point")
        XCTAssertEqual(route(nil), .plain, "no offer was ever presented")
    }

    func testRetainedCardFollowsTheCurrentOfferWhileKeepingTheHumansChoices() {
        let first = StandingRuleOffer(ruleID: nil, clientLabel: "Planner", connectionPrefix: "abcdef01", replacesExisting: false)
        let replacing = StandingRuleOffer(ruleID: UUID(), clientLabel: "Planner", connectionPrefix: "abcdef01", replacesExisting: true)
        var model = StandingRuleCardModel(offer: first, bulkThreshold: 9)
        model.isSelected = true
        model.duration = 24 * 3600
        model.maxTeamLeads = 25
        XCTAssertEqual(model.checkboxLabel, "Also approve direct-child requests from other team leads this MCP connection starts in this workspace")

        let shown = model.presenting(replacing)
        XCTAssertEqual(shown.checkboxLabel, "Replace the standing rule for this connection")
        XCTAssertEqual(shown.offer, replacing)
        XCTAssertTrue(shown.isSelected)
        XCTAssertEqual(shown.duration, 24 * 3600)
        XCTAssertEqual(shown.maxTeamLeads, 25)
        XCTAssertEqual(shown.bulkThreshold, 9)

        let gone = model.presenting(nil)
        XCTAssertEqual(gone, model, "a missing current offer keeps the retained card as it was")
        XCTAssertTrue(gone.isSelected, "the ticked intent survives a missing offer")
    }

    func testHasContentForRuleWithNoGrantFalseAfterStopTrueWhileRuleGrantLive() {
        let now = Date()
        let grant = UUID()
        func visible(_ rule: DelegationStandingRule, live: Set<UUID>) -> Bool {
            ActiveStandingRuleRowModel.isVisible(rule: rule, liveGrantIDs: live, now: now)
        }
        XCTAssertTrue(visible(makeRule(now: now), live: []))
        let stopped = makeRule(grants: [grant], stoppedAt: now, now: now)
        XCTAssertTrue(visible(stopped, live: [grant]), "control: stopped rule with a live rule grant")
        XCTAssertFalse(visible(stopped, live: []))
        XCTAssertFalse(DelegationActiveScopesSection.hasContent(
            scopes: [], standing: [], globalAutoApprove: false, persistenceStatusMessage: nil,
            continuityRecoveryOffers: [], rules: [stopped], now: now
        ))
        let notice = StandingRuleNotice(id: UUID(), cause: .noStamp)
        XCTAssertTrue(DelegationActiveScopesSection.hasContent(
            scopes: [], standing: [], globalAutoApprove: false, persistenceStatusMessage: nil,
            continuityRecoveryOffers: [], notices: [notice], now: now
        ))
        XCTAssertFalse(DelegationActiveScopesSection.hasContent(
            scopes: [], standing: [], globalAutoApprove: false, persistenceStatusMessage: nil,
            continuityRecoveryOffers: [], notices: [], now: now
        ))
    }

    func testRowButtonsMapToTheirStopActionsAndStopIsOnlyOfferedWhileActive() {
        let now = Date()
        let live = UUID()
        func perform(_ row: ActiveStandingRuleRowModel, _ index: Int) -> [(UUID, Bool)] {
            var calls: [(UUID, Bool)] = []
            row.perform(row.actions[index]) { calls.append(($0, $1)) }
            return calls
        }
        let active = makeRow(makeRule(grants: [live], now: now), live: [live], now: now)
        XCTAssertTrue(active.canStop)
        XCTAssertEqual(active.actions.map(\.title), ["Stop rule", "Stop rule and revoke 1 grants"])
        XCTAssertEqual(active.actions.map(\.revokesIssuedGrants), [false, true])
        let stop = perform(active, 0)
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop.first?.0, active.id)
        XCTAssertEqual(stop.first?.1, false)
        let revoke = perform(active, 1)
        XCTAssertEqual(revoke.count, 1)
        XCTAssertEqual(revoke.first?.0, active.id)
        XCTAssertEqual(revoke.first?.1, true)

        XCTAssertEqual(makeRow(makeRule(now: now), now: now).actions.map(\.title), ["Stop rule"], "no live rule grant: no revoke button")
        for ended in [
            makeRule(grants: [live], stoppedAt: now, now: now),
            makeRule(grants: [live], closedAt: now, now: now)
        ] {
            let row = makeRow(ended, live: [live], now: now)
            XCTAssertFalse(row.canStop)
            XCTAssertEqual(row.actions.map(\.title), ["Stop rule and revoke 1 grants"], "an ended rule offers only the revoke")
        }
        let expired = makeRow(makeRule(grants: [live], now: now), live: [live], now: now.addingTimeInterval(7200))
        XCTAssertFalse(expired.canStop)
        XCTAssertEqual(expired.actions.map(\.revokesIssuedGrants), [true])
    }

    func testExpiredRuleIsVisibleOnlyWhileARuleGrantIsLive() {
        let now = Date()
        let grant = UUID()
        let rule = makeRule(grants: [grant], now: now)
        let later = now.addingTimeInterval(7200)
        XCTAssertTrue(ActiveStandingRuleRowModel.isVisible(rule: rule, liveGrantIDs: [], now: now), "control: active")
        XCTAssertEqual(rule.effectiveState(now: later), .expired)
        XCTAssertTrue(ActiveStandingRuleRowModel.isVisible(rule: rule, liveGrantIDs: [grant], now: later))
        XCTAssertFalse(ActiveStandingRuleRowModel.isVisible(rule: rule, liveGrantIDs: [], now: later))
    }

    func testSettledSuffixOnlyOnRuleGrants() {
        let ruleGrant = UUID(), seedGrant = UUID()
        let rule = makeRule(grants: [ruleGrant])
        XCTAssertEqual(ActiveStandingRuleRowModel.grantSuffix(scopeID: ruleGrant, rules: [rule]), " · settled by standing rule")
        XCTAssertEqual(ActiveStandingRuleRowModel.grantSuffix(scopeID: seedGrant, rules: [rule]), "")
    }

    func testRowShowsStateLinesAndButtonLabelsWithLiveCounts() {
        let now = Date()
        let live = UUID(), gone = UUID()
        let row = makeRow(makeRule(grants: [live, gone], now: now), live: [live], now: now)
        for needle in ["Planner", "ABCDEF01", "Alpha"] {
            XCTAssertTrue(row.title.contains(needle), row.title)
        }
        for needle in [
            "observe · control · restructure",
            StandingRuleCardModel.timeText(now.addingTimeInterval(3600)),
            "2 of 10 team leads",
            "connection open",
            "active"
        ] {
            XCTAssertTrue(row.detail.contains(needle), row.detail)
        }
        XCTAssertTrue(row.asOf.hasPrefix("as of "))
        XCTAssertEqual(row.stopTitle, "Stop rule")
        XCTAssertEqual(row.revokeTitle, "Stop rule and revoke 1 grants")
        XCTAssertNil(makeRow(makeRule(now: now), now: now).revokeTitle)
        XCTAssertTrue(ActiveStandingRuleRowModel.fullAccessNote.contains("full access does not affect this rule"))
    }

    func testTransientNotLiveSampleShowsConnectionUnavailableBesideOpenAndClosed() {
        let now = Date()
        let rule = makeRule(now: now)
        XCTAssertTrue(makeRow(rule, connectionLive: true, now: now).detail.contains("connection open"))
        let transient = makeRow(rule, connectionLive: false, now: now)
        XCTAssertTrue(transient.detail.contains("connection unavailable"), transient.detail)
        XCTAssertFalse(transient.detail.contains("connection closed"))
        let closed = makeRow(makeRule(closedAt: now, now: now), connectionLive: false, now: now)
        XCTAssertTrue(closed.detail.contains("connection closed"), closed.detail)
    }

    func testNoticeMessagesNameTheFailingCheck() {
        let reasons: [(StandingRuleNotice.Cause, String)] = [
            (.connectionClosed, "the MCP connection that started this team lead is no longer open"),
            (.noStamp, "this team lead was not freshly started by an open MCP connection"),
            (.requestChanged, "the request changed before Grant")
        ]
        for (cause, reason) in reasons {
            let message = StandingRuleNotice(id: UUID(), cause: cause).message
            XCTAssertEqual(message, "The standing rule was not created: \(reason). The team lead's own request was approved.")
        }
    }
}
