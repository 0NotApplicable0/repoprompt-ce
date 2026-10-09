import Foundation

/// Resolves the exact agy conversation trajectory DB announced by the current turn's unique
/// `--log-file`. This avoids guessing from globally newest DB timestamps, which can cross-wire a
/// RepoPrompt run with a simultaneously launched external `agy` process.
final class AntigravityTrajectoryToolLog: @unchecked Sendable {
    private static let maxConversationLogPrefixBytes = 256 * 1024
    private static let failureReadMaxAttempts = 8
    private static let failureReadTimeBudget: Duration = .milliseconds(250)

    private let conversationsRoot: URL
    private let lock = NSLock()
    private var turnGeneration: UInt64 = 0
    private var turnLogFileURL: URL?
    private var resolvedConversationURL: URL?
    private var validatedLogFileSize: Int?

    init(environment: [String: String]) {
        let home: URL = if let h = environment["HOME"], !h.isEmpty { URL(fileURLWithPath: h) }
        else { FileManager.default.homeDirectoryForCurrentUser }
        conversationsRoot = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    }

    /// Starts a new correlation window before launching one `agy --print` turn. A resume invocation
    /// creates a new conversation id and log file, so the prior binding must never carry forward.
    func beginTurn(logFileURL: URL?) {
        lock.withLock {
            turnGeneration &+= 1
            turnLogFileURL = logFileURL
            resolvedConversationURL = nil
            validatedLogFileSize = nil
        }
    }

    func locate() -> URL? {
        let snapshot = lock.withLock {
            (turnGeneration, turnLogFileURL, resolvedConversationURL, validatedLogFileSize)
        }
        guard let logFileURL = snapshot.1,
              let currentLogFileSize = Self.regularFileSize(logFileURL)
        else { return nil }

        if let resolved = snapshot.2, snapshot.3 == currentLogFileSize {
            guard Self.isRegularFile(resolved) else { return nil }
            return lock.withLock {
                // `beginTurn` can replace the binding while the filesystem check is in flight.
                // A cached predecessor must not surface even once in the successor turn.
                guard turnGeneration == snapshot.0,
                      resolvedConversationURL == resolved,
                      validatedLogFileSize == currentLogFileSize
                else { return nil }
                return resolved
            }
        }

        guard let conversationID = Self.conversationID(inLogAt: logFileURL) else { return nil }

        let candidate = conversationsRoot.appendingPathComponent("\(conversationID).db")
        guard Self.isRegularFile(candidate) else { return nil }

        return lock.withLock {
            // A resume can replace the active log while this filesystem read is in flight. Never
            // publish the predecessor's DB into the successor turn.
            guard turnGeneration == snapshot.0 else { return nil }
            guard resolvedConversationURL == nil || resolvedConversationURL == candidate else { return nil }
            resolvedConversationURL = candidate
            validatedLogFileSize = currentLogFileSize
            return candidate
        }
    }

    /// Reads the newest terminal failure from this turn's exact log-announced conversation. AGY can
    /// commit its final WAL row just after the child exits, so retry under a short attempt and
    /// monotonic-time budget. Raw trajectory payloads never leave the read-only store.
    func latestCorrelatedFailureKind(
        maxAttempts: Int = failureReadMaxAttempts,
        timeBudget: Duration = failureReadTimeBudget,
        waitForRetry: @Sendable @escaping (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        storeFactory: @Sendable @escaping (String) -> (any AntigravityTrajectoryStoreReading)? = {
            AntigravityTrajectoryStore(path: $0)
        }
    ) async throws -> AntigravityTrajectoryStore.FailureKind? {
        guard maxAttempts > 0 else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeBudget)
        for attempt in 0 ..< maxAttempts {
            try Task.checkCancellation()
            guard attempt == 0 || clock.now < deadline else { return nil }
            if let path = locate()?.path,
               let failureKind = storeFactory(path)?.latestFailureKind()
            {
                return failureKind
            }
            guard attempt + 1 < maxAttempts else { return nil }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return nil }
            let requested = Duration.milliseconds(min((attempt + 1) * 10, 40))
            await waitForRetry(min(requested, remaining))
        }
        return nil
    }

    /// Extracts one canonical UUID from complete `Created conversation <UUID>` log lines. Multiple
    /// distinct ids are ambiguous and fail closed; arbitrary UUIDs elsewhere in diagnostics never
    /// become trajectory authority.
    static func conversationID(inLogData data: Data) -> String? {
        let marker = "Created conversation "
        var matches = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let markerRange = line.range(of: marker) else { continue }
            let token = String(line[markerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                token.count == 36,
                let uuid = UUID(uuidString: token),
                uuid.uuidString.caseInsensitiveCompare(token) == .orderedSame
            else { continue }
            matches.insert(uuid.uuidString.lowercased())
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func conversationID(inLogAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            guard let data = try handle.read(upToCount: maxConversationLogPrefixBytes),
                  !data.isEmpty
            else { return nil }
            return conversationID(inLogData: data)
        } catch {
            return nil
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func regularFileSize(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.intValue
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
/// Handles **auto-resume**: each resumed `--print --conversation` turn forks to a new conversation
/// DB. The provider starts a new per-turn log correlation window, so a later poll switches to that
/// exact announced DB — resetting the per-DB idx watermark while the emitter's invocation-id dedup
/// carries across the switch. Runs until the surrounding task is cancelled.
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
    ) async -> AntigravityTrajectoryStore.FailureKind? {
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

        // Resolve terminal evidence from a fresh store after the final drain. Never reuse
        // `currentPath`: `beginTurn` may have replaced the binding while the prior poll was active.
        guard let finalPath = locate()?.path else { return nil }
        return storeFactory(finalPath)?.latestFailureKind()
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
            currentPath = newest // a resume turn announced its exact forked DB → restart watermark
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
