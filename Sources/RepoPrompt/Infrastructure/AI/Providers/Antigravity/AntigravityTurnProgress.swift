import Foundation

final class AntigravityTurnProgress: @unchecked Sendable {
    static let idleLimit: TimeInterval = 120
    static let failureMessage = "Antigravity fork-fallback produced no stdout or trajectory progress for 120 seconds. The stalled process was stopped; retry or run `agy` interactively to inspect the failure."

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var lastProgressAt: TimeInterval = 0
    private var active = false
    private var timedOut = false

    init(now: @escaping @Sendable () -> TimeInterval) {
        self.now = now
    }

    func beginTurn() {
        lock.withLock {
            lastProgressAt = now()
            active = true
            timedOut = false
        }
    }

    func recordProgress() {
        lock.withLock {
            guard active, !timedOut else { return }
            lastProgressAt = now()
        }
    }

    func claimIdleTimeout() -> Bool {
        lock.withLock {
            guard active, !timedOut, now() - lastProgressAt >= Self.idleLimit else { return false }
            timedOut = true
            return true
        }
    }

    func endTurn() {
        lock.withLock { active = false }
    }

    var hasTimedOut: Bool {
        lock.withLock { timedOut }
    }
}
