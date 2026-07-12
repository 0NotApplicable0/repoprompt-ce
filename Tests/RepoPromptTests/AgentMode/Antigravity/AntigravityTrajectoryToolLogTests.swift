@testable import RepoPromptApp
import XCTest

final class AntigravityTrajectoryToolLogTests: XCTestCase {
    /// — Locator —
    func testLocatorFindsDBAppearingAfterLaunch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agy-\(UUID().uuidString)")
        let convs = root.appendingPathComponent(".gemini/antigravity-cli/conversations")
        try FileManager.default.createDirectory(at: convs, withIntermediateDirectories: true)
        try Data().write(to: convs.appendingPathComponent("old.db"))
        let log = AntigravityTrajectoryToolLog(environment: ["HOME": root.path])
        XCTAssertNil(log.locate())
        try Data().write(to: convs.appendingPathComponent("new.db"))
        XCTAssertEqual(log.locate()?.lastPathComponent, "new.db")
    }

    /// — Emitter dedup/advance (pure) —
    private func toolPayload(_ callid: String) -> Data {
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
        let tool = f(1, Array(callid.utf8)) + f(2, Array("view_file".utf8)) + f(3, Array(#"{"toolSummary":"S"}"#.utf8))
        return Data(f(5, f(4, tool)))
    }

    private func step(_ idx: Int64, _ status: Int64, _ callid: String) -> AntigravityTrajectoryStore.ToolStep {
        .init(idx: idx, status: status, payload: toolPayload(callid))
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
}
