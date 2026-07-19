@testable import RepoPromptApp
import SQLite3
import XCTest

private final class SequencedAntigravityTrajectoryStore: AntigravityTrajectoryStoreReading, @unchecked Sendable {
    private var responses: [[AntigravityTrajectoryStore.ToolStep]?]

    init(responses: [[AntigravityTrajectoryStore.ToolStep]?]) {
        self.responses = responses
    }

    func steps(after _: Int64, limit _: Int32) -> [AntigravityTrajectoryStore.ToolStep]? {
        responses.isEmpty ? [] : responses.removeFirst()
    }
}

private actor AntigravityFinalDrainRetryRecorder {
    private var durations: [Duration] = []

    func record(_ duration: Duration) {
        durations.append(duration)
    }

    func snapshot() -> [Duration] {
        durations
    }
}

final class AntigravityTrajectoryToolLogTests: XCTestCase {
    /// — Locator —
    func testLocatorFindsDBAppearingAfterLaunch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agy-\(UUID().uuidString)")
        let convs = root.appendingPathComponent(".gemini/antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: convs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = AntigravityTrajectoryToolLog(environment: ["HOME": root.path])

        let firstLog = root.appendingPathComponent("first.log")
        log.beginTurn(logFileURL: firstLog)
        XCTAssertNil(log.locate())

        let firstID = UUID()
        try Data("I0719 server.go:1] Created conversation not-a-uuid\n".utf8).write(to: firstLog)
        let unrelatedID = UUID()
        try Data().write(to: convs.appendingPathComponent("\(unrelatedID.uuidString.lowercased()).db"))
        XCTAssertNil(log.locate(), "malformed and unrelated conversations must never be guessed")

        try Data("I0719 server.go:1] Created conversation \(firstID.uuidString.lowercased())\n".utf8)
            .write(to: firstLog)
        XCTAssertNil(log.locate(), "the exact announced DB may legitimately lag the log line")
        try Data().write(to: convs.appendingPathComponent("\(firstID.uuidString.lowercased()).db"))
        XCTAssertEqual(log.locate()?.lastPathComponent, "\(firstID.uuidString.lowercased()).db")

        // Once bound, a later external AGY DB cannot redirect the current turn.
        let laterExternalID = UUID()
        try Data().write(to: convs.appendingPathComponent("\(laterExternalID.uuidString.lowercased()).db"))
        XCTAssertEqual(log.locate()?.lastPathComponent, "\(firstID.uuidString.lowercased()).db")

        // The log can keep growing after the first bind. A second announced id makes the turn
        // ambiguous even when it appears later, so the cached first DB must no longer be returned.
        let appendedAmbiguousID = UUID()
        try Data("""
        I0719 server.go:1] Created conversation \(firstID.uuidString.lowercased())
        I0719 server.go:2] Created conversation \(appendedAmbiguousID.uuidString)
        """.utf8).write(to: firstLog)
        XCTAssertNil(log.locate())

        // Resume turns get a new log and exact DB binding; the predecessor cannot leak forward.
        let secondID = UUID()
        let secondLog = root.appendingPathComponent("second.log")
        try Data("I0719 server.go:2] Created conversation \(secondID.uuidString)\n".utf8).write(to: secondLog)
        try Data().write(to: convs.appendingPathComponent("\(secondID.uuidString.lowercased()).db"))
        log.beginTurn(logFileURL: secondLog)
        XCTAssertEqual(log.locate()?.lastPathComponent, "\(secondID.uuidString.lowercased()).db")

        let thirdID = UUID()
        let ambiguous = Data("""
        I0719 server.go:3] Created conversation \(secondID.uuidString)
        I0719 server.go:4] Created conversation \(thirdID.uuidString)
        """.utf8)
        XCTAssertNil(AntigravityTrajectoryToolLog.conversationID(inLogData: ambiguous))
    }

    /// — Emitter dedup/advance (pure) —
    private func toolPayload(
        _ callid: String,
        name: String = "view_file",
        json: String = #"{"toolSummary":"S"}"#
    ) -> Data {
        func v(_ x: UInt64) -> [UInt8] {
            var n = x, o: [UInt8] = []
            repeat {
                var b = UInt8(n & 0x7F)
                n >>= 7
                if n != 0 { b |= 0x80 }
                o.append(b)
            } while n != 0
            return o
        }
        func f(_ n: Int, _ b: [UInt8]) -> [UInt8] {
            v(UInt64(n << 3 | 2)) + v(UInt64(b.count)) + b
        }
        let tool = f(1, Array(callid.utf8)) + f(2, Array(name.utf8)) + f(3, Array(json.utf8))
        return Data(f(5, f(4, tool)))
    }

    private func step(
        _ idx: Int64,
        _ status: Int64,
        _ callid: String,
        failureKind: AntigravityTrajectoryStore.FailureKind? = nil
    ) -> AntigravityTrajectoryStore.ToolStep {
        .init(idx: idx, status: status, payload: toolPayload(callid), failureKind: failureKind)
    }

    private func createTrajectoryDB(at path: String, payload: Data) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(
            handle,
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, status INTEGER, error_details BLOB, step_payload BLOB);",
            nil,
            nil,
            nil
        ), SQLITE_OK)

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var insert: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            handle,
            "INSERT INTO steps (idx, status, step_payload) VALUES (1, 1, ?);",
            -1,
            &insert,
            nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(insert) }
        payload.withUnsafeBytes {
            _ = sqlite3_bind_blob(insert, 1, $0.baseAddress, Int32(payload.count), sqliteTransient)
        }
        XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
    }

    private func createEmptyTrajectoryDB(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(
            handle,
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, status INTEGER, error_details BLOB, step_payload BLOB);",
            nil,
            nil,
            nil
        ), SQLITE_OK)
    }

    private func insertTerminalTrajectorySteps(at path: String, count: Int) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var insert: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            handle,
            "INSERT INTO steps (idx, status, step_payload) VALUES (?, 3, ?);",
            -1,
            &insert,
            nil
        ), SQLITE_OK)
        defer { sqlite3_finalize(insert) }
        for idx in 1 ... count {
            let payload = toolPayload("backlog-\(idx)")
            sqlite3_bind_int64(insert, 1, Int64(idx))
            payload.withUnsafeBytes {
                _ = sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32(payload.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
            XCTAssertEqual(sqlite3_reset(insert), SQLITE_OK)
            sqlite3_clear_bindings(insert)
        }
        XCTAssertEqual(sqlite3_exec(handle, "COMMIT;", nil, nil, nil), SQLITE_OK)
    }

    private func updateTrajectoryStatus(at path: String, to status: Int) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE steps SET status = \(status) WHERE idx = 1;", nil, nil, nil),
            SQLITE_OK
        )
    }

    func testEmitsCallThenResultAcrossPollsWithoutDuplication() {
        var e = AntigravityTrajectoryEmitter()
        // Poll 1: idx 1 in-flight (status 1) → call only, watermark holds (advanceTo nil).
        let p1 = e.process([step(1, 1, "a")])
        XCTAssertEqual(p1.events.map(\.type), ["tool_call"])
        XCTAssertNil(p1.advanceTo)
        // Poll 2: idx 1 now terminal → result only (call already emitted), advance to 1.
        let p2 = e.process([step(1, 3, "a")])
        XCTAssertEqual(p2.events.map(\.type), ["tool_result"])
        XCTAssertEqual(p2.advanceTo, 1)
    }

    func testNonToolStepAdvancesWatermarkSilently() {
        var e = AntigravityTrajectoryEmitter()
        let nonTool = AntigravityTrajectoryStore.ToolStep(idx: 5, status: 3, payload: Data([0x08, 0x0F]))
        let r = e.process([nonTool])
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertEqual(r.advanceTo, 5)
    }

    func testDedupIsByCallIDNotIdxAcrossForkedDBs() {
        // A resumed run forks to a NEW DB whose idx restarts; the same call id appearing at a
        // different idx must NOT re-emit a card (dedup is by invocation id, not row idx).
        var e = AntigravityTrajectoryEmitter()
        let first = e.process([step(3, 3, "shared")])
        XCTAssertEqual(first.events.map(\.type), ["tool_call", "tool_result"])
        let forked = e.process([step(99, 3, "shared")]) // same call id, different idx (new DB)
        XCTAssertTrue(forked.events.isEmpty)
    }

    func testPendingSuppressedMcpStepHoldsWatermarkUntilSuccessfulTerminalStatus() {
        var e = AntigravityTrajectoryEmitter()
        let json = #"{"ToolName":"set_status","ServerName":"RepoPromptCE"}"#
        let pending = AntigravityTrajectoryStore.ToolStep(
            idx: 4,
            status: 1,
            payload: toolPayload("mcp", name: "call_mcp_tool", json: json)
        )

        let first = e.process([pending])
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertNil(first.advanceTo)

        let completed = AntigravityTrajectoryStore.ToolStep(
            idx: 4,
            status: 3,
            payload: toolPayload("mcp", name: "call_mcp_tool", json: json)
        )
        let second = e.process([completed])
        XCTAssertTrue(second.events.isEmpty) // expected-PID tracking owns the successful card
        XCTAssertEqual(second.advanceTo, 4)
    }

    func testDeniedMcpStepEmitsFailedCardAndAdvancesWatermark() {
        var e = AntigravityTrajectoryEmitter()
        let json = #"{"ToolName":"set_status","ServerName":"RepoPromptCE"}"#
        let denied = AntigravityTrajectoryStore.ToolStep(
            idx: 7,
            status: 7,
            payload: toolPayload("denied", name: "call_mcp_tool", json: json),
            failureKind: .headlessPermissionDenied
        )

        let first = e.process([denied])
        XCTAssertEqual(first.events.map(\.type), ["tool_call", "tool_result"])
        XCTAssertEqual(first.events.map(\.toolName), ["set_status", "set_status"])
        XCTAssertEqual(first.events.last?.toolIsError, true)
        XCTAssertEqual(first.advanceTo, 7)

        let repeated = e.process([denied])
        XCTAssertTrue(repeated.events.isEmpty)
        XCTAssertEqual(repeated.advanceTo, 7)
    }

    func testGenericFailedMcpStepRemainsSuppressedAndAdvancesWatermark() {
        var e = AntigravityTrajectoryEmitter()
        let json = #"{"ToolName":"set_status","ServerName":"RepoPromptCE"}"#
        let failed = AntigravityTrajectoryStore.ToolStep(
            idx: 8,
            status: 7,
            payload: toolPayload("failed", name: "call_mcp_tool", json: json),
            failureKind: .other
        )

        let result = e.process([failed])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.advanceTo, 8)
    }

    func testCancellationFinalPollEmitsLateTerminalResultExactlyOnce() async throws {
        let path = NSTemporaryDirectory() + "agy-tail-final-poll-\(UUID().uuidString).db"
        let payload = toolPayload("late-terminal")
        try createTrajectoryDB(at: path, payload: payload)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let (pollGate, pollGateContinuation) = AsyncStream<Void>.makeStream()
        let firstPoll = AsyncTestCondition(false)
        let databaseURL = URL(fileURLWithPath: path)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { databaseURL },
                waitBetweenPolls: { _ in
                    firstPoll.update { $0 = true }
                    var iterator = pollGate.makeAsyncIterator()
                    _ = await iterator.next()
                }
            )
        }
        defer {
            tailTask.cancel()
            pollGateContinuation.finish()
            continuation.finish()
        }
        try await firstPoll.waitUntil("initial trajectory poll") { $0 }

        // Commit the terminal transition after the first poll. The closed test gate prevents an
        // ordinary second poll, so cancellation itself is the only possible flush signal.
        try updateTrajectoryStatus(at: path, to: 3)
        tailTask.cancel()
        await tailTask.value
        pollGateContinuation.finish()
        continuation.finish()

        var events: [AIStreamResult] = []
        for try await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.type), ["tool_call", "tool_result"])
        XCTAssertEqual(events.count(where: { $0.type == "tool_call" }), 1)
        XCTAssertEqual(events.count(where: { $0.type == "tool_result" }), 1)
        XCTAssertEqual(events[0].toolInvocationID, events[1].toolInvocationID)
    }

    func testCancellationFinalDrainConsumesMoreThanOnePageExactlyOnce() async throws {
        let path = NSTemporaryDirectory() + "agy-tail-backlog-\(UUID().uuidString).db"
        try createEmptyTrajectoryDB(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let (pollGate, pollGateContinuation) = AsyncStream<Void>.makeStream()
        let didPoll = AsyncTestCondition(false)
        let databaseURL = URL(fileURLWithPath: path)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { databaseURL },
                waitBetweenPolls: { _ in
                    didPoll.update { $0 = true }
                    var iterator = pollGate.makeAsyncIterator()
                    _ = await iterator.next()
                }
            )
        }
        defer {
            tailTask.cancel()
            pollGateContinuation.finish()
            continuation.finish()
        }

        // Wait until the ordinary poll has observed the empty DB, then commit a backlog requiring
        // two 500-row pages entirely behind the cancellation synchronization edge.
        try await didPoll.waitUntil("initial empty trajectory poll") { $0 }
        try insertTerminalTrajectorySteps(at: path, count: 501)
        tailTask.cancel()
        await tailTask.value
        pollGateContinuation.finish()
        continuation.finish()

        var events: [AIStreamResult] = []
        for try await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events.count(where: { $0.type == "tool_call" }), 501)
        XCTAssertEqual(events.count(where: { $0.type == "tool_result" }), 501)
        XCTAssertEqual(Set(events.compactMap(\.toolInvocationID)).count, 501)
    }

    func testCancellationFinalDrainRetriesTransientQueryFailure() async throws {
        let pending = step(1, 1, "transient-final")
        let terminal = step(1, 3, "transient-final")
        let fakeStore = SequencedAntigravityTrajectoryStore(responses: [[pending], nil, [terminal]])
        let retryRecorder = AntigravityFinalDrainRetryRecorder()
        let fakeURL = URL(fileURLWithPath: "/tmp/agy-transient-final.db")
        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let (pollGate, pollGateContinuation) = AsyncStream<Void>.makeStream()
        let firstPoll = AsyncTestCondition(false)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { fakeURL },
                waitBetweenPolls: { _ in
                    firstPoll.update { $0 = true }
                    var iterator = pollGate.makeAsyncIterator()
                    _ = await iterator.next()
                },
                waitForFinalDrainRetry: { duration in
                    await retryRecorder.record(duration)
                },
                storeFactory: { _ in fakeStore }
            )
        }
        defer {
            tailTask.cancel()
            pollGateContinuation.finish()
            continuation.finish()
        }

        try await firstPoll.waitUntil("initial transient trajectory poll") { $0 }
        tailTask.cancel()
        await tailTask.value
        pollGateContinuation.finish()
        continuation.finish()

        var events: [AIStreamResult] = []
        for try await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.type), ["tool_call", "tool_result"])
        XCTAssertEqual(events[0].toolInvocationID, events[1].toolInvocationID)
        let retryDurations = await retryRecorder.snapshot()
        XCTAssertEqual(retryDurations, [.milliseconds(10)])
    }
}
