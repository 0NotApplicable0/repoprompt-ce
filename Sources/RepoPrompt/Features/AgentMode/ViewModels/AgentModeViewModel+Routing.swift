import Foundation

extension AgentModeViewModel {
    private struct RoutedSelectionRollback {
        let target: AgentRoutingExecutableTarget
    }

    func canRouteFreshTask(session: TabSession?) -> Bool {
        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard let modelRouterRuntime,
              configuration.enabled,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              modelRouterRuntime.isBackendReady(backendID),
              let session,
              freshTaskRoutingEligibility(session: session, text: nil)
        else { return false }
        return true
    }

    func cancelFreshTaskRouting(tabID: UUID) async {
        guard let runtime = modelRouterRuntime,
              let owned = freshTaskRoutingByTabID[tabID]
        else { return }
        await runtime.coordinator.cancel(requestID: owned.requestID)
        owned.task.cancel()
        clearFreshTaskRoutingOwnership(owned)
    }

    func submitUserTurnAfterFreshTaskRouting(
        text: String,
        claim: AgentComposerSubmitClaim,
        session: TabSession,
        destinationTabID: UUID
    ) async -> UserTurnSubmissionResult {
        guard claim.attempt.routingIntent == .routeFreshTask else {
            return submitUserTurn(
                text: text,
                tabID: destinationTabID,
                rawDraftText: claim.attempt.rawDraftSnapshot
            )
        }
        guard let runtime = modelRouterRuntime else {
            return .blocked(message: "Model routing is unavailable. Turn off Route to send with the current selection.")
        }

        let configuration = modelRouterSettingsStore.modelRouterConfiguration()
        guard configuration.enabled,
              configuration.validity == .valid,
              let backendID = configuration.selectedBackendID,
              freshTaskRoutingEligibility(session: session, text: text)
        else {
            return .blocked(message: "This task is not eligible for routing. Turn off Route to send with the current selection.")
        }

        let roles = Set(configuration.candidateRoles)
        let providers = configuration.allowedProviders
        guard let candidates = try? AgentTaskRoutingCandidateBuilder().build(
            workspaceID: workspaceManager?.activeWorkspaceID,
            roles: roles,
            allowedProviders: providers,
            availability: agentAvailabilityContext,
            settingsStore: modelRouterSettingsStore
        ),
            let request = try? AgentTaskRoutingEnvelopeBuilder().build(
                requestID: claim.attempt.id,
                text: text,
                candidates: candidates.map(\.descriptor),
                containsAttachments: !session.pendingImageAttachments.isEmpty,
                containsTaggedPaths: !session.pendingTaggedFileAttachments.isEmpty,
                invokesWorkflowOrSlashCommand: session.selectedWorkflow != nil
                    || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
            )
        else {
            return .blocked(message: "The configured router policy does not produce at least two distinct available targets.")
        }

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
        let outcome = await routeTask.value
        guard ownsFreshTaskRouting(ownership) else {
            return .blocked(message: "Model routing was cancelled.")
        }
        clearFreshTaskRoutingOwnership(ownership)

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
            return .blocked(message: "The router could not choose a route. Retry, or turn off Route to send using your current selection.")
        case .cancelled:
            return .blocked(message: "Model routing was cancelled.")
        }
    }

    private func freshTaskRoutingEligibility(session: TabSession, text: String?) -> Bool {
        guard isFreshFirstSendDestination(session),
              session.providerSessionID == nil,
              session.codexConversationID == nil,
              session.mcpControlContext == nil,
              !session.isMCPOriginated,
              session.parentSessionID == nil,
              !session.pendingHandoff.hasPayload,
              session.pendingImageAttachments.isEmpty,
              session.pendingTaggedFileAttachments.isEmpty,
              session.selectedWorkflow == nil
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
