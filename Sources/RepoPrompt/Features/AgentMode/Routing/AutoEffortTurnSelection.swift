import Foundation

/// Ephemeral choice for one composer-created user turn. Never written to the model picker or settings.
struct AutoEffortTurnSelection: Equatable {
    let provider: AgentProviderKind
    let selectedModelRaw: String
    let manualEffortRaw: String?
    let effortRaw: String

    func isCurrent(
        provider currentProvider: AgentProviderKind,
        selectedModelRaw currentModelRaw: String,
        manualEffortRaw currentManualEffortRaw: String?,
        enabled: Bool
    ) -> Bool {
        enabled
            && provider == currentProvider
            && selectedModelRaw == currentModelRaw
            && manualEffortRaw == currentManualEffortRaw
    }
}

/// Conservative exact-model admission. The provider's live effort catalog supplies the choices;
/// a model name alone never authorizes an effort that the active runtime does not advertise.
enum AutoEffortModelPolicy {
    private static let codexModels: Set<String> = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
    private static let claudeModels: Set<String> = [
        "claude-opus-5", "claude-opus-5-5", "claude-fable-5-1", "claude-mythos-5-1"
    ]

    static func codexEfforts(modelRaw: String, advertised: [CodexReasoningEffort]) -> [String] {
        guard let base = CodexModelSpecifier(raw: modelRaw).baseModel?.lowercased(),
              codexModels.contains(base)
        else { return [] }
        let permitted: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
        return permitted.filter { advertised.contains($0) }.map(\.rawValue)
    }

    static func claudeEfforts(modelRaw: String, advertised: [ClaudeCodeEffortLevel]) -> [String] {
        guard let base = ClaudeModelSpecifier(raw: modelRaw).baseModel?.lowercased(),
              claudeModels.contains(base)
        else { return [] }
        let permitted: [ClaudeCodeEffortLevel] = [.low, .medium, .high, .xhigh, .max]
        return permitted.filter { advertised.contains($0) }.map(\.rawValue)
    }
}
