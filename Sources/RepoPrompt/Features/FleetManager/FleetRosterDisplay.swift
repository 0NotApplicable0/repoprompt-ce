import Foundation

enum FleetRosterDisplay {
    enum Tone: Equatable {
        case running
        case waiting
        case success
        case failure
        case neutral
    }

    struct RollupLine: Equatable {
        var summary: String
        var waitingText: String?
        var otherWindowText: String?
        var running: Int
        var waiting: Int
        var rest: Int
    }

    struct Summary: Equatable {
        var agents: Int
        var subAgents: Int
        var running: Int
        var waiting: Int
        var failed: Int
        var workspaces: Int
        var parked: Int
        var onScreen: Int
    }

    static func stateLabel(_ state: AgentSessionRunState) -> String {
        switch state {
        case .idle: "Idle"
        case .running: "Running"
        case .waitingForUser: "Waiting for you"
        case .waitingForQuestion: "Has a question"
        case .waitingForApproval: "Needs approval"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    static func tone(_ state: AgentSessionRunState) -> Tone {
        switch state {
        case .running: .running
        case .waitingForUser, .waitingForQuestion, .waitingForApproval: .waiting
        case .completed: .success
        case .failed: .failure
        case .idle, .cancelled: .neutral
        }
    }

    static func pendingLabel(_ kind: FleetRosterPendingKind) -> String {
        switch kind {
        case .approval: "Approval"
        case .question: "Question"
        case .operatorTurn: "Your turn"
        }
    }

    static func relativeTime(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        switch seconds {
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }

    static func rollupLine(_ rollup: FleetRosterRollup) -> RollupLine? {
        guard rollup.totalSubagents > 0 else { return nil }
        let noun = rollup.totalSubagents == 1 ? "sub-agent" : "sub-agents"
        var summary = "\(rollup.totalSubagents) \(noun)"
        if rollup.runningCount > 0 { summary += " \u{00B7} \(rollup.runningCount) running" }
        let other = rollup.otherWindowCount
        return RollupLine(
            summary: summary,
            waitingText: rollup.waitingCount > 0 ? "\(rollup.waitingCount) waiting on you" : nil,
            otherWindowText: other > 0 ? (other == 1 ? "1 in another window" : "\(other) in other windows") : nil,
            running: rollup.runningCount,
            waiting: rollup.waitingCount,
            rest: max(0, rollup.totalSubagents - rollup.runningCount - rollup.waitingCount)
        )
    }

    static func hasDisclosure(_ row: FleetRosterRow) -> Bool {
        !row.children.isEmpty
    }

    struct Occurrence: Hashable {
        var windowID: Int
        var workspaceID: UUID
        var sessionID: UUID
    }

    static func occurrence(of row: FleetRosterRow, in section: FleetRosterSection) -> Occurrence {
        Occurrence(windowID: section.windowID, workspaceID: section.workspaceID, sessionID: row.id)
    }

    static func visibleChildren(of row: FleetRosterRow, in section: FleetRosterSection, collapsed: Set<Occurrence>) -> [FleetRosterRow] {
        collapsed.contains(occurrence(of: row, in: section)) ? [] : row.children
    }

    static func sectionCounts(_ section: FleetRosterSection) -> (running: String, waiting: String) {
        ("\(section.runningCount) running", "\(section.waitingCount) waiting")
    }

    static func parkedLabel(_ isParked: Bool) -> String {
        isParked ? "Parked" : "On screen"
    }

    static func summary(_ sections: [FleetRosterSection]) -> Summary {
        let rows = sections.flatMap(\.allRows)
        let parked = sections.filter(\.isParked).count
        return Summary(
            agents: rows.count,
            subAgents: rows.count(where: { $0.parent != nil }),
            running: sections.reduce(0) { $0 + $1.runningCount },
            waiting: sections.reduce(0) { $0 + $1.waitingCount },
            failed: rows.count(where: { $0.runState == .failed }),
            workspaces: sections.count,
            parked: parked,
            onScreen: sections.count - parked
        )
    }

    static func workspaceLine(_ summary: Summary) -> String {
        let noun = summary.workspaces == 1 ? "workspace" : "workspaces"
        return "\(summary.workspaces) \(noun) \u{00B7} \(summary.parked) parked \u{00B7} \(summary.onScreen) on screen"
    }

    static func emptyState() -> (title: String, message: String) {
        ("No live workspaces", "Workspace windows appear here as soon as a project workspace opens.")
    }
}
