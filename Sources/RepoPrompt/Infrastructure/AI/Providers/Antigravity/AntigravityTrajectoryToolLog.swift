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

/// Pure dedup/advance core: turns polled steps into ordered card events, exactly once each, and
/// computes the next watermark without skipping in-flight tool steps.
struct AntigravityTrajectoryEmitter {
    private let parser = AntigravityToolStepParser()
    private var emittedCalls: Set<Int64> = []
    private var emittedResults: Set<Int64> = []
    private var after: Int64 = 0

    mutating func process(_ steps: [AntigravityTrajectoryStore.ToolStep]) -> (events: [AIStreamResult], nextAfter: Int64) {
        var events: [AIStreamResult] = []
        var advancing = true
        for step in steps.sorted(by: { $0.idx < $1.idx }) {
            guard let parsed = parser.parse(status: step.status, payload: step.payload) else {
                if advancing { after = max(after, step.idx) } // non-tool step: done, advance
                continue
            }
            if emittedCalls.insert(step.idx).inserted { events.append(parsed.call) }
            if let result = parsed.result {
                if emittedResults.insert(step.idx).inserted { events.append(result) }
                if advancing { after = max(after, step.idx) } // terminal tool: done, advance
            } else {
                advancing = false // in-flight: stop advancing, re-read next poll
            }
        }
        return (events, after)
    }
}

/// Tails an agy trajectory DB and forwards tool-card events. Fail-open: waits for the DB to appear,
/// opens it read-only, polls new steps, and reopens if the `steps` table is not yet present. Runs
/// until the surrounding task is cancelled.
enum AntigravityTrajectoryToolLogStream {
    static func tail(
        into continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        locate: @Sendable @escaping () -> URL?,
        pollNanos: UInt64 = 200_000_000
    ) async {
        var url: URL?
        while !Task.isCancelled, url == nil {
            url = locate()
            if url == nil { try? await Task.sleep(nanoseconds: pollNanos) }
        }
        guard !Task.isCancelled, let dbURL = url else { return }

        var emitter = AntigravityTrajectoryEmitter()
        var store: AntigravityTrajectoryStore?
        var after: Int64 = 0
        while !Task.isCancelled {
            if store == nil { store = AntigravityTrajectoryStore(path: dbURL.path) }
            if let s = store {
                if let rows = s.steps(after: after, limit: 500) {
                    let (events, nextAfter) = emitter.process(rows)
                    for event in events {
                        continuation.yield(event)
                    }
                    after = nextAfter
                } else {
                    store = nil // table not ready / query failed → reopen
                }
            }
            try? await Task.sleep(nanoseconds: pollNanos)
        }
    }
}
