import Foundation

@MainActor
struct AgentTaskRoutingCandidateBuilder {
    struct Candidate: Equatable {
        let opaqueKey: String
        let roles: [AgentModelCatalog.TaskLabelKind]
        let target: AgentRoutingExecutableTarget
        let descriptor: AgentTaskRoutingCandidateDescriptor
    }

    enum BuildError: Error, Equatable { case insufficientDistinctTargets }

    let opaqueKey: () -> String

    init(opaqueKey: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.opaqueKey = opaqueKey
    }

    func build(
        workspaceID: UUID?,
        roles: Set<AgentModelCatalog.TaskLabelKind>,
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        settingsStore: (any MCPAgentRoleDefaultsStoring)? = nil
    ) throws -> [Candidate] {
        let resolutions = MCPAgentRoleDefaultsService.resolutions(
            availability: availability,
            workspaceID: workspaceID,
            settingsStore: settingsStore
        )
        var grouped: [AgentRoutingExecutableTarget: [AgentModelCatalog.TaskLabelKind]] = [:]
        var order: [AgentRoutingExecutableTarget] = []
        for resolution in resolutions where roles.contains(resolution.role)
            && !resolution.overrideUnavailable
            && surface.allows(resolution.effective.agent)
        {
            guard allowedProviders.contains(resolution.effective.agent) else { continue }
            let target = AgentRoutingExecutableTarget(
                agentRaw: resolution.effective.agent.rawValue,
                modelRaw: resolution.effective.modelRaw,
                reasoningEffortRaw: resolution.effective.agent == .codexExec
                    ? CodexModelSpecifier(raw: resolution.effective.modelRaw).reasoningEffort?.rawValue
                    : nil,
                modelParameters: resolution.modelParameters
            )
            if grouped[target] == nil { order.append(target) }
            grouped[target, default: []].append(resolution.role)
        }
        guard (1 ... 4).contains(order.count) else { throw BuildError.insufficientDistinctTargets }
        return order.map { target in
            let groupedRoles = grouped[target] ?? []
            let key = opaqueKey()
            return Candidate(
                opaqueKey: key,
                roles: groupedRoles,
                target: target,
                descriptor: AgentTaskRoutingCandidateDescriptor(
                    opaqueKey: key,
                    roleLabels: groupedRoles.map(\.rawValue),
                    targetDescription: Self.targetDescription(
                        target,
                        displayName: resolutions.first(where: {
                            $0.effective.agent.rawValue == target.agentRaw
                                && $0.effective.modelRaw == target.modelRaw
                        })?.effectiveDisplayName ?? target.modelRaw
                    ),
                    rubricVersion: "rpce.agent-role-rubric.v1",
                    rubric: groupedRoles.compactMap(Self.rubric).joined(separator: " ")
                )
            )
        }
    }

    private static func targetDescription(
        _ target: AgentRoutingExecutableTarget,
        displayName: String
    ) -> String {
        let provider = AgentProviderKind(rawValue: target.agentRaw)?.displayName ?? target.agentRaw
        let effort = target.reasoningEffortRaw.map { ", reasoning effort: \($0)" } ?? ""
        return "Provider: \(provider); model: \(displayName)\(effort)."
    }

    private static func rubric(_ role: AgentModelCatalog.TaskLabelKind) -> String? {
        switch role {
        case .explore: "Bounded mapping, search, discovery, and low-latency investigation; not broad implementation."
        case .engineer: "Ordinary implementation, debugging, tests, and refactoring with balanced cost and rigor."
        case .pair: "Difficult, high-risk, interactive engineering where the strongest configured implementation target is justified."
        case .design: "Architecture, API and tradeoff analysis, and planning where implementation throughput is secondary."
        }
    }
}
