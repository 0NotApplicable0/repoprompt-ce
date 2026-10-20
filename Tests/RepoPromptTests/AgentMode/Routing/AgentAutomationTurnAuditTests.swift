import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptProviderQuota
import RepoPromptSettingsCore
import RepoPromptShared
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
final class RoutingExecutionMetadataTests: XCTestCase {
    private let available = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: true,
        openCodeAvailable: true
    )

    private func option(
        _ raw: String,
        _ providerDefault: Bool = false,
        effortVariant: AgentModelEffortVariant? = nil,
        rawEfforts: [String] = []
    ) -> AgentModelOption {
        .init(
            rawValue: raw,
            displayName: raw,
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: providerDefault,
            supportedReasoningEffortRawValues: rawEfforts,
            effortVariant: effortVariant
        )
    }

    private func builder(
        _ catalog: [AgentProviderKind: [AgentModelOption]],
        key: @escaping () -> String = { UUID().uuidString }
    ) -> AgentTaskRoutingCandidateBuilder {
        AgentTaskRoutingCandidateBuilder(opaqueKey: key, modelOptions: { provider, _ in catalog[provider] ?? [] })
    }

    func testPreviewCatalogMemoRetainsExactOutputsAndRemovesDuplicateRead() throws {
        let availability = AgentModelCatalog.AvailabilityContext(
            claudeCodeAvailable: false,
            codexAvailable: true,
            openCodeAvailable: false
        )
        let catalog: [AgentProviderKind: [AgentModelOption]] = [
            .codexExec: [option("gpt-6-sol", true), option("gpt-6-luna")]
        ]
        let profileSnapshot = RoutingModelProfileSnapshot.bundled
        var baselineCalls = 0
        let baselineOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            baselineCalls += 1
            return catalog[provider] ?? []
        }
        let baselineProviders = AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: availability,
            modelOptions: baselineOptions
        )
        var baselineKey = 0
        let baselineCandidates = try AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                baselineKey += 1
                return "candidate-\(baselineKey)"
            },
            profileSnapshot: profileSnapshot,
            modelOptions: baselineOptions
        ).build(allowedProviders: baselineProviders, availability: availability)

        var memoCalls = 0
        var memoizedOptions: [AgentProviderKind: [AgentModelOption]] = [:]
        let memoOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = { provider, _ in
            if let options = memoizedOptions[provider] {
                return options
            }
            memoCalls += 1
            let options = catalog[provider] ?? []
            memoizedOptions[provider] = options
            return options
        }
        let memoProviders = AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: availability,
            modelOptions: memoOptions
        )
        var memoKey = 0
        let memoCandidates = try AgentTaskRoutingCandidateBuilder(
            opaqueKey: {
                memoKey += 1
                return "candidate-\(memoKey)"
            },
            profileSnapshot: profileSnapshot,
            modelOptions: memoOptions
        ).build(allowedProviders: memoProviders, availability: availability)

        XCTAssertEqual(baselineProviders, [.codexExec])
        XCTAssertEqual(memoProviders, baselineProviders)
        XCTAssertEqual(baselineCalls, 2)
        XCTAssertEqual(memoCalls, 1)
        XCTAssertEqual(memoCandidates, baselineCandidates)
        XCTAssertEqual(
            Self.previewSignatures(memoCandidates, availability: availability),
            Self.previewSignatures(baselineCandidates, availability: availability)
        )
    }

    private static func previewSignatures(
        _ candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        availability: AgentModelCatalog.AvailabilityContext
    ) -> [String] {
        candidates.compactMap { candidate in
            guard let provider = AgentProviderKind(rawValue: candidate.target.agentRaw) else { return nil }
            let displayName = AgentModelCatalog.displayName(
                for: candidate.target.modelRaw,
                agentKind: provider,
                availability: availability
            )
            return "\(candidate.utilityTier)|\(provider.rawValue)|\(candidate.target.modelRaw)|\(candidate.target.reasoningEffortRaw ?? "")|\(displayName)"
        }
    }

    func testSnapshotScopeIsStableAndChangesWithCatalogSurfaceAndAvailability() {
        let first = builder([.codexExec: [option("future-model", true)]])
        let original = first.capture(allowedProviders: [.codexExec], availability: available)
        let repeatCapture = first.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(original, repeatCapture)
        XCTAssertEqual(original.models.map(\.baseModelRaw), ["future-model"])

        let changed = builder([.codexExec: [option("future-model", true, rawEfforts: ["new-effort"])]]).capture(
            allowedProviders: [.codexExec], availability: available
        )
        XCTAssertNotEqual(original.scope.catalogRevision, changed.scope.catalogRevision)
        XCTAssertNotEqual(original.scope, changed.scope)
        XCTAssertNotEqual(
            original.scope,
            first.capture(allowedProviders: [.codexExec], availability: available, surface: .headless).scope
        )
        XCTAssertNotEqual(
            original.scope,
            first.capture(
                allowedProviders: [.codexExec],
                availability: .init(claudeCodeAvailable: false, codexAvailable: true, openCodeAvailable: false)
            ).scope
        )
    }

    func testUnknownAdvertisedModelRemainsInCatalogButNotRouterShortlist() throws {
        let raw = "future-model-high"
        let builder = builder([.codexExec: [option(raw), option("gpt-6-sol"), option("gpt-6-luna")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(snapshot.models.map(\.baseModelRaw), [raw, "gpt-6-sol", "gpt-6-luna"])
        XCTAssertTrue(snapshot.contains(.init(agentRaw: AgentProviderKind.codexExec.rawValue, modelRaw: raw, reasoningEffortRaw: nil, modelParameters: [])))
        XCTAssertEqual(try builder.build(snapshot: snapshot).map(\.target.modelRaw), ["gpt-6-luna", "gpt-6-sol"])

        let exactRecord = CodexDynamicModelRecord(
            id: raw, model: raw, displayName: raw, description: "", isDefault: false
        )
        let parsed = CodexModelSpecifier.splitLegacyModelID(raw, discoveredRecords: [exactRecord])
        XCTAssertEqual(parsed.baseModel, raw)
        XCTAssertNil(parsed.reasoningEffort)
    }

    func testDistinctExactProviderIDsAreNotCaseFoldedOrDeduplicated() throws {
        let builder = builder([.codexExec: [option("Future"), option("future")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(snapshot.models.map(\.baseModelRaw), ["Future", "future"])
        XCTAssertThrowsError(try builder.build(snapshot: snapshot))
    }

    func testEffortLikeExactUnknownModelAndExcludedProviderCannotEnterShortlist() throws {
        let builder = builder([.codexExec: [option("gpt-6-sol-high"), option("ordinary-model")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertEqual(snapshot.models.map(\.baseModelRaw), ["gpt-6-sol-high", "ordinary-model"])
        XCTAssertThrowsError(try builder.build(snapshot: snapshot))

        let otherProvider = self.builder([.openCode: [option("gpt-6-sol"), option("ordinary-model")]])
        let otherSnapshot = otherProvider.capture(allowedProviders: [.openCode], availability: available)
        XCTAssertEqual(otherSnapshot.models.map(\.baseModelRaw), ["gpt-6-sol", "ordinary-model"])
        XCTAssertThrowsError(try otherProvider.build(snapshot: otherSnapshot))
    }

    func testAdvertisedRawEffortIsPreservedButNotOfferedUnlessExecutable() throws {
        let base = option("gpt-6-sol", true, rawEfforts: ["high", "future-depth"])
        let builder = builder([.codexExec: [base, option("gpt-6-luna")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        let model = try XCTUnwrap(snapshot.models.first { $0.baseModelRaw == "gpt-6-sol" })
        XCTAssertEqual(model.efforts.map(\.id.rawValue), ["high", "future-depth"])
        XCTAssertNil(model.defaultEffortID)
        XCTAssertEqual(model.efforts.map(\.isExecutable), [true, false])
        XCTAssertEqual(model.efforts.first?.executableTarget?.modelRaw, "gpt-6-sol")
        XCTAssertEqual(model.efforts.first?.executableTarget?.reasoningEffortRaw, "high")
        let chosen = try XCTUnwrap(builder.build(snapshot: snapshot).first { $0.target.modelRaw == "gpt-6-sol" })
        let efforts = try builder.buildEfforts(for: chosen, snapshot: snapshot)
        XCTAssertEqual(Set(efforts.compactMap(\.target.reasoningEffortRaw)), ["high"])
        XCTAssertFalse(efforts.contains { $0.utilityTier == "future-depth" })
        XCTAssertTrue(try snapshot.contains(XCTUnwrap(efforts.first { $0.target.reasoningEffortRaw == "high" }).target))
    }

    func testCodexDynamicMapperRetainsUnknownRawEffortsThroughOptionProjection() {
        let remote = CodexAppServerClient.RemoteModel(
            id: "future-codex",
            model: "future-codex",
            displayName: "Future Codex",
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: "high", description: ""),
                .init(reasoningEffort: "future-depth", description: "")
            ],
            defaultReasoningEffort: "future-depth"
        )
        let mapped = CodexDynamicModelMapper.options(from: [remote])
        XCTAssertFalse(mapped.isEmpty)
        XCTAssertTrue(mapped.allSatisfy {
            $0.supportedReasoningEffortRawValues == ["high", "future-depth", "future-depth"]
        })
        let projected = AgentCodexModelRegistry().resolvedOptions(
            staticOptions: [], preferredLiveModels: [remote]
        )
        XCTAssertTrue(projected.contains {
            $0.rawValue == "future-codex-high"
                && $0.effortVariant?.baseModelRaw == "future-codex"
                && $0.supportedReasoningEffortRawValues.contains("future-depth")
        })
    }

    func testCodexStoreRoundTripsUnknownRawEffortAndDefault() throws {
        let suite = "RoutingCodexRawEffort.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = CodexAppServerClient.RemoteModel(
            id: "future-codex", model: "future-codex", displayName: "Future Codex",
            description: "", isDefault: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: "high", description: ""),
                .init(reasoningEffort: "future-depth", description: "")
            ],
            defaultReasoningEffort: "future-depth"
        )
        CodexDynamicModelStore.save([remote], defaults: defaults)
        let loaded = try XCTUnwrap(CodexDynamicModelStore.load(defaults: defaults).first)
        XCTAssertEqual(loaded.supportedReasoningEfforts.map(\.reasoningEffort), ["high", "future-depth"])
        XCTAssertEqual(loaded.defaultReasoningEffort, "future-depth")
        let projected = CodexDynamicModelStore.modelOptions(defaults: defaults)
        XCTAssertTrue(projected.allSatisfy { $0.supportedReasoningEffortRawValues.contains("future-depth") })
    }

    func testFastCodexVariantsRetainServiceTierInTheirBaseTarget() throws {
        let remote = CodexAppServerClient.RemoteModel(
            id: "gpt-6-sol",
            model: "gpt-6-sol",
            displayName: "GPT-6 Sol",
            description: "",
            isDefault: false,
            supportedReasoningEfforts: [.init(reasoningEffort: "high", description: "")],
            defaultReasoningEffort: "high"
        )
        let options = AgentCodexModelRegistry().resolvedOptions(
            staticOptions: [], preferredLiveModels: [remote]
        )
        let fast = try XCTUnwrap(options.first { $0.rawValue == "gpt-6-sol-fast-high" })
        XCTAssertEqual(fast.effortVariant?.baseModelRaw, "gpt-6-sol-fast")
        let snapshot = builder([.codexExec: options]).capture(
            allowedProviders: [.codexExec], availability: available
        )
        let fastModel = try XCTUnwrap(snapshot.models.first { $0.baseModelRaw == "gpt-6-sol-fast" })
        XCTAssertEqual(fastModel.efforts.first?.executableTarget?.modelRaw, "gpt-6-sol-fast")
        XCTAssertEqual(fastModel.efforts.first?.executableTarget?.reasoningEffortRaw, "high")
    }

    func testACPCatalogRoundTripsUnknownEffortRawWithoutAuthorizingExecution() throws {
        let suite = "RoutingRawEffort.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: "acp-future",
                displayName: "acp-future",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: false,
                supportedReasoningEffortRawValues: ["future-depth", "high"],
                defaultReasoningEffortRawValue: "future-depth"
            )],
            currentModelRaw: "acp-future"
        )
        ACPDynamicModelStore.save(source, for: .openCode, defaults: defaults)
        let loaded = try XCTUnwrap(ACPDynamicModelStore.load(providerID: .openCode, defaults: defaults))
        XCTAssertEqual(loaded.options.first?.supportedReasoningEffortRawValues, ["future-depth", "high"])
        XCTAssertEqual(loaded.options.first?.defaultReasoningEffortRawValue, "future-depth")
        let metadata = builder([.openCode: loaded.options]).capture(
            allowedProviders: [.openCode], availability: available
        )
        XCTAssertEqual(metadata.models.first?.efforts.map(\.id.rawValue), ["future-depth", "high"])
        XCTAssertEqual(metadata.models.first?.efforts.map(\.isExecutable), [false, false])
        XCTAssertEqual(metadata.models.first?.defaultEffortID?.rawValue, "future-depth")
    }

    func testCuratedFrontierIsDeterministicBoundedAndExcludesAdvertisedACPProvider() throws {
        let catalog: [AgentProviderKind: [AgentModelOption]] = [
            .codexExec: [option("gpt-6-sol"), option("gpt-6-luna"), option("gpt-6-astra")],
            .claudeCode: [option("claude-sonnet-5"), option("claude-opus-5-5")],
            .openCode: [option("opencode-new")]
        ]
        var next = 0
        let builder = builder(catalog) { next += 1
            return "choice-\(next)"
        }
        let snapshot = builder.capture(allowedProviders: Set(catalog.keys), availability: available)
        let references: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] = [
            .init(roleLabel: "Engineer", provider: .codexExec, modelRaw: "gpt-6-sol", isUserOverride: true)
        ]
        let first = try builder.build(snapshot: snapshot, roleDefaults: references, maximumChoices: 4)
        let second = try builder.build(snapshot: snapshot, roleDefaults: references, maximumChoices: 4)
        XCTAssertEqual(first.map(\.target), second.map(\.target))
        XCTAssertEqual(first.map(\.target.modelRaw), ["gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "claude-sonnet-5"])
        XCTAssertTrue(try XCTUnwrap(first.first { $0.target.modelRaw == "gpt-6-sol" }).descriptor.targetDescription.contains("Engineer (user-set)"))
        XCTAssertFalse(first.contains { $0.target.agentRaw == AgentProviderKind.openCode.rawValue })
    }

    func testRoleReferencesDoNotReorderCuratedShortlist() throws {
        let catalog: [AgentProviderKind: [AgentModelOption]] = [
            .codexExec: [option("gpt-6-sol"), option("gpt-6-luna")],
            .claudeCode: [option("claude-sonnet-5"), option("claude-opus-5-5")]
        ]
        let references: [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] = [
            .init(roleLabel: "Engineer", provider: .claudeCode, modelRaw: "claude-opus-5-5", isUserOverride: true)
        ]
        let candidates = try builder(catalog).build(
            allowedProviders: Set(catalog.keys), availability: available,
            roleDefaults: references, maximumChoices: 4
        )
        XCTAssertEqual(candidates.map(\.target.modelRaw), ["gpt-6-luna", "gpt-6-sol", "claude-sonnet-5", "claude-opus-5-5"])
        XCTAssertTrue(candidates.last?.descriptor.targetDescription.contains("Engineer (user-set)") == true)
    }

    func testInsufficientServiceCapacityFallsBackBeforeCallingService() {
        let builder = builder([.codexExec: [option("gpt-6-luna"), option("gpt-6-sol")]])
        let snapshot = builder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertThrowsError(try builder.build(snapshot: snapshot, maximumChoices: 1)) { error in
            XCTAssertEqual(error as? AgentTaskRoutingCandidateBuilder.BuildError, .insufficientCapacity)
        }
    }

    func testSnapshotRejectsEffortDecisionAfterCatalogChanges() throws {
        let originalBuilder = builder([.codexExec: [option("gpt-6-sol", rawEfforts: ["high"]), option("gpt-6-luna")]])
        let original = originalBuilder.capture(allowedProviders: [.codexExec], availability: available)
        let selected = try XCTUnwrap(originalBuilder.build(snapshot: original).first { $0.target.modelRaw == "gpt-6-sol" })
        let changedBuilder = builder([.codexExec: [option("gpt-6-sol", rawEfforts: ["low"]), option("gpt-6-luna")]])
        let changed = changedBuilder.capture(allowedProviders: [.codexExec], availability: available)
        XCTAssertThrowsError(try changedBuilder.buildEfforts(for: selected, snapshot: changed))
    }
}

@MainActor
final class AgentTaskRoutingDecisionLogTests: XCTestCase {
    private let taskSentinel = "DECISION_LOG_SENTINEL_TASK_TEXT_DO_NOT_RECORD_9f3c"
    private let secretSentinel = "sk-jev-secret-do-not-log-7712"

    func testModelStagePickWritesOneDecisionEvent() async throws {
        let fixture = try await makeFixture()
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let picked = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: taskSentinel, surface: .general, logContext: context
        )
        XCTAssertEqual(picked?.modelRaw, "claude-opus-5-5:high")
        let rows = try await readRows(fixture)
        let decisions = assertStages(rows, requestID: context.requestID, expected: [.model, .effort])
        let row = try XCTUnwrap(decisions.first { $0.stage == .model })
        XCTAssertEqual(row.schema, 1)
        XCTAssertEqual(row.scope, .subagent)
        XCTAssertEqual(row.outcome, .selected)
        XCTAssertEqual(row.backend, "jev")
        XCTAssertEqual(row.jevModel, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(row.policyVersion, JevRouterCredentialService.routingPolicyVersion)
        XCTAssertEqual(Set(row.candidates.compactMap(\.provider)), ["claudeCode", "codexExec"])
        XCTAssertEqual(Set(row.candidates.map(\.model)), ["claude-opus-5-5", "gpt-6-sol"])
        XCTAssertTrue(row.candidates.allSatisfy { $0.effort == nil && $0.modelParameters.isEmpty })
        XCTAssertEqual(row.chosenTarget, .init(provider: "claudeCode", model: "claude-opus-5-5", effort: nil))
        try assertEvidence(row)
    }

    func testEffortStagePickWritesOneDecisionEvent() async throws {
        let fixture = try await makeFixture()
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let picked = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: taskSentinel, surface: .general, logContext: context
        )
        XCTAssertEqual(picked.map(AgentTaskRoutingLogTarget.init)?.effort, "high")
        let rows = try await readRows(fixture)
        let decisions = assertStages(rows, requestID: context.requestID, expected: [.model, .effort])
        let row = try XCTUnwrap(decisions.first { $0.stage == .effort })
        XCTAssertEqual(row.outcome, .selected)
        XCTAssertEqual(Set(row.candidates.compactMap(\.effort)), ["medium", "high"])
        XCTAssertTrue(row.candidates.allSatisfy { $0.provider == "claudeCode" && $0.model.hasPrefix("claude-opus-5-5") })
        XCTAssertEqual(row.chosenTarget, .init(provider: "claudeCode", model: "claude-opus-5-5:high", effort: "high"))
        try assertEvidence(row)
    }

    func testAutoEffortJudgeWritesOneDecisionEvent() async throws {
        let fixture = try await makeFixture(autoEffort: true)
        let session = try composerSession(fixture)
        session.selectedModelRaw = "claude-opus-5-5"
        let text = "Implement a parser and verify its error handling. \(taskSentinel)"
        XCTAssertNotNil(AutoEffortTaskSummary.make(from: text))
        let result = await fixture.viewModel.chooseAutoEffortForUserTurn(text: text, session: session, workflow: nil)
        XCTAssertEqual(result.selection?.effortRaw, "medium")
        XCTAssertEqual(result.audit.decision, .selected)
        let rows = try await readRows(fixture)
        let row = try XCTUnwrap(decisions(rows).first)
        _ = try assertStages(rows, requestID: XCTUnwrap(UUID(uuidString: row.requestID)), expected: [.autoEffort])
        XCTAssertEqual(row.sessionID, session.activeAgentSessionID?.uuidString)
        XCTAssertEqual(row.scope, .primarySession)
        XCTAssertEqual(row.policyVersion, JevRouterCredentialService.routingPolicyVersion)
        XCTAssertEqual(row.chosenTarget, .init(provider: "claudeCode", model: "claude-opus-5-5", effort: "medium"))
        XCTAssertTrue(row.candidates.contains { $0.effort == "medium" })
        try assertEvidence(row)
    }

    func testAbstentionFailureAndCancellationWriteDecisionEvents() async throws {
        let fixture = try await makeFixture()
        for plan in [DecisionLogBackend.Plan.abstain, .failure, .cancelled] {
            await fixture.backend.enqueue(plan)
            let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
            do {
                let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                    task: taskSentinel, surface: .general, logContext: context
                )
                XCTAssertNotEqual(plan, .cancelled, "Cancellation must reject the route")
                XCTAssertNil(target)
            } catch AgentModeViewModel.GlobalModelRoutingError.cancelled {
                XCTAssertEqual(plan, .cancelled)
            }
            let rows = try await readRows(fixture)
            let events = assertStages(rows, requestID: context.requestID, expected: [.model])
            let row = try XCTUnwrap(events.first)
            XCTAssertNil(row.chosenKey)
            XCTAssertNil(row.chosenTarget)
            switch plan {
            case .abstain:
                XCTAssertEqual(row.outcome, .abstained)
                XCTAssertEqual(row.reasonCode, "confidence_below_floor")
                XCTAssertEqual(row.confidence, 0.5)
                XCTAssertNotNil(row.probabilities)
            case .failure:
                XCTAssertEqual(row.outcome, .failed)
                XCTAssertEqual(row.failure, DecisionFailureCategory.transport.rawValue)
                XCTAssertNil(row.probabilities)
                XCTAssertNil(row.confidence)
                XCTAssertNil(row.jevModel)
            case .cancelled:
                XCTAssertEqual(row.outcome, .cancelled)
                XCTAssertNil(row.probabilities)
                XCTAssertNil(row.confidence)
            case .selected:
                XCTFail("Unexpected plan")
            }
        }
    }

    func testLocalSingleCandidateWritesDecisionWithoutJevRequest() async throws {
        let fixture = try await makeFixture(singleCandidate: true)
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: taskSentinel, surface: .general, logContext: context
        )
        XCTAssertEqual(target?.modelRaw, "claude-opus-5-5")
        XCTAssertNil(target?.reasoningEffortRaw)
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty)
        let rows = try await readRows(fixture)
        let events = assertStages(rows, requestID: context.requestID, expected: [.model, .effort])
        for row in events {
            XCTAssertEqual(row.outcome, .localSingleCandidate)
            XCTAssertEqual(row.backend, "local")
            XCTAssertEqual(row.candidates.count, 1)
            XCTAssertEqual(row.chosenKey, row.candidates.first?.key)
            XCTAssertNotNil(row.chosenTarget)
            XCTAssertNil(row.jevModel)
            XCTAssertNil(row.policyVersion)
            XCTAssertNil(row.probabilities)
            XCTAssertNil(row.confidence)
            XCTAssertNil(row.latencyMs)
        }
    }

    func testAgentRunStartWritesAppliedEvent() async throws {
        for scenario in StartScenario.allCases {
            let fixture = try await makeFixture()
            if scenario == .fallback { await fixture.backend.enqueue(.abstain) }
            var service = AgentRunMCPToolService(
                toolName: "agent_run",
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "decision-log", windowID: fixture.window.windowID) },
                requireTargetWindow: { fixture.window },
                resolveRequestedTabID: { _ in nil },
                resolveSpawnParentSourceTabID: { _ in nil },
                resolveSpawnParentSessionID: { _, _ in nil },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: startRun(rejected: scenario == .rejected)
            )
            service.resolveOracleReviewLaunchSource = { _, window in
                let workspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
                let tabID = try XCTUnwrap(workspace.activeComposeTabID)
                return ResolvedAgentRunOracleReviewLaunchSource(
                    snapshot: AgentRunOracleReviewLaunchSnapshot(
                        route: .explicitWindowActiveCompose, windowID: window.windowID, workspaceID: workspace.id,
                        tabID: tabID, selectionRevision: 0, promptText: "", selection: StoredSelection(),
                        sourceAgentSessionID: nil, routedRunID: nil
                    ),
                    source: .unavailable(.init(
                        delegationID: UUID(), sourceTabID: tabID, workspaceID: workspace.id,
                        sourceAgentSessionID: nil, sourceAgentRunID: nil,
                        reason: .sourceCaptureFailed("decision log fixture")
                    ))
                )
            }
            do {
                _ = try await service.execute(args: startArguments)
                XCTAssertNotEqual(scenario, .rejected)
            } catch {
                guard scenario == .rejected else { throw error }
            }
            let rows = try await readRows(fixture)
            try assertApplied(rows, scenario: scenario, scope: .subagent)
        }
    }

    func testAgentExploreStartWritesAppliedEvent() async throws {
        for scenario in StartScenario.allCases {
            let fixture = try await makeFixture()
            let parentTarget = try await fixture.viewModel.mcpResolveOrCreateSessionTarget(
                tabID: nil, sessionID: nil, createIfNeeded: true, sessionName: "Decision log parent"
            )
            let parentID = try XCTUnwrap(parentTarget.sessionID)
            let parentStart = startRun(rejected: false)
            _ = try await parentStart(
                parentTarget, "Parent task", .init(connectionID: nil, clientName: "decision-log", windowID: fixture.window.windowID),
                fixture.viewModel, "claudeCode", AgentModel.claudeSonnet.rawValue, nil, .pair, nil, nil, nil, false
            )
            fixture.viewModel.mcpAcceptSessionTarget(parentTarget)
            let parent = try XCTUnwrap(fixture.viewModel.session(for: parentTarget.tabID, createIfNeeded: false))
            XCTAssertEqual(parent.mcpControlContext?.sessionID, parentID)
            XCTAssertEqual(parent.mcpControlContext?.taskLabelKind, .pair)
            if scenario == .fallback { await fixture.backend.enqueue(.abstain) }
            let service = AgentExploreMCPToolService(
                toolName: "agent_explore",
                captureRequestMetadata: { .init(connectionID: UUID(), clientName: "decision-log", windowID: fixture.window.windowID) },
                requireTargetWindow: { fixture.window },
                resolveSpawnSourceTabID: { _ in parent.tabID },
                resolveSpawnParentSessionID: { _, _ in parentID },
                withHeartbeat: { _, _, _, _, operation in try await operation() },
                startRun: startRun(rejected: scenario == .rejected)
            )
            do {
                _ = try await service.execute(args: startArguments)
                XCTAssertNotEqual(scenario, .rejected)
            } catch {
                guard scenario == .rejected else { throw error }
            }
            let rows = try await readRows(fixture)
            try assertApplied(rows, scenario: scenario, scope: .headless)
        }
    }

    func testComposerSubmissionWritesAppliedEvent() async throws {
        for scenario in StartScenario.allCases {
            let fixture = try await makeFixture()
            let session = try composerSession(fixture)
            let target = try XCTUnwrap(fixture.viewModel.makeComposerSubmitTarget(tabID: session.tabID, session: session))
            let attempt = AgentComposerSubmitAttempt(
                id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: taskSentinel
            )
            guard case let .claimed(claim) = fixture.viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else {
                return XCTFail("Expected composer claim")
            }
            if scenario == .fallback { await fixture.backend.enqueue(.abstain) }
            if scenario == .rejected { await fixture.backend.enqueue(.cancelled) }
            fixture.viewModel.test_setCurrentTabIDOverride(nil)
            let result = await fixture.viewModel.executeComposerSubmitAttempt(text: taskSentinel, claim: claim)
            if scenario == .rejected {
                guard case .blocked = result else { return XCTFail("Cancelled route must block the start") }
            } else {
                XCTAssertEqual(result, .submitted)
            }
            try await AsyncTestWait.waitUntil("composer routing application settled", timeout: 5) {
                await fixture.log.flush()
                return (try? self.readLines(fixture.url).contains { if case .applied = $0 { return true }
                    return false
                }) == true
            }
            let rows = try await readRows(fixture)
            try assertApplied(rows, scenario: scenario, scope: .primarySession)
            let applied = try XCTUnwrap(applications(rows).first)
            XCTAssertEqual(applied.requestID, attempt.id.uuidString)
        }
    }

    func testLogOmitsTaskTextAndSecrets() async throws {
        let fixture = try await makeFixture(autoEffort: true)
        let pathSentinel = "/private/decision-log-secret/fixture.swift"
        let text = "Implement a parser and verify its error handling. \(taskSentinel) \(secretSentinel) \(pathSentinel)"
        XCTAssertNotNil(AutoEffortTaskSummary.make(from: text))
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(task: text, surface: .general, logContext: context)
        await context.finish(.rejected)
        let session = try composerSession(fixture)
        session.selectedModelRaw = "claude-opus-5-5"
        _ = await fixture.viewModel.chooseAutoEffortForUserTurn(text: text, session: session, workflow: nil)
        let rows = try await readRows(fixture)
        XCTAssertEqual(decisions(rows).count, 3)
        XCTAssertEqual(applications(rows).count, 1)
        let raw = try String(contentsOf: fixture.url, encoding: .utf8)
        for line in raw.split(separator: "\n") {
            XCTAssertFalse(line.contains(taskSentinel))
            XCTAssertFalse(line.contains(secretSentinel))
            XCTAssertFalse(line.contains(pathSentinel))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if object["event"] as? String == "decision" {
                XCTAssertTrue(object["rationale"] is NSNull)
            }
        }
    }

    func testLogRotatesAtSizeLimit() async throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("jev-decisions.jsonl")
        let limit = AgentTaskRoutingDecisionLog.minimumMaxBytes
        let log = AgentTaskRoutingDecisionLog(fileURL: url, maxBytes: limit)
        for _ in 0 ..< 160 {
            let context = AgentTaskRoutingRouteContext(requestID: UUID(), scope: .subagent, log: log)
            var draft = AgentTaskRoutingDecisionDraft(stage: .model, outcome: .localSingleCandidate)
            draft.backend = "local"
            draft.chosenKey = "only"
            draft.chosenTarget = .init(provider: "claudeCode", model: "claude-opus-5-5", effort: "high")
            draft.candidates = try [.init(key: "only", target: XCTUnwrap(draft.chosenTarget))]
            await context.emitDecision(draft)
            await context.finish(.rejected)
        }
        await log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["jev-decisions.jsonl", "jev-decisions.jsonl.1"])
        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, limit)
            XCTAssertFalse(try readLines(file).isEmpty)
        }
    }

    func testDecisionLogAppendIsSafeAcrossConcurrentWriters() async throws {
        if try await runDecisionLogWriterIfRequested(rotating: false) { return }
        let directory = try makeDirectory()
        try await runConcurrentDecisionLogWriters(in: directory, rotating: false)
        let url = directory.appendingPathComponent("jev-decisions.jsonl")
        let rows = try concurrentWriterRows(at: url)
        XCTAssertEqual(rows.count, 4 * 128)
        XCTAssertEqual(Set(rows), Set((0 ..< 4).flatMap { writer in
            (0 ..< 128).map { "\(writer):\($0)" }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".1"))
    }

    func testDecisionLogRotationIsSafeAcrossConcurrentWriters() async throws {
        if try await runDecisionLogWriterIfRequested(rotating: true) { return }
        let directory = try makeDirectory()
        try await runConcurrentDecisionLogWriters(in: directory, rotating: true)
        let url = directory.appendingPathComponent("jev-decisions.jsonl")
        let rotated = URL(fileURLWithPath: url.path + ".1")
        var rows: [String] = []
        for file in [rotated, url] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            XCTAssertLessThanOrEqual(size, AgentTaskRoutingDecisionLog.minimumMaxBytes)
            rows += try concurrentWriterRows(at: file)
        }
        XCTAssertEqual(rows.count, 12)
        XCTAssertEqual(Set(rows), Set((0 ..< 4).flatMap { writer in
            (0 ..< 3).map { "\(writer):\($0)" }
        }))
    }

    private func runDecisionLogWriterIfRequested(rotating: Bool) async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RPCE_ROUTING_LOG_WRITER_DIRECTORY"],
              let writer = environment["RPCE_ROUTING_LOG_WRITER_INDEX"].flatMap(Int.init)
        else { return false }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let log = AgentTaskRoutingDecisionLog(
            fileURL: directory.appendingPathComponent("jev-decisions.jsonl"),
            maxBytes: rotating ? AgentTaskRoutingDecisionLog.minimumMaxBytes : 32 * 1024 * 1024
        )
        if rotating {
            await log.append(concurrentWriterLine(writer: writer, row: 0))
            await log.flush()
        }
        try Data().write(to: directory.appendingPathComponent("ready-\(writer)"))
        try await AsyncTestWait.waitUntil("concurrent log writers released", timeout: 30) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path)
        }
        for row in rotating ? 1 ..< 3 : 0 ..< 128 {
            await log.append(concurrentWriterLine(writer: writer, row: row))
            await log.flush()
        }
        let snapshot = await log.snapshot()
        XCTAssertEqual(snapshot.droppedCount, 0)
        return true
    }

    private func runConcurrentDecisionLogWriters(in directory: URL, rotating: Bool) async throws {
        let method = rotating
            ? "testDecisionLogRotationIsSafeAcrossConcurrentWriters"
            : "testDecisionLogAppendIsSafeAcrossConcurrentWriters"
        var processes: [Process] = []
        defer {
            for process in processes where process.isRunning {
                process.terminate()
            }
        }
        for writer in 0 ..< 4 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest", "-XCTest", "\(String(reflecting: Self.self))/\(method)",
                Bundle(for: Self.self).bundleURL.path
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["RPCE_ROUTING_LOG_WRITER_DIRECTORY"] = directory.path
            environment["RPCE_ROUTING_LOG_WRITER_INDEX"] = String(writer)
            let home = directory.appendingPathComponent("home-\(writer)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            environment["HOME"] = home.path
            environment["CFFIXED_USER_HOME"] = home.path
            process.environment = environment
            let output = directory.appendingPathComponent("writer-\(writer).log")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            processes.append(process)
        }
        try await AsyncTestWait.waitUntil("all concurrent log writers ready", timeout: 30) {
            (0 ..< 4).allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready-\($0)").path)
            } || processes.contains { !$0.isRunning }
        }
        XCTAssertTrue((0 ..< 4).allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready-\($0)").path)
        })
        try Data().write(to: directory.appendingPathComponent("go"))
        try await AsyncTestWait.waitUntil("concurrent log writers finished", timeout: 30) {
            processes.allSatisfy { !$0.isRunning }
        }
        for (writer, process) in processes.enumerated() {
            let output = try String(contentsOf: directory.appendingPathComponent("writer-\(writer).log"), encoding: .utf8)
            XCTAssertEqual(process.terminationStatus, 0, output)
            XCTAssertTrue(output.contains("\(method)]' passed"), output)
        }
    }

    private func concurrentWriterLine(writer: Int, row: Int) -> Data {
        let json = "{\"writer\":\(writer),\"row\":\(row)}"
        return Data((json + String(repeating: " ", count: 8192 - json.utf8.count - 1) + "\n").utf8)
    }

    private func concurrentWriterRows(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { line in
            XCTAssertEqual(line.utf8.count, 8191)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Int])
            return try "\(XCTUnwrap(object["writer"])):\(XCTUnwrap(object["row"]))"
        }
    }

    private enum StartScenario: CaseIterable { case applied, fallback, rejected }

    @MainActor
    private struct Fixture {
        let base: RoutedStartFixture
        let backend: DecisionLogBackend
        let log: AgentTaskRoutingDecisionLog
        let url: URL
        var window: WindowState {
            base.window
        }

        var viewModel: AgentModeViewModel {
            window.agentModeViewModel
        }
    }

    private var startArguments: [String: Value] {
        ["op": .string("start"), "message": .string(taskSentinel), "detach": .bool(true)]
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DecisionLogTests-\(UUID())", isDirectory: true)
        let directory = root.appendingPathComponent("ModelRouter", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return directory
    }

    private func makeFixture(singleCandidate: Bool = false, autoEffort: Bool = false) async throws -> Fixture {
        let base = try await RoutedStartFixture.make(testCase: self, modelClass: "claude-opus", effortRaw: "high")
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("jev-decisions.jsonl")
        let suite = "DecisionLogTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(
            defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: directory.appendingPathComponent("settings.json"))
        )
        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev, roles: Set(AgentModelCatalog.TaskLabelKind.allCases), providers: [.claudeCode, .codexExec]
        )
        store.setAutoEffortBackend(.jev)
        store.setAutoEffortEnabled(autoEffort)
        let backend = DecisionLogBackend()
        let log = AgentTaskRoutingDecisionLog(fileURL: url)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(service: backend)], demandSource: store, decisionLog: log)
        runtime.candidateBuilderFactory = {
            AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in
                let raw: String
                switch provider {
                case .claudeCode: raw = "claude-opus-5-5"
                case .codexExec where !singleCandidate: raw = "gpt-6-sol"
                default: return []
                }
                let base = AgentModelOption(
                    rawValue: raw, displayName: raw, description: nil, isPlaceholderDefault: false, isProviderDefault: true,
                    supportedReasoningEffortRawValues: singleCandidate ? [] : ["medium", "high"]
                )
                guard provider == .claudeCode, !singleCandidate else { return [base] }
                return [base] + [CodexReasoningEffort.medium, .high].map { effort in
                    AgentModelOption(
                        rawValue: "\(raw):\(effort.rawValue)", displayName: raw, description: nil,
                        isPlaceholderDefault: false, isProviderDefault: false,
                        effortVariant: .init(baseModelRaw: raw, reasoningEffort: effort)
                    )
                }
            })
        }
        let viewModel = base.window.agentModeViewModel
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        addTeardownBlock { await runtime.teardown() }
        await runtime.reconcileDemand()
        try await AsyncTestWait.waitUntil("decision log service ready", timeout: 5) { runtime.isBackendReady(.jev) }
        return Fixture(base: base, backend: backend, log: log, url: url)
    }

    private func composerSession(_ fixture: Fixture) throws -> AgentModeViewModel.TabSession {
        let tabID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspace?.activeComposeTabID)
        fixture.viewModel.test_setCurrentTabIDOverride(tabID)
        let session = fixture.viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = AgentModel.claudeSonnet.rawValue
        return session
    }

    private func startRun(rejected: Bool) -> AgentRunMCPToolService.StartRun {
        { target, message, metadata, viewModel, agent, model, effort, label, workflow, parent, oracle, preserve in
            try await AgentExternalMCPRunStarter.startPreservingCallerBinding(
                target: target, message: message, metadata: metadata, agentModeVM: viewModel,
                agentRaw: agent, modelRaw: model, reasoningEffortRaw: effort, taskLabelKind: label,
                workflow: workflow, expectedParentSessionID: parent, oracleReviewSource: oracle,
                preserveRoutedInitialEffort: preserve,
                dispatchInstruction: { _, _, _, _, _ in
                    if rejected { throw MCPError.internalError("fixture start rejected") }
                    return .startedRun
                }
            )
        }
    }

    private func readRows(_ fixture: Fixture) async throws -> [AgentTaskRoutingLogLine] {
        await fixture.log.flush()
        return try readLines(fixture.url)
    }

    private func readLines(_ url: URL) throws -> [AgentTaskRoutingLogLine] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(AgentTaskRoutingLogLine.self, from: Data($0.utf8))
        }
    }

    private func decisions(_ rows: [AgentTaskRoutingLogLine]) -> [AgentTaskRoutingDecisionEvent] {
        rows.compactMap { if case let .decision(event) = $0 { return event }
            return nil
        }
    }

    private func applications(_ rows: [AgentTaskRoutingLogLine]) -> [AgentTaskRoutingAppliedEvent] {
        rows.compactMap { if case let .applied(event) = $0 { return event }
            return nil
        }
    }

    @discardableResult
    private func assertStages(
        _ rows: [AgentTaskRoutingLogLine], requestID: UUID, expected: Set<AgentTaskRoutingLogStage>,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [AgentTaskRoutingDecisionEvent] {
        let events = decisions(rows).filter { $0.requestID == requestID.uuidString }
        XCTAssertEqual(Set(events.map(\.stage)), expected, file: file, line: line)
        XCTAssertEqual(events.count, expected.count, "Exactly one decision per expected request/stage", file: file, line: line)
        return events
    }

    private func assertEvidence(_ row: AgentTaskRoutingDecisionEvent, file: StaticString = #filePath, line: UInt = #line) throws {
        let chosen = try XCTUnwrap(row.chosenKey, file: file, line: line)
        let probabilities = try XCTUnwrap(row.probabilities, file: file, line: line)
        XCTAssertEqual(Set(probabilities.keys), Set(row.candidates.map(\.key)), file: file, line: line)
        XCTAssertEqual(probabilities[chosen], 0.75, file: file, line: line)
        XCTAssertEqual(row.confidence, 0.75, file: file, line: line)
        XCTAssertEqual(row.inputTokens, 120, file: file, line: line)
        XCTAssertEqual(row.outputTokens, 16, file: file, line: line)
        XCTAssertNotNil(row.latencyMs, file: file, line: line)
        XCTAssertNil(row.failure, file: file, line: line)
        XCTAssertNil(row.rationale, file: file, line: line)
    }

    private func assertApplied(
        _ rows: [AgentTaskRoutingLogLine], scenario: StartScenario, scope: AgentTaskRoutingLogScope,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let events = applications(rows)
        XCTAssertEqual(events.count, 1, "Exactly one application per routed start", file: file, line: line)
        let event = try XCTUnwrap(events.first, file: file, line: line)
        XCTAssertEqual(event.schema, 1, file: file, line: line)
        XCTAssertEqual(event.scope, scope, file: file, line: line)
        let requestID = try XCTUnwrap(UUID(uuidString: event.requestID), file: file, line: line)
        let expected: Set<AgentTaskRoutingLogStage> = scenario == .fallback || (scenario == .rejected && scope == .primarySession)
            ? [.model] : [.model, .effort]
        _ = assertStages(rows, requestID: requestID, expected: expected, file: file, line: line)
        XCTAssertEqual(Set(decisions(rows).map(\.requestID)), [event.requestID], file: file, line: line)
        switch scenario {
        case .applied:
            XCTAssertEqual(event.outcome, .applied, file: file, line: line)
            XCTAssertNotNil(event.sessionID, file: file, line: line)
            XCTAssertEqual(event.provider, "claudeCode", file: file, line: line)
            XCTAssertEqual(event.model, "claude-opus-5-5:high", file: file, line: line)
            XCTAssertEqual(event.effort, "high", file: file, line: line)
            XCTAssertEqual(event.modelParameters, [], file: file, line: line)
            XCTAssertEqual(event.picked, .init(provider: "claudeCode", model: "claude-opus-5-5:high", effort: "high"), file: file, line: line)
        case .fallback:
            XCTAssertEqual(event.outcome, .fallback, file: file, line: line)
            XCTAssertNotNil(event.sessionID, file: file, line: line)
            XCTAssertNotNil(event.provider, file: file, line: line)
            XCTAssertNotNil(event.model, file: file, line: line)
            XCTAssertNil(event.picked, file: file, line: line)
        case .rejected:
            XCTAssertEqual(event.outcome, .rejected, file: file, line: line)
            XCTAssertNil(event.sessionID, file: file, line: line)
            XCTAssertNil(event.provider, file: file, line: line)
            XCTAssertNil(event.model, file: file, line: line)
            XCTAssertNil(event.effort, file: file, line: line)
        }
    }
}

@MainActor
final class AgentTaskRoutingMakerDiversityTests: XCTestCase {
    func testEveryModelDefinitionHasAMaker() {
        let projection = AgentTaskRoutingCandidateBuilder().registeredTargetMakers
        let expected: [String: AgentTaskRoutingMaker] = [
            "gpt-luna": .openai, "gpt-5.6-terra": .openai, "gpt-sol": .openai, "gpt-6-astra": .openai,
            "claude-haiku": .anthropic, "claude-sonnet": .anthropic, "claude-opus": .anthropic, "claude-fable": .anthropic,
            "gemini-flash": .google, "gemini-pro": .google, "grok": .xai, "composer": .cursor, "cursor-grok": .xai
        ]
        XCTAssertEqual(Set(projection.keys), Set(expected.keys))
        XCTAssertEqual(projection.values.compactMap(\.self).count, expected.count)
        for (modelClass, maker) in expected {
            XCTAssertEqual(projection[modelClass] ?? nil, maker, modelClass)
        }
        let identities: [(AgentProviderKind, String, AgentTaskRoutingMaker?)] = [
            (.claudeCode, "opus", .anthropic), (.claudeCode, "default", .anthropic),
            (.codexExec, "gpt-6.1-sol", .openai),
            (.antigravity, "gemini-3.8-flash-high", .google), (.antigravity, "gemini-3.1-pro-low", .google),
            (.grok, "grok-4.7", .xai), (.cursor, "grok-4.7", .xai), (.cursor, "composer-2.5", .cursor),
            (.cursor, "unknown", nil), (.openCode, "claude-opus-5-5", nil)
        ]
        for (provider, raw, maker) in identities {
            XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(provider: provider, modelRaw: raw), maker, raw)
            XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(for: target(provider, raw)), maker, raw)
        }
    }

    func testExcludedMakerIsRemovedBeforeJevRequest() async throws {
        for capacity in [12, 2] {
            let fixture = try await makeFixture(maximumChoices: capacity)
            let result = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "Review the parser", surface: .general, diversity: excluding([.openai]), logContext: fixture.context
            )
            XCTAssertEqual(result?.agentRaw, "claudeCode")
            let requests = await fixture.backend.requests
            let modelRequests = requests.filter { $0.question.name == "model_route" }
            XCTAssertEqual(modelRequests.count, 1)
            let request = try XCTUnwrap(modelRequests.first)
            XCTAssertEqual(request.question.choices.count, 2)
            XCTAssertTrue(request.question.choices.allSatisfy { $0.description.contains("Provider: claudeCode;") })
            XCTAssertFalse(request.question.choices.contains { $0.description.contains("Provider: codexExec;") })
            let row = try await modelRow(fixture)
            let candidates = try XCTUnwrap(row["candidates"] as? [[String: Any]])
            XCTAssertEqual(Set(candidates.compactMap { $0["key"] as? String }), Set(request.question.choices.map(\.opaqueKey)))
            XCTAssertEqual(Set(candidates.compactMap { $0["provider"] as? String }), ["claudeCode"])
        }
    }

    func testSingleAllowedCandidateAppliesWithoutJevRequest() async throws {
        let fixture = try await makeFixture(singleClaude: true)
        let result = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "Review the parser", surface: .general, diversity: excluding([.openai]), logContext: fixture.context
        )
        XCTAssertEqual(result, target(.claudeCode, "claude-opus-5-5"))
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty)
        let row = try await modelRow(fixture)
        XCTAssertEqual(row["outcome"] as? String, "localSingleCandidate")
        XCTAssertEqual((row["candidates"] as? [Any])?.count, 1)
        XCTAssertEqual(row["makerExclusions"] as? [String: [String]], ["openai": ["exclude_makers"]])
    }

    func testAllCandidatesExcludedFailsTyped() async throws {
        let fixture = try await makeFixture()
        do {
            _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                task: "Review the parser", surface: .general, diversity: excluding(AgentTaskRoutingMaker.allCases),
                logContext: fixture.context
            )
            XCTFail("An empty allowed set must reject routing")
        } catch {
            XCTAssertEqual(error as? AgentModeViewModel.GlobalModelRoutingError, .allCandidatesExcluded)
        }
        let requests = await fixture.backend.requests
        XCTAssertTrue(requests.isEmpty)
        let row = try await modelRow(fixture)
        XCTAssertEqual(row["outcome"] as? String, "failed")
        XCTAssertEqual(row["failure"] as? String, "allCandidatesExcluded")
        XCTAssertEqual((row["candidates"] as? [Any])?.count, 0)
    }

    func testFallbackNeverReturnsExcludedMaker() async throws {
        for mode in [FallbackMode.notReady, .abstain, .failure, .disabled] {
            for excludesBaseline in [true, false] {
                let fixture = try await makeFixture(ready: mode != .notReady)
                if mode == .disabled { fixture.store.setModelRouterEnabled(false) }
                if mode == .abstain { await fixture.backend.enqueue(.abstain) }
                if mode == .failure { await fixture.backend.enqueue(.failure) }
                let baseline = excludesBaseline ? target(.codexExec, "gpt-6-sol") : target(.claudeCode, "claude-sonnet-5-5")
                let diversity = excluding([.openai])
                do {
                    let result = try await fixture.viewModel.routeSubagentTargetIfEnabled(
                        task: "Review the parser", surface: .general, baseline: baseline, allowUsageBalance: false,
                        diversity: diversity, logContext: fixture.context
                    )
                    XCTAssertFalse(excludesBaseline, "\(mode): an excluded fallback must fail")
                    let applied = result ?? baseline
                    XCTAssertEqual(AgentTaskRoutingMakerCatalog.maker(for: applied), .anthropic)
                } catch {
                    XCTAssertTrue(excludesBaseline, "\(mode): an allowed fallback must remain usable")
                    XCTAssertEqual(error as? AgentModeViewModel.GlobalModelRoutingError, .fallbackDiversityExcluded)
                }
                let requests = await fixture.backend.requests
                if mode == .notReady || mode == .disabled { XCTAssertTrue(requests.isEmpty) }
            }
        }
    }

    func testExclusionIsLoggedWithSource() async throws {
        let fixture = try await makeFixture()
        let diversity = AgentTaskRoutingDiversityOptions(exclusions: [
            "openai": [.reviewDiversity, .diverseFromSessions, .excludeMakers]
        ])
        _ = try await fixture.viewModel.routeSubagentTargetIfEnabled(
            task: "Review the parser", surface: .general, diversity: diversity, logContext: fixture.context
        )
        let rows = try await rows(fixture)
        let models = rows.filter { $0["stage"] as? String == "model" }
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(models.first)["makerExclusions"] as? [String: [String]],
            ["openai": ["exclude_makers", "diverse_from_sessions", "review_diversity"]]
        )
        let efforts = rows.filter { $0["stage"] as? String == "effort" }
        XCTAssertEqual(efforts.count, 1)
        XCTAssertTrue(try XCTUnwrap(efforts.first)["makerExclusions"] is NSNull)
    }

    private enum FallbackMode { case notReady, abstain, failure, disabled }

    @MainActor
    private struct Fixture {
        let base: RoutedStartFixture
        let store: GlobalSettingsStore
        let backend: DecisionLogBackend
        let log: AgentTaskRoutingDecisionLog
        let url: URL
        let context: AgentTaskRoutingRouteContext
        var viewModel: AgentModeViewModel {
            base.window.agentModeViewModel
        }
    }

    private func target(_ provider: AgentProviderKind, _ raw: String) -> AgentRoutingExecutableTarget {
        .init(agentRaw: provider.rawValue, modelRaw: raw, reasoningEffortRaw: nil, modelParameters: [])
    }

    private func excluding(_ makers: [AgentTaskRoutingMaker]) -> AgentTaskRoutingDiversityOptions {
        .init(exclusions: Dictionary(uniqueKeysWithValues: makers.map { ($0.rawValue, [.excludeMakers]) }))
    }

    private func makeFixture(singleClaude: Bool = false, ready: Bool = true, maximumChoices: Int = 12) async throws -> Fixture {
        let base = try await RoutedStartFixture.make(testCase: self, modelClass: "claude-opus", effortRaw: "high")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MakerDiversity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "MakerDiversity.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(
            defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json"))
        )
        store.enableModelRouterWithCurrentPolicy(
            backendID: .jev, roles: Set(AgentModelCatalog.TaskLabelKind.allCases), providers: [.claudeCode, .codexExec]
        )
        let backend = DecisionLogBackend(ready: ready, maximumChoices: maximumChoices)
        let url = root.appendingPathComponent("ModelRouter", isDirectory: true).appendingPathComponent("jev-decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: url)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(service: backend)], demandSource: store, decisionLog: log)
        runtime.candidateBuilderFactory = {
            AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in
                let models: [String] = switch provider {
                case .claudeCode: singleClaude ? ["claude-opus-5-5"] : ["claude-sonnet-5-5", "claude-opus-5-5"]
                case .codexExec: ["gpt-6-luna", "gpt-6-sol"]
                default: []
                }
                return models.map { AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: false) }
            })
        }
        let viewModel = base.window.agentModeViewModel
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        addTeardownBlock { await runtime.teardown() }
        await runtime.reconcileDemand()
        if ready {
            try await AsyncTestWait.waitUntil("maker diversity service ready", timeout: 5) { runtime.isBackendReady(.jev) }
        }
        let context = try XCTUnwrap(viewModel.makeRouteLogContext(scope: .subagent))
        return .init(base: base, store: store, backend: backend, log: log, url: url, context: context)
    }

    private func rows(_ fixture: Fixture) async throws -> [[String: Any]] {
        await fixture.log.flush()
        return try String(contentsOf: fixture.url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func modelRow(_ fixture: Fixture) async throws -> [String: Any] {
        let models = try await rows(fixture).filter { $0["stage"] as? String == "model" }
        XCTAssertEqual(models.count, 1)
        return try XCTUnwrap(models.first)
    }
}

@MainActor
final class AgentTaskRoutingExplorationTests: XCTestCase {
    private let opus = "claude-opus-5-5"
    private let sonnet = "claude-sonnet-5-5"

    func testDebugAndReleaseUseSeparateRoutingStateLocations() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingLocations-\(UUID())", isDirectory: true)
        let debug = AppProfileLocations(identity: .repoPromptCE(.debug), homeDirectory: home, releaseCustomStorageRoots: [])
        let release = AppProfileLocations(identity: .repoPromptCE(.release), homeDirectory: home)
        XCTAssertNotEqual(debug.applicationSupportRoot, release.applicationSupportRoot)
        let counter = AgentTaskRoutingExplorationAdvisor.defaultFileURL()
        let log = AgentTaskRoutingDecisionLog.defaultFileURL()
        let counterRoot = counter.deletingLastPathComponent().deletingLastPathComponent()
        let logRoot = log.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if DEBUG
            let expected = debug.applicationSupportRoot.lastPathComponent
            let other = release.applicationSupportRoot.lastPathComponent
        #else
            let expected = release.applicationSupportRoot.lastPathComponent
            let other = debug.applicationSupportRoot.lastPathComponent
        #endif
        XCTAssertEqual(counterRoot.lastPathComponent, expected)
        XCTAssertEqual(logRoot.lastPathComponent, expected)
        XCTAssertNotEqual(counterRoot.lastPathComponent, other)
        XCTAssertNotEqual(logRoot.lastPathComponent, other)
        XCTAssertEqual(counterRoot, logRoot)
    }

    func testOffNeverExplores() async throws {
        let fixture = try await makeFixture(randomness: .off)
        for counter in 1 ... 40 {
            let route = try await route(fixture)
            XCTAssertEqual(route.target?.modelRaw, "claude-opus-5-5:high")
            try assertOverride(route.row, kind: "none", counter: counter)
        }
        fixture.store.setRandomness(.low)
        for _ in 1 ... 9 {
            _ = try await route(fixture)
        }
        let fiftieth = try await route(fixture)
        XCTAssertEqual(fiftieth.target?.modelRaw, "claude-sonnet-5-5:high")
    }

    func testLevelsExploreAtFixedPositions() async throws {
        let levels: [(AgentRoutingRandomness, [Int])] = [
            (.low, [10, 30]), (.medium, [5, 15, 25, 35]), (.high, [3, 8, 13, 18, 23, 28, 33, 38])
        ]
        for (level, positions) in levels {
            let fixture = try await makeFixture(randomness: level)
            for counter in 1 ... 40 {
                let result = try await route(fixture)
                let exploring = positions.contains(counter)
                XCTAssertEqual(result.target?.modelRaw, exploring ? "claude-sonnet-5-5:high" : "claude-opus-5-5:high", "\(level)#\(counter)")
                try assertOverride(result.row, kind: exploring ? "exploration" : "none", counter: counter)
            }
        }
        let advisor = AgentTaskRoutingExplorationAdvisor(fileURL: nil)
        for counter in 1 ... 20 {
            for scope in [AgentTaskRoutingScope.primarySession, .subagent] {
                let record = await advisor.decide(scope: scope, randomness: .low, chosenKey: "a", orderedKeys: ["a", "b"], scores: ["a": 0.75, "b": 0.25])
                XCTAssertEqual(record.counter, UInt64(counter))
                XCTAssertEqual(record.kind, counter == 10 ? .exploration : .none)
                XCTAssertEqual(record.appliedKey, counter == 10 ? "b" : "a")
            }
        }
    }

    func testExplorationAppliesJevRunnerUp() async throws {
        let fixture = try await makeFixture(stored: ["subagent": 9])
        let result = try await route(fixture)
        XCTAssertEqual(result.target?.modelRaw, "claude-sonnet-5-5:high")
        XCTAssertNotEqual(result.target?.modelRaw, "claude-opus-5-5:high")
        XCTAssertEqual(result.target.map(AgentTaskRoutingLogTarget.init)?.effort, "high")
        let requests = await fixture.backend.requests
        let effort = try XCTUnwrap(requests.first { $0.question.name == "effort_route" })
        XCTAssertTrue(effort.question.choices.allSatisfy { $0.description.contains(sonnet) })

        let tied = try await makeFixture(stored: ["subagent": 9], mode: .tiedRunnerUp)
        let tiedResult = try await route(tied)
        let tiedRequests = await tied.backend.requests
        let model = try XCTUnwrap(tiedRequests.first { $0.question.name == "model_route" })
        let firstTied = try XCTUnwrap(model.question.choices.first {
            $0.description.contains(sonnet) || $0.description.contains("claude-haiku-4-5")
        })
        let override = try XCTUnwrap(tiedResult.row["override"] as? [String: Any])
        XCTAssertEqual(override["appliedKey"] as? String, firstTied.opaqueKey)

        let unavailable = try await makeFixture(stored: ["subagent": 9], mode: .missingProbabilities)
        let unchanged = try await route(unavailable)
        XCTAssertEqual(unchanged.target?.modelRaw, "claude-opus-5-5:high")
        try assertOverride(unchanged.row, kind: "explorationUnavailable", counter: 10)

        let primary = try await makeFixture(stored: ["primarySession": 9])
        let session = try await routeComposer(primary)
        XCTAssertEqual(session.selectedModelRaw, "claude-sonnet-5-5:high")
        XCTAssertNotEqual(session.selectedModelRaw, opus, "The routed destination must not apply Jev's first choice")
        let row = try await modelRows(primary).last
        try assertOverride(XCTUnwrap(row), kind: "exploration", counter: 10)
    }

    func testExplorationSkipsUsageBalancing() async throws {
        let control = try await makeFixture()
        try enableUsage(control)
        let balanced = try await route(control)
        XCTAssertEqual(balanced.target?.agentRaw, "codexExec", "The control must exercise a real usage override")
        try assertOverride(balanced.row, kind: "none", counter: 1)

        let exploring = try await makeFixture(stored: ["subagent": 9])
        try enableUsage(exploring)
        let kept = try await route(exploring)
        XCTAssertEqual(kept.target?.agentRaw, "claudeCode")
        XCTAssertEqual(kept.target?.modelRaw, "claude-sonnet-5-5:high", "Usage balancing must not replace an explored pick")
        try assertOverride(kept.row, kind: "exploration", counter: 10)

        let primary = try await makeFixture(stored: ["primarySession": 9])
        try enableUsage(primary)
        let session = try await routeComposer(primary)
        XCTAssertEqual(session.selectedModelRaw, "claude-sonnet-5-5:high")
        XCTAssertNotEqual(session.selectedModelRaw, opus, "The routed destination must not apply Jev's first choice")
        XCTAssertNil(session.automationTurnAudit.last?.router.usageBalancingReason)
    }

    func testSingleCandidateAndFailuresDoNotAdvanceCounter() async throws {
        for mode in [ExplorationDecisionBackend.Mode.single, .abstain, .failure, .cancelled, .invalidKey, .nonJev] {
            let fixture = try await makeFixture(mode: mode)
            do {
                _ = try await route(fixture)
                XCTAssertNotEqual(mode, .cancelled)
            } catch AgentModeViewModel.GlobalModelRoutingError.cancelled {
                XCTAssertEqual(mode, .cancelled)
            }
            let count = await fixture.advisor.counter(for: .subagent)
            XCTAssertEqual(count, 0, "\(mode)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.counterURL.path), "\(mode)")
            let rows = try await modelRows(fixture)
            XCTAssertEqual(rows.count, 1)
            XCTAssertTrue(try XCTUnwrap(rows.first)["override"] is NSNull)
        }
        let counted = try await makeFixture()
        _ = try await route(counted)
        let count = await counted.advisor.counter(for: .subagent)
        XCTAssertEqual(count, 1, "The effort stage does not consume another count")
    }

    func testCounterPersistsWithoutSettingsRevisionChange() async throws {
        let fixture = try await makeFixture(randomness: .off)
        let revision = fixture.store.modelRouterSettingsRevision
        let settings = fixture.store.modelRouterConfiguration()
        for _ in 1 ... 9 {
            _ = try await route(fixture)
        }
        XCTAssertEqual(fixture.store.modelRouterSettingsRevision, revision)
        XCTAssertEqual(fixture.store.modelRouterConfiguration(), settings)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.counterURL)) as? [String: Any])
        XCTAssertEqual(document["counters"] as? [String: Int], ["subagent": 9])
        XCTAssertNotEqual(fixture.counterURL.lastPathComponent, "globalSettings.json")
        let restarted = try await makeFixture(counterURL: fixture.counterURL)
        let result = try await route(restarted)
        XCTAssertEqual(result.target?.modelRaw, "claude-sonnet-5-5:high")
        try assertOverride(result.row, kind: "exploration", counter: 10)
        let primary = await restarted.advisor.decide(scope: .primarySession, randomness: .low, chosenKey: "a", orderedKeys: ["a", "b"], scores: ["a": 0.75, "b": 0.25])
        XCTAssertEqual(primary.counter, 1)
        XCTAssertEqual(primary.kind, .none)
    }

    func testExplorationOverrideIsLogged() async throws {
        let fixture = try await makeFixture(stored: ["subagent": 9])
        let result = try await route(fixture, diversity: .init(exclusions: ["openai": [.excludeMakers]]))
        let record = try XCTUnwrap(result.row["override"] as? [String: Any])
        let candidates = try XCTUnwrap(result.row["candidates"] as? [[String: Any]])
        let original = try XCTUnwrap(candidates.first { $0["model"] as? String == opus }?["key"] as? String)
        let applied = try XCTUnwrap(candidates.first { $0["model"] as? String == sonnet }?["key"] as? String)
        XCTAssertEqual(record["originalKey"] as? String, original)
        XCTAssertEqual(record["appliedKey"] as? String, applied)
        XCTAssertNotEqual(original, applied)
        XCTAssertEqual(result.row["chosenKey"] as? String, original)
        XCTAssertEqual((result.row["probabilities"] as? [String: Double])?[original], 0.7)
        XCTAssertEqual(record["randomness"] as? String, "low")
        XCTAssertEqual(record["durable"] as? Bool, true)
        XCTAssertEqual(result.row["makerExclusions"] as? [String: [String]], ["openai": ["exclude_makers"]])
        try assertOverride(result.row, kind: "exploration", counter: 10)
    }

    @MainActor
    private struct Fixture {
        let base: RoutedStartFixture
        let store: GlobalSettingsStore
        let backend: ExplorationDecisionBackend
        let advisor: AgentTaskRoutingExplorationAdvisor
        let log: AgentTaskRoutingDecisionLog
        let logURL: URL
        let counterURL: URL
        var viewModel: AgentModeViewModel {
            base.window.agentModeViewModel
        }
    }

    private func makeFixture(
        stored: [String: Int] = [:], randomness: AgentRoutingRandomness = .low,
        mode: ExplorationDecisionBackend.Mode = .selected, counterURL: URL? = nil
    ) async throws -> Fixture {
        let base = try await RoutedStartFixture.make(testCase: self, modelClass: "claude-opus", effortRaw: "high")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Exploration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = counterURL ?? root.appendingPathComponent("exploration-counters.json")
        if !stored.isEmpty {
            try JSONSerialization.data(withJSONObject: ["schema": 1, "counters": stored]).write(to: url)
        }
        let suite = "Exploration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        let backend = ExplorationDecisionBackend(mode: mode)
        store.enableModelRouterWithCurrentPolicy(backendID: backend.id, roles: Set(AgentModelCatalog.TaskLabelKind.allCases), providers: [.claudeCode, .codexExec])
        store.setRandomness(randomness)
        let advisor = AgentTaskRoutingExplorationAdvisor(fileURL: url)
        let logURL = root.appendingPathComponent("ModelRouter", isDirectory: true).appendingPathComponent("decisions.jsonl")
        let log = AgentTaskRoutingDecisionLog(fileURL: logURL)
        let runtime = try AgentTaskRouterRuntime(registrations: [.init(service: backend)], demandSource: store, decisionLog: log, explorationAdvisor: advisor)
        runtime.candidateBuilderFactory = {
            AgentTaskRoutingCandidateBuilder(modelOptions: { provider, _ in
                let raws: [String] = switch provider {
                case .claudeCode: mode == .single ? ["claude-opus-5-5"] : ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"]
                case .codexExec: mode == .single ? [] : ["gpt-6-luna", "gpt-6-sol"]
                default: []
                }
                return raws.flatMap { raw -> [AgentModelOption] in
                    let base = AgentModelOption(rawValue: raw, displayName: raw, description: nil, isPlaceholderDefault: false, isProviderDefault: true, supportedReasoningEffortRawValues: mode == .single ? [] : ["medium", "high"])
                    guard provider == .claudeCode, mode != .single else { return [base] }
                    return [base] + [CodexReasoningEffort.medium, .high].map { effort in
                        AgentModelOption(rawValue: "\(raw):\(effort.rawValue)", displayName: raw, description: nil, isPlaceholderDefault: false, isProviderDefault: false, effortVariant: .init(baseModelRaw: raw, reasoningEffort: effort))
                    }
                }
            })
        }
        let viewModel = base.window.agentModeViewModel
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        addTeardownBlock { await runtime.teardown() }
        await runtime.reconcileDemand()
        try await AsyncTestWait.waitUntil("exploration service ready", timeout: 5) { runtime.isBackendReady(backend.id) }
        return .init(base: base, store: store, backend: backend, advisor: advisor, log: log, logURL: logURL, counterURL: url)
    }

    private func route(_ fixture: Fixture, diversity: AgentTaskRoutingDiversityOptions = .none) async throws -> (target: AgentRoutingExecutableTarget?, row: [String: Any]) {
        let context = try XCTUnwrap(fixture.viewModel.makeRouteLogContext(scope: .subagent))
        let target = try await fixture.viewModel.routeSubagentTargetIfEnabled(task: "Implement parser", surface: .general, diversity: diversity, logContext: context)
        let rows = try await modelRows(fixture)
        return try (target, XCTUnwrap(rows.last { $0["requestID"] as? String == context.requestID.uuidString }))
    }

    private func routeComposer(_ fixture: Fixture) async throws -> AgentModeViewModel.TabSession {
        let vm = fixture.viewModel
        let tabID = try XCTUnwrap(fixture.base.window.workspaceManager.activeWorkspace?.activeComposeTabID)
        vm.test_setCurrentTabIDOverride(tabID)
        let session = vm.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = opus
        let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: tabID, session: session))
        let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "Implement parser")
        guard case let .claimed(claim) = vm.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else {
            throw XCTUnwrapError()
        }
        vm.test_setCurrentTabIDOverride(nil)
        var destinationTabID: UUID?
        let result = await vm.executeComposerSubmitAttempt(text: "Implement parser", claim: claim, createAndActivateSessionTab: {
            destinationTabID = await vm.createAndActivateSessionTab()
            return destinationTabID
        })
        XCTAssertEqual(result, .submitted)
        let routedSession = try XCTUnwrap(vm.session(for: XCTUnwrap(destinationTabID), createIfNeeded: false))
        XCTAssertNotEqual(routedSession.tabID, session.tabID)
        XCTAssertEqual(routedSession.automationTurnAudit.last?.router.chosenModelRaw, routedSession.selectedModelRaw)
        return routedSession
    }

    private struct XCTUnwrapError: Error {}

    private func modelRows(_ fixture: Fixture) async throws -> [[String: Any]] {
        await fixture.log.flush()
        return try String(contentsOf: fixture.logURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { $0["event"] as? String == "decision" && $0["stage"] as? String == "model" }
    }

    private func assertOverride(_ row: [String: Any], kind: String, counter: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let record = try XCTUnwrap(row["override"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(record["kind"] as? String, kind, file: file, line: line)
        XCTAssertEqual(record["counter"] as? Int, counter, file: file, line: line)
        XCTAssertEqual(record["position"] as? Int, (counter - 1) % 20 + 1, file: file, line: line)
    }

    private func enableUsage(_ fixture: Fixture) throws {
        fixture.store.setUsageBalancingEnabled(true)
        let advisor = AgentUsageBalancer()
        fixture.viewModel.modelRouterRuntime?.usageBalancer = advisor
        let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(18000))
        for (provider, used) in [(AgentProviderKind.claudeCode, 95), (.codexExec, 10)] {
            let snapshot = try ClaudeAccountUsageMapper.snapshot(data: Data("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":\"\(reset)\"}}".utf8), account: .init(lineage: .anthropicFirstParty, opaqueAccountID: nil, credentialProfileID: "exploration-test"), observedAt: now)
            advisor.update(snapshot, provider: provider.rawValue)
        }
    }
}

private actor ExplorationDecisionBackend: DecisionService {
    enum Mode: Equatable { case selected, tiedRunnerUp, missingProbabilities, single, abstain, failure, cancelled, invalidKey, nonJev }
    nonisolated let id: DecisionServiceID
    nonisolated let displayName = "Exploration fixture"
    nonisolated var capabilities: DecisionServiceCapabilities {
        .init(contextKinds: [.text], finiteChoice: .init(minimumChoices: 2, maximumChoices: 12, maximumContextBytes: 24 * 1024, maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024, maximumAggregateBytes: 128 * 1024), evidence: .init(confidence: true, probabilityDistribution: true, usage: true))
    }

    private let mode: Mode
    private(set) var requests: [FiniteChoiceDecisionRequest] = []

    init(mode: Mode) {
        self.mode = mode
        id = mode == .nonJev ? .init(rawValue: "exploration-other") : .jev
    }

    func readinessSnapshot() -> DecisionReadiness {
        .ready(generation: 1, policyVersion: JevRouterCredentialService.routingPolicyVersion)
    }

    func decide(_ request: FiniteChoiceDecisionRequest) -> DecisionOutcome {
        requests.append(request)
        let modelStage = request.question.name == "model_route"
        if modelStage {
            switch mode {
            case .abstain: return .abstained(reasonCode: "fixture", evidence: nil)
            case .failure: return .failed(category: .transport, retryable: true, evidence: nil)
            case .cancelled: return .cancelled
            case .invalidKey: return .selected(opaqueKey: "not-a-candidate", evidence: nil)
            default: break
            }
        }
        guard let chosen = request.question.choices.first(where: {
            $0.description.contains(modelStage ? "claude-opus-5-5" : "Role references: effort:high")
        }) else { return .invalidResponse }
        let others = request.question.choices.filter { $0.opaqueKey != chosen.opaqueKey }
        let runnerUps = others.filter {
            $0.description.contains("claude-sonnet-5-5") || (mode == .tiedRunnerUp && $0.description.contains("claude-haiku-4-5"))
        }
        let probabilities = request.question.choices.map { choice in
            let value: Double = if choice.opaqueKey == chosen.opaqueKey { 0.7 }
            else if modelStage, runnerUps.contains(where: { $0.opaqueKey == choice.opaqueKey }) { 0.24 / Double(runnerUps.count) }
            else { (modelStage ? 0.06 : 0.3) / Double(modelStage ? max(others.count - runnerUps.count, 1) : others.count) }
            return DecisionChoiceValue(opaqueKey: choice.opaqueKey, value: value)
        }
        let evidence = DecisionEvidence(acceptancePolicyVersion: JevRouterCredentialService.routingPolicyVersion, confidence: 0.7, scores: nil, scoreSemantics: nil, probabilities: mode == .missingProbabilities ? nil : probabilities, probabilitySemantics: mode == .missingProbabilities ? nil : .probability, usage: nil)
        return .selected(opaqueKey: chosen.opaqueKey, evidence: evidence)
    }
}

private actor DecisionLogBackend: DecisionService {
    enum Plan: Equatable { case selected, abstain, failure, cancelled }
    nonisolated let id = DecisionServiceID.jev
    nonisolated let displayName = "Decision log fixture"
    nonisolated let maximumChoices: Int
    nonisolated var capabilities: DecisionServiceCapabilities {
        .init(
            contextKinds: [.text],
            finiteChoice: .init(
                minimumChoices: 2, maximumChoices: maximumChoices, maximumContextBytes: 24 * 1024,
                maximumInstructionsBytes: 16 * 1024, maximumChoiceDescriptionBytes: 8 * 1024,
                maximumAggregateBytes: 128 * 1024
            ),
            evidence: .init(confidence: true, probabilityDistribution: true, usage: true)
        )
    }

    private let ready: Bool
    private var plans: [Plan] = []
    private(set) var requests: [FiniteChoiceDecisionRequest] = []

    init(ready: Bool = true, maximumChoices: Int = 12) {
        self.ready = ready
        self.maximumChoices = maximumChoices
    }

    func enqueue(_ plan: Plan) {
        plans.append(plan)
    }

    func readinessSnapshot() -> DecisionReadiness {
        ready ? .ready(generation: 1, policyVersion: JevRouterCredentialService.routingPolicyVersion)
            : .needsConfiguration(generation: 1, reason: "Fixture is not configured")
    }

    func decide(_ request: FiniteChoiceDecisionRequest) -> DecisionOutcome {
        requests.append(request)
        let plan = plans.isEmpty ? .selected : plans.removeFirst()
        if plan == .cancelled { return .cancelled }
        if plan == .failure { return .failed(category: .transport, retryable: true, evidence: nil) }
        let choice = request.question.choices.first {
            switch request.question.name {
            case "model_route": $0.description.contains("Provider: claudeCode;")
            case "effort_route": $0.description.contains("Role references: effort:high")
            default: $0.description.contains("Use medium reasoning effort")
            }
        }
        guard let choice else { return .invalidResponse }
        let confidence = plan == .abstain ? 0.5 : 0.75
        let remainder = (1 - confidence) / Double(request.question.choices.count - 1)
        let evidence = DecisionEvidence(
            acceptancePolicyVersion: JevRouterCredentialService.routingPolicyVersion,
            confidence: confidence, scores: nil, scoreSemantics: nil,
            probabilities: request.question.choices.map { .init(opaqueKey: $0.opaqueKey, value: $0.opaqueKey == choice.opaqueKey ? confidence : remainder) },
            probabilitySemantics: .probability, usage: .init(inputTokens: 120, outputTokens: 16)
        )
        return plan == .abstain ? .abstained(reasonCode: "confidence_below_floor", evidence: evidence)
            : .selected(opaqueKey: choice.opaqueKey, evidence: evidence)
    }
}
