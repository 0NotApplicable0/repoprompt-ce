import Foundation

/// Builds the router-owned quality/cost frontier from live provider catalogs.
///
/// Manual Agent Models role assignments deliberately do not participate. Router mode owns the
/// complete model-and-effort decision; provider limits and user guidance are its only overrides.
@MainActor
struct AgentTaskRoutingCandidateBuilder {
    struct Candidate: Equatable {
        let opaqueKey: String
        let utilityTier: String
        let target: AgentRoutingExecutableTarget
        let descriptor: AgentTaskRoutingCandidateDescriptor
    }

    enum BuildError: Error, Equatable { case noAvailableTargets }

    private struct FrontierDefinition {
        let provider: AgentProviderKind
        let baseModelAliases: [String]
        let effortRaw: String?
        let utilityTier: String
        let rubric: String
    }

    let opaqueKey: () -> String

    init(opaqueKey: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.opaqueKey = opaqueKey
    }

    func build(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) throws -> [Candidate] {
        let definitions = Self.frontierDefinitions.filter {
            allowedProviders.contains($0.provider)
                && surface.allows($0.provider)
                && AgentModelCatalog.isAgentAvailable($0.provider, availability: availability)
        }
        var seenTargets: Set<AgentRoutingExecutableTarget> = []
        let candidates = definitions.compactMap { definition -> Candidate? in
            guard let option = Self.resolveOption(definition, availability: availability) else { return nil }
            let target = Self.executableTarget(option.rawValue, provider: definition.provider)
            guard seenTargets.insert(target).inserted else { return nil }
            let key = opaqueKey()
            return Candidate(
                opaqueKey: key,
                utilityTier: definition.utilityTier,
                target: target,
                descriptor: AgentTaskRoutingCandidateDescriptor(
                    opaqueKey: key,
                    roleLabels: [definition.utilityTier],
                    targetDescription: Self.targetDescription(
                        target,
                        displayName: option.displayName
                    ),
                    rubricVersion: AgentTaskRoutingModelProfileCatalog.rubricVersion,
                    rubric: definition.rubric
                )
            )
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

    static func availableProviders(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Set<AgentProviderKind> {
        Set([AgentProviderKind.codexExec, .claudeCode].filter {
            surface.allows($0) && AgentModelCatalog.isAgentAvailable($0, availability: availability)
        })
    }

    private static let frontierDefinitions: [FrontierDefinition] = [
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-luna"],
            effortRaw: "low",
            utilityTier: "economy",
            rubric: "Economy tier. Use only for simple, bounded, low-risk work with clear instructions and a strong reliability margin; avoid it when failure, clarification, or retry would erase the savings."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-terra"],
            effortRaw: "medium",
            utilityTier: "balanced",
            rubric: "Balanced tier. Prefer for ordinary implementation, debugging, tests, and analysis when it has a clear reliability margin."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-sol", "gpt-5.6"],
            effortRaw: "high",
            utilityTier: "strong",
            rubric: "Strong tier. Use for difficult, ambiguous, cross-cutting, or high-risk execution where extra capability materially reduces failure or retry risk."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-astra"],
            effortRaw: "high",
            utilityTier: "frontier",
            rubric: "Frontier tier. Reserve for exceptional end-to-end complexity, severe risk, or tasks whose expected value clearly justifies premium cost."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-haiku-4-5-20251001", "claude-haiku-4-5", "haiku"],
            effortRaw: nil,
            utilityTier: "economy",
            rubric: "Economy tier. Use only for simple, bounded, low-risk work with clear instructions and a strong reliability margin; avoid it when failure, clarification, or retry would erase the savings."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-sonnet-5", "sonnet"],
            effortRaw: "medium",
            utilityTier: "balanced",
            rubric: "Balanced tier. Prefer for ordinary implementation, debugging, tests, and analysis when it has a clear reliability margin."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-opus-5", "opus"],
            effortRaw: "high",
            utilityTier: "strong",
            rubric: "Strong tier. Use for difficult, ambiguous, cross-cutting, or high-risk execution where extra capability materially reduces failure or retry risk."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-fable-5-1", "fable"],
            effortRaw: "high",
            utilityTier: "frontier",
            rubric: "Frontier tier. Reserve for exceptional long-horizon or cross-codebase complexity whose expected value clearly justifies premium cost."
        )
    ]

    private static func resolveOption(
        _ definition: FrontierDefinition,
        availability: AgentModelCatalog.AvailabilityContext
    ) -> AgentModelOption? {
        let options = AgentModelCatalog.options(for: definition.provider, availability: availability)
        return definition.baseModelAliases.lazy.compactMap { alias in
            options.first { option in
                switch definition.provider {
                case .codexExec:
                    let specifier = CodexModelSpecifier(raw: option.rawValue)
                    return specifier.baseModel?.caseInsensitiveCompare(alias) == .orderedSame
                        && specifier.reasoningEffort?.rawValue == definition.effortRaw
                case .claudeCode:
                    let specifier = ClaudeModelSpecifier(raw: option.rawValue)
                    return specifier.baseModel?.caseInsensitiveCompare(alias) == .orderedSame
                        && specifier.effortLevel?.rawValue == definition.effortRaw
                default:
                    return false
                }
            }
        }.first
    }

    private static func executableTarget(
        _ modelRaw: String,
        provider: AgentProviderKind
    ) -> AgentRoutingExecutableTarget {
        AgentRoutingExecutableTarget(
            agentRaw: provider.rawValue,
            modelRaw: modelRaw,
            reasoningEffortRaw: provider == .codexExec
                ? CodexModelSpecifier(raw: modelRaw).reasoningEffort?.rawValue
                : nil,
            modelParameters: []
        )
    }

    private static func targetDescription(
        _ target: AgentRoutingExecutableTarget,
        displayName: String
    ) -> String {
        let provider = AgentProviderKind(rawValue: target.agentRaw)?.displayName ?? target.agentRaw
        let effort = target.reasoningEffortRaw.map { ", reasoning effort: \($0)" } ?? ""
        return "Provider: \(provider); model: \(displayName)\(effort). \(AgentTaskRoutingModelProfileCatalog.description(for: target))"
    }
}
