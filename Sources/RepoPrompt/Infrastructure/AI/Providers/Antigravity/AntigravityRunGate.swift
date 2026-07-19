import Foundation

/// Serializes `agy --print` runs within this process.
///
/// agy auto-assigns conversation ids and exposes no way to read them (not on stdout, not in the
/// `--log-file`) or to supply one (`--conversation <new-id>` is ignored; agy mints its own). The
/// only handle on "which conversation DB belongs to this run" is therefore "the newest DB created
/// after launch" (see `AntigravityTrajectoryToolLog`). That guess is correct only when at most one
/// agy run executes at a time — otherwise two concurrent runs could tail or resume each other's
/// conversation, cross-wiring tool cards and the auto-resume `--conversation` id.
///
/// This actor enforces that single-run invariant for in-process runs (FIFO). Runs from external
/// agy processes are out of scope, mirroring grok's cwd-scoping assumption.
actor AntigravityRunGate {
    static let shared = AntigravityRunGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var locked = false
    private var waiters: [Waiter] = []

    /// Acquire the gate, suspending FIFO until the current holder releases.
    func lock() async throws {
        try Task.checkCancellation()
        if !locked {
            locked = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard acquired else { throw CancellationError() }

        // Cancellation can race the FIFO handoff after the waiter leaves the queue. Relinquish an
        // already-granted permit before throwing so neither this task nor its successor is stranded.
        if Task.isCancelled {
            unlock()
            throw CancellationError()
        }
    }

    /// Release the gate, waking the next FIFO waiter (if any). Must be called exactly once per
    /// successful `lock()`.
    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Number of runs currently parked waiting for the gate. Test-only observability seam so a test
    /// can deterministically confirm a second acquirer is parked before the holder releases.
    var waiterCount: Int {
        waiters.count
    }

    /// Test-only observability for cancellation coverage: removing a queued waiter must not release
    /// the current holder's permit.
    var isLocked: Bool {
        locked
    }
}
