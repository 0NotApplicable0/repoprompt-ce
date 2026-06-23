@testable import RepoPrompt
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
    }

    func testMissingStepsTableReturnsNilNotEmpty() throws {
        let path = try makeDB(withSteps: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try XCTUnwrap(AntigravityTrajectoryStore(path: path))
        XCTAssertNil(store.steps(after: 0, limit: 100)) // table not ready → nil (reopen signal)
    }

    func testInitFailsForMissingFile() {
        XCTAssertNil(AntigravityTrajectoryStore(path: NSTemporaryDirectory() + "nope-\(UUID().uuidString).db"))
    }
}
