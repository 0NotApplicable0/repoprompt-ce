@testable import RepoPrompt
import XCTest

final class GrokToolEventParserTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testToolCallCarriesNameAndArgs() {
        let parser = GrokToolEventParser()
        let line = #"{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read","rawInput":{"path":"/a/b.swift","limit":80}}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "tool_call")
        XCTAssertEqual(result?.toolName, "Read")
        XCTAssertEqual(result?.toolArgs, "/a/b.swift (lines 1–80)")
        XCTAssertNotNil(result?.toolInvocationID)
    }

    func testCommandArgPreferredForShell() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c2","title":"Shell","rawInput":{"command":"git diff --stat","description":"d"}}}}"#
        XCTAssertEqual(parser.parse(data(line))?.toolArgs, "git diff --stat")
    }

    func testTerminalUpdateBecomesToolResultWithSummary() {
        let parser = GrokToolEventParser()
        _ = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Grep","rawInput":{"pattern":"x"}}}}"#))
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"found 19 matches"}}]}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "tool_result")
        XCTAssertEqual(result?.toolName, "Grep") // carried from the opening tool_call (terminal update has no title)
        XCTAssertEqual(result?.toolOutput, "found 19 matches")
        XCTAssertEqual(result?.toolIsError, false)
    }

    func testStartAndResultShareInvocationID() {
        let parser = GrokToolEventParser()
        let start = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read","rawInput":{"path":"/a"}}}}"#))
        let done = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}}}"#))
        XCTAssertNotNil(start?.toolInvocationID)
        XCTAssertEqual(start?.toolInvocationID, done?.toolInvocationID)
    }

    func testFailedStatusIsError() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"failed","content":[{"type":"content","content":{"type":"text","text":"boom"}}]}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.toolIsError, true)
        XCTAssertEqual(result?.toolOutput, "boom")
    }

    func testReadArgIncludesLineRange() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read","rawInput":{"path":"/a.swift","limit":80}}}}"#
        XCTAssertEqual(parser.parse(data(line))?.toolArgs, "/a.swift (lines 1–80)")
    }

    func testBashResultIncludesExitCodeAndMarksNonZeroError() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"nope"}}],"rawOutput":{"type":"Bash","exit_code":2}}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.toolOutput, "exit 2 · nope")
        XCTAssertEqual(result?.toolIsError, true) // non-zero exit overrides the "completed" status
    }

    func testKindUsedAsNameFallbackWhenNoTitle() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","kind":"search","rawInput":{"pattern":"x"}}}}"#
        XCTAssertEqual(parser.parse(data(line))?.toolName, "Search")
    }

    func testThoughtChunkBecomesStatus() {
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"I'll read the file"}}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "status")
        XCTAssertEqual(result?.text, "I'll read the file")
    }

    func testThoughtChunksAccumulate() {
        let parser = GrokToolEventParser()
        _ = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"Read"}}}}"#))
        let result = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"ing X"}}}}"#))
        XCTAssertEqual(result?.text, "Reading X")
    }

    func testBashInProgressWithExitCodeCompletes() {
        // grok-composer reports shell results under status:in_progress with rawOutput+exit_code.
        let parser = GrokToolEventParser()
        let line = #"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"in_progress","rawOutput":{"type":"Bash","exit_code":0},"content":[{"type":"content","content":{"type":"text","text":"diff stats"}}]}}}"#
        let result = parser.parse(data(line))
        XCTAssertEqual(result?.type, "tool_result")
        XCTAssertEqual(result?.toolIsError, false)
        XCTAssertEqual(result?.toolOutput, "exit 0 · diff stats")
    }

    func testResultEmittedOncePerCall() {
        let parser = GrokToolEventParser()
        let first = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"in_progress","rawOutput":{"exit_code":0}}}}"#))
        let second = parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}}}"#))
        XCTAssertEqual(first?.type, "tool_result")
        XCTAssertNil(second) // dedup — second completion ignored
    }

    func testIntermediateAndNonToolLinesIgnored() {
        let parser = GrokToolEventParser()
        // Refinement update with no terminal status → ignored (no duplicate card).
        XCTAssertNil(parser.parse(data(#"{"params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"c1","title":"Skill x"}}}"#)))
        // Non-tool session updates → ignored.
        XCTAssertNil(parser.parse(data(#"{"params":{"update":{"sessionUpdate":"agent_message_chunk","content":"hi"}}}"#)))
        XCTAssertNil(parser.parse(data("not json")))
    }
}
