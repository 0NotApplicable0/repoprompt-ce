import Foundation

extension AgentModeViewModel {
    enum GlobalModelRoutingError: LocalizedError {
        case unavailable
        case noTargets
        case failed
        case cancelled
        case stale

        var errorDescription: String? {
            switch self {
            case .unavailable: "Model Router is enabled but its routing service is unavailable."
            case .noTargets: "Model Router has no available targets for this session type."
            case .failed: "Model Router could not choose a target."
            case .cancelled: "Model routing was cancelled."
            case .stale: "The Model Router policy changed while the request was in progress."
            }
        }
    }

    private struct RoutedSelectionRollback {
        let target: AgentRoutingExecutableTarget
    }

    func modelRouterPillProps() -> AgentModelRouterPillProps {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        let backendReady = configuration.selectedBackendID.map {
            modelRouterRuntime?.isBackendReady($0) == true
        } ?? false
        let available = backendReady && (try? AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: providers(for: .primarySession, configuration: configuration),
            availability: agentAvailabilityContext
        )) != nil
        let isRouting = currentTabID.map { freshTaskRoutingByTabID[$0] != nil } ?? false
        return AgentModelRouterPillProps(
            isOn: configuration.enabled,
            isAvailable: available || configuration.enabled,
            isRouting: isRouting,
            disabledReason: available || configuration.enabled
                ? nil
                : "Configure a routing service and targets in Model Router Settings."
        )
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
            availability: agentAvailabilityContext
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
        modelRouterSettingsStore.modelRouterConfiguration().enabled
            && freshTaskRoutingEligibility(session: session, text: nil)
    }

    func submitUserTurnAfterFreshTaskRouting(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID
    ) async -> UserTurnSubmissionResult {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.enabled else {
            return submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot
            )
        }
        guard freshTaskRoutingEligibility(session: session, text: text) else {
            return submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot
            )
        }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID
        else {
            return .blocked(message: "Model Router is unavailable. Turn it off to send with the current selection.")
        }

        let providers = providers(for: .primarySession, configuration: configuration)
        guard let candidates = try? AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: providers,
            availability: agentAvailabilityContext
        ) else {
            return .blocked(message: "The configured Router policy has no available primary-session targets.")
        }
        let request = candidates.count > 1 ? try? AgentTaskRoutingEnvelopeBuilder().build(
            requestID: claim.attempt.id,
            text: text,
            scope: .primarySession,
            customInstructions: configuration.customInstructions,
            candidates: candidates.map(\.descriptor)
        ) : nil

        let outcome: AgentTaskRoutingBackendOutcome
        if let request {
            let routeTask = Task {
                await runtime.coordinator.route(backendID: backendID, request: request)
            }
            let ownership = FreshTaskRoutingOwnership(
                requestID: request.requestID,
                sourceTabID: claim.attempt.sourceTabID,
                destinationTabID: destinationTabID,
                task: routeTask
            )
            guard freshTaskRoutingByTabID[ownership.sourceTabID] == nil,
                  freshTaskRoutingByTabID[ownership.destinationTabID] == nil
            else {
                routeTask.cancel()
                await runtime.coordinator.cancel(requestID: request.requestID)
                return .blocked(message: "Model routing is already in progress for this task.")
            }
            freshTaskRoutingByTabID[ownership.sourceTabID] = ownership
            freshTaskRoutingByTabID[ownership.destinationTabID] = ownership
            syncComposerUIState()
            syncStatusPillsUIState()
            outcome = await routeTask.value
            guard ownsFreshTaskRouting(ownership) else {
                return .blocked(message: "Model routing was cancelled.")
            }
            clearFreshTaskRoutingOwnership(ownership)
        } else if let only = candidates.first {
            outcome = .selected(opaqueKey: only.opaqueKey, evidence: nil)
        } else {
            return .blocked(message: "The configured Router policy has no available primary-session targets.")
        }

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
                return .blocked(message: "The router returned an invalid target.")
            }
            let baseline = RoutedSelectionRollback(target: executableTarget(for: session))
            guard applyRoutingTarget(selected.target, to: session) else {
                return .blocked(message: "The routed target is no longer available.")
            }
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
                rawDraftText: claim.attempt.rawDraftSnapshot
            )
            if result != .submitted {
                restoreRoutingSelection(baseline, on: session)
            } else {
                session.isDirty = true
                scheduleSave(for: session.tabID)
            }
            return result
        case .abstained, .failed:
            return .blocked(message: "The Router could not choose a target. Retry, or turn off Router to use your current selection.")
        case .cancelled:
            return .blocked(message: "Model routing was cancelled.")
        }
    }

    func routeSubagentTargetIfEnabled(
        task: String,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) async throws -> AgentRoutingExecutableTarget? {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.enabled else { return nil }
        guard let runtime = modelRouterRuntime,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              runtime.isBackendReady(backendID)
        else { throw GlobalModelRoutingError.unavailable }
        let candidates = try AgentTaskRoutingCandidateBuilder().build(
            allowedProviders: providers(for: .subagent, configuration: configuration),
            availability: agentAvailabilityContext,
            surface: surface
        )
        guard let first = candidates.first else { throw GlobalModelRoutingError.noTargets }
        guard candidates.count > 1 else {
            guard modelRouterConfigurationIsCurrent(configuration, backendID: backendID) else {
                throw GlobalModelRoutingError.stale
            }
            return first.target
        }
        let request = try AgentTaskRoutingEnvelopeBuilder().build(
            requestID: UUID(),
            text: task,
            scope: .subagent,
            customInstructions: configuration.customInstructions,
            candidates: candidates.map(\.descriptor)
        )
        let outcome = await runtime.coordinator.route(backendID: backendID, request: request)
        guard modelRouterConfigurationIsCurrent(configuration, backendID: backendID) else {
            throw GlobalModelRoutingError.stale
        }
        switch outcome {
        case let .selected(opaqueKey, _):
            guard let selected = candidates.only(where: { $0.opaqueKey == opaqueKey }) else {
                throw GlobalModelRoutingError.failed
            }
            return selected.target
        case .cancelled:
            throw GlobalModelRoutingError.cancelled
        case .abstained, .failed:
            throw GlobalModelRoutingError.failed
        }
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
            availability: agentAvailabilityContext,
            surface: scope == .subagent ? .headless : .general
        )
        guard let limit else { return available }
        return available.intersection([limit])
    }

    private func freshTaskRoutingEligibility(session: TabSession, text: String?) -> Bool {
        guard isFreshFirstSendDestination(session),
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

    private func executableTarget(for session: TabSession) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(
            agentRaw: session.selectedAgent.rawValue,
            modelRaw: session.selectedModelRaw,
            reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameters: session.acpModelParameterSelections
        )
    }

    private func applyRoutingTarget(_ target: AgentRoutingExecutableTarget, to session: TabSession) -> Bool {
        guard let agent = AgentProviderKind(rawValue: target.agentRaw),
              AgentModelCatalog.isAgentAvailable(agent, availability: agentAvailabilityContext)
        else { return false }
        session.selectedAgent = agent
        session.selectedModelRaw = target.modelRaw
        session.selectedReasoningEffortRaw = target.reasoningEffortRaw
        session.acpModelParameterSelections = target.modelParameters
        if session.tabID == currentTabID { applySessionToBindings(session) }
        return executableTarget(for: session) == target
    }

    private func restoreRoutingSelection(_ rollback: RoutedSelectionRollback, on session: TabSession) {
        guard let agent = AgentProviderKind(rawValue: rollback.target.agentRaw) else { return }
        session.selectedAgent = agent
        session.selectedModelRaw = rollback.target.modelRaw
        session.selectedReasoningEffortRaw = rollback.target.reasoningEffortRaw
        session.acpModelParameterSelections = rollback.target.modelParameters
        if session.tabID == currentTabID { applySessionToBindings(session) }
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
