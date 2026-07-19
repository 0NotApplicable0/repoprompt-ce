import Foundation
import SQLite3

protocol AntigravityTrajectoryStoreReading: AnyObject {
    func steps(after idx: Int64, limit: Int32) -> [AntigravityTrajectoryStore.ToolStep]?
}

/// Read-only reader over one agy conversation trajectory DB (`conversations/<id>.db`). Returns
/// steps newer than a watermark (all step types — the parser decides which are tool calls). Opens
/// `SQLITE_OPEN_READONLY` so it reads agy's live WAL DB without disturbing it. Fail-open: a failed
/// open returns nil; a failed query returns nil (distinct from `[]`) so the caller can reopen when
/// the `steps` table is not yet created.
final class AntigravityTrajectoryStore: AntigravityTrajectoryStoreReading {
    enum FailureKind: Equatable {
        case headlessPermissionDenied
        case other
    }

    struct ToolStep {
        let idx: Int64
        let status: Int64
        let payload: Data
        let failureKind: FailureKind?

        init(idx: Int64, status: Int64, payload: Data, failureKind: FailureKind? = nil) {
            self.idx = idx
            self.status = status
            self.payload = payload
            self.failureKind = failureKind
        }
    }

    /// `error_details` can include a full stack trace. Only inspect a small prefix and immediately
    /// reduce it to a non-sensitive classification; raw diagnostics never leave this store.
    static let maxErrorDetailsBytes = 4 * 1024

    static func shouldUseLegacyQuery(afterPrepareResult result: Int32, message: String) -> Bool {
        result == SQLITE_ERROR && message == "no such column: error_details"
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
        let sql = "SELECT idx, status, step_payload, substr(error_details, 1, ?) FROM steps WHERE idx > ? ORDER BY idx ASC LIMIT ?;"
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        var readsErrorDetails = prepareResult == SQLITE_OK
        if !readsErrorDetails {
            let prepareMessage = String(cString: sqlite3_errmsg(db))
            if stmt != nil {
                sqlite3_finalize(stmt)
                stmt = nil
            }
            guard Self.shouldUseLegacyQuery(
                afterPrepareResult: prepareResult,
                message: prepareMessage
            ) else {
                return nil
            }
            // Older agy schemas did not include `error_details`. Keep ordinary tool cards working
            // there, with an unknown failure kind, instead of treating the whole query as failed.
            let legacySQL = "SELECT idx, status, step_payload FROM steps WHERE idx > ? ORDER BY idx ASC LIMIT ?;"
            guard sqlite3_prepare_v2(db, legacySQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
            readsErrorDetails = false
        }
        defer { sqlite3_finalize(stmt) }
        if readsErrorDetails {
            sqlite3_bind_int(stmt, 1, Int32(Self.maxErrorDetailsBytes))
            sqlite3_bind_int64(stmt, 2, idx)
            sqlite3_bind_int(stmt, 3, limit)
        } else {
            sqlite3_bind_int64(stmt, 1, idx)
            sqlite3_bind_int(stmt, 2, limit)
        }
        var out: [ToolStep] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            var payload = Data()
            if let blob = sqlite3_column_blob(stmt, 2) {
                payload = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            var failureKind: FailureKind?
            if readsErrorDetails, let blob = sqlite3_column_blob(stmt, 3) {
                let details = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
                if !details.isEmpty {
                    let diagnostics = String(decoding: details, as: UTF8.self)
                    failureKind = AntigravityAgentProvider.isHeadlessPermissionDenial(
                        stderr: diagnostics,
                        logTail: nil
                    ) ? .headlessPermissionDenied : .other
                }
            }
            out.append(ToolStep(
                idx: sqlite3_column_int64(stmt, 0),
                status: sqlite3_column_int64(stmt, 1),
                payload: payload,
                failureKind: failureKind
            ))
            stepResult = sqlite3_step(stmt)
        }
        // BUSY/LOCKED/ERROR is a transient read failure, not proof that the trajectory drained.
        // Returning nil keeps the tailer's reopen/retry path active for the bounded final drain.
        guard stepResult == SQLITE_DONE else { return nil }
        return out
    }
}
