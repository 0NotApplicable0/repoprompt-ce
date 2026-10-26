import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
private func presentedFixture(
    stamp: StarterConnectionStamp,
    workspaceID: UUID,
    facts: (@MainActor (DelegationScopeRequest) -> StandingRuleFacts?)? = nil,
    isStarterLive: ((StarterConnectionStamp) -> Bool)? = nil
) async throws -> (SessionAdminScopeLifecycleTests.Fixture, DomainAgentSessionLinkEndpointIdentity) {
    var windows: [WindowState] = []
    let runtime = DelegationScopeRuntime(
        persistenceMode: .ephemeral,
        windows: { windows },
        standingRuleFacts: facts ?? { _ in .init(starter: stamp, workspaceID: workspaceID) },
        isStarterLive: isStarterLive ?? { $0 == stamp },
        starterGeneration: { connectionID in connectionID == stamp.connectionID ? stamp.lifecycleGeneration : nil }
    )
    let fixture = SessionAdminScopeLifecycleTests.Fixture(runtime: runtime)
    windows = [fixture.window]
    _ = try await fixture.installController()
    return try (fixture, XCTUnwrap(fixture.endpoint))
}

@MainActor
final class StandingRuleModelTests: XCTestCase {
    @MainActor
    private struct Case {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let now = Date(timeIntervalSince1970: 1_000_000)

        func request(
            capabilities: Set<DomainDelegationScopeCapability> = [.observe, .control, .restructure],
            threshold: Int = 25,
            expiresInSeconds: Int? = 60,
            kind: DomainDelegationScopeKind? = nil,
            sessionID: UUID? = nil
        ) -> DelegationScopeRequest {
            let session = sessionID ?? self.sessionID
            return DelegationScopeRequest(
                id: UUID(), requesterSessionID: session, requesterTabID: nil, requesterWindowID: nil,
                requesterTitle: nil, workspaceName: nil,
                kind: kind ?? .directChildren(rootSessionID: session, workspaceID: workspaceID),
                capabilities: capabilities, guardrails: .init(bulkConfirmationThreshold: threshold),
                expiresInSeconds: expiresInSeconds, reason: nil, idempotencyKey: nil, createdAt: now
            )
        }

        func rule(
            lifetime: TimeInterval = 3600,
            counted: Set<UUID> = [],
            maxTeamLeads: Int = 10,
            ceiling: Int = 25
        ) -> DelegationStandingRule {
            DelegationStandingRule(
                id: UUID(), createdAt: now, expiresAt: now.addingTimeInterval(lifetime), starter: stamp,
                workspaceID: workspaceID, countedTLs: counted, ruleGrants: [], stoppedAt: nil, replacedBy: nil,
                closedAt: nil, maxTeamLeads: maxTeamLeads, bulkThresholdCeiling: ceiling
            )
        }

        func facts(stamp: StarterConnectionStamp? = nil, workspaceID: UUID? = nil) -> StandingRuleFacts {
            StandingRuleFacts(starter: stamp ?? self.stamp, workspaceID: workspaceID ?? self.workspaceID)
        }

        func decide(
            _ rule: DelegationStandingRule,
            _ request: DelegationScopeRequest,
            facts: StandingRuleFacts? = nil,
            live: Bool = true,
            excluded: Bool = false,
            deleted: Bool = false
        ) -> StandingRuleDecision {
            OverseerAuthorizationEngine.standingRuleDecision(
                rule: rule, request: request, facts: facts ?? self.facts(), now: now, isStarterLive: live,
                isExcluded: excluded, isDeleted: deleted
            )
        }
    }

    func testMatchingRuleSettles() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
    }

    func testStoppedRuleRefusesBesideActiveControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        var stopped = c.rule()
        stopped.stoppedAt = c.now
        XCTAssertEqual(c.decide(stopped, c.request()), .refuse(.ruleNotActive(.stopped)))
    }

    func testReplacedRuleRefusesBesideActiveControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        var replaced = c.rule()
        replaced.replacedBy = UUID()
        XCTAssertEqual(c.decide(replaced, c.request()), .refuse(.ruleNotActive(.replaced)))
    }

    func testExpiredRuleRefusesBesideActiveControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        XCTAssertEqual(c.decide(c.rule(lifetime: 0), c.request()), .refuse(.ruleNotActive(.expired)))
    }

    func testClosedRuleRefusesBesideActiveControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        var closed = c.rule()
        closed.closedAt = c.now
        XCTAssertEqual(c.decide(closed, c.request()), .refuse(.ruleNotActive(.connectionClosed)))
    }

    func testRequestPastRuleEndRefusesIncludingDefaultHourInLastHour() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(lifetime: 3600), c.request(expiresInSeconds: 3600)), .settle)
        XCTAssertEqual(
            c.decide(c.rule(lifetime: 3599), c.request(expiresInSeconds: 3600)),
            .refuse(.expiryPastRuleEnd)
        )
        XCTAssertEqual(
            c.decide(c.rule(lifetime: 60), c.request(expiresInSeconds: 61)),
            .refuse(.expiryPastRuleEnd)
        )
    }

    func testNilExpiryRefusesBesideFiniteControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request(expiresInSeconds: 60)), .settle)
        XCTAssertEqual(c.decide(c.rule(), c.request(expiresInSeconds: nil)), .refuse(.noExpiry))
    }

    func testThresholdAboveCeilingRefusesBesideAtCeilingControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(ceiling: 5), c.request(threshold: 5)), .settle)
        XCTAssertEqual(c.decide(c.rule(ceiling: 5), c.request(threshold: 6)), .refuse(.thresholdAboveCeiling))
    }

    func testCapabilityOutsideTheThreeRefusesBesideSubsetControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request(capabilities: [.observe, .control, .restructure])), .settle)
        let outside = DomainDelegationScopeCapability.allCases.first {
            !DomainDelegationScopeCapability.directChildrenPermitted.contains($0)
        }
        guard let extra = outside else { return XCTFail("no capability outside the permitted set") }
        XCTAssertEqual(
            c.decide(c.rule(), c.request(capabilities: [.observe, .control, .restructure, extra])),
            .refuse(.capabilityOutsideSet)
        )
    }

    func testFullCountRefusesNewTeamLeadButSettlesCountedOne() {
        let c = Case()
        let other = UUID()
        let full = c.rule(counted: [other], maxTeamLeads: 1)
        XCTAssertEqual(c.decide(full, c.request()), .refuse(.teamLeadCountFull))
        let withSelf = c.rule(counted: [c.sessionID], maxTeamLeads: 1)
        XCTAssertEqual(c.decide(withSelf, c.request()), .settle)
        XCTAssertEqual(c.decide(c.rule(counted: [other], maxTeamLeads: 2), c.request()), .settle)
    }

    func testOtherWorkspaceRefusesBesideSameWorkspaceControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        XCTAssertEqual(
            c.decide(c.rule(), c.request(), facts: c.facts(workspaceID: UUID())),
            .refuse(.otherWorkspace)
        )
        let elsewhere = c.request(kind: .directChildren(rootSessionID: c.sessionID, workspaceID: UUID()))
        XCTAssertEqual(c.decide(c.rule(), elsewhere), .refuse(.otherWorkspace))
    }

    func testOtherStampRefusesBesideSameStampControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        let sameConnectionOtherGeneration = StarterConnectionStamp(
            connectionID: c.stamp.connectionID, lifecycleGeneration: c.stamp.lifecycleGeneration + 1
        )
        let otherConnection = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        for stamp in [sameConnectionOtherGeneration, otherConnection] {
            XCTAssertEqual(c.decide(c.rule(), c.request(), facts: c.facts(stamp: stamp)), .refuse(.otherStarter))
        }
    }

    func testNotLiveExcludedAndDeletedRefuseBesideControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        XCTAssertEqual(c.decide(c.rule(), c.request(), live: false), .refuse(.starterNotLive))
        XCTAssertEqual(c.decide(c.rule(), c.request(), excluded: true), .refuse(.excluded))
        XCTAssertEqual(c.decide(c.rule(), c.request(), deleted: true), .refuse(.deleted))
    }

    func testOtherKindRefusesBesideDirectChildrenControl() {
        let c = Case()
        XCTAssertEqual(c.decide(c.rule(), c.request()), .settle)
        XCTAssertEqual(
            c.decide(c.rule(), c.request(kind: .tree(rootSessionID: c.sessionID))),
            .refuse(.otherKind)
        )
        XCTAssertEqual(
            c.decide(c.rule(), c.request(kind: .session(targetSessionID: c.sessionID))),
            .refuse(.otherKind)
        )
    }

    func testStatePrecedenceStoppedReplacedExpiredClosedActive() {
        let c = Case()
        var rule = c.rule()
        XCTAssertEqual(rule.effectiveState(now: c.now), .active)
        rule.closedAt = c.now
        XCTAssertEqual(rule.effectiveState(now: c.now), .connectionClosed)
        XCTAssertEqual(rule.effectiveState(now: rule.expiresAt), .expired)
        rule.replacedBy = UUID()
        XCTAssertEqual(rule.effectiveState(now: rule.expiresAt), .replaced)
        rule.stoppedAt = c.now
        XCTAssertEqual(rule.effectiveState(now: rule.expiresAt), .stopped)
    }

    func testTransientNotLiveSampleNeitherLatchesNorPrunes() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let rule = c.rule()
        book.add(rule)
        book.evaluate(now: c.now, starterGeneration: { _ in c.stamp.lifecycleGeneration }, isGrantLive: { _ in false })
        XCTAssertEqual(book.rules[rule.id]?.closedAt, nil)
        XCTAssertEqual(book.rules[rule.id]?.effectiveState(now: c.now), .active)
    }

    func testTerminalGenerationLossLatchesMonotonically() {
        for lost: UInt64? in [nil, 2] {
            let c = Case()
            var book = DelegationStandingRuleBook()
            let rule = c.rule()
            let grant = UUID()
            book.add(rule)
            book.recordRuleGrant(scopeID: grant, teamLead: c.sessionID, in: rule.id)
            book.evaluate(now: c.now, starterGeneration: { _ in lost }, isGrantLive: { $0 == grant })
            XCTAssertEqual(book.rules[rule.id]?.closedAt, c.now)
            XCTAssertEqual(book.rules[rule.id]?.effectiveState(now: c.now), .connectionClosed)
            book.evaluate(
                now: c.now.addingTimeInterval(1), starterGeneration: { _ in c.stamp.lifecycleGeneration },
                isGrantLive: { $0 == grant }
            )
            XCTAssertEqual(book.rules[rule.id]?.closedAt, c.now)
        }
    }

    func testEndedRulePrunedOnlyWhenNoRuleGrantIsLive() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let rule = c.rule()
        let ruleGrant = UUID()
        let seedGrant = UUID()
        book.add(rule)
        book.recordRuleGrant(scopeID: ruleGrant, teamLead: c.sessionID, in: rule.id)
        book.stop(id: rule.id, now: c.now)
        book.evaluate(now: c.now, starterGeneration: { _ in c.stamp.lifecycleGeneration }, isGrantLive: { $0 == ruleGrant })
        XCTAssertNotNil(book.rules[rule.id])
        book.evaluate(now: c.now, starterGeneration: { _ in c.stamp.lifecycleGeneration }, isGrantLive: { $0 == seedGrant })
        XCTAssertNil(book.rules[rule.id])
    }

    func testActiveRuleWithNoGrantIsKeptByEvaluate() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let rule = c.rule()
        book.add(rule)
        book.evaluate(now: c.now, starterGeneration: { _ in c.stamp.lifecycleGeneration }, isGrantLive: { _ in false })
        XCTAssertNotNil(book.rules[rule.id])
    }

    func testCountTeamLeadsAndRuleGrantsAreRecordedPerRule() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let rule = c.rule()
        let seed = UUID()
        let scope = UUID()
        book.add(rule)
        book.countTeamLead(seed, in: rule.id)
        XCTAssertEqual(book.rules[rule.id]?.countedTLs, [seed])
        XCTAssertEqual(book.rules[rule.id]?.ruleGrants, [])
        book.recordRuleGrant(scopeID: scope, teamLead: c.sessionID, in: rule.id)
        XCTAssertEqual(book.rules[rule.id]?.countedTLs, [seed, c.sessionID])
        XCTAssertEqual(book.rules[rule.id]?.ruleGrants, [scope])
        book.recordRuleGrant(scopeID: UUID(), teamLead: UUID(), in: UUID())
        XCTAssertEqual(book.rules.count, 1)
    }

    func testReplaceMarksOldRuleReplacedAndKeepsItsGrantsAndExclusions() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let old = c.rule()
        let grant = UUID()
        let excluded = UUID()
        book.add(old)
        book.recordRuleGrant(scopeID: grant, teamLead: c.sessionID, in: old.id)
        book.exclude(excluded)
        let successor = c.rule()
        book.replace(successor)
        XCTAssertEqual(book.rules[old.id]?.replacedBy, successor.id)
        XCTAssertEqual(book.rules[old.id]?.effectiveState(now: c.now), .replaced)
        XCTAssertEqual(book.rules[old.id]?.ruleGrants, [grant])
        XCTAssertEqual(book.rules[successor.id]?.effectiveState(now: c.now), .active)
        XCTAssertEqual(book.rules[successor.id]?.countedTLs, [])
        XCTAssertTrue(book.isExcluded(excluded))
        let unrelated = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        var other = c.rule()
        other = DelegationStandingRule(
            id: UUID(), createdAt: c.now, expiresAt: other.expiresAt, starter: unrelated,
            workspaceID: c.workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        book.replace(other)
        XCTAssertEqual(book.rules[successor.id]?.replacedBy, nil)
    }

    func testReplaceLeavesTheSameConnectionsRuleInAnotherWorkspaceActive() {
        let c = Case()
        let otherWorkspace = UUID()
        var book = DelegationStandingRuleBook()
        let inFirst = c.rule()
        let inSecond = DelegationStandingRule(
            id: UUID(), createdAt: c.now, expiresAt: c.now.addingTimeInterval(3600), starter: c.stamp,
            workspaceID: otherWorkspace, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        book.add(inFirst)
        book.add(inSecond)
        let successor = c.rule()
        book.replace(successor)
        XCTAssertEqual(book.rules[inFirst.id]?.replacedBy, successor.id)
        XCTAssertNil(book.rules[inSecond.id]?.replacedBy)
        XCTAssertEqual(book.rules[inSecond.id]?.effectiveState(now: c.now), .active)
    }

    func testReplaceLeavesTheSameConnectionIDAtAnotherGenerationActive() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let regenerated = DelegationStandingRule(
            id: UUID(), createdAt: c.now, expiresAt: c.now.addingTimeInterval(3600),
            starter: StarterConnectionStamp(connectionID: c.stamp.connectionID, lifecycleGeneration: 2),
            workspaceID: c.workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        book.add(regenerated)
        let original = c.rule(), successor = c.rule()
        book.add(original)
        book.replace(successor)
        XCTAssertEqual(book.rules[original.id]?.replacedBy, successor.id)
        XCTAssertNil(book.rules[regenerated.id]?.replacedBy)
    }

    func testExclusionsAddAndRemove() {
        var book = DelegationStandingRuleBook()
        let id = UUID()
        XCTAssertFalse(book.isExcluded(id))
        book.exclude(id)
        XCTAssertTrue(book.isExcluded(id))
        book.removeExclusion(id)
        XCTAssertFalse(book.isExcluded(id))
    }

    func testStopIsIdempotentAndNoticesPruneAndDismiss() {
        let c = Case()
        var book = DelegationStandingRuleBook()
        let rule = c.rule()
        book.add(rule)
        book.stop(id: rule.id, now: c.now)
        book.stop(id: rule.id, now: c.now.addingTimeInterval(5))
        XCTAssertEqual(book.rules[rule.id]?.stoppedAt, c.now)
        let kept = StandingRuleNotice(id: UUID(), cause: .noStamp)
        let ended = StandingRuleNotice(id: UUID(), cause: .connectionClosed)
        let dismissed = StandingRuleNotice(id: UUID(), cause: .requestChanged)
        [kept, ended, dismissed].forEach { book.addNotice($0) }
        book.dismissNotice(id: dismissed.id)
        book.pruneNotices { $0.id == ended.id }
        XCTAssertEqual(Set(book.notices.keys), [kept.id])
    }
}

@MainActor
final class StandingRuleCreationTests: XCTestCase {
    func testPresentedApprovalWithOptionsWouldCreateOneRule() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let controlPair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let controlRuntime = controlPair.0.runtime
        let controlEndpoint = controlPair.1
        let control = try controlRuntime.requestScope(
            requesterSessionID: controlEndpoint.sessionID,
            requesterTabID: controlEndpoint.tabID,
            kind: .directChildren(rootSessionID: controlEndpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try controlRuntime.approve(
            requestID: control.id,
            presentedWindowID: controlEndpoint.windowID,
            presentedTabID: controlEndpoint.tabID,
            presentedSessionID: controlEndpoint.sessionID
        ).get())
        XCTAssertEqual(controlRuntime.rules.count, 0)

        let witnessPair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let witnessRuntime = witnessPair.0.runtime
        let witnessEndpoint = witnessPair.1
        let witness = try witnessRuntime.requestScope(
            requesterSessionID: witnessEndpoint.sessionID,
            requesterTabID: witnessEndpoint.tabID,
            kind: .directChildren(rootSessionID: witnessEndpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try witnessRuntime.approve(
            requestID: witness.id,
            presentedWindowID: witnessEndpoint.windowID,
            presentedTabID: witnessEndpoint.tabID,
            presentedSessionID: witnessEndpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(witnessRuntime.rules.count, 1)
        let rule = try XCTUnwrap(witnessRuntime.rules.first)
        XCTAssertEqual(rule.countedTLs, [witnessEndpoint.sessionID])
        XCTAssertTrue(rule.ruleGrants.isEmpty)
        XCTAssertEqual(rule.bulkThresholdCeiling, 25)
    }

    private func seededRule(
        options: StandingRuleOptions,
        approvedThreshold: Int? = nil,
        approvedCapabilities: Set<DomainDelegationScopeCapability>? = nil
    ) async throws -> (SessionAdminScopeLifecycleTests.Fixture, UUID, Result<DomainDelegationScopeRecord, DomainDelegationScopeDenial>) {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let (fixture, endpoint) = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let request = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID,
            requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        var guardrails = request.guardrails
        if let approvedThreshold { guardrails.bulkConfirmationThreshold = approvedThreshold }
        let result = fixture.runtime.approve(
            requestID: request.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID,
            capabilities: approvedCapabilities,
            guardrails: guardrails,
            standingRuleOptions: options
        )
        return (fixture, workspace, result)
    }

    func testDurationIsClampedToFourToTwentyFourHours() async throws {
        for (seconds, expected) in [(0.0, 4.0 * 3600), (1000.0 * 3600, 24.0 * 3600)] {
            let (fixture, _, result) = try await seededRule(options: .init(duration: seconds))
            XCTAssertNoThrow(try result.get())
            let rule = try XCTUnwrap(fixture.runtime.rules.first)
            XCTAssertEqual(rule.expiresAt.timeIntervalSince(rule.createdAt), expected)
        }
    }

    func testTeamLeadLimitIsClampedToFiveToFifty() async throws {
        for (requested, expected) in [(1, 5), (500, 50)] {
            let (fixture, _, result) = try await seededRule(options: .init(maxTeamLeads: requested))
            XCTAssertNoThrow(try result.get())
            XCTAssertEqual(fixture.runtime.rules.first?.maxTeamLeads, expected)
        }
    }

    func testCeilingIsTheApprovedCardThresholdUpToTwentyFive() async throws {
        let (fixture, workspace, result) = try await seededRule(options: .init(), approvedThreshold: 7)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(fixture.runtime.rules.first?.bulkThresholdCeiling, 7)
        func derived(threshold: Int) throws -> DelegationScopeRequest {
            let session = UUID()
            return try fixture.runtime.requestScope(
                requesterSessionID: session,
                requesterTabID: nil,
                kind: .directChildren(rootSessionID: session, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure],
                guardrails: .init(bulkConfirmationThreshold: threshold),
                expiresInSeconds: 60,
                reason: nil,
                idempotencyKey: UUID().uuidString
            ).get()
        }
        let above = try derived(threshold: 8)
        XCTAssertFalse(fixture.runtime.approveWithStandingConsent(requestID: above.id))
        XCTAssertEqual(fixture.runtime.request(id: above.id, requesterSessionID: above.requesterSessionID)?.state, .pending)
        let at = try derived(threshold: 7)
        XCTAssertTrue(fixture.runtime.approveWithStandingConsent(requestID: at.id))

        let (capped, _, cappedResult) = try await seededRule(options: .init(), approvedThreshold: 40)
        XCTAssertNoThrow(try cappedResult.get())
        XCTAssertEqual(capped.runtime.rules.first?.bulkThresholdCeiling, 25)
    }

    func testCardApprovedWithoutTheFullCapabilitySetCreatesNoRuleAndNamesTheChange() async throws {
        let (fixture, _, result) = try await seededRule(options: .init(), approvedCapabilities: [.observe])
        XCTAssertNoThrow(try result.get())
        XCTAssertTrue(fixture.runtime.rules.isEmpty)
        XCTAssertEqual(fixture.runtime.notices.map(\.cause), [.requestChanged])
        let seed = try XCTUnwrap(fixture.runtime.allLiveScopes().first)
        XCTAssertEqual(seed.grant.capabilities, [.observe])
        XCTAssertTrue(fixture.runtime.debugIsStandingRuleExcludedForTesting(seed.grant.granteeSessionID))
    }

    func testOfferNeedsAPendingRequestInTheFactsWorkspace() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let (fixture, endpoint) = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let request = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID,
            requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNotNil(fixture.runtime.standingRuleOffer(for: request), "control: pending request in the facts workspace")
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: request.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID
        ).get())
        let decided = try XCTUnwrap(fixture.runtime.request(id: request.id, requesterSessionID: endpoint.sessionID))
        XCTAssertNotEqual(decided.state, .pending)
        XCTAssertNil(fixture.runtime.standingRuleOffer(for: decided), "a decided request is offered nothing")

        let (elsewhere, elsewhereEndpoint) = try await presentedFixture(
            stamp: stamp,
            workspaceID: workspace,
            facts: { _ in .init(starter: stamp, workspaceID: UUID()) }
        )
        let other = try elsewhere.runtime.requestScope(
            requesterSessionID: elsewhereEndpoint.sessionID,
            requesterTabID: elsewhereEndpoint.tabID,
            kind: .directChildren(rootSessionID: elsewhereEndpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNil(elsewhere.runtime.standingRuleOffer(for: other), "facts for another workspace offer nothing")
    }

    func testNarrowedApprovalOfANonDirectChildrenRequestExcludesNobody() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let (fixture, endpoint) = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let tree = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID,
            requesterTabID: endpoint.tabID,
            kind: .tree(rootSessionID: endpoint.sessionID),
            capabilities: [.observe, .control],
            guardrails: .init(),
            expiresInSeconds: 3600,
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: tree.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID,
            capabilities: [.observe]
        ).get())
        XCTAssertEqual(fixture.runtime.allLiveScopes().first?.grant.capabilities, [.observe], "control: the approval was narrowed")
        XCTAssertFalse(fixture.runtime.debugIsStandingRuleExcludedForTesting(endpoint.sessionID))
        let direct = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID, requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), reason: nil, idempotencyKey: nil
        ).get()
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: direct.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID, capabilities: [.observe]
        ).get())
        XCTAssertTrue(fixture.runtime.debugIsStandingRuleExcludedForTesting(endpoint.sessionID))
    }

    func testRuleCreationSweepLeavesNonDirectChildrenRequestsPending() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let (fixture, endpoint) = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let other = UUID()
        func treeRequest(_ capabilities: Set<DomainDelegationScopeCapability>) throws -> DelegationScopeRequest {
            try fixture.runtime.requestScope(
                requesterSessionID: other,
                requesterTabID: nil,
                kind: .tree(rootSessionID: other),
                capabilities: capabilities,
                guardrails: .init(),
                expiresInSeconds: 3600,
                reason: nil,
                idempotencyKey: UUID().uuidString
            ).get()
        }
        let first = try treeRequest([.observe])
        let second = try treeRequest([.observe, .control])
        let direct = try fixture.runtime.requestScope(
            requesterSessionID: other, requesterTabID: nil,
            kind: .directChildren(rootSessionID: other, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure], guardrails: .init(),
            expiresInSeconds: 60, reason: nil, idempotencyKey: "sweep-direct"
        ).get()
        XCTAssertNoThrow(try fixture.runtime.approve(requestID: first.id, grantAllForSession: true).get())
        XCTAssertTrue(fixture.runtime.sessionWideApprovals.contains(other))
        XCTAssertEqual(fixture.runtime.request(id: second.id, requesterSessionID: other)?.state, .pending)

        let seed = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID,
            requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: seed.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(fixture.runtime.rules.count, 1)
        XCTAssertNotNil(fixture.runtime.request(id: direct.id, requesterSessionID: other)?.state.scopeID)
        XCTAssertEqual(fixture.runtime.request(id: second.id, requesterSessionID: other)?.state, .pending)
    }

    func testOfferAndRuleCarryTheStartersSelfDeclaredNameNotTheRequesterTitle() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        for (label, expected) in [("Claude Code", "Claude Code" as String?), (nil, nil)] {
            let (fixture, endpoint) = try await presentedFixture(
                stamp: stamp,
                workspaceID: workspace,
                facts: { _ in .init(starter: stamp, workspaceID: workspace, clientLabel: label) }
            )
            func request() throws -> DelegationScopeRequest {
                try fixture.runtime.requestScope(
                    requesterSessionID: endpoint.sessionID,
                    requesterTabID: endpoint.tabID,
                    kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
                    capabilities: [.observe, .control, .restructure],
                    guardrails: .init(),
                    reason: nil,
                    idempotencyKey: UUID().uuidString,
                    requesterTitle: "Team lead title"
                ).get()
            }
            let first = try request()
            XCTAssertEqual(fixture.runtime.standingRuleOffer(for: first)?.clientLabel, expected)
            XCTAssertNoThrow(try fixture.runtime.approve(
                requestID: first.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
                presentedSessionID: endpoint.sessionID, standingRuleOptions: .init()
            ).get())
            XCTAssertEqual(fixture.runtime.rules.first?.clientLabel, expected)
            let second = try request()
            XCTAssertEqual(fixture.runtime.standingRuleOffer(for: second)?.clientLabel, expected, "the replace offer names the starter too")
            XCTAssertNoThrow(try fixture.runtime.approve(
                requestID: second.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
                presentedSessionID: endpoint.sessionID, standingRuleOptions: .init()
            ).get())
            XCTAssertEqual(fixture.runtime.rules.count, 2)
            XCTAssertEqual(Set(fixture.runtime.rules.map(\.clientLabel)), [expected])
        }
    }

    func testStalePresenterApprovesNothingAndCreatesNoRuleBesideLiveControl() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let (fixture, endpoint) = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let request = try fixture.runtime.requestScope(
            requesterSessionID: endpoint.sessionID,
            requesterTabID: endpoint.tabID,
            kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: request.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(fixture.runtime.rules.count, 1)

        for presentation in [
            (endpoint.windowID + 1, endpoint.tabID, endpoint.sessionID),
            (endpoint.windowID, UUID(), endpoint.sessionID),
            (endpoint.windowID, endpoint.tabID, UUID())
        ] {
            let stale = try fixture.runtime.requestScope(
                requesterSessionID: endpoint.sessionID,
                requesterTabID: endpoint.tabID,
                kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure],
                guardrails: .init(),
                reason: nil,
                idempotencyKey: UUID().uuidString
            ).get()
            XCTAssertThrowsError(try fixture.runtime.approve(
                requestID: stale.id,
                presentedWindowID: presentation.0,
                presentedTabID: presentation.1,
                presentedSessionID: presentation.2,
                standingRuleOptions: .init()
            ).get())
        }
        XCTAssertEqual(fixture.runtime.rules.count, 1)
    }

    func testCreationFailurePublishesCauseNamedNoticeAfterCardApproval() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        var live = false
        let (closedFixture, closedEndpoint) = try await presentedFixture(
            stamp: stamp,
            workspaceID: workspace,
            isStarterLive: { _ in live }
        )
        let closed = try closedFixture.runtime.requestScope(
            requesterSessionID: closedEndpoint.sessionID,
            requesterTabID: closedEndpoint.tabID,
            kind: .directChildren(rootSessionID: closedEndpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try closedFixture.runtime.approve(
            requestID: closed.id,
            presentedWindowID: closedEndpoint.windowID,
            presentedTabID: closedEndpoint.tabID,
            presentedSessionID: closedEndpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(closedFixture.runtime.rules.count, 0)
        XCTAssertEqual(closedFixture.runtime.notices.map(\.cause), [.connectionClosed])
        let closedRecordID = try XCTUnwrap(try (XCTUnwrap(
            closedFixture.runtime.request(id: closed.id, requesterSessionID: closedEndpoint.sessionID)
        )).state.scopeID)
        XCTAssertNotNil(closedFixture.runtime.record(id: closedRecordID))
        try closedFixture.runtime.dismissStandingRuleNotice(id: XCTUnwrap(closedFixture.runtime.notices.first).id)
        XCTAssertTrue(closedFixture.runtime.notices.isEmpty)

        let (stampFixture, stampEndpoint) = try await presentedFixture(
            stamp: stamp,
            workspaceID: workspace,
            facts: { _ in nil }
        )
        let noStamp = try stampFixture.runtime.requestScope(
            requesterSessionID: stampEndpoint.sessionID,
            requesterTabID: stampEndpoint.tabID,
            kind: .directChildren(rootSessionID: stampEndpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try stampFixture.runtime.approve(
            requestID: noStamp.id,
            presentedWindowID: stampEndpoint.windowID,
            presentedTabID: stampEndpoint.tabID,
            presentedSessionID: stampEndpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(stampFixture.runtime.notices.map(\.cause), [.noStamp])

        let (changedFixture, changedEndpoint) = try await presentedFixture(
            stamp: stamp,
            workspaceID: workspace,
            facts: { _ in .init(starter: stamp, workspaceID: UUID()) }
        )
        let changed = try changedFixture.runtime.requestScope(
            requesterSessionID: changedEndpoint.sessionID,
            requesterTabID: changedEndpoint.tabID,
            kind: .directChildren(rootSessionID: changedEndpoint.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNoThrow(try changedFixture.runtime.approve(
            requestID: changed.id,
            presentedWindowID: changedEndpoint.windowID,
            presentedTabID: changedEndpoint.tabID,
            presentedSessionID: changedEndpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(changedFixture.runtime.notices.map(\.cause), [.requestChanged])
    }

    func testReplacementRetainsExistingGrantsAndOfferRequiresLiveFullCapabilityRequest() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let (fixture, endpoint) = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        func request(capabilities: Set<DomainDelegationScopeCapability>) throws -> DelegationScopeRequest {
            try fixture.runtime.requestScope(
                requesterSessionID: endpoint.sessionID,
                requesterTabID: endpoint.tabID,
                kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
                capabilities: capabilities,
                guardrails: .init(),
                reason: nil,
                idempotencyKey: UUID().uuidString
            ).get()
        }
        let first = try request(capabilities: [.observe, .control, .restructure])
        XCTAssertNotNil(fixture.runtime.standingRuleOffer(for: first))
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: first.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID,
            standingRuleOptions: .init()
        ).get())
        let original = try XCTUnwrap(fixture.runtime.rules.first)
        let derivedSession = UUID()
        let derived = try fixture.runtime.requestScope(
            requesterSessionID: derivedSession,
            requesterTabID: nil,
            kind: .directChildren(rootSessionID: derivedSession, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            expiresInSeconds: 60,
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertTrue(fixture.runtime.approveWithStandingConsent(requestID: derived.id))
        let derivedScopeID = try XCTUnwrap(try (XCTUnwrap(
            fixture.runtime.request(id: derived.id, requesterSessionID: derivedSession)
        )).state.scopeID)
        let second = try request(capabilities: [.observe, .control, .restructure])
        let offer = try XCTUnwrap(fixture.runtime.standingRuleOffer(for: second))
        XCTAssertTrue(offer.replacesExisting)
        XCTAssertEqual(offer.ruleID, original.id)
        XCTAssertEqual(offer.connectionPrefix.count, 8)
        XCTAssertNoThrow(try fixture.runtime.approve(
            requestID: second.id,
            presentedWindowID: endpoint.windowID,
            presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID,
            standingRuleOptions: .init(maxTeamLeads: 5)
        ).get())
        let replacement = try XCTUnwrap(fixture.runtime.rules.first { $0.id != original.id })
        XCTAssertEqual(fixture.runtime.rules.first { $0.id == original.id }?.replacedBy, replacement.id)
        XCTAssertEqual(fixture.runtime.rules.first { $0.id == original.id }?.ruleGrants, [derivedScopeID])
        XCTAssertEqual(replacement.countedTLs, [endpoint.sessionID])

        let narrowed = try request(capabilities: [.observe, .control])
        XCTAssertNil(fixture.runtime.standingRuleOffer(for: narrowed))
        let noLivePair = try await presentedFixture(
            stamp: stamp,
            workspaceID: workspace,
            isStarterLive: { _ in false }
        )
        let noLive = try noLivePair.0.runtime.requestScope(
            requesterSessionID: noLivePair.1.sessionID,
            requesterTabID: noLivePair.1.tabID,
            kind: .directChildren(rootSessionID: noLivePair.1.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: UUID().uuidString
        ).get()
        XCTAssertNil(noLivePair.0.runtime.standingRuleOffer(for: noLive))
    }
}

private extension DelegationScopeRequest.State {
    var scopeID: UUID? {
        if case let .granted(scopeID) = self { return scopeID }
        return nil
    }
}

@MainActor
final class StandingRuleSettlementTests: XCTestCase {
    func testLiveStampedRequestWouldSettleWithNoCard() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral,
            standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) },
            isStarterLive: { $0 == stamp },
            starterGeneration: { connectionID in connectionID == stamp.connectionID ? stamp.lifecycleGeneration : nil }
        )
        let kind: DomainDelegationScopeKind = .directChildren(rootSessionID: sessionID, workspaceID: workspaceID)
        let control = try runtime.requestScope(
            requesterSessionID: sessionID, requesterTabID: nil, kind: kind,
            capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
            reason: nil, idempotencyKey: "control"
        ).get()
        XCTAssertFalse(runtime.approveWithStandingConsent(requestID: control.id))
        XCTAssertEqual(runtime.request(id: control.id, requesterSessionID: sessionID)?.state, .pending)
        let rule = DelegationStandingRule(
            id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp,
            workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        let witness = try runtime.requestScope(
            requesterSessionID: sessionID, requesterTabID: nil, kind: kind,
            capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
            reason: nil, idempotencyKey: "witness"
        ).get()
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: witness.id))
    }

    func testRuleMintPreservesRequestedGrantAndRecordsProvenance() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let date = Date(timeIntervalSince1970: 1_000_000)
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral,
            now: { date },
            standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) },
            isStarterLive: { $0 == stamp },
            starterGeneration: { _ in stamp.lifecycleGeneration }
        )
        let rule = DelegationStandingRule(
            id: UUID(), createdAt: date, expiresAt: date.addingTimeInterval(3600), starter: stamp,
            workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        let request = try runtime.requestScope(
            requesterSessionID: sessionID, requesterTabID: nil,
            kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID),
            capabilities: [.observe], guardrails: .init(bulkConfirmationThreshold: 7), expiresInSeconds: 60,
            reason: nil, idempotencyKey: "mint"
        ).get()

        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: request.id))
        guard case let .granted(scopeID)? = runtime.request(id: request.id, requesterSessionID: sessionID)?.state,
              let record = runtime.record(id: scopeID)
        else { return XCTFail("the matching rule should mint a grant") }
        XCTAssertEqual(record.grant.kind, request.kind)
        XCTAssertEqual(record.grant.capabilities, request.capabilities)
        XCTAssertEqual(record.grant.guardrails.bulkConfirmationThreshold, 7)
        XCTAssertEqual(record.grant.guardrails.expiresAt, date.addingTimeInterval(60))
        XCTAssertFalse(record.grant.unrestricted)
        XCTAssertEqual(record.grant.origin, .user)
        XCTAssertEqual(runtime.standingRuleProvenance(scopeID: scopeID)?.ruleID, rule.id)
        XCTAssertEqual(runtime.rules.first?.countedTLs, [sessionID])
        XCTAssertEqual(runtime.rules.first?.ruleGrants, [scopeID])
    }

    func testRuleRefusalsLeavePendingBesideMatchingControl() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral,
            standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) },
            isStarterLive: { $0 == stamp },
            starterGeneration: { _ in stamp.lifecycleGeneration }
        )
        let rule = DelegationStandingRule(
            id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp,
            workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        func request(workspace: UUID, key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: sessionID, requesterTabID: nil,
                kind: .directChildren(rootSessionID: sessionID, workspaceID: workspace),
                capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: key
            ).get()
        }
        let matching = try request(workspace: workspaceID, key: "matching")
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: matching.id))
        let otherWorkspace = try request(workspace: UUID(), key: "other-workspace")
        XCTAssertFalse(runtime.approveWithStandingConsent(requestID: otherWorkspace.id))
        XCTAssertEqual(runtime.request(id: otherWorkspace.id, requesterSessionID: sessionID)?.state, .pending)
    }

    func testReissueUsesFreshKeyWithoutConsumingTeamLeadBudget() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        var current = Date(timeIntervalSince1970: 1_000_000)
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral,
            now: { current },
            standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) },
            isStarterLive: { $0 == stamp },
            starterGeneration: { _ in stamp.lifecycleGeneration }
        )
        let rule = DelegationStandingRule(
            id: UUID(), createdAt: current, expiresAt: current.addingTimeInterval(3600), starter: stamp,
            workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil,
            maxTeamLeads: 1
        )
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        func request(_ key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: sessionID, requesterTabID: nil,
                kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID),
                capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: key
            ).get()
        }
        let first = try request("first")
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: first.id))
        guard case let .granted(firstScope)? = runtime.request(id: first.id, requesterSessionID: sessionID)?.state else {
            return XCTFail("initial rule settlement should grant")
        }
        current = current.addingTimeInterval(61)
        XCTAssertFalse(runtime.record(id: firstScope)?.isActive == true, "the first grant expired naturally")
        XCTAssertEqual(try request("first").id, first.id)
        let reissue = try request("reissue")
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: reissue.id))
        XCTAssertEqual(runtime.rules.first?.countedTLs, [sessionID])
        XCTAssertEqual(runtime.rules.first?.ruleGrants.count, 2)
    }

    func testOtherConnectionNoStampNotLiveDeletedAndNilProviderStayPendingBesideControl() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let rule = DelegationStandingRule(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil)
        func request(_ runtime: DelegationScopeRuntime, session: UUID, key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(requesterSessionID: session, requesterTabID: nil, kind: .directChildren(rootSessionID: session, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: key).get()
        }
        let control = DelegationScopeRuntime(persistenceMode: .ephemeral, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { $0 == stamp }, starterGeneration: { _ in stamp.lifecycleGeneration })
        control.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        let controlRequest = try request(control, session: sessionID, key: "control")
        XCTAssertTrue(control.approveWithStandingConsent(requestID: controlRequest.id))
        let cases: [(String, @MainActor (DelegationScopeRequest) -> StandingRuleFacts?, (StarterConnectionStamp) -> Bool, Bool)] = [
            ("other connection", { _ in .init(starter: .init(connectionID: UUID(), lifecycleGeneration: 1), workspaceID: workspaceID) }, { _ in true }, false),
            ("no stamp", { _ in .init(starter: .init(connectionID: UUID(), lifecycleGeneration: 2), workspaceID: workspaceID) }, { _ in true }, false),
            ("not live", { _ in .init(starter: stamp, workspaceID: workspaceID) }, { _ in false }, false),
            ("provider nil", { _ in nil }, { _ in true }, false),
            ("deleted", { _ in .init(starter: stamp, workspaceID: workspaceID) }, { _ in true }, true)
        ]
        for (label, facts, live, deleted) in cases {
            let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, standingRuleFacts: facts, isStarterLive: live, starterGeneration: { _ in stamp.lifecycleGeneration })
            runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
            let candidate = try request(runtime, session: sessionID, key: label)
            if deleted { _ = runtime.revokeAll(involving: sessionID) }
            XCTAssertFalse(runtime.approveWithStandingConsent(requestID: candidate.id), label)
            XCTAssertEqual(runtime.request(id: candidate.id, requesterSessionID: sessionID)?.state, .some(.pending), label)
        }
    }

    func testThresholdExpiryAndFullCountMissesStayPendingBesideControls() throws {
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let date = Date(timeIntervalSince1970: 1_000_000)
        func install(maxTeamLeads: Int = 10, ceiling: Int = 5, lifetime: TimeInterval = 3600) -> DelegationScopeRuntime {
            let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, now: { date }, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { _ in true }, starterGeneration: { _ in stamp.lifecycleGeneration })
            runtime.debugInstallStandingRuleForTesting(.init(id: UUID(), createdAt: date, expiresAt: date.addingTimeInterval(lifetime), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil, maxTeamLeads: maxTeamLeads, bulkThresholdCeiling: ceiling), issuedScopeID: UUID())
            return runtime
        }
        func request(_ runtime: DelegationScopeRuntime, _ session: UUID, _ key: String, threshold: Int = 5, expiry: Int = 60) throws -> DelegationScopeRequest {
            try runtime.requestScope(requesterSessionID: session, requesterTabID: nil, kind: .directChildren(rootSessionID: session, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(bulkConfirmationThreshold: threshold), expiresInSeconds: expiry, reason: nil, idempotencyKey: key).get()
        }
        let thresholdRuntime = install()
        let thresholdControl = try request(thresholdRuntime, UUID(), "threshold-control")
        XCTAssertTrue(thresholdRuntime.approveWithStandingConsent(requestID: thresholdControl.id))
        let thresholdMiss = try request(thresholdRuntime, UUID(), "threshold-miss", threshold: 6)
        XCTAssertFalse(thresholdRuntime.approveWithStandingConsent(requestID: thresholdMiss.id))
        XCTAssertEqual(thresholdRuntime.request(id: thresholdMiss.id, requesterSessionID: thresholdMiss.requesterSessionID)?.state, .pending)
        let expiryRuntime = install(lifetime: 60)
        let expiryControl = try request(expiryRuntime, UUID(), "expiry-control", expiry: 60)
        XCTAssertTrue(expiryRuntime.approveWithStandingConsent(requestID: expiryControl.id))
        let expiryMiss = try request(expiryRuntime, UUID(), "expiry-miss", expiry: 61)
        XCTAssertFalse(expiryRuntime.approveWithStandingConsent(requestID: expiryMiss.id))
        XCTAssertEqual(expiryRuntime.request(id: expiryMiss.id, requesterSessionID: expiryMiss.requesterSessionID)?.state, .pending)
        let countRuntime = install(maxTeamLeads: 1)
        let first = try request(countRuntime, UUID(), "count-control")
        XCTAssertTrue(countRuntime.approveWithStandingConsent(requestID: first.id))
        let countMiss = try request(countRuntime, UUID(), "count-miss")
        XCTAssertFalse(countRuntime.approveWithStandingConsent(requestID: countMiss.id))
        XCTAssertEqual(countRuntime.request(id: countMiss.id, requesterSessionID: countMiss.requesterSessionID)?.state, .pending)
    }

    func testOutOfSetCapabilityIsInvalidWithAndWithoutRule() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let outside = try XCTUnwrap(DomainDelegationScopeCapability.allCases.first { !DomainDelegationScopeCapability.directChildrenPermitted.contains($0) })
        for installRule in [false, true] {
            let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral)
            if installRule { runtime.debugInstallStandingRuleForTesting(.init(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil), issuedScopeID: UUID()) }
            let result = runtime.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID), capabilities: [.observe, outside], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: installRule ? "with" : "without")
            guard case .failure(.invalid) = result else { return XCTFail("out-of-set capability should be invalid") }
            let valid = runtime.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: installRule ? "with-valid" : "without-valid")
            guard case .success = valid else { return XCTFail("control: an in-set capability should be accepted (rule installed: \(installRule))") }
        }
    }

    func testExistingSufficientGrantIsReusedBeforeRuleBudget() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { _ in true }, starterGeneration: { _ in stamp.lifecycleGeneration })
        let rule = DelegationStandingRule(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil)
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        let kind: DomainDelegationScopeKind = .directChildren(rootSessionID: sessionID, workspaceID: workspaceID)
        let existingRequest = try runtime.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: kind, capabilities: [.observe], guardrails: .init(), expiresInSeconds: 120, reason: nil, idempotencyKey: "existing").get()
        let existing = try runtime.approve(requestID: existingRequest.id).get()
        let candidate = try runtime.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: kind, capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: "candidate").get()
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: candidate.id))
        XCTAssertEqual(runtime.request(id: candidate.id, requesterSessionID: sessionID)?.state, .granted(scopeID: existing.id))
        XCTAssertEqual(runtime.rules.first?.countedTLs, [])
        XCTAssertEqual(runtime.rules.first?.ruleGrants, [])
    }

    func testFullAccessTogglePreservesRuleGrantAndGrantAllRefusesDirectChildren() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { _ in true }, starterGeneration: { _ in stamp.lifecycleGeneration })
        let rule = DelegationStandingRule(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil)
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        let request = try runtime.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: "rule").get()
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: request.id))
        let ruleGrant = try XCTUnwrap(runtime.rules.first?.ruleGrants.first)
        runtime.isGlobalAutoApproveEnabled = { true }
        _ = runtime.ensureGlobalAutoApproveScope(for: UUID())
        runtime.isGlobalAutoApproveEnabled = { false }
        runtime.reconcileGlobalAutoApprove()
        XCTAssertTrue(runtime.liveScopes(grantedTo: sessionID).contains { $0.id == ruleGrant })
        XCTAssertEqual(runtime.rules.count, 1)
        let target = UUID()
        let pending = try runtime.requestScope(requesterSessionID: target, requesterTabID: nil, kind: .directChildren(rootSessionID: target, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: "grant-all").get()
        XCTAssertEqual(runtime.approve(requestID: pending.id, grantAllForSession: true), .failure(.approvalExceedsRequest))
    }

    func testSeedTeamLeadReissuesAtFullCountWithFreshKey() throws {
        let seed = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        var current = Date(timeIntervalSince1970: 1_000_000)
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, now: { current }, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { _ in true }, starterGeneration: { _ in stamp.lifecycleGeneration })
        let rule = DelegationStandingRule(id: UUID(), createdAt: current, expiresAt: current.addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [seed], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil, maxTeamLeads: 1)
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        func request(_ key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(requesterSessionID: seed, requesterTabID: nil, kind: .directChildren(rootSessionID: seed, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: key).get()
        }
        let first = try request("seed-first")
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: first.id))
        guard case let .granted(scopeID)? = runtime.request(id: first.id, requesterSessionID: seed)?.state else { return XCTFail("seed should settle") }
        current = current.addingTimeInterval(61)
        XCTAssertFalse(runtime.record(id: scopeID)?.isActive == true, "the first grant expired naturally")
        let reissue = try request("seed-reissue")
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: reissue.id))
        XCTAssertEqual(runtime.rules.first?.countedTLs, [seed])
    }

    func testDuplicateRuleMintLeavesPendingAndBookkeepingUnchangedBesideControl() throws {
        let sessionID = UUID()
        let workspaceID = UUID()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let duplicate = UUID()
        let control = DelegationScopeRuntime(persistenceMode: .ephemeral, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { _ in true }, starterGeneration: { _ in stamp.lifecycleGeneration })
        let controlRule = DelegationStandingRule(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil)
        control.debugInstallStandingRuleForTesting(controlRule, issuedScopeID: UUID())
        let controlRequest = try control.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: "control").get()
        XCTAssertTrue(control.approveWithStandingConsent(requestID: controlRequest.id))
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral, makeUUID: { duplicate }, standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspaceID) }, isStarterLive: { _ in true }, starterGeneration: { _ in stamp.lifecycleGeneration })
        let installed = try runtime.requestScope(requesterSessionID: UUID(), requesterTabID: nil, kind: .tree(rootSessionID: UUID()), capabilities: [.observe], guardrails: .init(), reason: nil, idempotencyKey: "installed").get()
        _ = try runtime.approve(requestID: installed.id).get()
        let rule = DelegationStandingRule(id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(3600), starter: stamp, workspaceID: workspaceID, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil)
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: UUID())
        let request = try runtime.requestScope(requesterSessionID: sessionID, requesterTabID: nil, kind: .directChildren(rootSessionID: sessionID, workspaceID: workspaceID), capabilities: [.observe], guardrails: .init(), expiresInSeconds: 60, reason: nil, idempotencyKey: "duplicate").get()
        XCTAssertFalse(runtime.approveWithStandingConsent(requestID: request.id))
        XCTAssertEqual(runtime.request(id: request.id, requesterSessionID: sessionID)?.state, .pending)
        XCTAssertEqual(runtime.rules.first?.countedTLs, [])
        XCTAssertEqual(runtime.rules.first?.ruleGrants, [])
        XCTAssertNil(runtime.standingRuleProvenance(scopeID: duplicate))
    }
}

@MainActor
final class StandingRuleSweepTests: XCTestCase {
    func testPresentedRuleCreationWouldSweepMatchingPendingRequests() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        func makeRequests(_ runtime: DelegationScopeRuntime, endpoint: DomainAgentSessionLinkEndpointIdentity) throws -> (DelegationScopeRequest, DelegationScopeRequest, DelegationScopeRequest) {
            let pendingOneSession = UUID()
            let pendingOne = try runtime.requestScope(
                requesterSessionID: pendingOneSession,
                requesterTabID: nil,
                kind: .directChildren(rootSessionID: pendingOneSession, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure],
                guardrails: .init(),
                expiresInSeconds: 60,
                reason: nil,
                idempotencyKey: "one"
            ).get()
            let pendingTwoSession = UUID()
            let pendingTwo = try runtime.requestScope(
                requesterSessionID: pendingTwoSession,
                requesterTabID: nil,
                kind: .directChildren(rootSessionID: pendingTwoSession, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure],
                guardrails: .init(),
                expiresInSeconds: 60,
                reason: nil,
                idempotencyKey: "two"
            ).get()
            let presented = try runtime.requestScope(
                requesterSessionID: endpoint.sessionID,
                requesterTabID: endpoint.tabID,
                kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure],
                guardrails: .init(),
                expiresInSeconds: 60,
                reason: nil,
                idempotencyKey: "presented"
            ).get()
            return (pendingOne, pendingTwo, presented)
        }
        let controlPair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let controlRuntime = controlPair.0.runtime
        let controlEndpoint = controlPair.1
        let control = try makeRequests(controlRuntime, endpoint: controlEndpoint)
        XCTAssertNoThrow(try controlRuntime.approve(requestID: control.2.id, presentedWindowID: controlEndpoint.windowID, presentedTabID: controlEndpoint.tabID, presentedSessionID: controlEndpoint.sessionID).get())
        XCTAssertEqual(controlRuntime.request(id: control.0.id, requesterSessionID: control.0.requesterSessionID)?.state, .pending)
        XCTAssertEqual(controlRuntime.request(id: control.1.id, requesterSessionID: control.1.requesterSessionID)?.state, .pending)
        let witnessPair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let witnessRuntime = witnessPair.0.runtime
        let witnessEndpoint = witnessPair.1
        let witness = try makeRequests(witnessRuntime, endpoint: witnessEndpoint)
        XCTAssertNoThrow(try witnessRuntime.approve(requestID: witness.2.id, presentedWindowID: witnessEndpoint.windowID, presentedTabID: witnessEndpoint.tabID, presentedSessionID: witnessEndpoint.sessionID, standingRuleOptions: .init()).get())
        guard case .granted? = witnessRuntime.request(id: witness.0.id, requesterSessionID: witness.0.requesterSessionID)?.state,
              case .granted? = witnessRuntime.request(id: witness.1.id, requesterSessionID: witness.1.requesterSessionID)?.state
        else {
            XCTFail("pending requests should be granted by the standing-rule sweep")
            return
        }
    }

    private struct Rig {
        let runtime: DelegationScopeRuntime
        let endpoint: DomainAgentSessionLinkEndpointIdentity
        let workspace: UUID
        let seed: DelegationScopeRequest
    }

    private func makeRig(
        stamp: StarterConnectionStamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1),
        isStarterLive: ((StarterConnectionStamp) -> Bool)? = nil
    ) async throws -> Rig {
        let workspace = UUID()
        let pair = try await presentedFixture(stamp: stamp, workspaceID: workspace, isStarterLive: isStarterLive)
        let seed = try pair.0.runtime.requestScope(
            requesterSessionID: pair.1.sessionID, requesterTabID: pair.1.tabID,
            kind: .directChildren(rootSessionID: pair.1.sessionID, workspaceID: workspace),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
            reason: nil, idempotencyKey: "seed"
        ).get()
        return Rig(runtime: pair.0.runtime, endpoint: pair.1, workspace: workspace, seed: seed)
    }

    @discardableResult
    private func pending(_ rig: Rig, session: UUID = UUID(), key: String, expiry: Int = 60) throws -> DelegationScopeRequest {
        try rig.runtime.requestScope(
            requesterSessionID: session, requesterTabID: nil,
            kind: .directChildren(rootSessionID: session, workspaceID: rig.workspace),
            capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: expiry,
            reason: nil, idempotencyKey: key
        ).get()
    }

    private func approveSeed(_ rig: Rig, options: StandingRuleOptions? = nil) {
        XCTAssertNoThrow(try rig.runtime.approve(
            requestID: rig.seed.id, presentedWindowID: rig.endpoint.windowID, presentedTabID: rig.endpoint.tabID,
            presentedSessionID: rig.endpoint.sessionID, standingRuleOptions: options
        ).get())
    }

    private func isGranted(_ runtime: DelegationScopeRuntime, _ request: DelegationScopeRequest) -> Bool {
        if case .granted? = runtime.request(id: request.id, requesterSessionID: request.requesterSessionID)?.state { return true }
        return false
    }

    private func isPending(_ runtime: DelegationScopeRuntime, _ request: DelegationScopeRequest) -> Bool {
        runtime.request(id: request.id, requesterSessionID: request.requesterSessionID)?.state == .pending
    }

    func testSweepSettlesOldestFirstUntilTheCountAndLeavesTheRestAsCards() async throws {
        let control = try await makeRig()
        let controlRequests = try (0 ..< 6).map { try pending(control, key: "c\($0)") }
        approveSeed(control)
        XCTAssertEqual(controlRequests.count { isPending(control.runtime, $0) }, 6)
        XCTAssertEqual(control.runtime.rules.count, 0)

        let witness = try await makeRig()
        let requests = try (0 ..< 6).map { try pending(witness, key: "w\($0)") }
        approveSeed(witness, options: StandingRuleOptions(maxTeamLeads: 5))
        XCTAssertEqual(requests.prefix(4).map { isGranted(witness.runtime, $0) }, [true, true, true, true])
        XCTAssertEqual(requests.suffix(2).map { isPending(witness.runtime, $0) }, [true, true])
        let rule = try XCTUnwrap(witness.runtime.rules.first)
        XCTAssertEqual(rule.countedTLs.count, 5)
        XCTAssertEqual(rule.ruleGrants.count, 4)
    }

    func testCountedTeamLeadStillSettlesAfterTheCountFillsBesideUncountedControl() async throws {
        let rig = try await makeRig()
        let others = try (0 ..< 5).map { try pending(rig, key: "o\($0)") }
        let counted = try pending(rig, session: rig.endpoint.sessionID, key: "again", expiry: 120)
        approveSeed(rig, options: StandingRuleOptions(maxTeamLeads: 5))
        XCTAssertEqual(others.prefix(4).map { isGranted(rig.runtime, $0) }, [true, true, true, true])
        XCTAssertTrue(isPending(rig.runtime, others[4]), "uncounted team lead is refused once the count is full")
        XCTAssertTrue(isGranted(rig.runtime, counted), "counted team lead still settles after the count is full")
        XCTAssertEqual(rig.runtime.rules.first?.countedTLs.count, 5)
    }

    func testRequestRecordedDuringThePassIsOutsideTheSnapshotBesideSettledControl() async throws {
        let rig = try await makeRig()
        let first = try pending(rig, key: "first")
        let second = try pending(rig, key: "second")
        var recorded: DelegationScopeRequest?
        let runtime = rig.runtime
        runtime.liveScopesDidChange = { [self] in
            guard recorded == nil, runtime.rules.first?.ruleGrants.isEmpty == false else { return }
            recorded = try? pending(rig, key: "during")
        }
        approveSeed(rig, options: .init())
        let late = try XCTUnwrap(recorded)
        XCTAssertTrue(isGranted(runtime, first))
        XCTAssertTrue(isGranted(runtime, second))
        XCTAssertTrue(isPending(runtime, late), "a request recorded during the pass is not swept")
        runtime.liveScopesDidChange = nil
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: late.id), "the same request settles through the ordinary path")
    }

    func testReentrantDidChangeIsSurvivedAndKeepsTheCountExact() async throws {
        let rig = try await makeRig()
        let others = try (0 ..< 4).map { try pending(rig, key: "o\($0)") }
        var reentrant: DelegationScopeRequest?
        let runtime = rig.runtime
        runtime.liveScopesDidChange = { [self] in
            guard reentrant == nil, runtime.rules.first?.ruleGrants.isEmpty == false else { return }
            reentrant = try? pending(rig, key: "reentrant")
            if let reentrant { runtime.approveWithStandingConsent(requestID: reentrant.id) }
        }
        approveSeed(rig, options: StandingRuleOptions(maxTeamLeads: 5))
        let late = try XCTUnwrap(reentrant)
        XCTAssertTrue(isGranted(runtime, late))
        XCTAssertEqual(others.map { isGranted(runtime, $0) }, [true, true, true, false])
        XCTAssertTrue(isPending(runtime, others[3]))
        let rule = try XCTUnwrap(runtime.rules.first)
        XCTAssertEqual(rule.countedTLs.count, 5)
        XCTAssertEqual(rule.ruleGrants.count, 4)
    }

    func testTabReboundToAnotherQualifyingTeamLeadIsNotSweptBesideUnreboundControl() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        var windows: [WindowState] = []
        let runtime = DelegationScopeRuntime(
            persistenceMode: .ephemeral,
            windows: { windows },
            standingRuleFacts: { WindowStatesManager.shared.standingRuleFacts(for: $0, in: windows) },
            isStarterLive: { $0 == stamp },
            starterGeneration: { $0 == stamp.connectionID ? stamp.lifecycleGeneration : nil }
        )
        let fixture = SessionAdminScopeLifecycleTests.Fixture(runtime: runtime)
        windows = [fixture.window]
        addTeardownBlock { @MainActor in await fixture.window.tearDown() }
        let seedSession = try await fixture.installController(startedBy: stamp)
        let seedEndpoint = try XCTUnwrap(fixture.endpoint)
        func request(_ endpoint: DomainAgentSessionLinkEndpointIdentity, _ key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: endpoint.sessionID, requesterTabID: endpoint.tabID,
                kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: endpoint.workspaceID),
                capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
                reason: nil, idempotencyKey: key
            ).get()
        }
        let seed = try request(seedEndpoint, "seed")
        _ = seedSession
        let reboundTab = UUID()
        let controlTab = UUID()
        _ = try await installController(in: fixture.window, tabID: reboundTab, stamp: stamp)
        _ = try await installController(in: fixture.window, tabID: controlTab, stamp: stamp)
        let reboundEndpoint = try XCTUnwrap(fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: reboundTab))
        let controlEndpoint = try XCTUnwrap(fixture.window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: controlTab))
        let rebound = try request(reboundEndpoint, "rebound")
        let control = try request(controlEndpoint, "control")
        XCTAssertNotNil(runtime.standingRuleFacts(for: rebound))
        _ = try await installController(in: fixture.window, tabID: reboundTab, stamp: stamp)
        XCTAssertNil(runtime.standingRuleFacts(for: rebound))
        XCTAssertNotNil(runtime.standingRuleFacts(for: control))

        XCTAssertNoThrow(try runtime.approve(
            requestID: seed.id, presentedWindowID: seedEndpoint.windowID, presentedTabID: seedEndpoint.tabID,
            presentedSessionID: seedEndpoint.sessionID, standingRuleOptions: .init()
        ).get())
        XCTAssertTrue(isGranted(runtime, control), "the unrebound qualifying controller is swept")
        XCTAssertTrue(isPending(runtime, rebound), "a tab now showing another controller is not swept")
    }

    func testLivenessIsSampledPerCandidateAndSettledOnesStayGranted() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        var calls = 0
        var failAfter = Int.max
        let rig = try await makeRig(stamp: stamp) { candidate in
            calls += 1
            return candidate == stamp && calls <= failAfter
        }
        let requests = try (0 ..< 5).map { try pending(rig, key: "o\($0)") }
        failAfter = 3
        approveSeed(rig, options: .init())
        XCTAssertEqual(requests.map { isGranted(rig.runtime, $0) }, [true, true, false, false, false])
        XCTAssertEqual(requests.suffix(3).map { isPending(rig.runtime, $0) }, [true, true, true])
        XCTAssertEqual(calls, 1 + 5, "one creation sample, then one per candidate")

        calls = 0
        failAfter = Int.max
        let control = try await makeRig(stamp: stamp) { candidate in
            calls += 1
            return candidate == stamp && calls <= failAfter
        }
        let controlRequests = try (0 ..< 5).map { try pending(control, key: "c\($0)") }
        approveSeed(control, options: .init())
        XCTAssertEqual(controlRequests.map { isGranted(control.runtime, $0) }, [true, true, true, true, true])
    }

    func testSixteenRequestersWithFourPendingEachSettleExactlyTheCap() async throws {
        let rig = try await makeRig()
        let sessions = (0 ..< 16).map { _ in UUID() }
        let requests = try sessions.enumerated().map { index, session in
            try (0 ..< 4).map { try pending(rig, session: session, key: "r\(index)-\($0)") }
        }
        let clock = ContinuousClock()
        let started = clock.now
        approveSeed(rig, options: .init())
        let elapsed = clock.now - started
        print("STANDING_RULE_SWEEP_DURATION 64 pending, cap 10: \(elapsed)")
        let rule = try XCTUnwrap(rig.runtime.rules.first)
        XCTAssertEqual(rule.countedTLs.count, StandingRuleOptions.defaultTeamLeads)
        let settledSessions = Set(requests.joined().filter { isGranted(rig.runtime, $0) }.map(\.requesterSessionID))
        XCTAssertEqual(settledSessions, Set(sessions.prefix(StandingRuleOptions.defaultTeamLeads - 1)))
        XCTAssertEqual(requests.joined().count { isGranted(rig.runtime, $0) }, (StandingRuleOptions.defaultTeamLeads - 1) * 4)
        XCTAssertEqual(requests.joined().count { isPending(rig.runtime, $0) }, (16 - StandingRuleOptions.defaultTeamLeads + 1) * 4)
    }

    private func installController(
        in window: WindowState, tabID: UUID, stamp: StarterConnectionStamp
    ) async throws -> AgentModeViewModel.TabSession {
        let workspaceID = try XCTUnwrap(window.workspaceManager.activeWorkspaceID)
        let index = try XCTUnwrap(window.workspaceManager.workspaces.firstIndex { $0.id == workspaceID })
        let sessionID = UUID()
        if let tabIndex = window.workspaceManager.workspaces[index].composeTabs.firstIndex(where: { $0.id == tabID }) {
            window.workspaceManager.workspaces[index].composeTabs[tabIndex].activeAgentSessionID = sessionID
        } else {
            window.workspaceManager.workspaces[index].composeTabs.append(
                ComposeTabState(id: tabID, name: "Controller", activeAgentSessionID: sessionID)
            )
        }
        let session = AgentModeViewModel.TabSession(tabID: tabID)
        window.agentModeViewModel.test_installLiveSession(session)
        _ = try XCTUnwrap(window.agentModeViewModel.test_installPersistentSessionBinding(sessionID: sessionID, on: session))
        let registration = await AgentRunSessionStore.register(sessionID: sessionID)
        session.mcpControlContext = .init(
            sessionID: sessionID, activationID: UUID(), registration: registration,
            currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
            originatingConnectionID: stamp.connectionID, startedBy: stamp,
            interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: stamp.connectionID),
            suppressUserNotifications: true, forceAutoEditEnabled: false,
            autoEditEnabledBeforeOverride: false, taskLabelKind: .pair
        )
        return session
    }
}

@MainActor
final class StandingRuleRevocationTests: XCTestCase {
    func testStopAndRevokeWouldRevokeOnlyRuleGrants() throws {
        let runtime = DelegationScopeRuntime(persistenceMode: .ephemeral)
        let ruleSession = UUID()
        let cardSession = UUID()
        let workspace = UUID()
        let kind: DomainDelegationScopeKind = .directChildren(rootSessionID: ruleSession, workspaceID: workspace)
        let ruleRequest = try runtime.requestScope(
            requesterSessionID: ruleSession,
            requesterTabID: nil,
            kind: kind,
            capabilities: [.observe],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: "rule"
        ).get()
        let ruleGrant = try runtime.approve(requestID: ruleRequest.id).get()
        let cardRequest = try runtime.requestScope(
            requesterSessionID: cardSession,
            requesterTabID: nil,
            kind: .directChildren(rootSessionID: cardSession, workspaceID: workspace),
            capabilities: [.observe],
            guardrails: .init(),
            reason: nil,
            idempotencyKey: "card"
        ).get()
        let cardGrant = try runtime.approve(requestID: cardRequest.id).get()
        let rule = DelegationStandingRule(
            id: UUID(),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60),
            starter: .init(connectionID: UUID(), lifecycleGeneration: 1),
            workspaceID: workspace,
            countedTLs: [],
            ruleGrants: [ruleGrant.id],
            stoppedAt: nil,
            replacedBy: nil,
            closedAt: nil
        )
        runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: ruleGrant.id)
        runtime.stopStandingRule(id: rule.id, revokeIssuedGrants: true)
        XCTAssertFalse(runtime.liveScopes(grantedTo: ruleSession).contains { $0.id == ruleGrant.id }, "rule grant revoked")
        XCTAssertTrue(runtime.liveScopes(grantedTo: cardSession).contains { $0.id == cardGrant.id }, "unrelated card grant stays live")
    }

    @MainActor
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000_000)
    }

    @MainActor
    private final class StarterSample {
        var generation: UInt64? = 1
        var live = true
    }

    private struct Rig {
        let runtime: DelegationScopeRuntime
        let clock: Clock
        let sample: StarterSample
        let stamp: StarterConnectionStamp
        let workspace: UUID
    }

    private let allThree: Set<DomainDelegationScopeCapability> = [.observe, .control, .restructure]

    private func makeRig(persistenceMode: DelegationScopeRuntime.PersistenceMode = .ephemeral) -> Rig {
        let clock = Clock()
        let sample = StarterSample()
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let runtime = DelegationScopeRuntime(
            persistenceMode: persistenceMode,
            now: { MainActor.assumeIsolated { clock.date } },
            standingRuleFacts: { _ in .init(starter: stamp, workspaceID: workspace) },
            isStarterLive: { candidate in MainActor.assumeIsolated { sample.live && candidate == stamp } },
            starterGeneration: { id in MainActor.assumeIsolated { id == stamp.connectionID ? sample.generation : nil } },
            notifyCatalogChanged: { _ in }
        )
        return Rig(runtime: runtime, clock: clock, sample: sample, stamp: stamp, workspace: workspace)
    }

    @discardableResult
    private func installRule(
        _ rig: Rig, lifetime: TimeInterval = 7200, counted: Set<UUID> = [], grants: Set<UUID> = []
    ) -> DelegationStandingRule {
        let rule = DelegationStandingRule(
            id: UUID(), createdAt: rig.clock.date, expiresAt: rig.clock.date.addingTimeInterval(lifetime),
            starter: rig.stamp, workspaceID: rig.workspace, countedTLs: counted, ruleGrants: grants,
            stoppedAt: nil, replacedBy: nil, closedAt: nil
        )
        rig.runtime.debugInstallStandingRuleForTesting(rule, issuedScopeID: grants.first ?? UUID())
        return rule
    }

    private func request(
        _ rig: Rig, _ session: UUID, _ key: String, expiry: Int = 60, workspace: UUID? = nil
    ) throws -> DelegationScopeRequest {
        try rig.runtime.requestScope(
            requesterSessionID: session, requesterTabID: nil,
            kind: .directChildren(rootSessionID: session, workspaceID: workspace ?? rig.workspace),
            capabilities: allThree, guardrails: .init(), expiresInSeconds: expiry, reason: nil, idempotencyKey: key
        ).get()
    }

    private func cardGrant(_ rig: Rig, _ session: UUID, _ key: String) throws -> DomainDelegationScopeRecord {
        try rig.runtime.approve(requestID: request(rig, session, key, expiry: 3600).id).get()
    }

    private func isPending(_ rig: Rig, _ request: DelegationScopeRequest) -> Bool {
        rig.runtime.request(id: request.id, requesterSessionID: request.requesterSessionID)?.state == .pending
    }

    private func isLive(_ rig: Rig, _ scope: DomainDelegationScopeRecord) -> Bool {
        rig.runtime.record(id: scope.id)?.isActive == true
    }

    private func scopeID(_ rig: Rig, _ request: DelegationScopeRequest) -> UUID? {
        rig.runtime.request(id: request.id, requesterSessionID: request.requesterSessionID)?.state.scopeID
    }

    func testReadPathsPublishNothingWhileARuleIsInstalledAndARealChangePublishesOnce() throws {
        let rig = makeRig()
        let holder = UUID()
        let held = try cardGrant(rig, holder, "held")
        let rule = installRule(rig, lifetime: 600, grants: [held.id])
        var emissions = 0
        var ruleValues = 0
        let willChange = rig.runtime.objectWillChange.sink { emissions += 1 }
        let ruleChanges = rig.runtime.$rules.dropFirst().sink { _ in ruleValues += 1 }
        for _ in 0 ..< 3 {
            XCTAssertEqual(rig.runtime.liveScopes(grantedTo: holder).count, 1)
            XCTAssertEqual(rig.runtime.allLiveScopes().count, 1)
        }
        rig.clock.date = rig.clock.date.addingTimeInterval(30)
        XCTAssertEqual(rig.runtime.liveScopes(grantedTo: holder).count, 1)
        XCTAssertEqual(rig.runtime.rules.count, 1)
        XCTAssertEqual(emissions, 0, "reads that reach expiry and rule evaluation publish nothing")
        XCTAssertEqual(ruleValues, 0)

        rig.runtime.stopStandingRule(id: rule.id, revokeIssuedGrants: false)
        XCTAssertEqual(ruleValues, 1, "a real change publishes the rule list once")
        XCTAssertGreaterThan(emissions, 0)
        let afterChange = emissions
        XCTAssertEqual(rig.runtime.liveScopes(grantedTo: holder).count, 1)
        XCTAssertEqual(emissions, afterChange, "reads after the change publish nothing")
        withExtendedLifetime((willChange, ruleChanges)) {}
    }

    func testNonDirectChildrenDecisionsNeverExcludeTheirRequester() throws {
        let rig = makeRig()
        installRule(rig)
        func tree(_ session: UUID, _ key: String) throws -> DelegationScopeRequest {
            try rig.runtime.requestScope(
                requesterSessionID: session, requesterTabID: nil, kind: .tree(rootSessionID: session),
                capabilities: [.observe], guardrails: .init(), expiresInSeconds: 3600, reason: nil, idempotencyKey: key
            ).get()
        }
        let deniedDirect = UUID(), deniedTree = UUID(), revokedDirect = UUID(), revokedTree = UUID()
        try rig.runtime.deny(requestID: request(rig, deniedDirect, "deny-direct").id)
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(deniedDirect), "control: a denied direct-children request excludes")
        try rig.runtime.deny(requestID: tree(deniedTree, "deny-tree").id)
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(deniedTree))

        try rig.runtime.revoke(scopeID: cardGrant(rig, revokedDirect, "revoke-direct").id)
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(revokedDirect), "control: a revoked direct-children grant excludes")
        let treeGrant = try rig.runtime.approve(requestID: tree(revokedTree, "revoke-tree").id).get()
        rig.runtime.revoke(scopeID: treeGrant.id)
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(revokedTree))
        let releasedDirect = UUID()
        let directGrant = try cardGrant(rig, releasedDirect, "release-direct")
        XCTAssertNoThrow(try rig.runtime.release(scopeID: directGrant.id, caller: .agentSession(releasedDirect)).get())
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(releasedDirect))
        let released = UUID()
        let releasedGrant = try rig.runtime.approve(requestID: tree(released, "release-tree").id).get()
        XCTAssertNoThrow(try rig.runtime.release(scopeID: releasedGrant.id, caller: .agentSession(released)).get())
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(released))
    }

    func testStopKeepsGrantsAndNeverDecidesAPendingCard() throws {
        let rig = makeRig()
        let rule = installRule(rig)
        let first = UUID(), second = UUID(), third = UUID(), foreign = UUID()
        let beforeStop = try request(rig, first, "first")
        XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: beforeStop.id), "control: the active rule settles")
        let firstGrant = try XCTUnwrap(scopeID(rig, beforeStop))
        let card = try request(rig, foreign, "foreign", workspace: UUID())
        XCTAssertFalse(rig.runtime.approveWithStandingConsent(requestID: card.id))

        rig.runtime.stopStandingRule(id: rule.id, revokeIssuedGrants: false)
        rig.runtime.stopStandingRule(id: rule.id, revokeIssuedGrants: false)

        XCTAssertNotNil(rig.runtime.rules.first?.stoppedAt, "the stopped rule stays listed while its grant is live")
        XCTAssertTrue(rig.runtime.record(id: firstGrant)?.isActive == true, "stop keeps issued grants")
        XCTAssertTrue(isPending(rig, card), "stop never decides a pending card")
        let afterStop = try request(rig, second, "second")
        XCTAssertFalse(rig.runtime.approveWithStandingConsent(requestID: afterStop.id), "a stopped rule settles nothing new")
        XCTAssertTrue(isPending(rig, afterStop))
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(first), "stop alone excludes nobody")
        XCTAssertTrue(try isPending(rig, request(rig, third, "third")))
    }

    func testStopAndRevokeRevokesExactlyTheRuleGrants() throws {
        let rig = makeRig()
        let seedTL = UUID(), ruleTL = UUID(), unrelatedTL = UUID()
        let seed = try cardGrant(rig, seedTL, "seed")
        let ruleTLTree = try rig.runtime.approve(requestID: rig.runtime.requestScope(
            requesterSessionID: ruleTL, requesterTabID: nil, kind: .tree(rootSessionID: ruleTL),
            capabilities: [.observe], guardrails: .init(), expiresInSeconds: 3600, reason: nil, idempotencyKey: "tree"
        ).get().id).get()
        let unrelated = try cardGrant(rig, unrelatedTL, "unrelated")
        let rule = installRule(rig, counted: [seedTL])
        let issued = try request(rig, ruleTL, "rule")
        XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: issued.id), "control: the rule mints a grant")
        let ruleGrantID = try XCTUnwrap(scopeID(rig, issued))
        XCTAssertEqual(rig.runtime.rules.first?.ruleGrants, [ruleGrantID])

        rig.runtime.stopStandingRule(id: rule.id, revokeIssuedGrants: true)

        XCTAssertFalse(rig.runtime.record(id: ruleGrantID)?.isActive == true, "the rule grant is revoked")
        XCTAssertTrue(isLive(rig, seed), "the seed card grant survives")
        XCTAssertTrue(isLive(rig, ruleTLTree), "another grant of the same team lead survives")
        XCTAssertTrue(isLive(rig, unrelated), "an unrelated card grant survives")
        XCTAssertTrue(rig.runtime.rules.isEmpty, "the stopped rule has no live rule grant left")
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(ruleTL))
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(seedTL))
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(unrelatedTL))
    }

    func testEachExclusionHookBlocksAFreshKeyRequestWhileHumanApprovalStillWorks() throws {
        enum Hook: String, CaseIterable { case deny, revoke, release, stopAndRevoke }
        for hook in Hook.allCases {
            let rig = makeRig()
            let rule = installRule(rig)
            let control = UUID(), subject = UUID(), laterControl = UUID()
            let controlRequest = try request(rig, control, "control")
            XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: controlRequest.id), "\(hook): control team lead settles")
            XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(subject), "\(hook): not yet excluded")

            switch hook {
            case .deny:
                try rig.runtime.deny(requestID: request(rig, subject, "first").id)
            case .revoke:
                try rig.runtime.revoke(scopeID: cardGrant(rig, subject, "first").id)
            case .release:
                let granted = try cardGrant(rig, subject, "first")
                XCTAssertNoThrow(try rig.runtime.release(scopeID: granted.id, caller: .agentSession(subject)).get())
            case .stopAndRevoke:
                let issued = try request(rig, subject, "first")
                XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: issued.id), "\(hook): subject first settles under the rule")
                rig.runtime.stopStandingRule(id: rule.id, revokeIssuedGrants: true)
                installRule(rig)
            }

            XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(subject), "\(hook): excluded")
            let fresh = try request(rig, subject, "fresh-\(hook.rawValue)")
            XCTAssertFalse(rig.runtime.approveWithStandingConsent(requestID: fresh.id), "\(hook): fresh key is not settled")
            XCTAssertTrue(isPending(rig, fresh), "\(hook): stays a card")
            let laterRequest = try request(rig, laterControl, "later")
            XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: laterRequest.id), "\(hook): another team lead still settles")
            XCTAssertNoThrow(try rig.runtime.approve(requestID: fresh.id).get(), "\(hook): the human card approval still works")
        }
    }

    func testNarrowedPresentedApprovalExcludesAndReplacementKeepsExclusions() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        func plantRule(in runtime: DelegationScopeRuntime) {
            runtime.debugInstallStandingRuleForTesting(DelegationStandingRule(
                id: UUID(), createdAt: Date(), expiresAt: Date().addingTimeInterval(7200), starter: stamp,
                workspaceID: workspace, countedTLs: [], ruleGrants: [], stoppedAt: nil, replacedBy: nil, closedAt: nil
            ), issuedScopeID: UUID())
        }
        func card(_ runtime: DelegationScopeRuntime, _ endpoint: DomainAgentSessionLinkEndpointIdentity, _ key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: endpoint.sessionID, requesterTabID: endpoint.tabID,
                kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 3600,
                reason: nil, idempotencyKey: key
            ).get()
        }
        func plain(_ runtime: DelegationScopeRuntime, _ session: UUID, _ key: String) throws -> DelegationScopeRequest {
            try runtime.requestScope(
                requesterSessionID: session, requesterTabID: nil,
                kind: .directChildren(rootSessionID: session, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 60,
                reason: nil, idempotencyKey: key
            ).get()
        }

        let controlPair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let controlRuntime = controlPair.0.runtime
        let controlEndpoint = controlPair.1
        let full = try card(controlRuntime, controlEndpoint, "full")
        XCTAssertNoThrow(try controlRuntime.approve(
            requestID: full.id, presentedWindowID: controlEndpoint.windowID, presentedTabID: controlEndpoint.tabID,
            presentedSessionID: controlEndpoint.sessionID
        ).get())
        XCTAssertFalse(controlRuntime.debugIsStandingRuleExcludedForTesting(controlEndpoint.sessionID), "a full-capability approval excludes nobody")

        let pair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let runtime = pair.0.runtime
        let endpoint = pair.1
        plantRule(in: runtime)
        let narrowed = try card(runtime, endpoint, "narrow")
        XCTAssertNoThrow(try runtime.approve(
            requestID: narrowed.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
            presentedSessionID: endpoint.sessionID, capabilities: [.observe]
        ).get())
        XCTAssertTrue(runtime.debugIsStandingRuleExcludedForTesting(endpoint.sessionID))
        let fresh = try card(runtime, endpoint, "fresh")
        XCTAssertFalse(runtime.approveWithStandingConsent(requestID: fresh.id))
        XCTAssertEqual(runtime.request(id: fresh.id, requesterSessionID: endpoint.sessionID)?.state, .pending)
        let other = try plain(runtime, UUID(), "other")
        XCTAssertTrue(runtime.approveWithStandingConsent(requestID: other.id), "control: another team lead settles")
        XCTAssertNoThrow(try runtime.approve(requestID: fresh.id).get(), "the human card approval still works")

        let seedPair = try await presentedFixture(stamp: stamp, workspaceID: workspace)
        let seedRuntime = seedPair.0.runtime
        let seedEndpoint = seedPair.1
        let firstSeed = try card(seedRuntime, seedEndpoint, "seed-1")
        XCTAssertNoThrow(try seedRuntime.approve(
            requestID: firstSeed.id, presentedWindowID: seedEndpoint.windowID, presentedTabID: seedEndpoint.tabID,
            presentedSessionID: seedEndpoint.sessionID, standingRuleOptions: .init()
        ).get())
        let denied = UUID()
        try seedRuntime.deny(requestID: plain(seedRuntime, denied, "denied").id)
        XCTAssertTrue(seedRuntime.debugIsStandingRuleExcludedForTesting(denied))
        let secondSeed = try card(seedRuntime, seedEndpoint, "seed-2")
        XCTAssertNoThrow(try seedRuntime.approve(
            requestID: secondSeed.id, presentedWindowID: seedEndpoint.windowID, presentedTabID: seedEndpoint.tabID,
            presentedSessionID: seedEndpoint.sessionID, standingRuleOptions: .init()
        ).get())
        XCTAssertEqual(seedRuntime.rules.count { $0.effectiveState(now: Date()) == .active }, 1, "replacement leaves one active rule")
        XCTAssertTrue(seedRuntime.debugIsStandingRuleExcludedForTesting(denied), "replacement keeps exclusions")
        let afterReplacement = try plain(seedRuntime, denied, "after-replacement")
        XCTAssertFalse(seedRuntime.approveWithStandingConsent(requestID: afterReplacement.id))
        let replacementControl = try plain(seedRuntime, UUID(), "replacement-control")
        XCTAssertTrue(seedRuntime.approveWithStandingConsent(requestID: replacementControl.id), "control: the replacement rule settles")
    }

    func testExclusionLeavesOnSessionDeletionWhileTheCountIsKept() throws {
        let rig = makeRig()
        installRule(rig)
        let subject = UUID(), bystander = UUID()
        let issued = try request(rig, subject, "first")
        XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: issued.id))
        try rig.runtime.revoke(scopeID: XCTUnwrap(scopeID(rig, issued)))
        let bystanderGrant = try cardGrant(rig, bystander, "bystander")
        rig.runtime.revoke(scopeID: bystanderGrant.id)
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(subject))
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(bystander))

        rig.runtime.revokeAll(involving: subject)

        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(subject), "deletion drops the exclusion")
        XCTAssertTrue(rig.runtime.debugIsStandingRuleExcludedForTesting(bystander), "control: another exclusion stays")
        XCTAssertEqual(rig.runtime.rules.first?.countedTLs.contains(subject), true, "deletion keeps the count")
    }

    func testEndedRuleIsPrunedOnlyWhenNoRuleGrantIsLive() throws {
        let rig = makeRig()
        let seedTL = UUID(), holder = UUID()
        let seed = try cardGrant(rig, seedTL, "seed")
        let held = try cardGrant(rig, holder, "held")
        installRule(rig, lifetime: 60, counted: [seedTL], grants: [held.id])
        XCTAssertEqual(rig.runtime.rules.count, 1, "control: an active rule is listed")

        rig.clock.date = rig.clock.date.addingTimeInterval(120)
        XCTAssertTrue(rig.runtime.liveScopes(grantedTo: holder).contains { $0.id == held.id })
        XCTAssertEqual(rig.runtime.rules.count, 1, "an ended rule with a live rule grant stays")
        XCTAssertEqual(rig.runtime.rules.first?.effectiveState(now: rig.clock.date), .expired)

        rig.runtime.revoke(scopeID: held.id)
        XCTAssertTrue(rig.runtime.rules.isEmpty, "pruned once no rule grant is live")
        XCTAssertTrue(isLive(rig, seed), "the seed card grant outlives the rule")

        let seedOnly = makeRig()
        let onlySeed = try cardGrant(seedOnly, seedTL, "seed")
        installRule(seedOnly, lifetime: 60, counted: [seedTL])
        XCTAssertEqual(seedOnly.runtime.rules.count, 1, "control: active")
        seedOnly.clock.date = seedOnly.clock.date.addingTimeInterval(120)
        XCTAssertTrue(seedOnly.runtime.liveScopes(grantedTo: seedTL).contains { $0.id == onlySeed.id })
        XCTAssertTrue(seedOnly.runtime.rules.isEmpty, "the seed card grant never keeps an ended rule alive")
    }

    func testClosedStateLatchesOnlyOnTerminalGenerationLoss() throws {
        let rig = makeRig()
        installRule(rig)
        let holder = UUID()
        let issued = try request(rig, holder, "first")
        XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: issued.id))

        rig.sample.live = false
        let transient = try request(rig, UUID(), "transient")
        XCTAssertFalse(rig.runtime.approveWithStandingConsent(requestID: transient.id), "a not-live sample refuses")
        XCTAssertNil(rig.runtime.rules.first?.closedAt, "a transient sample does not latch")
        XCTAssertEqual(rig.runtime.rules.first?.effectiveState(now: rig.clock.date), .active)
        rig.sample.live = true
        XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: transient.id), "a later live sample settles")

        let revisionBefore = rig.runtime.revision
        rig.sample.generation = nil
        _ = try request(rig, UUID(), "terminal")
        XCTAssertNotNil(rig.runtime.rules.first?.closedAt, "terminal generation loss latches")
        XCTAssertEqual(rig.runtime.rules.first?.effectiveState(now: rig.clock.date), .connectionClosed)
        XCTAssertGreaterThan(rig.runtime.revision, revisionBefore, "the latch republishes")

        rig.sample.generation = 1
        _ = try request(rig, UUID(), "after")
        XCTAssertEqual(rig.runtime.rules.first?.effectiveState(now: rig.clock.date), .connectionClosed, "the latch is monotonic")
    }

    func testRestartDropsTheRuleAndRestoresDerivedGrantsAsOrdinaryGrants() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("standing-rule-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        func makeStore() -> DelegationScopeStore {
            DelegationScopeStore(
                fileURL: directory.appendingPathComponent(DelegationScopeStore.filename),
                backupsDirectoryURL: directory.appendingPathComponent("Backups", isDirectory: true),
                mode: .enabled
            )
        }
        let rig = makeRig(persistenceMode: .requiresStore)
        await rig.runtime.bootstrap(store: makeStore())
        let rule = installRule(rig)
        let holder = UUID()
        let issued = try request(rig, holder, "first", expiry: 600)
        XCTAssertTrue(rig.runtime.approveWithStandingConsent(requestID: issued.id), "control: the rule settles before the restart")
        let derivedID = try XCTUnwrap(scopeID(rig, issued))
        await rig.runtime.flushPersistence()

        rig.runtime.freezeForTermination()
        XCTAssertTrue(rig.runtime.rules.isEmpty)
        XCTAssertTrue(rig.runtime.notices.isEmpty)
        XCTAssertFalse(rig.runtime.debugIsStandingRuleExcludedForTesting(holder))
        _ = await rig.runtime.settleForTermination()

        let restarted = makeRig(persistenceMode: .requiresStore)
        await restarted.runtime.bootstrap(store: makeStore())
        let restored = try XCTUnwrap(restarted.runtime.record(id: derivedID), "the derived grant is restored")
        XCTAssertTrue(restored.isActive)
        XCTAssertEqual(restored.grant.origin, .user)
        XCTAssertFalse(restored.grant.unrestricted)
        XCTAssertEqual(restored.grant.guardrails.expiresAt, rule.createdAt.addingTimeInterval(600))
        XCTAssertTrue(restarted.runtime.rules.isEmpty, "no rule after restart")
        XCTAssertNil(restarted.runtime.standingRuleProvenance(scopeID: derivedID))
        let newcomer = try request(restarted, UUID(), "newcomer")
        XCTAssertFalse(restarted.runtime.approveWithStandingConsent(requestID: newcomer.id), "no new settlement")
        let longer = try request(restarted, holder, "longer", expiry: 3600)
        XCTAssertFalse(restarted.runtime.approveWithStandingConsent(requestID: longer.id), "the restored grant is ordinary, not a rule")
        XCTAssertTrue(isPending(restarted, newcomer) && isPending(restarted, longer))
    }

    func testTabRemovalAndTeamLeadDeletionEndThatTeamLeadsNotices() async throws {
        let stamp = StarterConnectionStamp(connectionID: UUID(), lifecycleGeneration: 1)
        let workspace = UUID()
        let pair = try await presentedFixture(stamp: stamp, workspaceID: workspace, facts: { _ in nil })
        let runtime = pair.0.runtime
        let endpoint = pair.1
        func approveWithRuleOption(_ key: String) throws {
            let card = try runtime.requestScope(
                requesterSessionID: endpoint.sessionID, requesterTabID: endpoint.tabID,
                kind: .directChildren(rootSessionID: endpoint.sessionID, workspaceID: workspace),
                capabilities: [.observe, .control, .restructure], guardrails: .init(), expiresInSeconds: 3600,
                reason: nil, idempotencyKey: key
            ).get()
            XCTAssertNoThrow(try runtime.approve(
                requestID: card.id, presentedWindowID: endpoint.windowID, presentedTabID: endpoint.tabID,
                presentedSessionID: endpoint.sessionID, standingRuleOptions: .init()
            ).get())
        }
        try approveWithRuleOption("first")
        XCTAssertEqual(runtime.notices.count, 1)
        XCTAssertEqual(runtime.notices.first?.tabID, endpoint.tabID)

        runtime.standingRuleTabsDidRemove([UUID()])
        XCTAssertEqual(runtime.notices.count, 1, "control: another tab's removal leaves the notice")
        runtime.standingRuleTabsDidRemove([endpoint.tabID])
        XCTAssertTrue(runtime.notices.isEmpty, "removing the tab ends its notices")

        try approveWithRuleOption("second")
        XCTAssertEqual(runtime.notices.count, 1)
        runtime.revokeAll(involving: UUID())
        XCTAssertEqual(runtime.notices.count, 1, "control: another team lead's deletion leaves the notice")
        runtime.revokeAll(involving: endpoint.sessionID)
        XCTAssertTrue(runtime.notices.isEmpty, "deleting the team lead ends its notices")
    }
}
