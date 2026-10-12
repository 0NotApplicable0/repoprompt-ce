import Foundation

extension AgentModeViewModel {
    enum GlobalModelRoutingError: LocalizedError {
        case unavailable
        case noTargets
        case failed
        case cancelled
        case stale
        case allCandidatesExcluded
        case fallbackDiversityExcluded

        var errorDescription: String? {
            switch self {
            case .unavailable: "Model Router is enabled but its routing service is unavailable."
            case .noTargets: "Model Router has no available targets for this session type."
            case .failed: "Model Router could not choose a target."
            case .cancelled: "Model routing was cancelled."
            case .stale: "The Model Router policy changed while the request was in progress."
            case .allCandidatesExcluded: "Every Model Router candidate belongs to an excluded maker."
            case .fallbackDiversityExcluded: "Model Router fallback would use an excluded or unknown maker."
            }
        }
    }

    private struct RoutedSelectionRollback {
        let target: AgentRoutingExecutableTarget
    }

    func modelRouterPillProps() -> AgentModelRouterPillProps {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        let available = modelRouterCanRoutePrimarySession(configuration)
        let isRouting = currentTabID.map { freshTaskRoutingByTabID[$0] != nil } ?? false
        let disabledReason: String? = if configuration.enabled, !available {
            "Router is enabled but paused until its routing service and provider targets are available. Click to turn it off."
        } else if !available {
            "Configure a routing service and targets in Model Router Settings."
        } else {
            nil
        }
        return AgentModelRouterPillProps(
            isOn: configuration.enabled,
            isAvailable: available || configuration.enabled,
            isRouting: isRouting,
            disabledReason: disabledReason,
            usageBalancing: configuration.usageBalancing.enabled
        )
    }

    func autoEffortPillProps() -> AgentAutoEffortPillProps {
        let session = activeSession
        let feedback = session?.autoEffortFeedback.flatMap { feedback in
            feedback.provider == session?.selectedAgent && feedback.selectedModelRaw == session?.selectedModelRaw
                ? feedback : nil
        }
        return AgentAutoEffortPillProps(
            isOn: modelRouterSettingsStore.autoEffortEnabled(),
            isAvailable: modelRouterRuntime?.isBackendReady(.jev) == true,
            isJudging: session?.autoEffortJudgmentID != nil,
            feedback: feedback
        )
    }

    func toggleAutoEffort() {
        let enabled = modelRouterSettingsStore.autoEffortEnabled()
        guard enabled || modelRouterRuntime?.isBackendReady(.jev) == true else { return }
        modelRouterSettingsStore.setAutoEffortEnabled(!enabled)
        syncStatusPillsUIState()
    }

    func handleModelRouterRuntimeChanged() {
        reconcileModelRouterEnabledState()
    }

    func handleModelRouterAvailabilityChanged() {
        reconcileModelRouterEnabledState()
    }

    private func reconcileModelRouterEnabledState() {
        // Readiness and target availability are transient runtime observations, not
        // authorities for the user's persisted enablement intent. Keeping the intent
        // enabled lets startup and provider discovery recover automatically.
        syncAllActiveUIState()
    }

    func toggleGlobalModelRouter() {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        if configuration.enabled {
            modelRouterSettingsStore.setModelRouterEnabled(false)
            modelRouterRuntime?.cancelRoutingRequests()
            syncAllActiveUIState()
            return
        }
        guard let backendID = configuration.selectedBackendID,
              modelRouterRuntime?.isBackendReady(backendID) == true
        else { return }
        guard (try? AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: providers(for: .primarySession, configuration: configuration),
            availability: modelRouterAvailabilityContext
        )) != nil else { return }
        modelRouterSettingsStore.setModelRouterEnabled(true)
        syncAllActiveUIState()
    }

    func cancelFreshTaskRouting(tabID: UUID) async {
        guard let runtime = modelRouterRuntime,
              let owned = freshTaskRoutingByTabID[tabID]
        else { return }
        await runtime.coordinator.cancel(requestID: owned.requestID)
        owned.task.cancel()
        clearFreshTaskRoutingOwnership(owned)
    }

    func isGlobalModelRouterControllingFreshTask(_ session: TabSession) -> Bool {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        return configuration.enabled
            && modelRouterCanRoutePrimarySession(configuration)
            && freshTaskRoutingEligibility(session: session, text: nil)
    }

    /// Mints a route-owned decision-log context for one routed request, or nil without a router runtime.
    func makeRouteLogContext(
        scope: AgentTaskRoutingLogScope,
        requestID: UUID = UUID()
    ) -> AgentTaskRoutingRouteContext? {
        modelRouterRuntime.map {
            AgentTaskRoutingRouteContext(requestID: requestID, scope: scope, log: $0.decisionLog)
        }
    }

    /// The composer wrapper: the route context lives for this submission and its single start hook.
    func submitUserTurnAfterFreshTaskRouting(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID
    ) async -> UserTurnSubmissionResult {
        guard let context = makeRouteLogContext(scope: .primarySession, requestID: claim.attempt.id) else {
            return await submitUserTurnAfterFreshTaskRoutingBody(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID, logContext: nil
            )
        }
        return await context.runStartScope(unarmedOnReturn: { (result: UserTurnSubmissionResult) in
            if case .blocked = result { return .rejected }
            return .notStarted
        }) {
            await submitUserTurnAfterFreshTaskRoutingBody(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID, logContext: context
            )
        }
    }

    private func submitUserTurnAfterFreshTaskRoutingBody(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID,
        logContext: AgentTaskRoutingRouteContext?
    ) async -> UserTurnSubmissionResult {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.enabled,
              freshTaskRoutingEligibility(session: session, text: text)
        else {
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID
            )
        }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else {
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                routerAudit: .init(configured: true, eligible: true, judgmentRequested: false, decision: .unavailable)
            )
        }

        let providers = providers(for: .primarySession, configuration: configuration)
        let routeTask = Task {
            await routeModelThenEffort(
                requestID: claim.attempt.id,
                text: text,
                scope: .primarySession,
                surface: .general,
                providers: providers,
                configuration: configuration,
                backendID: backendID,
                runtime: runtime,
                logContext: logContext
            )
        }
        let stagedResult: StagedTaskRoutingResult
        do {
            let ownership = FreshTaskRoutingOwnership(
                requestID: claim.attempt.id,
                sourceTabID: claim.attempt.sourceTabID,
                destinationTabID: destinationTabID,
                task: routeTask
            )
            guard freshTaskRoutingByTabID[ownership.sourceTabID] == nil,
                  freshTaskRoutingByTabID[ownership.destinationTabID] == nil
            else {
                routeTask.cancel()
                await runtime.coordinator.cancel(requestID: claim.attempt.id)
                _ = await routeTask.value
                return .blocked(message: "Model routing is already in progress for this task.")
            }
            freshTaskRoutingByTabID[ownership.sourceTabID] = ownership
            freshTaskRoutingByTabID[ownership.destinationTabID] = ownership
            syncComposerUIState()
            syncStatusPillsUIState()
            stagedResult = await routeTask.value
            guard ownsFreshTaskRouting(ownership) else {
                return .blocked(message: "Model routing was cancelled.")
            }
            clearFreshTaskRoutingOwnership(ownership)
        }
        let candidates = stagedResult.candidates
        let outcome = stagedResult.outcome
        var routedAudit = AgentAutomationTurnAudit.Feature(
            configured: true,
            eligible: true,
            judgmentRequested: stagedResult.judgmentRequested,
            decision: .selected,
            fallbackApplied: stagedResult.effortFallback,
            usageBalancingReason: stagedResult.usageBalancingReason
        )
        let fallbackAudit = AgentAutomationTurnAudit.Feature(
            configured: true,
            eligible: true,
            judgmentRequested: stagedResult.judgmentRequested,
            decision: .fallback,
            fallbackApplied: true
        )

        let currentConfiguration = modelRouterSettingsStore.modelRouterConfiguration()
        guard composerSubmitClaimIsCurrent(claim),
              sessions[destinationTabID] === session,
              currentConfiguration.revision == configuration.revision,
              currentConfiguration.selectedBackendID == backendID,
              freshTaskRoutingEligibility(session: session, text: text)
        else {
            return .blocked(message: "The routing request became stale before submission.")
        }

        switch outcome {
        case let .selected(opaqueKey, _):
            guard let selected = candidates.only(where: { $0.opaqueKey == opaqueKey }) else {
                return await submitUserTurnAfterAutoEffort(
                    text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                    routerAudit: fallbackAudit
                )
            }
            let baseline = RoutedSelectionRollback(target: executableTarget(for: session))
            guard applyRoutingTarget(selected.target, to: session) else {
                return await submitUserTurnAfterAutoEffort(
                    text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                    routerAudit: fallbackAudit
                )
            }
            await logContext?.recordPick(selected.target)
            routedAudit.chosenModelRaw = selected.target.modelRaw
            routedAudit.chosenEffortRaw = selected.target.reasoningEffortRaw
            guard composerSubmitClaimIsCurrent(claim),
                  sessions[destinationTabID] === session,
                  modelRouterSettingsStore.modelRouterConfiguration().revision == configuration.revision,
                  freshTaskRoutingEligibility(session: session, text: text)
            else {
                restoreRoutingSelection(baseline, on: session)
                return .blocked(message: "The routing request became stale before submission.")
            }
            let result = submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot,
                routerAudit: routedAudit
            )
            if result != .submitted {
                restoreRoutingSelection(baseline, on: session)
            } else {
                session.isDirty = true
                scheduleSave(for: session.tabID)
            }
            return result
        case .abstained, .failed:
            return await submitUserTurnAfterUsageBalancing(
                text: text, claim: claim, session: session, destinationTabID: destinationTabID,
                routerAudit: fallbackAudit
            )
        case .cancelled:
            return .blocked(message: "Model routing was cancelled.")
        }
    }

    /// A routed fresh task already received its initial effort from Model Router. All other
    /// eligible user turns use the same decision path, whether sent by the composer or MCP.
    func submitUserTurnAfterAutoEffort(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID,
        routerAudit: AgentAutomationTurnAudit.Feature? = nil
    ) async -> UserTurnSubmissionResult {
        guard modelRouterSettingsStore.autoEffortEnabled() else {
            return submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot,
                routerAudit: routerAudit
            )
        }
        let choice = await chooseAutoEffortForUserTurn(
            text: claim.attempt.rawDraftSnapshot,
            session: session,
            workflow: session.selectedWorkflow
        )
        let selection = choice.selection
        guard composerSubmitClaimIsCurrent(claim), sessions[destinationTabID] === session
        else { return .blocked(message: Self.staleComposerSubmitTargetMessage) }
        if let routerAudit, routerAudit.usageBalancingReason != nil {
            guard modelRouterSettingsStore.modelRouterConfiguration().usageBalancing.enabled,
                  routerAudit.chosenModelRaw == session.selectedModelRaw,
                  routerAudit.usageBalancingProviderRaw == session.selectedAgent.rawValue,
                  routerAudit.chosenEffortRaw == session.selectedReasoningEffortRaw
            else {
                return .blocked(message: "The usage-balanced selection changed before submission. Send again with the current selection.")
            }
        }
        let result = submitUserTurn(
            text: text,
            tabID: destinationTabID,
            rawDraftText: claim.attempt.rawDraftSnapshot,
            autoEffortSelection: selection,
            autoEffortAudit: choice.audit,
            routerAudit: routerAudit
        )
        if result == .submitted, let selection {
            recordSubmittedAutoEffort(selection, for: session)
        }
        return result
    }

    /// Shared pre-turn judgment. MCP calls this only before an inactive run starts, never to
    /// change effort in the middle of an active provider turn or override an initial routed start.
    func chooseAutoEffortForUserTurn(
        text: String,
        session: TabSession,
        workflow: AgentWorkflowDefinition?
    ) async -> (selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature) {
        guard modelRouterSettingsStore.autoEffortEnabled() else {
            return (nil, .init(configured: false, eligible: false, judgmentRequested: false, decision: .disabled))
        }
        guard !session.runState.isActive,
              AutoEffortModelPolicy.shouldJudgeWorkflow(workflow),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
              let maskedExcerpt = AutoEffortTaskSummary.make(from: text)
        else {
            return (nil, .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible))
        }
        guard let runtime = modelRouterRuntime, runtime.isBackendReady(.jev) else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: false, decision: .unavailable))
        }

        let provider = session.selectedAgent
        let modelRaw = session.selectedModelRaw
        let selectedWorkflow = session.selectedWorkflow
        let workflowMutationGeneration = session.userWorkflowSelectionMutationGeneration
        let modelID: String
        let efforts: [String]
        let manualEffortRaw: String?
        switch provider {
        case .codexExec:
            guard let base = CodexModelSpecifier(raw: modelRaw).baseModel else { return ineligibleAutoEffortChoice() }
            let option = codexCoordinator.modelOptions(for: .codexExec).first {
                CodexModelSpecifier(raw: $0.rawValue).baseModel?.caseInsensitiveCompare(base) == .orderedSame
            }
            modelID = base
            efforts = AutoEffortModelPolicy.codexEfforts(
                modelRaw: modelRaw,
                advertised: option?.supportedReasoningEfforts ?? []
            )
            manualEffortRaw = codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode:
            guard let base = ClaudeModelSpecifier(raw: modelRaw).baseModel else { return ineligibleAutoEffortChoice() }
            modelID = base
            efforts = AutoEffortModelPolicy.claudeEfforts(
                modelRaw: modelRaw,
                advertised: AgentModelCatalog.supportedClaudeEfforts(
                    forSelectedModelRaw: modelRaw,
                    agentKind: provider
                )
            )
            manualEffortRaw = claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default:
            return ineligibleAutoEffortChoice()
        }
        guard efforts.count >= 2 else { return ineligibleAutoEffortChoice() }
        let judgmentID = UUID()
        session.autoEffortJudgmentID = judgmentID
        if currentTabID == session.tabID { syncStatusPillsUIState() }
        defer {
            if session.autoEffortJudgmentID == judgmentID {
                session.autoEffortJudgmentID = nil
                if currentTabID == session.tabID { syncStatusPillsUIState() }
            }
        }
        let chosen = await runtime.chooseAutoEffort(
            maskedTaskExcerpt: maskedExcerpt,
            selectedModelID: modelID,
            builtInWorkflow: workflow?.builtInWorkflow,
            efforts: efforts,
            logScope: session.mcpControlContext != nil ? .subagent : .primarySession
        )
        guard modelRouterSettingsStore.autoEffortEnabled(),
              sessions[session.tabID] === session,
              session.autoEffortJudgmentID == judgmentID,
              session.selectedWorkflow == selectedWorkflow,
              session.userWorkflowSelectionMutationGeneration == workflowMutationGeneration,
              session.selectedAgent == provider,
              session.selectedModelRaw == modelRaw,
              !session.runState.isActive,
              let chosen, efforts.contains(chosen)
        else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback, fallbackApplied: true))
        }
        let currentManualEffortRaw: String? = switch provider {
        case .codexExec: codexCoordinator.effectiveCodexSelection(for: session).reasoningEffort
        case .claudeCode: claudeCoordinator.currentClaudeEffortLevel(for: session).rawValue
        default: nil
        }
        guard currentManualEffortRaw == manualEffortRaw else {
            return (nil, .init(configured: true, eligible: true, judgmentRequested: true, decision: .fallback, fallbackApplied: true))
        }
        return (
            AutoEffortTurnSelection(
                provider: provider,
                selectedModelRaw: modelRaw,
                manualEffortRaw: manualEffortRaw,
                effortRaw: chosen
            ),
            .init(
                configured: true, eligible: true, judgmentRequested: true, decision: .selected,
                chosenModelRaw: modelRaw, chosenEffortRaw: chosen
            )
        )
    }

    private func ineligibleAutoEffortChoice() -> (
        selection: AutoEffortTurnSelection?, audit: AgentAutomationTurnAudit.Feature
    ) {
        (nil, .init(configured: true, eligible: false, judgmentRequested: false, decision: .ineligible))
    }

    func recordSubmittedAutoEffort(_ selection: AutoEffortTurnSelection, for session: TabSession) {
        guard sessions[session.tabID] === session else { return }
        session.autoEffortFeedback = AutoEffortTurnFeedback(
            selection: selection,
            previous: session.autoEffortFeedback
        )
        if currentTabID == session.tabID { syncStatusPillsUIState() }
    }

    func routeSubagentTargetIfEnabled(
        task: String,
        surface: AgentModelCatalog.AgentSelectionSurface,
        baseline: AgentRoutingExecutableTarget? = nil,
        allowUsageBalance: Bool = true,
        logContext: AgentTaskRoutingRouteContext? = nil,
        diversity: AgentTaskRoutingDiversityOptions = .none
    ) async throws -> AgentRoutingExecutableTarget? {
        await logContext?.attachMakerExclusions(diversity.canonicalMakerExclusions)
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        let fallback = { [self] in
            baseline.flatMap { allowUsageBalance ? localUsageDecision(basedOn: $0, scope: .subagent, surface: surface)?.candidate.target : nil }
        }
        /// With exclusions, a fallback needs a proven-allowed baseline; a swap is taken only when it is allowed too.
        /// `preRouteReason` is set when no route ran, so the single model row is written here.
        func fencedFallback(preRouteReason: String?) async throws -> AgentRoutingExecutableTarget? {
            guard !diversity.exclusions.isEmpty else { return fallback() }
            guard Self.isAllowed(baseline, by: diversity) else {
                if preRouteReason != nil {
                    await emitFailedDecision(.model, candidates: [], failure: .fallbackDiversityExcluded, context: logContext)
                }
                await logContext?.finish(.rejected)
                throw GlobalModelRoutingError.fallbackDiversityExcluded
            }
            if let preRouteReason {
                await emitFailedDecision(
                    .model, candidates: [], failure: .policyUnavailable, reasonCode: preRouteReason, context: logContext
                )
            }
            guard let swap = fallback(), Self.isAllowed(swap, by: diversity) else { return nil }
            return swap
        }
        guard configuration.enabled else { return try await fencedFallback(preRouteReason: "router_disabled") }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else { return try await fencedFallback(preRouteReason: "backend_not_ready") }
        let result = await routeModelThenEffort(
            requestID: logContext?.requestID ?? UUID(),
            text: task,
            scope: .subagent,
            surface: surface,
            providers: providers(for: .subagent, configuration: configuration),
            configuration: configuration,
            backendID: backendID,
            runtime: runtime,
            allowUsageBalance: allowUsageBalance,
            logContext: logContext,
            diversity: diversity
        )
        guard modelRouterConfigurationIsCurrent(configuration, backendID: backendID) else {
            await logContext?.finish(.rejected)
            throw GlobalModelRoutingError.stale
        }
        switch result.outcome {
        case let .selected(opaqueKey, _):
            let target = result.candidates.only(where: { $0.opaqueKey == opaqueKey })?.target
            await logContext?.recordPick(target)
            return target
        case .cancelled:
            await logContext?.finish(.rejected)
            throw GlobalModelRoutingError.cancelled
        case .failed(.allCandidatesExcluded, _, _):
            await logContext?.finish(.rejected)
            throw GlobalModelRoutingError.allCandidatesExcluded
        case .abstained, .failed:
            return try await fencedFallback(preRouteReason: nil)
        }
    }

    /// A target is allowed only when its maker is known and not excluded; unknown makers never pass.
    private static func isAllowed(_ target: AgentRoutingExecutableTarget?, by diversity: AgentTaskRoutingDiversityOptions) -> Bool {
        guard let target, let maker = AgentTaskRoutingMakerCatalog.maker(for: target) else { return false }
        return diversity.exclusions[maker.rawValue] == nil
    }

    private func routeModelThenEffort(
        requestID: UUID,
        text: String,
        scope: AgentTaskRoutingScope,
        surface: AgentModelCatalog.AgentSelectionSurface,
        providers: Set<AgentProviderKind>,
        configuration: AgentTaskRouterConfiguration,
        backendID: AgentTaskRouterBackendID,
        runtime: AgentTaskRouterRuntime,
        allowUsageBalance: Bool = true,
        logContext: AgentTaskRoutingRouteContext? = nil,
        diversity: AgentTaskRoutingDiversityOptions = .none
    ) async -> StagedTaskRoutingResult {
        let builder = runtime.candidateBuilderFactory()
        let routingText = AgentTaskRoutingTaskExcerpt.make(from: text)
        guard let built = try? builder.build(
            allowedProviders: providers,
            availability: modelRouterAvailabilityContext,
            surface: surface,
            roleDefaults: agentModelRoleDefaultReferences()
        ), !built.isEmpty else {
            await emitFailedDecision(.model, candidates: [], context: logContext)
            return StagedTaskRoutingResult(
                candidates: [],
                outcome: .failed(category: .invalidRequest, retryable: false, evidence: nil)
            )
        }
        let models = diversity.exclusions.isEmpty ? built : built.filter { Self.isAllowed($0.target, by: diversity) }
        guard let firstModel = models.first else {
            await emitFailedDecision(.model, candidates: [], failure: .allCandidatesExcluded, context: logContext)
            return StagedTaskRoutingResult(
                candidates: [],
                outcome: .failed(category: .allCandidatesExcluded, retryable: false, evidence: nil)
            )
        }

        var selectedModel: AgentTaskRoutingCandidateBuilder.Candidate
        var usageBalancingReason: String?
        var modelEvidence: AgentTaskRoutingDecisionEvidence?
        var judgmentRequested = false
        if models.count == 1 {
            selectedModel = firstModel
            await logContext?.emitDecision(Self.localDecisionDraft(stage: .model, chosen: firstModel, candidates: models))
        } else {
            guard let modelRequest = try? AgentTaskRoutingEnvelopeBuilder().build(
                requestID: requestID,
                text: routingText,
                scope: scope,
                decisionStage: .model,
                customInstructions: configuration.customInstructions,
                candidates: models.map(\.descriptor)
            ) else {
                await emitFailedDecision(.model, candidates: models, context: logContext)
                return StagedTaskRoutingResult(
                    candidates: models,
                    outcome: .failed(category: .invalidRequest, retryable: false, evidence: nil)
                )
            }
            judgmentRequested = true
            let modelOutcome = await tracedRoute(
                runtime: runtime, backendID: backendID, request: modelRequest,
                candidates: models, context: logContext
            )
            guard case let .selected(modelKey, evidence) = modelOutcome,
                  let match = models.only(where: { $0.opaqueKey == modelKey })
            else { return StagedTaskRoutingResult(candidates: models, outcome: modelOutcome, judgmentRequested: true) }
            selectedModel = match
            modelEvidence = evidence
            if allowUsageBalance, configuration.usageBalancing.enabled, !Task.isCancelled,
               modelRouterConfigurationIsCurrent(configuration, backendID: backendID), let advisor = runtime.usageBalancer
            {
                let decision = advisor.choose(selected: match, candidates: models, evidence: evidence, configuration: configuration)
                selectedModel = decision.candidate
                usageBalancingReason = decision.reason
            }
        }

        guard !Task.isCancelled else {
            var cancelled = AgentTaskRoutingDecisionDraft(stage: .effort, outcome: .cancelled)
            cancelled.backend = backendID.rawValue
            await logContext?.emitDecision(cancelled)
            return StagedTaskRoutingResult(candidates: models, outcome: .cancelled, judgmentRequested: judgmentRequested)
        }
        let modelFallback = StagedTaskRoutingResult(
            candidates: models,
            outcome: .selected(opaqueKey: selectedModel.opaqueKey, evidence: modelEvidence),
            judgmentRequested: judgmentRequested,
            effortFallback: true,
            usageBalancingReason: usageBalancingReason
        )
        guard let efforts = try? builder.buildEfforts(
            for: selectedModel,
            availability: modelRouterAvailabilityContext,
            allowPaidFast: configuration.allowPaidFastRouting
        ), let firstEffort = efforts.first else {
            await emitFailedDecision(.effort, candidates: [], context: logContext)
            return modelFallback
        }
        guard efforts.count > 1 else {
            await logContext?.emitDecision(Self.localDecisionDraft(stage: .effort, chosen: firstEffort, candidates: efforts))
            return StagedTaskRoutingResult(
                candidates: efforts,
                outcome: .selected(opaqueKey: firstEffort.opaqueKey, evidence: nil),
                judgmentRequested: judgmentRequested,
                usageBalancingReason: usageBalancingReason
            )
        }
        guard let effortRequest = try? AgentTaskRoutingEnvelopeBuilder().build(
            requestID: requestID,
            text: routingText,
            scope: scope,
            decisionStage: .effort,
            customInstructions: configuration.customInstructions,
            candidates: efforts.map(\.descriptor)
        ) else {
            await emitFailedDecision(.effort, candidates: efforts, context: logContext)
            return modelFallback
        }
        judgmentRequested = true
        let effortOutcome = await tracedRoute(
            runtime: runtime, backendID: backendID, request: effortRequest,
            candidates: efforts, context: logContext
        )
        switch effortOutcome {
        case let .selected(key, _):
            guard let target = efforts.only(where: { $0.opaqueKey == key })?.target,
                  configuration.allowPaidFastRouting || !AgentTaskRoutingCandidateBuilder.isPaidFast(target) else { return modelFallback }
            return StagedTaskRoutingResult(candidates: efforts, outcome: effortOutcome, judgmentRequested: true, usageBalancingReason: usageBalancingReason)
        case .cancelled:
            return StagedTaskRoutingResult(candidates: models, outcome: .cancelled, judgmentRequested: judgmentRequested)
        case .abstained, .failed:
            return StagedTaskRoutingResult(
                candidates: modelFallback.candidates,
                outcome: modelFallback.outcome,
                judgmentRequested: true,
                effortFallback: true,
                usageBalancingReason: usageBalancingReason
            )
        }
    }

    private func emitFailedDecision(
        _ stage: AgentTaskRoutingLogStage,
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        failure: AgentTaskRoutingBackendFailureCategory = .invalidRequest,
        reasonCode: String? = nil,
        context: AgentTaskRoutingRouteContext?
    ) async {
        var draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .failed)
        draft.candidates = candidates.map { .init(key: $0.opaqueKey, target: .init($0.target)) }
        draft.failure = failure.rawValue
        draft.reasonCode = reasonCode
        await context?.emitDecision(draft)
    }

    private static func localDecisionDraft(
        stage: AgentTaskRoutingLogStage,
        chosen: AgentTaskRoutingCandidateBuilder.Candidate,
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate]
    ) -> AgentTaskRoutingDecisionDraft {
        var draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .localSingleCandidate)
        draft.backend = "local"
        draft.candidates = candidates.map { .init(key: $0.opaqueKey, target: .init($0.target)) }
        draft.chosenKey = chosen.opaqueKey
        draft.chosenTarget = .init(chosen.target)
        return draft
    }

    /// Routes through the traced coordinator path and writes the stage's one decision row. The returned
    /// outcome is exactly what the untraced coordinator would have returned.
    private func tracedRoute(
        runtime: AgentTaskRouterRuntime,
        backendID: AgentTaskRouterBackendID,
        request: AgentTaskRoutingRequest,
        candidates: [AgentTaskRoutingCandidateBuilder.Candidate],
        context: AgentTaskRoutingRouteContext?
    ) async -> AgentTaskRoutingBackendOutcome {
        let traced = await runtime.routeTraced(backendID: backendID, request: request)
        guard let context else { return traced.outcome }
        let stage: AgentTaskRoutingLogStage = request.decisionStage == .model ? .model : .effort
        var draft: AgentTaskRoutingDecisionDraft
        var evidence: AgentTaskRoutingDecisionEvidence?
        switch traced.outcome {
        case let .selected(key, selectedEvidence):
            evidence = selectedEvidence
            if let chosen = candidates.only(where: { $0.opaqueKey == key }) {
                draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .selected)
                draft.chosenKey = key
                draft.chosenTarget = .init(chosen.target)
            } else {
                draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .failed)
                draft.failure = AgentTaskRoutingBackendFailureCategory.invalidResponse.rawValue
            }
        case let .abstained(reason, abstainedEvidence):
            evidence = abstainedEvidence
            draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .abstained)
            draft.reasonCode = abstainedEvidence?.reasonCode ?? reason
        case let .failed(category, _, failedEvidence):
            evidence = failedEvidence
            draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .failed)
            draft.failure = category.rawValue
        case .cancelled:
            draft = AgentTaskRoutingDecisionDraft(stage: stage, outcome: .cancelled)
        }
        draft.backend = traced.trace.backendID.rawValue
        draft.jevModel = traced.trace.jevModel
        draft.latencyMs = traced.trace.latencyMs
        draft.candidates = candidates.map { .init(key: $0.opaqueKey, target: .init($0.target)) }
        if let evidence {
            draft.policyVersion = evidence.policyVersion
            draft.confidence = evidence.confidence
            draft.probabilities = evidence.scores
            draft.inputTokens = evidence.inputTokens
            draft.outputTokens = evidence.outputTokens
            draft.reasonCode = draft.reasonCode ?? evidence.reasonCode
        }
        await context.emitDecision(draft)
        return traced.outcome
    }

    private func modelRouterConfigurationIsCurrent(
        _ configuration: AgentTaskRouterConfiguration,
        backendID: AgentTaskRouterBackendID
    ) -> Bool {
        let current = modelRouterSettingsStore.modelRouterConfiguration()
        return current.enabled
            && current.revision == configuration.revision
            && current.selectedBackendID == backendID
    }

    private func providers(
        for scope: AgentTaskRoutingScope,
        configuration: AgentTaskRouterConfiguration
    ) -> Set<AgentProviderKind> {
        let limit = switch scope {
        case .primarySession: configuration.primaryProvider
        case .subagent: configuration.subagentProvider
        }
        let available = AgentTaskRoutingCandidateBuilder.availableProviders(
            availability: modelRouterAvailabilityContext,
            surface: scope == .subagent ? .headless : .general
        )
        return AgentTaskRoutingCandidateBuilder.providers(
            preferring: limit,
            from: available
        )
    }

    private func agentModelRoleDefaultReferences() -> [AgentTaskRoutingCandidateBuilder.RoleDefaultReference] {
        MCPAgentRoleDefaultsService.resolutions(
            availability: modelRouterAvailabilityContext,
            workspaceID: workspaceManager?.activeWorkspaceID
        ).map { resolution in
            AgentTaskRoutingCandidateBuilder.RoleDefaultReference(
                roleLabel: resolution.roleLabel,
                provider: resolution.effective.agent,
                modelRaw: resolution.effective.modelRaw,
                isUserOverride: resolution.hasStoredOverride
            )
        }
    }

    func freshTaskRoutingEligibility(session: TabSession, text: String?) -> Bool {
        guard isModelRouterEligibleFirstSendDestination(session),
              session.providerSessionID == nil,
              session.codexConversationID == nil,
              session.mcpControlContext == nil,
              !session.isMCPOriginated,
              session.parentSessionID == nil,
              !session.pendingHandoff.hasPayload
        else { return false }
        guard let text else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("/")
    }

    /// Selected prompt workflows still create a brand-new provider session and therefore remain
    /// Router-owned. The broader first-send helper excludes workflows because it also guards tab
    /// creation and cleanup, where an empty destination must not yet carry copied pending state.
    private func isModelRouterEligibleFirstSendDestination(_ session: TabSession) -> Bool {
        !session.runState.isActive
            && !session.hasSentFirstMessage
            && session.runID == nil
            && session.activeRunAttemptID == nil
            && session.items.isEmpty
            && session.transcript.turns.isEmpty
            && session.pendingImageAttachments.isEmpty
            && session.pendingTaggedFileAttachments.isEmpty
    }

    private func modelRouterCanRoutePrimarySession(_ configuration: AgentTaskRouterConfiguration) -> Bool {
        guard let backendID = configuration.selectedBackendID,
              modelRouterRuntime?.isBackendReady(backendID) == true
        else { return false }
        return AgentTaskRoutingCandidateBuilder().hasAvailableTarget(
            allowedProviders: providers(for: .primarySession, configuration: configuration),
            availability: modelRouterAvailabilityContext
        )
    }

    func executableTarget(for session: TabSession) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameters: session.acpModelParameterSelections
        )
    }

    func applyRoutingTarget(_ target: AgentRoutingExecutableTarget, to session: TabSession) -> Bool {
        guard let agent = AgentProviderKind(rawValue: target.agentRaw),
              AgentModelCatalog.isAgentAvailable(agent, availability: modelRouterAvailabilityContext)
        else { return false }
        session.selectedAgent = agent
        session.selectedModelRaw = target.modelRaw
        session.selectedReasoningEffortRaw = target.reasoningEffortRaw
        session.acpModelParameterSelections = target.modelParameters
        if session.tabID == currentTabID {
            applySessionToBindings(session)
        }
        return executableTarget(for: session) == target
    }

    private func restoreRoutingSelection(_ rollback: RoutedSelectionRollback, on session: TabSession) {
        restoreUsageStartingTarget(rollback.target, on: session)
    }

    func restoreUsageStartingTarget(_ target: AgentRoutingExecutableTarget, on session: TabSession) {
        guard let agent = AgentProviderKind(rawValue: target.agentRaw) else { return }
        session.selectedAgent = agent
        session.selectedModelRaw = target.modelRaw
        session.selectedReasoningEffortRaw = target.reasoningEffortRaw
        session.acpModelParameterSelections = target.modelParameters
        if session.tabID == currentTabID {
            applySessionToBindings(session)
        }
    }

    private func ownsFreshTaskRouting(_ ownership: FreshTaskRoutingOwnership) -> Bool {
        freshTaskRoutingByTabID[ownership.sourceTabID]?.requestID == ownership.requestID
            && freshTaskRoutingByTabID[ownership.destinationTabID]?.requestID == ownership.requestID
    }

    private func clearFreshTaskRoutingOwnership(_ ownership: FreshTaskRoutingOwnership) {
        if freshTaskRoutingByTabID[ownership.sourceTabID]?.requestID == ownership.requestID {
            freshTaskRoutingByTabID.removeValue(forKey: ownership.sourceTabID)
        }
        if freshTaskRoutingByTabID[ownership.destinationTabID]?.requestID == ownership.requestID {
            freshTaskRoutingByTabID.removeValue(forKey: ownership.destinationTabID)
        }
        syncComposerUIState()
        syncStatusPillsUIState()
        requestUIRefresh(tabID: ownership.sourceTabID, urgent: true)
        if ownership.destinationTabID != ownership.sourceTabID {
            requestUIRefresh(tabID: ownership.destinationTabID, urgent: true)
        }
    }
}

private extension Collection {
    func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        var match: Element?
        for element in self where try predicate(element) {
            guard match == nil else { return nil }
            match = element
        }
        return match
    }
}
