import Foundation
import RepoPromptSettingsCore

/// An opaque provider value. An advertised value is not necessarily executable by this app.
struct ExecutionEffortID: Hashable {
    let rawValue: String
}

struct RoutingExecutionEffort: Equatable {
    let id: ExecutionEffortID
    let executableTarget: AgentRoutingExecutableTarget?

    var isExecutable: Bool {
        executableTarget != nil
    }
}

struct RoutingExecutionModelMetadata: Equatable {
    let provider: AgentProviderKind
    let baseModelRaw: String
    let displayName: String
    let isProviderDefault: Bool
    let catalogOrder: Int
    let advertisedOptionRawValues: [String]
    let defaultEffortID: ExecutionEffortID?
    let efforts: [RoutingExecutionEffort]

    var baseTarget: AgentRoutingExecutableTarget {
        .init(agentRaw: provider.rawValue, modelRaw: baseModelRaw, reasoningEffortRaw: nil, modelParameters: [])
    }
}

/// One immutable provider-catalog read for a complete model-then-effort transaction.
/// Equality of scope fences application when the surface, availability or catalog changes.
struct RoutingExecutionMetadataSnapshot: Equatable {
    struct Scope: Equatable {
        let surface: AgentModelCatalog.AgentSelectionSurface
        let availability: AgentModelCatalog.AvailabilityContext
        let allowedProviders: Set<AgentProviderKind>
        let catalogRevision: String
    }

    let scope: Scope
    let models: [RoutingExecutionModelMetadata]

    func contains(_ target: AgentRoutingExecutableTarget) -> Bool {
        models.contains { model in
            model.baseTarget == target || model.efforts.contains { $0.executableTarget == target }
        }
    }

    func model(for target: AgentRoutingExecutableTarget) -> RoutingExecutionModelMetadata? {
        models.first { $0.baseTarget == target }
    }
}

/// Reads the existing execution catalog; it does not discover, authorize, or persist models.
@MainActor
struct RoutingExecutionMetadataAdapter {
    private let modelOptions: @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption]
    /// Cursor's advertised effort control for a base model. Its exact `config_id` and values are
    /// the only source of Cursor effort targets; absence means one provider-default target.
    private let cursorThinking: @MainActor (String) -> ACPModelParameterDefinition?

    init(
        cursorThinking: @escaping @MainActor (String) -> ACPModelParameterDefinition? = {
            ACPModelParameterResolver.parameterSet(providerID: .cursor, selectedModelRaw: $0)?.definition(kind: .thinking)
        },
        modelOptions: @escaping @MainActor (AgentProviderKind, AgentModelCatalog.AvailabilityContext) -> [AgentModelOption] = {
            AgentModelCatalog.options(for: $0, availability: $1)
        }
    ) {
        self.cursorThinking = cursorThinking
        self.modelOptions = modelOptions
    }

    func capture(
        allowedProviders: Set<AgentProviderKind>,
        availability: AgentModelCatalog.AvailabilityContext,
        surface: AgentModelCatalog.AgentSelectionSurface
    ) -> RoutingExecutionMetadataSnapshot {
        let providers = allowedProviders.sorted { $0.rawValue < $1.rawValue }.filter {
            surface.allows($0) && AgentModelCatalog.isAgentAvailable($0, availability: availability)
        }
        var revision = StableCatalogRevision()
        var models: [RoutingExecutionModelMetadata] = []
        for provider in providers {
            let options = modelOptions(provider, availability)
            revision.append(provider.rawValue)
            for option in options {
                revision.append(option.rawValue)
                revision.append(option.displayName)
                revision.append(option.isPlaceholderDefault ? "placeholder" : "model")
                revision.append(option.isProviderDefault ? "default" : "ordinary")
                revision.append(option.effortVariant?.baseModelRaw ?? "")
                revision.append(option.effortVariant?.reasoningEffort.rawValue ?? "")
                revision.append(option.defaultReasoningEffortRawValue ?? option.defaultReasoningEffort?.rawValue ?? "")
                for effort in option.supportedReasoningEffortRawValues {
                    revision.append(effort)
                }
                for effort in option.supportedReasoningEfforts {
                    revision.append(effort.rawValue)
                }
            }
            models.append(contentsOf: self.models(for: provider, options: options, revision: &revision))
        }
        return .init(
            scope: .init(
                surface: surface,
                availability: availability,
                allowedProviders: allowedProviders,
                catalogRevision: revision.value
            ),
            models: models
        )
    }

    private func models(
        for provider: AgentProviderKind,
        options: [AgentModelOption],
        revision: inout StableCatalogRevision
    ) -> [RoutingExecutionModelMetadata] {
        struct Entry {
            var raw: String
            var displayName: String
            var isDefault: Bool
            var order: Int
            var effortRawValues: [String]
            var optionRawValues: [String]
            var defaultEffortRaw: String?
            var variantTargets: [String: AgentRoutingExecutableTarget]
        }
        var order: [String] = []
        var entries: [String: Entry] = [:]
        for (index, option) in options.enumerated() where !option.isPlaceholderDefault {
            // Antigravity advertises effort as a suffix on the full model ID. Group those IDs under
            // the base model; each advertised ID remains the exact executable effort target.
            let antigravityVariant = provider == .antigravity
                ? RoutingModelIdentity.antigravityEffortSplit(option.rawValue)
                : nil
            let isEffortVariant = option.effortVariant != nil || antigravityVariant != nil
            let base = option.effortVariant?.baseModelRaw ?? antigravityVariant?.base ?? option.rawValue
            guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = base
            if entries[key] == nil {
                order.append(key)
                entries[key] = Entry(
                    raw: base,
                    displayName: isEffortVariant ? base : option.displayName,
                    isDefault: false,
                    order: index,
                    effortRawValues: [],
                    optionRawValues: [],
                    defaultEffortRaw: nil,
                    variantTargets: [:]
                )
            }
            guard var entry = entries[key] else { continue }
            if !isEffortVariant { entry.displayName = option.displayName }
            entry.isDefault = entry.isDefault || option.isProviderDefault
            entry.optionRawValues.append(option.rawValue)
            entry.defaultEffortRaw = entry.defaultEffortRaw
                ?? option.defaultReasoningEffortRawValue
                ?? option.defaultReasoningEffort?.rawValue
            entry.effortRawValues.append(contentsOf: option.supportedReasoningEffortRawValues)
            entry.effortRawValues.append(contentsOf: option.supportedReasoningEfforts.map(\.rawValue))
            if let variant = option.effortVariant {
                entry.effortRawValues.append(variant.reasoningEffort.rawValue)
                entry.variantTargets[variant.reasoningEffort.rawValue] = .init(
                    agentRaw: provider.rawValue,
                    modelRaw: provider == .codexExec ? base : option.rawValue,
                    reasoningEffortRaw: provider == .codexExec ? variant.reasoningEffort.rawValue : nil,
                    modelParameters: []
                )
            }
            if let antigravityVariant {
                entry.effortRawValues.append(antigravityVariant.effort)
                entry.variantTargets[antigravityVariant.effort] = .init(
                    agentRaw: provider.rawValue,
                    modelRaw: option.rawValue,
                    reasoningEffortRaw: nil,
                    modelParameters: []
                )
            }
            entries[key] = entry
        }
        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            var seen: Set<String> = []
            if provider == .cursor,
               let thinking = cursorThinking(entry.raw), !thinking.choices.isEmpty
            {
                revision.append(thinking.configID)
                let efforts = thinking.choices.compactMap { choice -> RoutingExecutionEffort? in
                    guard !choice.rawValue.isEmpty, seen.insert(choice.rawValue).inserted else { return nil }
                    revision.append(choice.rawValue)
                    return .init(
                        id: .init(rawValue: choice.rawValue),
                        executableTarget: .init(
                            agentRaw: provider.rawValue,
                            modelRaw: entry.raw,
                            reasoningEffortRaw: nil,
                            modelParameters: [ACPModelParameterSelection(
                                providerID: .cursor,
                                baseModelRaw: entry.raw,
                                kind: .thinking,
                                configID: thinking.configID,
                                valueRaw: choice.rawValue
                            )]
                        )
                    )
                }
                return .init(
                    provider: provider,
                    baseModelRaw: entry.raw,
                    displayName: entry.displayName,
                    isProviderDefault: entry.isDefault,
                    catalogOrder: entry.order,
                    advertisedOptionRawValues: entry.optionRawValues,
                    defaultEffortID: thinking.currentValueRaw.isEmpty ? nil : ExecutionEffortID(rawValue: thinking.currentValueRaw),
                    efforts: efforts
                )
            }
            let efforts = entry.effortRawValues.compactMap { raw -> RoutingExecutionEffort? in
                guard !raw.isEmpty, seen.insert(raw).inserted else { return nil }
                let target = Self.executableEffortTarget(
                    provider: provider,
                    base: entry.raw,
                    raw: raw,
                    variant: entry.variantTargets[raw]
                )
                return .init(id: .init(rawValue: raw), executableTarget: target)
            }
            return .init(
                provider: provider,
                baseModelRaw: entry.raw,
                displayName: entry.displayName,
                isProviderDefault: entry.isDefault,
                catalogOrder: entry.order,
                advertisedOptionRawValues: entry.optionRawValues,
                defaultEffortID: entry.defaultEffortRaw.map { ExecutionEffortID(rawValue: $0) },
                efforts: efforts
            )
        }
    }

    private static func executableEffortTarget(
        provider: AgentProviderKind,
        base: String,
        raw: String,
        variant: AgentRoutingExecutableTarget?
    ) -> AgentRoutingExecutableTarget? {
        if provider == .codexExec,
           let known = CodexReasoningEffort.parse(raw), known.rawValue == raw
        {
            return .init(agentRaw: provider.rawValue, modelRaw: base, reasoningEffortRaw: raw, modelParameters: [])
        }
        if provider == .claudeCode,
           let known = ClaudeCodeEffortLevel.parse(raw), known.rawValue == raw
        {
            return variant
        }
        // Antigravity executes only the exact full model ID it advertised for this effort.
        if provider == .antigravity { return variant }
        // ACP and future effort values remain visible metadata until their execution bridge
        // can submit the exact raw value; profiles cannot authorize that bridge.
        return nil
    }
}

/// Deterministic, non-cryptographic catalog change token; no process-randomized Hasher.
private struct StableCatalogRevision {
    private var hash: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ value: String) {
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        hash = (hash ^ 255) &* 1_099_511_628_211
    }

    var value: String {
        String(hash, radix: 16)
    }
}
