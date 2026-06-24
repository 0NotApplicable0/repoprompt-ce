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
            guard let parsed = parser.parse(status: step.status, payload: step.payload) else {
                if advancing { advanceTo = step.idx } // non-tool step: done, advance
                continue
            }
            if emittedCalls.insert(parsed.invocationID).inserted { events.append(parsed.call) }
            if let result = parsed.result {
                if emittedResults.insert(parsed.invocationID).inserted { events.append(result) }
                if advancing { advanceTo = step.idx } // terminal tool: done, advance
            } else {
                advancing = false // in-flight: stop advancing, re-read next poll
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
    static func tail(
        into continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        locate: @Sendable @escaping () -> URL?,
        pollNanos: UInt64 = 200_000_000
    ) async {
        var currentPath: String?
        while !Task.isCancelled, currentPath == nil {
            currentPath = locate()?.path
            if currentPath == nil { try? await Task.sleep(nanoseconds: pollNanos) }
        }
        guard !Task.isCancelled else { return }

        var emitter = AntigravityTrajectoryEmitter() // invocation-id dedup persists across DB switches
        var store: AntigravityTrajectoryStore?
        var after: Int64 = 0
        while !Task.isCancelled {
            if let newest = locate()?.path, newest != currentPath {
                currentPath = newest // a resume turn forked to a newer DB → switch, restart watermark
                store = nil
                after = 0
            }
            if let path = currentPath {
                if store == nil { store = AntigravityTrajectoryStore(path: path) }
                if let s = store {
                    if let rows = s.steps(after: after, limit: 500) {
                        let (events, advanceTo) = emitter.process(rows)
                        for event in events {
                            continuation.yield(event)
                        }
                        if let advanceTo { after = max(after, advanceTo) }
                    } else {
                        store = nil // table not ready / query failed → reopen
                    }
                }
            }
            try? await Task.sleep(nanoseconds: pollNanos)
        }
    }
}
