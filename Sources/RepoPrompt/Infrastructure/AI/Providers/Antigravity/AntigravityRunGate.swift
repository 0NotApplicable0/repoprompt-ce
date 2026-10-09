import Foundation

/// Orders one Antigravity run's `agy --print` turns on its own provider instance.
///
/// Each `AntigravityAgentProvider` owns one gate, and production builds one provider per run, so
/// separate runs never wait on each other. On one instance the gate hands its permit to the
/// registered stream producer and releases it only after that producer's cleanup, so a replacement
/// request on the same instance cannot launch before its cancelled predecessor has cleaned up.
///
/// agy auto-assigns conversation ids. `AntigravityTrajectoryToolLog` binds each turn to the exact id
/// announced in that turn's unique `--log-file`, so concurrent agy processes cannot cross-wire tool
/// cards or the auto-resume `--conversation` id.
actor AntigravityRunGate {
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
