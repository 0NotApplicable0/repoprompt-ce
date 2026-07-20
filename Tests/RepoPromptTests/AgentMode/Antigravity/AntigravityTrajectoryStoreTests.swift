@testable import RepoPromptApp
import SQLite3
import XCTest

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
