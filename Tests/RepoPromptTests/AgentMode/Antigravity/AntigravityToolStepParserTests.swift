@testable import RepoPromptApp
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
