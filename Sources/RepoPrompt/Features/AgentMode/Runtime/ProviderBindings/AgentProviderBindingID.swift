import Foundation

enum AgentProviderBindingID: String, CaseIterable, Hashable {
    case codex
    case claude
    case openCode
    case cursor
    case antigravity
    case grok
    case grokBuild
    case devin

    /// Keep grokBuild decodable without exposing retired agent permissions.
    static let allCases: [AgentProviderBindingID] = [.codex, .claude, .openCode, .cursor, .antigravity, .grok, .devin]

    var displayName: String {
        switch self {
        case .codex:
            "Codex CLI"
        case .claude:
            "Claude Code"
        case .openCode:
            "OpenCode"
        case .cursor:
            "Cursor CLI"
        case .antigravity:
            "Antigravity CLI"
        case .grok:
            "Grok CLI"
        case .grokBuild:
            "Grok Build"
        case .devin:
            "Devin CLI"
        }
    }
}

extension AgentProviderKind {
    var providerBindingID: AgentProviderBindingID {
        switch self {
        case .codexExec:
            .codex
        case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
            .claude
        case .openCode:
            .openCode
        case .cursor:
            .cursor
        case .antigravity:
            .antigravity
        case .grok:
            .grok
        case .grokBuild:
            .grokBuild
        case .devin:
            .devin
        }
    }
}
