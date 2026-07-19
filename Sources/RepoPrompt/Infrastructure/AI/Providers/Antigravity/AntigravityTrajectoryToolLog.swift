import Foundation

/// Locates the agy conversation trajectory DB created for the current run (newest DB that appears
/// after launch), mirroring grok's `GrokSessionToolLog`. agy creates exactly one new
/// `~/.gemini/antigravity-cli/conversations/<id>.db` per `--print` run.
struct AntigravityTrajectoryToolLog {
    private let conversationsRoot: URL
    private let preexisting: Set<String>

    init(environment: [String: String]) {
        let home: URL = if let h = environment["HOME"], !h.isEmpty { URL(fileURLWithPath: h) }
        else { FileManager.default.homeDirectoryForCurrentUser }
        conversationsRoot = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        preexisting = Self.dbNames(in: conversationsRoot)
    }

    func locate() -> URL? {
        let fresh = Self.dbNames(in: conversationsRoot).subtracting(preexisting)
        guard !fresh.isEmpty else { return nil }
        return fresh.map { conversationsRoot.appendingPathComponent($0) }
            .max { Self.modified($0) < Self.modified($1) }
    }

    private static func dbNames(in root: URL) -> Set<String> {
        guard let e = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(e.filter { $0.pathExtension == "db" }.map(\.lastPathComponent))
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// Pure dedup core: turns polled steps into ordered card events, exactly once each, and reports the
/// highest contiguous "done" idx to advance the per-DB query watermark to.
///
/// Dedup is keyed on the tool **invocation id** (stable per agy call id), NOT the row `idx`. This
/// matters because a resumed run forks to a NEW conversation DB whose `idx` restarts at 0 — keying on
/// idx would collide across DBs. Invocation-id keying lets the SAME emitter span every resume turn
/// without re-emitting or duplicating a card. This assumes agy re-materializes a resumed
/// conversation's recalled steps with their ORIGINAL call ids (empirically true); were a future agy
/// to assign fresh ids to recalled rows, an already-shown card could re-emit — a benign duplicate,
/// never a crash or hang.
struct AntigravityTrajectoryEmitter {
    private let parser = AntigravityToolStepParser()
    private var emittedCalls: Set<UUID> = []
    private var emittedResults: Set<UUID> = []

    /// - Returns: the new card events, plus the highest contiguous "done" idx to advance the caller's
    ///   per-DB watermark to (`nil` ⇒ don't advance; a not-yet-terminal tool step must be re-read).
    mutating func process(_ steps: [AntigravityTrajectoryStore.ToolStep]) -> (events: [AIStreamResult], advanceTo: Int64?) {
        var events: [AIStreamResult] = []
        var advanceTo: Int64?
        var advancing = true
        for step in steps.sorted(by: { $0.idx < $1.idx }) {
            switch parser.parseRow(
                status: step.status,
                payload: step.payload,
                failureKind: step.failureKind
            ) {
            case .nonTool:
                if advancing { advanceTo = step.idx } // non-tool step: done, advance
            case let .suppressedMCP(isTerminal):
                if isTerminal {
                    if advancing { advanceTo = step.idx } // successful MCP card came from expected-PID tracking
                } else {
                    advancing = false // suppressed but in-flight: hold the watermark until final status
                }
            case let .visible(parsed):
                if emittedCalls.insert(parsed.invocationID).inserted { events.append(parsed.call) }
                if let result = parsed.result {
                    if emittedResults.insert(parsed.invocationID).inserted { events.append(result) }
                    if advancing { advanceTo = step.idx } // terminal tool: done, advance
                } else {
                    advancing = false // in-flight: stop advancing, re-read next poll
                }
            }
        }
        return (events, advanceTo)
    }
}

/// Tails the run's agy trajectory DB and forwards tool-card events. Fail-open: waits for the DB to
/// appear, opens it read-only, polls new steps, and reopens if the `steps` table is not yet present.
///
/// Handles **auto-resume**: each resumed `--print --conversation` turn forks to a NEWER conversation
/// DB, so every poll re-evaluates `locate()` (which returns the newest DB to appear) and switches to
/// it — resetting the per-DB idx watermark while the emitter's invocation-id dedup carries across the
/// switch. Runs until the surrounding task is cancelled.
enum AntigravityTrajectoryToolLogStream {
    private static let pageLimit: Int32 = 500
    private static let finalDrainMaxAttempts = 8
    private static let finalDrainTimeBudget: Duration = .milliseconds(250)

    private enum PollResult {
        case drained
        case hasMore
        case retryable
    }

    static func tail(
        into continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        locate: @Sendable @escaping () -> URL?,
        pollNanos: UInt64 = 200_000_000,
        waitBetweenPolls: @Sendable @escaping (UInt64) async -> Void = { nanos in
            try? await Task.sleep(nanoseconds: nanos)
        },
        waitForFinalDrainRetry: @Sendable @escaping (Duration) async -> Void = { duration in
            // The tail task is already cancelled when the final drain runs, so an ordinary
            // Task.sleep would return immediately. Isolate the short bounded wait from the
            // caller's cancellation state to give a just-committing WAL writer time to settle.
            await Task.detached {
                try? await Task.sleep(for: duration)
            }.value
        },
        storeFactory: @Sendable @escaping (String) -> (any AntigravityTrajectoryStoreReading)? = {
            AntigravityTrajectoryStore(path: $0)
        }
    ) async {
        var currentPath: String?
        var emitter = AntigravityTrajectoryEmitter() // invocation-id dedup persists across DB switches
        var store: (any AntigravityTrajectoryStoreReading)?
        var after: Int64 = 0
        while !Task.isCancelled {
            pollOnce(
                into: continuation,
                locate: locate,
                storeFactory: storeFactory,
                currentPath: &currentPath,
                store: &store,
                after: &after,
                emitter: &emitter
            )
            await waitBetweenPolls(pollNanos)
        }

        // The process can commit terminal statuses or a multi-page backlog after the preceding poll
        // but immediately before provider teardown. Cancellation is the synchronization edge: drain
        // with the same path/store/watermark/emitter under a small attempt and wall-clock budget.
        if Task.isCancelled {
            await drainOnCancellation(
                into: continuation,
                locate: locate,
                storeFactory: storeFactory,
                currentPath: &currentPath,
                store: &store,
                after: &after,
                emitter: &emitter,
                waitForRetry: waitForFinalDrainRetry
            )
        }
    }

    @discardableResult
    private static func pollOnce(
        into continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        locate: @Sendable () -> URL?,
        storeFactory: @Sendable (String) -> (any AntigravityTrajectoryStoreReading)?,
        currentPath: inout String?,
        store: inout (any AntigravityTrajectoryStoreReading)?,
        after: inout Int64,
        emitter: inout AntigravityTrajectoryEmitter
    ) -> PollResult {
        if let newest = locate()?.path, newest != currentPath {
            currentPath = newest // a resume turn forked to a newer DB → switch, restart watermark
            store = nil
            after = 0
        }
        guard let path = currentPath else { return .retryable }
        if store == nil { store = storeFactory(path) }
        guard let activeStore = store else { return .retryable }
        guard let rows = activeStore.steps(after: after, limit: pageLimit) else {
            // The table is not ready or the query failed. Reopen on the next ordinary/final poll.
            store = nil
            return .retryable
        }
        guard !rows.isEmpty else { return .drained }

        let (events, advanceTo) = emitter.process(rows)
        for event in events {
            continuation.yield(event)
        }
        if let advanceTo { after = max(after, advanceTo) }

        // A fully consumed short page reaches the current end. A full consumed page may have more
        // rows behind it. No contiguous advancement means an in-flight row must be retried.
        let consumedThroughPage = rows.last.map { after >= $0.idx } == true
        if consumedThroughPage, rows.count < Int(pageLimit) { return .drained }
        return consumedThroughPage ? .hasMore : .retryable
    }

    private static func drainOnCancellation(
        into continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        locate: @Sendable () -> URL?,
        storeFactory: @Sendable (String) -> (any AntigravityTrajectoryStoreReading)?,
        currentPath: inout String?,
        store: inout (any AntigravityTrajectoryStoreReading)?,
        after: inout Int64,
        emitter: inout AntigravityTrajectoryEmitter,
        waitForRetry: @Sendable (Duration) async -> Void
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: finalDrainTimeBudget)
        for attempt in 0 ..< finalDrainMaxAttempts {
            guard attempt == 0 || clock.now < deadline else { return }
            switch pollOnce(
                into: continuation,
                locate: locate,
                storeFactory: storeFactory,
                currentPath: &currentPath,
                store: &store,
                after: &after,
                emitter: &emitter
            ) {
            case .drained:
                return
            case .hasMore:
                continue
            case .retryable:
                guard attempt + 1 < finalDrainMaxAttempts else { return }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { return }
                // Back off across the grace window instead of burning every attempt immediately:
                // 10, 20, 30, then 40 ms (capped), always clipped to the monotonic deadline.
                let requested = Duration.milliseconds(min((attempt + 1) * 10, 40))
                await waitForRetry(min(requested, remaining))
            }
        }
    }
}
