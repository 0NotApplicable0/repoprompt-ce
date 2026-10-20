import Foundation
import RepoPromptSettingsCore

/// Builds router-owned choices from one provider-authoritative metadata snapshot.
/// Profile prose is advisory and never admits a model or effort.
@MainActor
struct AgentTaskRoutingCandidateBuilder {
    struct Candidate: Equatable {
        let opaqueKey: String
        let utilityTier: String
        let target: AgentRoutingExecutableTarget
        let descriptor: AgentTaskRoutingCandidateDescriptor
        let snapshotScope: RoutingExecutionMetadataSnapshot.Scope?
        let profileIdentity: String?
        var usagePeerClass: String?
        var usageModelAliases: Set<String> = []

        init(
            opaqueKey: String,
            utilityTier: String,
            target: AgentRoutingExecutableTarget,
            descriptor: AgentTaskRoutingCandidateDescriptor,
            snapshotScope: RoutingExecutionMetadataSnapshot.Scope? = nil,
            profileIdentity: String? = nil,
            usagePeerClass: String? = nil,
            usageModelAliases: Set<String> = []
        ) {
            self.opaqueKey = opaqueKey
            self.utilityTier = utilityTier
            self.target = target
            self.descriptor = descriptor
            self.snapshotScope = snapshotScope
            self.profileIdentity = profileIdentity
            self.usagePeerClass = usagePeerClass
            self.usageModelAliases = usageModelAliases
        }
    }

    enum BuildError: Error, Equatable {
        case noAvailableTargets
        case insufficientCapacity
    }

    private struct NewestVersionedBase {
        let prefix: String
        let suffix: String?
    }

    private struct ModelDefinition {
        let provider: AgentProviderKind
        let baseModelAliases: [String]
        let modelClass: String
        let preferredCodexFamily: String?
        let newestVersionedBase: NewestVersionedBase?
        let rubric: String

        /// Explicit substitution constraints, not a claim of identical model capabilities.
        var usagePeerClass: String? {
            switch modelClass {
            case "gpt-luna", "claude-haiku": "light"
            case "gpt-5.6-terra", "claude-sonnet": "balanced"
            case "gpt-sol", "claude-opus": "strong"
            case "gpt-6-astra", "claude-fable": "frontier"
            default: nil
            }
        }

        init(
            provider: AgentProviderKind,
            baseModelAliases: [String],
            modelClass: String,
            preferredCodexFamily: String? = nil,
            newestVersionedBase: NewestVersionedBase? = nil,
            rubric: String
        ) {
            self.provider = provider
            self.baseModelAliases = baseModelAliases
            self.modelClass = modelClass
            self.preferredCodexFamily = preferredCodexFamily
            self.newestVersionedBase = newestVersionedBase
            self.rubric = rubric
        }
    }

    struct ModelFamilyAvailability: Equatable {
        let id: String
        let displayName: String
        let provider: AgentProviderKind
        let model: RoutingExecutionModelMetadata?
        let unavailableReason: String?

        var isAvailable: Bool {
            model != nil
        }
    }

    struct RoleDefaultReference: Equatable {
        let roleLabel: String
        let provider: AgentProviderKind
        let modelRaw: String
        let isUserOverride: Bool
    }

    let opaqueKey: () -> String
    private let metadata: RoutingExecutionMetadataAdapter
    private let profiles: RoutingModelProfileResolver
    private let profileSnapshot: RoutingModelProfileSnapshot

    init(
        opaqueKey: @escaping () -> String = { UUID().uuidString.lowercased() },
        profileResolver: RoutingModelProfileResolver? = nil,
        profileSnapshot: RoutingModelProfileSnapshot? = nil,
        cursorThinking: @escaping @MainActor (String) -> ACPModelParameterDefinition? = {
            ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: $0)?.definition(kind: .thinking)
        },
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) {
        self.opaqueKey = opaqueKey
        metadata = RoutingExecutionMetadataAdapter(cursorThinking: cursorThinking, modelOptions: modelOptions)
        let snapshot = profileSnapshot ?? RoutingModelProfileSnapshot.bundled
        self.profileSnapshot = snapshot
        profiles = profileResolver ?? snapshot.resolver
    }

    func capture(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> RoutingExecutionMetadataSnapshot {
        metadata.capture(allowedProviders: allowedProviders, availability: availability, surface: surface)
    }

    func build(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        roleDefaults: [RoleDefaultReference] = [],
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        try build(
            snapshot: capture(allowedProviders: allowedProviders, availability: availability, surface: surface),
            roleDefaults: roleDefaults,
            maximumChoices: maximumChoices
        )
    }

    func build(
        snapshot: RoutingExecutionMetadataSnapshot,
        roleDefaults: [RoleDefaultReference] = [],
        excludedMakers: Set<String> = [],
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        let available = Self.executableModels(in: snapshot)
        guard !available.isEmpty else { throw BuildError.noAvailableTargets }
        let allSelected = excludedMakers.isEmpty ? available : available.filter { _, model in
            guard let maker = AgentTaskRoutingMakerCatalog.maker(for: model.baseTarget) else { return false }
            return !excludedMakers.contains(maker.rawValue)
        }
        guard !allSelected.isEmpty else { return [] }
        let capacity = min(maximumChoices, FiniteChoiceDecisionValidator.maximumChoices)
        guard capacity > 0, allSelected.count == 1 || capacity >= 2 else {
            throw BuildError.insufficientCapacity
        }
        let selected = Array(allSelected.prefix(capacity))
        return selected.map { definition, model in
            let target = model.baseTarget
            let profile = profiles.resolve(model, catalogRevision: snapshot.scope.catalogRevision)
            let key = opaqueKey()
            let tier = definition.preferredCodexFamily == nil ? definition.modelClass : model.baseModelRaw
            let references = roleDefaults.filter { reference in
                reference.provider == model.provider
                    && model.advertisedOptionRawValues.contains {
                        $0 == reference.modelRaw
                    }
            }
            return Candidate(
                opaqueKey: key,
                utilityTier: tier,
                target: target,
                descriptor: .init(
                    opaqueKey: key,
                    roleLabels: [tier],
                    targetDescription: Self.modelDescription(model, profile: profile, snapshotDate: profiles.snapshotDate, roleDefaults: references),
                    rubricVersion: profiles.rubricVersion,
                    rubric: definition.rubric
                ),
                snapshotScope: snapshot.scope,
                profileIdentity: profileSnapshot.identity,
                usagePeerClass: definition.usagePeerClass,
                usageModelAliases: Set([model.baseModelRaw] + (model.provider == .claudeCode ? definition.baseModelAliases.filter { ["opus", "sonnet", "haiku", "fable"].contains($0) } : []))
            )
        }
    }

    func buildEfforts(
        for model: Candidate,
        availability: AgentModelCatalog.AvailabilityContext,
        allowPaidFast: Bool = false,
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        guard let scope = model.snapshotScope else { throw BuildError.noAvailableTargets }
        return try buildEfforts(
            for: model,
            snapshot: capture(
                allowedProviders: scope.allowedProviders,
                availability: availability,
                surface: scope.surface
            ),
            allowPaidFast: allowPaidFast,
            maximumChoices: maximumChoices
        )
    }

    func buildEfforts(
        for model: Candidate,
        snapshot: RoutingExecutionMetadataSnapshot,
        allowPaidFast: Bool = false,
        maximumChoices: Int = FiniteChoiceDecisionValidator.maximumChoices
    ) throws -> [Candidate] {
        guard model.snapshotScope == snapshot.scope,
              model.profileIdentity == profileSnapshot.identity,
              let selected = snapshot.model(for: model.target)
        else { throw BuildError.noAvailableTargets }
        // A Fast tier remains an exact provider-advertised target. Never synthesize it from
        // a model name, and expose it only after the explicit paid-tier opt-in.
        let fastVariants = allowPaidFast && selected.provider == .codexExec
            ? snapshot.models.filter {
                $0.provider == .codexExec && Self.isPaidFast($0.baseTarget)
                    && CodexModelSpecifier(raw: $0.baseModelRaw).baseModel == selected.baseModelRaw
            } : []
        let baseTargets = (Self.offersBaseEffortTarget(selected) ? [selected.baseTarget] : [])
            + selected.efforts.compactMap(\.executableTarget)
        var seen: Set<AgentRoutingExecutableTarget> = []
        let ordinaryTargets = baseTargets.filter { !Self.isPaidFast($0) && seen.insert($0).inserted }
        let capacity = min(maximumChoices, FiniteChoiceDecisionValidator.maximumChoices)
        guard capacity > 0, ordinaryTargets.count <= capacity else { throw BuildError.insufficientCapacity }
        let optionalFastTargets = allowPaidFast
            ? baseTargets.filter(Self.isPaidFast)
            + fastVariants.flatMap { [$0.baseTarget] + $0.efforts.compactMap(\.executableTarget) }
            : []
        let fastTargets = optionalFastTargets.filter { seen.insert($0).inserted }
        let targets = ordinaryTargets + (ordinaryTargets.count + fastTargets.count <= capacity ? fastTargets : [])
        let candidates = targets.map { target -> Candidate in
            let key = opaqueKey()
            let effort = target.reasoningEffortRaw
                ?? selected.efforts.first(where: { $0.executableTarget == target })?.id.rawValue
                ?? "provider-default"
            return Candidate(
                opaqueKey: key,
                utilityTier: effort,
                target: target,
                descriptor: .init(
                    opaqueKey: key,
                    roleLabels: ["effort:\(effort)"],
                    targetDescription: "Already selected model: \(selected.displayName). \(profiles.effortDescription(raw: effort == "provider-default" ? nil : effort).value)",
                    rubricVersion: profiles.rubricVersion,
                    rubric: "Choose this effort only if it supplies the reasoning depth the task needs. Prefer the lowest effort with a clear reliability margin; raise effort when ambiguity, review depth, risk, or long-horizon reasoning warrants it."
                ),
                snapshotScope: snapshot.scope,
                profileIdentity: profileSnapshot.identity
            )
        }
        guard !candidates.isEmpty else { throw BuildError.noAvailableTargets }
        return candidates
    }

    /// Antigravity and Cursor advertise effort as exact variants of a base the router selects. When
    /// such variants exist the effort stage is exactly those variants; the bare base is offered only
    /// when the provider advertised it as its own model option (Antigravity) or no control exists.
    private static func offersBaseEffortTarget(_ model: RoutingExecutionModelMetadata) -> Bool {
        guard model.efforts.contains(where: \.isExecutable) else { return true }
        switch model.provider {
        case .antigravity: return model.advertisedOptionRawValues.contains(model.baseModelRaw)
        case .cursor: return false
        default: return true
        }
    }

    func usageCandidates(
        basedOn target: AgentRoutingExecutableTarget,
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) -> (selected: Candidate, candidates: [Candidate])? {
        guard target.modelParameters.isEmpty, !Self.isPaidFast(target),
              let provider = AgentProviderKind(rawValue: target.agentRaw),
              let base = Self.baseModelRaw(target.modelRaw, provider: provider),
              let models = try? build(allowedProviders: allowedProviders, availability: availability, surface: surface),
              let definition = Self.modelDefinitions.first(where: { definition in
                  definition.provider == provider && (definition.baseModelAliases.contains(base) || models.contains {
                      $0.target.agentRaw == provider.rawValue && $0.target.modelRaw == base && $0.usagePeerClass == definition.usagePeerClass
                  })
              }), let peerClass = definition.usagePeerClass else { return nil }
        let selectedKey = opaqueKey()
        let selected = Candidate(
            opaqueKey: selectedKey,
            utilityTier: definition.modelClass,
            target: target,
            descriptor: .init(opaqueKey: selectedKey, roleLabels: [], targetDescription: "Local starting choice", rubricVersion: "local", rubric: ""),
            snapshotScope: models.first?.snapshotScope,
            profileIdentity: profileSnapshot.identity,
            usagePeerClass: peerClass,
            usageModelAliases: Set([base] + definition.baseModelAliases.filter { ["opus", "sonnet", "haiku", "fable"].contains($0) })
        )
        let effort = Self.effortRaw(target, provider: provider)
        let peers = models.filter { $0.usagePeerClass == peerClass && $0.target.agentRaw != provider.rawValue }.compactMap { model -> Candidate? in
            guard let effort else { return model }
            guard let efforts = try? buildEfforts(for: model, availability: availability),
                  let peerProvider = AgentProviderKind(rawValue: model.target.agentRaw),
                  let match = efforts.first(where: { Self.effortRaw($0.target, provider: peerProvider) == effort }) else { return nil }
            return Candidate(
                opaqueKey: model.opaqueKey,
                utilityTier: model.utilityTier,
                target: match.target,
                descriptor: model.descriptor,
                snapshotScope: match.snapshotScope,
                profileIdentity: match.profileIdentity,
                usagePeerClass: model.usagePeerClass,
                usageModelAliases: model.usageModelAliases
            )
        }
        return (selected, [selected] + peers)
    }

    static func isPaidFast(_ target: AgentRoutingExecutableTarget) -> Bool {
        (target.agentRaw == AgentProviderKind.codexExec.rawValue && CodexModelSpecifier(raw: target.modelRaw).serviceTier != nil)
            || target.modelParameters.contains { $0.configID == "fast" && $0.valueRaw == "true" }
    }

    private static func effortRaw(_ target: AgentRoutingExecutableTarget, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: target.reasoningEffortRaw ?? CodexModelSpecifier(raw: target.modelRaw).reasoningEffort?.rawValue
        case .claudeCode: target.reasoningEffortRaw ?? ClaudeModelSpecifier(raw: target.modelRaw).effortLevel?.rawValue
        default: nil
        }
    }

    func hasAvailableTarget(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> Bool {
        for provider in Self.curatedProviders where allowedProviders.contains(provider)
            && surface.allows(provider)
            && AgentModelCatalog.isAgentAvailable(provider, availability: availability)
        {
            let snapshot = capture(allowedProviders: [provider], availability: availability, surface: surface)
            if !Self.executableModels(in: snapshot).isEmpty { return true }
        }
        return false
    }

    /// Saved scope intent narrows the executable frontier only while that provider is available.
    static func providers(
        for scope: AgentTaskRoutingScope,
        configuration: AgentTaskRouterConfiguration,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) -> Set<AgentProviderKind> {
        let available = availableProviders(availability: availability, surface: surface, modelOptions: modelOptions)
        let preferred = scope == .primarySession ? configuration.primaryProvider : configuration.subagentProvider
        if let preferred, available.contains(preferred) { return [preferred] }
        return available
    }

    static func availableProviders(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general,
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) -> Set<AgentProviderKind> {
        Set(curatedProviders.filter { provider in
            guard surface.allows(provider), AgentModelCatalog.isAgentAvailable(provider, availability: availability) else {
                return false
            }
            return !modelOptions(provider, availability).filter { !$0.isPlaceholderDefault }.isEmpty
        })
    }

    func modelFamilyAvailability(
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface = .general
    ) -> [ModelFamilyAvailability] {
        // Claude Code and Codex families are always listed. Cursor, Antigravity and Grok CLI
        // families are listed only while their provider is available; Cursor Grok only while
        // the Grok CLI is unavailable, as in the executable frontier.
        let grokCLIAvailable = AgentModelCatalog.isAgentAvailable(.grok, availability: availability)
        let definitions = Self.modelDefinitions.filter { definition in
            if Self.familyProjectionProviders.contains(definition.provider) { return true }
            guard surface.allows(definition.provider),
                  AgentModelCatalog.isAgentAvailable(definition.provider, availability: availability)
            else { return false }
            return definition.modelClass != "cursor-grok" || !grokCLIAvailable
        }
        let snapshot = capture(
            allowedProviders: Set(definitions.map(\.provider)),
            availability: availability,
            surface: surface
        )
        return definitions.map { definition in
            let displayName = Self.familyDisplayName(for: definition)
            let providerAvailable = surface.allows(definition.provider)
                && AgentModelCatalog.isAgentAvailable(definition.provider, availability: availability)
            let model = providerAvailable
                ? Self.resolveModel(definition, from: snapshot.models.filter { $0.provider == definition.provider })
                : nil
            let reason: String? = if model != nil {
                nil
            } else if !providerAvailable {
                "\(definition.provider.displayName) not connected."
            } else {
                "\(definition.provider.displayName) does not advertise a supported \(displayName) model."
            }
            return .init(
                id: "\(definition.provider.rawValue):\(definition.modelClass)",
                displayName: displayName,
                provider: definition.provider,
                model: model,
                unavailableReason: reason
            )
        }
    }

    private static let modelDefinitions: [ModelDefinition] = [
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-luna", "gpt-5.6-luna"],
            modelClass: "gpt-luna",
            preferredCodexFamily: "luna",
            rubric: "Judge Luna as a base model using its capability, expected completion reliability, and price. Do not choose it merely because the prompt is short."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-5.6-terra"],
            modelClass: "gpt-5.6-terra",
            rubric: "Judge Terra as a base model using its capability, expected completion reliability, and price. It is not a default and receives no preference from its market tier."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6"],
            modelClass: "gpt-sol",
            preferredCodexFamily: "sol",
            rubric: "Judge Sol as a base model using its capability, expected completion reliability, and price, including whether its stronger base capability avoids missed findings or retries."
        ),
        .init(
            provider: .codexExec,
            baseModelAliases: ["gpt-6-astra"],
            modelClass: "gpt-6-astra",
            rubric: "Judge Astra as a base model using its capability, expected completion reliability, and premium price."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-haiku-4-5-20251001", "claude-haiku-4-5", "haiku"],
            modelClass: "claude-haiku",
            rubric: "Judge Haiku as a base model using its capability, expected completion reliability, and price. Do not choose it merely because the prompt is short."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-sonnet-5-5", "claude-sonnet-5", "sonnet"],
            modelClass: "claude-sonnet",
            rubric: "Judge Sonnet as a base model using its capability, expected completion reliability, and price. It is not a default and receives no preference from its market tier."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-opus-5-5", "opus", "claude-opus-5"],
            modelClass: "claude-opus",
            rubric: "Judge Opus as a base model using its capability, expected completion reliability, and price, including whether its stronger base capability avoids missed findings or retries."
        ),
        .init(
            provider: .claudeCode,
            baseModelAliases: ["claude-fable-5-1", "fable"],
            modelClass: "claude-fable",
            rubric: "Judge Fable as a base model using its capability, expected completion reliability, and premium price."
        ),
        .init(
            provider: .antigravity,
            baseModelAliases: [],
            modelClass: "gemini-flash",
            newestVersionedBase: .init(prefix: "gemini-", suffix: "-flash"),
            rubric: "Judge Gemini Flash as a base model using its capability, expected completion reliability, and price."
        ),
        .init(
            provider: .antigravity,
            baseModelAliases: [],
            modelClass: "gemini-pro",
            newestVersionedBase: .init(prefix: "gemini-", suffix: nil),
            rubric: "Judge Gemini Pro as a base model using its capability, expected completion reliability, and price."
        ),
        .init(
            provider: .grok,
            baseModelAliases: [],
            modelClass: "grok",
            newestVersionedBase: .init(prefix: "grok-", suffix: ""),
            rubric: "Judge Grok as a base model using its capability, expected completion reliability, and price."
        ),
        .init(
            provider: .cursor,
            baseModelAliases: ["composer-2.5"],
            modelClass: "composer",
            rubric: "Judge Composer as a base model using its capability, expected completion reliability, and price."
        ),
        .init(
            provider: .cursor,
            baseModelAliases: ["grok-4.7"],
            modelClass: "cursor-grok",
            rubric: "Judge Cursor Grok as a base model using its capability, expected completion reliability, and price."
        )
    ]

    var registeredTargetMakers: [String: AgentTaskRoutingMaker?] {
        Dictionary(uniqueKeysWithValues: Self.modelDefinitions.map { definition in
            (
                definition.modelClass,
                AgentTaskRoutingMakerCatalog.maker(
                    provider: definition.provider,
                    modelRaw: definition.baseModelAliases.first ?? definition.modelClass
                )
            )
        })
    }

    static let curatedProviders: [AgentProviderKind] = [.codexExec, .claudeCode, .cursor, .antigravity, .grok]
    private static let familyProjectionProviders: [AgentProviderKind] = [.codexExec, .claudeCode]

    private static func familyDisplayName(for definition: ModelDefinition) -> String {
        switch definition.modelClass {
        case "gemini-flash": "Gemini Flash"
        case "gemini-pro": "Gemini Pro"
        case "cursor-grok": "Cursor Grok"
        default:
            definition.modelClass.split(separator: "-").last.map(String.init)?.capitalized
                ?? definition.modelClass.capitalized
        }
    }

    private static func executableModels(
        in snapshot: RoutingExecutionMetadataSnapshot
    ) -> [(ModelDefinition, RoutingExecutionModelMetadata)] {
        modelDefinitions.compactMap { definition in
            let provider = definition.provider
            guard snapshot.scope.allowedProviders.contains(provider),
                  snapshot.scope.surface.allows(provider),
                  AgentModelCatalog.isAgentAvailable(provider, availability: snapshot.scope.availability),
                  // Cursor's Grok is a fallback while the Grok CLI is unavailable, never a second Grok.
                  definition.modelClass != "cursor-grok"
                  || !AgentModelCatalog.isAgentAvailable(.grok, availability: snapshot.scope.availability),
                  let model = resolveModel(
                      definition,
                      from: snapshot.models.filter { $0.provider == provider }
                  )
            else { return nil }
            return (definition, model)
        }
    }

    private static func resolveModel(
        _ definition: ModelDefinition,
        from models: [RoutingExecutionModelMetadata]
    ) -> RoutingExecutionModelMetadata? {
        let providerModels = models.filter { model in
            guard model.provider == definition.provider else { return false }
            return baseModelRaw(model.baseModelRaw, provider: definition.provider) == model.baseModelRaw
        }
        if let family = definition.preferredCodexFamily {
            let options = providerModels.map { model in
                AgentModelOption(
                    rawValue: model.baseModelRaw,
                    displayName: model.displayName,
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: model.isProviderDefault
                )
            }
            if let preferred = AgentModelCatalog.preferredCodexFamilyOption(family, from: options),
               let model = providerModels.first(where: { $0.baseModelRaw == preferred.rawValue })
            { return model }
        }
        if let rule = definition.newestVersionedBase {
            return newestModel(in: providerModels, rule: rule)
        }
        return definition.baseModelAliases.lazy.compactMap { alias in
            providerModels.first { model in
                model.baseModelRaw.caseInsensitiveCompare(alias) == .orderedSame
            }
        }.first
    }

    private static func newestModel(
        in models: [RoutingExecutionModelMetadata],
        rule: NewestVersionedBase
    ) -> RoutingExecutionModelMetadata? {
        var newest: RoutingExecutionModelMetadata?
        var newestVersion: [Int] = []
        for model in models {
            let base = model.baseModelRaw.lowercased()
            guard base.hasPrefix(rule.prefix) else { continue }
            let versionedBase = base.dropFirst(rule.prefix.count)
            let versionText: Substring
            if let suffix = rule.suffix {
                guard versionedBase.hasSuffix(suffix), versionedBase.count > suffix.count else { continue }
                versionText = versionedBase.dropLast(suffix.count)
            } else {
                guard !versionedBase.split(separator: "-").contains("flash") else { continue }
                versionText = versionedBase.prefix { $0 != "-" }
            }
            let components = versionText.split(separator: ".", omittingEmptySubsequences: false)
            let version = components.compactMap { Int($0) }
            guard !version.isEmpty, version.count == components.count else { continue }
            if newest == nil || isEarlier(newestVersion, than: version) {
                newest = model
                newestVersion = version
            }
        }
        return newest
    }

    private static func isEarlier(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func baseModelRaw(_ raw: String, provider: AgentProviderKind) -> String? {
        switch provider {
        case .codexExec: CodexModelSpecifier(raw: raw).baseModel
        case .claudeCode: ClaudeModelSpecifier(raw: raw).baseModel
        case .antigravity: RoutingModelIdentity.antigravityEffortSplit(raw)?.base ?? raw
        case .cursor, .grok: raw
        default: nil
        }
    }

    private static func modelDescription(
        _ model: RoutingExecutionModelMetadata,
        profile: ResolvedRoutingProfile,
        snapshotDate: String,
        roleDefaults: [RoleDefaultReference]
    ) -> String {
        let references = if roleDefaults.isEmpty {
            ""
        } else {
            " Agent Models references: \(roleDefaultLabels(roleDefaults)). These are context about the user's established setup, not constraints or automatic choices."
        }
        return "Provider: \(model.provider.displayName); base model: \(model.displayName). \(profile.description(snapshotDate: snapshotDate))\(references)"
    }

    private static func roleDefaultLabels(_ references: [RoleDefaultReference]) -> String {
        references.map { reference in
            let source = reference.isUserOverride ? "user-set" : "recommended"
            return "\(reference.roleLabel) (\(source))"
        }.joined(separator: ", ")
    }
}
