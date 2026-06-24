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

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the gate, suspending FIFO until the current holder releases.
    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Release the gate, waking the next FIFO waiter (if any). Must be called exactly once per
    /// successful `lock()`.
    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Number of runs currently parked waiting for the gate. Test-only observability seam so a test
    /// can deterministically confirm a second acquirer is parked before the holder releases.
    var waiterCount: Int {
        waiters.count
    }
}
