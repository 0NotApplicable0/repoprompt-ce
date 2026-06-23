import Foundation
import SQLite3

/// Read-only reader over one agy conversation trajectory DB (`conversations/<id>.db`). Returns
/// steps newer than a watermark (all step types — the parser decides which are tool calls). Opens
/// `SQLITE_OPEN_READONLY` so it reads agy's live WAL DB without disturbing it. Fail-open: a failed
/// open returns nil; a failed query returns nil (distinct from `[]`) so the caller can reopen when
/// the `steps` table is not yet created.
final class AntigravityTrajectoryStore {
    struct ToolStep { let idx: Int64
        let status: Int64
        let payload: Data
    }

    private var db: OpaquePointer?

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let handle
        else {
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 50)
        db = handle
    }

    deinit { if let db { sqlite3_close(db) } }

    func steps(after idx: Int64, limit: Int32) -> [ToolStep]? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT idx, status, step_payload FROM steps WHERE idx > ? ORDER BY idx ASC LIMIT ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil } // table not ready
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, idx)
        sqlite3_bind_int(stmt, 2, limit)
        var out: [ToolStep] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var payload = Data()
            if let blob = sqlite3_column_blob(stmt, 2) {
                payload = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            out.append(ToolStep(
                idx: sqlite3_column_int64(stmt, 0),
                status: sqlite3_column_int64(stmt, 1),
                payload: payload
            ))
        }
        return out
    }
}
