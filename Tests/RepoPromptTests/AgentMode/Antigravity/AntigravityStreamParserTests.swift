@testable import RepoPromptApp
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
