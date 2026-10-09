import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptProcess
import SQLite3
import XCTest

final class AntigravityStreamParserTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testPlainTextBecomesSingleContent() {
        let results = AntigravityStreamParser.parseFinalOutput(data("pong\n"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "pong")
    }

    func testEmptyOrWhitespaceYieldsNoResults() {
        XCTAssertTrue(AntigravityStreamParser.parseFinalOutput(Data()).isEmpty)
        XCTAssertTrue(AntigravityStreamParser.parseFinalOutput(data("   \n  ")).isEmpty)
    }

    func testWholeJSONObjectWithResponseKey() {
        let results = AntigravityStreamParser.parseFinalOutput(data("{\"response\": \"hi there\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "hi there")
    }

    func testJSONLinesEachBecomeContent() {
        let jsonl = "{\"text\": \"a\"}\n{\"text\": \"b\"}"
        let results = AntigravityStreamParser.parseFinalOutput(data(jsonl))
        XCTAssertEqual(results.map(\.text), ["a", "b"])
    }

    func testCRLFJSONLinesEachBecomeContent() {
        // CRLF-delimited JSONL: a trailing \r must not defeat the `hasSuffix("}")` check that
        // selects the JSONL branch. Mirrors `testJSONLinesEachBecomeContent` expectations.
        let jsonl = "{\"text\": \"a\"}\r\n{\"text\": \"b\"}\r\n"
        let results = AntigravityStreamParser.parseFinalOutput(data(jsonl))
        XCTAssertEqual(results.map(\.text), ["a", "b"])
    }

    func testMultilinePlainTextStaysSingleContent() {
        let results = AntigravityStreamParser.parseFinalOutput(data("line one\nline two"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "line one\nline two")
    }

    func testGarbageJSONFallsBackToPlainText() {
        let results = AntigravityStreamParser.parseFinalOutput(data("{not valid json"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "{not valid json")
    }

    func testMixedJSONLAndPlainFallsBackToSinglePlainContent() {
        // First line is a content-bearing JSON object, second is a JSON object without a
        // known text key. Since not every line yields content, the JSONL branch must be
        // skipped and the whole output treated as a single plain-text block.
        let mixed = "{\"text\": \"a\"}\n{\"unrelated\": 1}"
        let results = AntigravityStreamParser.parseFinalOutput(data(mixed))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, mixed)
    }
}

final class AntigravityToolStepParserTests: XCTestCase {
    private func vint(_ v: UInt64) -> [UInt8] {
        var value = v, out: [UInt8] = []
        repeat {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            out.append(b)
        } while value != 0
        return out
    }

    private func field(_ n: Int, _ b: [UInt8]) -> [UInt8] {
        vint(UInt64(n << 3 | 2)) + vint(UInt64(b.count)) + b
    }

    /// payload → field5(step) → field4(tool){1:callid,2:name,3:argsJSON}
    private func payload(callid: String, name: String, json: String) -> Data {
        let tool = field(1, Array(callid.utf8)) + field(2, Array(name.utf8)) + field(3, Array(json.utf8))
        let step = field(4, tool)
        return Data(field(5, step))
    }

    private let viewJSON = #"{"AbsolutePath":"/Users/dev/x.swift","toolAction":"Viewing x","toolSummary":"View x.swift"}"#

    func testTerminalToolStepEmitsCallAndResult() throws {
        let p = AntigravityToolStepParser()
        let parsed = try XCTUnwrap(p.parse(status: 3, payload: payload(callid: "c1", name: "view_file", json: viewJSON)))
        XCTAssertEqual(parsed.call.type, "tool_call")
        XCTAssertEqual(parsed.call.toolName, "view_file")
        XCTAssertEqual(parsed.call.toolArgs, "/Users/dev/x.swift") // specific arg (AbsolutePath), not the generic summary
        XCTAssertEqual(parsed.call.toolInvocationID, parsed.invocationID)
        XCTAssertEqual(parsed.result?.type, "tool_result")
        XCTAssertEqual(parsed.result?.toolInvocationID, parsed.invocationID)
        XCTAssertEqual(parsed.result?.toolIsError, false)
    }

    func testNonTerminalStepEmitsCallButNoResult() throws {
        let p = AntigravityToolStepParser()
        let parsed = try XCTUnwrap(p.parse(status: 1, payload: payload(callid: "c1", name: "view_file", json: viewJSON)))
        XCTAssertNotNil(parsed.call)
        XCTAssertNil(parsed.result) // no fabricated completion
    }

    func testSameCallIDReusesInvocationID() {
        let p = AntigravityToolStepParser()
        let a = p.parse(status: 1, payload: payload(callid: "c1", name: "view_file", json: viewJSON))
        let b = p.parse(status: 3, payload: payload(callid: "c1", name: "view_file", json: viewJSON))
        XCTAssertEqual(a?.invocationID, b?.invocationID) // call→result stay one card across polls
    }

    func testRunCommandSummaryFromCommandLine() throws {
        let p = AntigravityToolStepParser()
        let json = #"{"CommandLine":"git status","Cwd":"/x"}"#
        let parsed = try XCTUnwrap(p.parse(status: 3, payload: payload(callid: "c2", name: "run_command", json: json)))
        XCTAssertEqual(parsed.call.toolName, "run_command")
        XCTAssertEqual(parsed.call.toolArgs, "git status") // CommandLine, the actual command
    }

    func testViewFileShowsPathWithLineRange() throws {
        let p = AntigravityToolStepParser()
        let json = #"{"AbsolutePath":"/Users/dev/a.swift","StartLine":10,"EndLine":40,"toolSummary":"View a.swift"}"#
        let parsed = try XCTUnwrap(p.parse(status: 3, payload: payload(callid: "c3", name: "view_file", json: json)))
        XCTAssertEqual(parsed.call.toolArgs, "/Users/dev/a.swift (lines 10–40)") // path + line range, like grok
    }

    func testCallMcpToolIsSuppressed() {
        // agy wraps RepoPrompt MCP calls as `call_mcp_tool`; those are already carded via expected-PID
        // MCP tool tracking with the real tool name + arguments, so the trajectory duplicate is dropped.
        let json = #"{"ToolName":"set_status","ServerName":"RepoPromptCE","toolSummary":"Set status"}"#
        XCTAssertNil(AntigravityToolStepParser().parse(status: 3, payload: payload(callid: "c4", name: "call_mcp_tool", json: json)))
    }

    func testDeniedMcpToolSurfacesStableFailedCardWithNestedIdentity() throws {
        let p = AntigravityToolStepParser()
        let json = #"{"ToolName":"set_status","ServerName":"RepoPromptCE","toolSummary":"Set status","Arguments":{"status_text":"private"}}"#
        let denied = try XCTUnwrap(
            p.parse(
                status: 7,
                payload: payload(callid: "denied-mcp", name: "call_mcp_tool", json: json),
                failureKind: .headlessPermissionDenied
            )
        )

        XCTAssertEqual(denied.call.type, "tool_call")
        XCTAssertEqual(denied.call.toolName, "set_status")
        XCTAssertEqual(denied.call.toolArgs, "RepoPromptCE/set_status")
        XCTAssertEqual(denied.call.toolInvocationID, denied.invocationID)
        XCTAssertEqual(denied.result?.type, "tool_result")
        XCTAssertEqual(denied.result?.toolName, "set_status")
        XCTAssertEqual(denied.result?.toolInvocationID, denied.invocationID)
        XCTAssertEqual(denied.result?.toolIsError, true)
        XCTAssertEqual(
            denied.result?.toolResultJSON,
            #"{"status":"failed","error":"Antigravity denied tool permission in headless mode."}"#
        )
        XCTAssertFalse(denied.result?.toolResultJSON?.contains("private") == true)

        let repeated = try XCTUnwrap(
            p.parse(
                status: 7,
                payload: payload(callid: "denied-mcp", name: "call_mcp_tool", json: json),
                failureKind: .headlessPermissionDenied
            )
        )
        XCTAssertEqual(repeated.invocationID, denied.invocationID)
    }

    func testGenericFailedMcpToolRemainsSuppressed() {
        let p = AntigravityToolStepParser()
        let json = #"{"ToolName":"set_status","ServerName":"RepoPromptCE","toolSummary":"Set status"}"#
        let payload = payload(callid: "failed-mcp", name: "call_mcp_tool", json: json)

        XCTAssertNil(p.parse(status: 7, payload: payload, failureKind: .other))
        XCTAssertNil(p.parse(status: 7, payload: payload)) // legacy schema: failure kind unavailable
        guard case let .suppressedMCP(isTerminal) = p.parseRow(
            status: 7,
            payload: payload,
            failureKind: .other
        ) else {
            return XCTFail("Expected generic failed MCP wrapper to remain suppressed")
        }
        XCTAssertTrue(isTerminal)
    }

    func testFailedNativeToolEmitsTerminalErrorResult() throws {
        let parsed = try XCTUnwrap(
            AntigravityToolStepParser().parse(
                status: 7,
                payload: payload(callid: "failed-native", name: "run_command", json: #"{"CommandLine":"false"}"#),
                failureKind: .other
            )
        )

        XCTAssertEqual(parsed.call.toolName, "run_command")
        XCTAssertEqual(parsed.result?.type, "tool_result")
        XCTAssertEqual(parsed.result?.toolIsError, true)
        XCTAssertEqual(
            parsed.result?.toolResultJSON,
            #"{"status":"failed","error":"Antigravity reported a failed tool step."}"#
        )
    }

    func testFallsBackToSummaryWhenNoSpecificArg() throws {
        let p = AntigravityToolStepParser()
        let json = #"{"toolSummary":"Did a thing","toolAction":"Doing a thing"}"#
        let parsed = try XCTUnwrap(p.parse(status: 3, payload: payload(callid: "c5", name: "some_tool", json: json)))
        XCTAssertEqual(parsed.call.toolArgs, "Did a thing") // human-readable summary only when no specific arg
    }

    func testNonToolStepReturnsNil() {
        // field5 → field9 (stats), no field4 tool message → not a tool step.
        let stats = field(9, vint(42))
        XCTAssertNil(AntigravityToolStepParser().parse(status: 3, payload: Data(field(5, stats))))
    }

    func testGarbagePayloadFailsOpen() {
        XCTAssertNil(AntigravityToolStepParser().parse(status: 3, payload: Data([0xFF, 0x00, 0x13])))
    }
}

final class AntigravityTrajectoryProtoScannerTests: XCTestCase {
    static func varint(_ v: UInt64) -> [UInt8] {
        var value = v, out: [UInt8] = []
        repeat {
            var b = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { b |= 0x80 }
            out.append(b)
        } while value != 0
        return out
    }

    static func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes
    }

    func testParsesStringAndNestedFields() {
        // field 1 = "id", field 5 = nested { field 2 = 200 bytes }
        let nested = Self.field(2, Array(repeating: 0x78, count: 200)) // forces a 2-byte length varint
        let bytes = Self.field(1, Array("id".utf8)) + Self.field(5, nested)
        let top = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data(bytes))
        XCTAssertEqual(top[1].flatMap { String(data: $0, encoding: .utf8) }, "id")
        let inner = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(top[5] ?? Data())
        XCTAssertEqual(inner[2]?.count, 200)
    }

    func testSkipsVarintFieldsAndStopsOnTruncation() {
        // field 1 = varint 8 (wire 0), then a truncated field 5 header.
        let bytes: [UInt8] = [0x08, 0x08, 0x2A, 0x32] // 0x2a=field5 wire2, len 50, no payload
        let f = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data(bytes))
        XCTAssertNil(f[1])
        XCTAssertNil(f[5]) // varint skipped, truncated field dropped, no crash
    }

    func testEmptyInputYieldsNoFields() {
        XCTAssertTrue(AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data()).isEmpty)
    }

    func testRejectsHugeLengthVarintWithoutTrapping() {
        // field 1, wire type 2, length = UInt64.max (10-byte varint: 0xFF*9, 0x01). Pre-fix this trapped
        // on Int(len); now it must return safely with the field rejected (length exceeds the buffer).
        let bytes: [UInt8] = [0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        let fields = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(Data(bytes))
        XCTAssertNil(fields[1])
    }
}

final class AntigravityTrajectoryStoreTests: XCTestCase {
    private func makeDB(withSteps: Bool) throws -> String {
        let path = NSTemporaryDirectory() + "agy-steps-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard withSteps else { return path } // empty db (no `steps` table)
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, step_payload BLOB);",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, type, status) in [(3, 8, 3), (4, 15, 3), (6, 21, 3)] {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                db,
                "INSERT INTO steps VALUES (\(idx), \(type), \(status), ?);",
                -1,
                &stmt,
                nil
            ), SQLITE_OK)
            let payload: [UInt8] = [0x2A, 0x02, 0x20, UInt8(idx)] // arbitrary blob bytes
            payload.withUnsafeBytes {
                _ = sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
                XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE) // step INSIDE closure (pointer valid)
            }
            sqlite3_finalize(stmt)
        }
        return path
    }

    func testReadsAllStepsAfterWatermark() throws {
        let path = try makeDB(withSteps: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try XCTUnwrap(AntigravityTrajectoryStore(path: path))
        XCTAssertEqual(store.steps(after: 0, limit: 100)?.map(\.idx), [3, 4, 6]) // no step_type filter
        XCTAssertEqual(store.steps(after: 4, limit: 100)?.map(\.idx), [6]) // watermark respected
        XCTAssertTrue(store.steps(after: 0, limit: 100)?.allSatisfy { $0.failureKind == nil } == true)
    }

    func testErrorDetailsAreBoundedAndReducedToRedactedFailureKinds() throws {
        let path = NSTemporaryDirectory() + "agy-error-details-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer {
            sqlite3_close(db)
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, status INTEGER, error_details BLOB, step_payload BLOB);",
            nil,
            nil,
            nil
        ), SQLITE_OK)

        let marker = Data("User denied permission for mcp(RepoPromptCE/set_status).".utf8)
        var markerBeyondBound = Data(repeating: 0x78, count: AntigravityTrajectoryStore.maxErrorDetailsBytes)
        markerBeyondBound.append(marker)
        let details = [marker, Data("network request failed with private diagnostics".utf8), markerBeyondBound]
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, detail) in details.enumerated() {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(
                db,
                "INSERT INTO steps (idx, status, error_details, step_payload) VALUES (?, 7, ?, X'');",
                -1,
                &stmt,
                nil
            ), SQLITE_OK)
            sqlite3_bind_int64(stmt, 1, Int64(offset + 1))
            detail.withUnsafeBytes {
                _ = sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(detail.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }

        let store = try XCTUnwrap(AntigravityTrajectoryStore(path: path))
        let rows = try XCTUnwrap(store.steps(after: 0, limit: 100))
        XCTAssertEqual(
            rows.map(\.failureKind),
            [.headlessPermissionDenied, .other, .other]
        )
    }

    func testLatestFailureRequiresNewestTerminalEphemeralMessage() throws {
        let path = NSTemporaryDirectory() + "agy-context-loss-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer {
            sqlite3_close(db)
            try? FileManager.default.removeItem(atPath: path)
        }
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, step_payload BLOB);",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db,
            "INSERT INTO steps VALUES (1, 17, 3, X'756E72656C61746564');",
            nil,
            nil,
            nil
        ), SQLITE_OK)

        let payload = Data([0x12, 0x02, 0x00, 0x01])
            + Data("agent executor error: trajectory converted to zero chat messages".utf8)
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            db,
            "INSERT INTO steps VALUES (2, 17, 3, ?);",
            -1,
            &stmt,
            nil
        ), SQLITE_OK)
        payload.withUnsafeBytes {
            _ = sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(payload.count), sqliteTransient)
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)

        let store = try XCTUnwrap(AntigravityTrajectoryStore(path: path))
        XCTAssertEqual(store.latestFailureKind(), .conversationContextLost)

        // A resumed/forked trajectory can copy older rows. Once any newer row exists, the stale
        // marker must not poison the current turn even if the newer row is an ordinary tool step.
        XCTAssertEqual(sqlite3_exec(
            db,
            "INSERT INTO steps VALUES (3, 8, 3, X'6E6577657220746F6F6C20726F77');",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        XCTAssertNil(store.latestFailureKind())
    }

    func testFailureClassifierRejectsUnrelatedPayloadAndWrongRowShape() {
        let marker = Data("agent executor error: trajectory converted to zero chat messages".utf8)
        XCTAssertNil(AntigravityTrajectoryStore.failureKind(stepType: 17, status: 3, payload: Data("unrelated".utf8)))
        XCTAssertNil(AntigravityTrajectoryStore.failureKind(stepType: 8, status: 3, payload: marker))
        XCTAssertNil(AntigravityTrajectoryStore.failureKind(stepType: 17, status: 7, payload: marker))

        var beyondBound = Data(repeating: 0x78, count: AntigravityTrajectoryStore.maxFailurePayloadBytes)
        beyondBound.append(marker)
        XCTAssertNil(AntigravityTrajectoryStore.failureKind(stepType: 17, status: 3, payload: beyondBound))
    }

    func testMissingStepsTableReturnsNilNotEmpty() throws {
        let path = try makeDB(withSteps: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try XCTUnwrap(AntigravityTrajectoryStore(path: path))
        XCTAssertNil(store.steps(after: 0, limit: 100)) // table not ready → nil (reopen signal)
    }

    func testLegacyFallbackRequiresConfirmedMissingErrorDetailsColumn() {
        XCTAssertTrue(AntigravityTrajectoryStore.shouldUseLegacyQuery(
            afterPrepareResult: SQLITE_ERROR,
            message: "no such column: error_details"
        ))
        XCTAssertFalse(AntigravityTrajectoryStore.shouldUseLegacyQuery(
            afterPrepareResult: SQLITE_BUSY,
            message: "database is locked"
        ))
        XCTAssertFalse(AntigravityTrajectoryStore.shouldUseLegacyQuery(
            afterPrepareResult: SQLITE_LOCKED,
            message: "database table is locked"
        ))
        XCTAssertFalse(AntigravityTrajectoryStore.shouldUseLegacyQuery(
            afterPrepareResult: SQLITE_ERROR,
            message: "no such table: steps"
        ))
    }

    func testLockedReadReturnsNilSoFinalDrainCanRetry() throws {
        let path = try makeDB(withSteps: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try XCTUnwrap(AntigravityTrajectoryStore(path: path))

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        XCTAssertNil(store.steps(after: 0, limit: 100))
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(store.steps(after: 0, limit: 100)?.map(\.idx), [3, 4, 6])
    }

    func testInitFailsForMissingFile() {
        XCTAssertNil(AntigravityTrajectoryStore(path: NSTemporaryDirectory() + "nope-\(UUID().uuidString).db"))
    }
}

private final class SequencedAntigravityTrajectoryStore: AntigravityTrajectoryStoreReading, @unchecked Sendable {
    private var responses: [[AntigravityTrajectoryStore.ToolStep]?]

    init(responses: [[AntigravityTrajectoryStore.ToolStep]?]) {
        self.responses = responses
    }

    func steps(after _: Int64, limit _: Int32) -> [AntigravityTrajectoryStore.ToolStep]? {
        responses.isEmpty ? [] : responses.removeFirst()
    }

    func latestFailureKind() -> AntigravityTrajectoryStore.FailureKind? {
        nil
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

private final class AntigravityTrajectoryTestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func snapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func waitUntil(_ description: String) async throws {
        try await AsyncTestWait.waitUntil(description) {
            self.snapshot()
        }
    }
}

private actor AntigravityLateContextLossWriter {
    private let path: String
    private var appended = false

    init(path: String) {
        self.path = path
    }

    func appendOnce() -> Bool {
        guard !appended else { return true }
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        let payload = Data("agent executor error: trajectory converted to zero chat messages".utf8)
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO steps (idx, step_type, status, step_payload) VALUES (2, 17, 3, ?);",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        payload.withUnsafeBytes {
            _ = sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(payload.count), sqliteTransient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        appended = true
        return true
    }

    func didAppend() -> Bool {
        appended
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

    func testCorrelatedFailureReadRetriesForLateWALCommit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agy-failure-\(UUID().uuidString)")
        let conversations = root.appendingPathComponent(".gemini/antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversationID = UUID()
        let logFile = root.appendingPathComponent("turn.log")
        try Data("Created conversation \(conversationID.uuidString)\n".utf8).write(to: logFile)
        let databaseURL = conversations.appendingPathComponent("\(conversationID.uuidString.lowercased()).db")
        try createFailureProbeDatabase(at: databaseURL.path)

        let log = AntigravityTrajectoryToolLog(environment: ["HOME": root.path])
        log.beginTurn(logFileURL: logFile)
        let writer = AntigravityLateContextLossWriter(path: databaseURL.path)
        let retryRecorder = AntigravityFinalDrainRetryRecorder()

        let failure = try await log.latestCorrelatedFailureKind(
            maxAttempts: 4,
            timeBudget: .seconds(1),
            waitForRetry: { duration in
                await retryRecorder.record(duration)
                _ = await writer.appendOnce()
            }
        )

        XCTAssertEqual(failure, .conversationContextLost)
        let didAppend = await writer.didAppend()
        XCTAssertTrue(didAppend)
        let retryDurations = await retryRecorder.snapshot()
        XCTAssertEqual(retryDurations, [.milliseconds(10)])
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

    private func createFailureProbeDatabase(at path: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, status INTEGER, step_payload BLOB);",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db,
            "INSERT INTO steps VALUES (1, 17, 3, X'6F7264696E617279');",
            nil,
            nil,
            nil
        ), SQLITE_OK)
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
        let firstPoll = AntigravityTrajectoryTestSignal(false)
        let databaseURL = URL(fileURLWithPath: path)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { databaseURL },
                waitBetweenPolls: { _ in
                    firstPoll.set()
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
        try await firstPoll.waitUntil("initial trajectory poll")

        // Commit the terminal transition after the first poll. The closed test gate prevents an
        // ordinary second poll, so cancellation itself is the only possible flush signal.
        try updateTrajectoryStatus(at: path, to: 3)
        tailTask.cancel()
        _ = await tailTask.value
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

    func testCancellationFinalDrainReturnsLateContextLossEvidence() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agy-final-failure-\(UUID().uuidString)")
        let conversations = root.appendingPathComponent(".gemini/antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversationID = UUID()
        let logFile = root.appendingPathComponent("turn.log")
        try Data("Created conversation \(conversationID.uuidString)\n".utf8).write(to: logFile)
        let databaseURL = conversations.appendingPathComponent("\(conversationID.uuidString.lowercased()).db")
        try createFailureProbeDatabase(at: databaseURL.path)

        let log = AntigravityTrajectoryToolLog(environment: ["HOME": root.path])
        log.beginTurn(logFileURL: logFile)
        let writer = AntigravityLateContextLossWriter(path: databaseURL.path)
        let (_, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let (pollGate, pollGateContinuation) = AsyncStream<Void>.makeStream()
        let firstPoll = AntigravityTrajectoryTestSignal(false)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { log.locate() },
                waitBetweenPolls: { _ in
                    firstPoll.set()
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

        try await firstPoll.waitUntil("initial trajectory poll")
        let didAppend = await writer.appendOnce()
        XCTAssertTrue(didAppend)
        tailTask.cancel()
        let failureKind = await tailTask.value
        pollGateContinuation.finish()
        continuation.finish()

        XCTAssertEqual(failureKind, .conversationContextLost)
    }

    func testCancellationFinalDrainConsumesMoreThanOnePageExactlyOnce() async throws {
        let path = NSTemporaryDirectory() + "agy-tail-backlog-\(UUID().uuidString).db"
        try createEmptyTrajectoryDB(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let (pollGate, pollGateContinuation) = AsyncStream<Void>.makeStream()
        let didPoll = AntigravityTrajectoryTestSignal(false)
        let databaseURL = URL(fileURLWithPath: path)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { databaseURL },
                waitBetweenPolls: { _ in
                    didPoll.set()
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
        try await didPoll.waitUntil("initial empty trajectory poll")
        try insertTerminalTrajectorySteps(at: path, count: 501)
        tailTask.cancel()
        _ = await tailTask.value
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
        let firstPoll = AntigravityTrajectoryTestSignal(false)
        let tailTask = Task {
            await AntigravityTrajectoryToolLogStream.tail(
                into: continuation,
                locate: { fakeURL },
                waitBetweenPolls: { _ in
                    firstPoll.set()
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

        try await firstPoll.waitUntil("initial transient trajectory poll")
        tailTask.cancel()
        _ = await tailTask.value
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
