@testable import RepoPrompt
import XCTest

final class GrokStreamParserTests: XCTestCase {
    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }

    func testPlainTextBecomesSingleContent() {
        let results = GrokStreamParser.parseFinalOutput(data("pong\n"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "pong")
    }

    func testEmptyOrWhitespaceYieldsNoResults() {
        XCTAssertTrue(GrokStreamParser.parseFinalOutput(Data()).isEmpty)
        XCTAssertTrue(GrokStreamParser.parseFinalOutput(data("   \n  ")).isEmpty)
    }

    func testWholeJSONObjectWithTextKey() {
        let results = GrokStreamParser.parseFinalOutput(data("{\"text\": \"hi there\", \"stopReason\": \"EndTurn\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "hi there")
    }

    func testWholeJSONObjectWithStopReasonStillEmitsContent() {
        // grok's `--output-format json` final object carries `text` plus metadata such as
        // `stopReason`/`sessionId`/`requestId`; only `text` is surfaced, as a content result.
        let json = "{\"text\": \"done\", \"stopReason\": \"EndTurn\", \"sessionId\": \"s1\", \"requestId\": \"r1\"}"
        let results = GrokStreamParser.parseFinalOutput(data(json))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "done")
    }

    func testErrorObjectBecomesErrorResult() {
        // grok failure shape: `{"type": "error", "message": "..."}` surfaces as an error result.
        let results = GrokStreamParser.parseFinalOutput(data("{\"type\": \"error\", \"message\": \"boom\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "error")
        XCTAssertEqual(results.first?.text, "boom")
    }

    func testErrorObjectWithoutMessageFallsBackToDefault() {
        let results = GrokStreamParser.parseFinalOutput(data("{\"type\": \"error\"}"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "error")
        XCTAssertEqual(results.first?.text, "Grok CLI reported an error.")
    }

    func testJSONLinesEachBecomeContent() {
        let jsonl = "{\"text\": \"a\"}\n{\"text\": \"b\"}"
        let results = GrokStreamParser.parseFinalOutput(data(jsonl))
        XCTAssertEqual(results.map(\.text), ["a", "b"])
    }

    func testCRLFJSONLinesEachBecomeContent() {
        // CRLF-delimited JSONL: a trailing \r must not defeat the `hasSuffix("}")` check that
        // selects the JSONL branch. Mirrors `testJSONLinesEachBecomeContent` expectations.
        let jsonl = "{\"text\": \"a\"}\r\n{\"text\": \"b\"}\r\n"
        let results = GrokStreamParser.parseFinalOutput(data(jsonl))
        XCTAssertEqual(results.map(\.text), ["a", "b"])
    }

    func testMultilinePlainTextStaysSingleContent() {
        let results = GrokStreamParser.parseFinalOutput(data("line one\nline two"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "line one\nline two")
    }

    func testGarbageJSONFallsBackToPlainText() {
        let results = GrokStreamParser.parseFinalOutput(data("{not valid json"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, "{not valid json")
    }

    func testMixedJSONLAndPlainFallsBackToSinglePlainContent() {
        // First line is a content-bearing JSON object, second is a JSON object without a
        // known text key. Since not every line yields content, the JSONL branch must be
        // skipped and the whole output treated as a single plain-text block.
        let mixed = "{\"text\": \"a\"}\n{\"unrelated\": 1}"
        let results = GrokStreamParser.parseFinalOutput(data(mixed))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "content")
        XCTAssertEqual(results.first?.text, mixed)
    }

    // MARK: - Streaming events (`--output-format streaming-json`)

    func testStreamingThoughtBecomesReasoning() {
        let result = GrokStreamParser.parseStreamingEvent(data("{\"type\":\"thought\",\"data\":\"hmm\"}"))
        XCTAssertEqual(result?.type, "reasoning")
        XCTAssertEqual(result?.reasoning, "hmm")
        XCTAssertNil(result?.text)
    }

    func testStreamingTextBecomesContent() {
        let result = GrokStreamParser.parseStreamingEvent(data("{\"type\":\"text\",\"data\":\"hi\"}"))
        XCTAssertEqual(result?.type, "content")
        XCTAssertEqual(result?.text, "hi")
    }

    func testStreamingEndBecomesMessageStop() {
        let json = "{\"type\":\"end\",\"stopReason\":\"EndTurn\",\"sessionId\":\"s1\",\"requestId\":\"r1\"}"
        let result = GrokStreamParser.parseStreamingEvent(data(json))
        XCTAssertEqual(result?.type, "message_stop")
        XCTAssertEqual(result?.stopReason, "EndTurn")
        XCTAssertEqual(result?.providerSessionID, "s1")
    }

    func testStreamingErrorBecomesError() {
        let result = GrokStreamParser.parseStreamingEvent(data("{\"type\":\"error\",\"message\":\"boom\"}"))
        XCTAssertEqual(result?.type, "error")
        XCTAssertEqual(result?.text, "boom")
    }

    func testStreamingEmptyThoughtIsIgnored() {
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(data("{\"type\":\"thought\",\"data\":\"\"}")))
    }

    func testStreamingUnknownTypeIsIgnored() {
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(data("{\"type\":\"heartbeat\"}")))
    }

    func testStreamingNonJSONLineIsIgnored() {
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(data("not json")))
        XCTAssertNil(GrokStreamParser.parseStreamingEvent(Data()))
    }
}
