@testable import RepoPrompt
import XCTest

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
        XCTAssertEqual(parsed.call.toolArgs, "View x.swift") // toolSummary
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
        XCTAssertEqual(parsed.call.toolArgs, "git status") // CommandLine when no toolSummary
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
