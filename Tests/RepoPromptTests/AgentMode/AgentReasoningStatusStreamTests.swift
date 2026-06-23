@testable import RepoPrompt
import XCTest

final class AgentReasoningStatusStreamTests: XCTestCase {
    // MARK: - statusPreview

    func testStatusPreviewCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(AgentReasoningStatusStream.statusPreview(from: "  Reading\n the  file \t"), "Reading the file")
    }

    func testStatusPreviewEmptyReturnsNil() {
        XCTAssertNil(AgentReasoningStatusStream.statusPreview(from: ""))
        XCTAssertNil(AgentReasoningStatusStream.statusPreview(from: "   \n\t "))
    }

    func testStatusPreviewKeepsTrailingPortionWhenLong() {
        let preview = AgentReasoningStatusStream.statusPreview(from: String(repeating: "a", count: 200), limit: 50)
        XCTAssertEqual(preview?.count, 51) // leading "…" + 50 trailing chars
        XCTAssertEqual(preview?.hasPrefix("…"), true)
    }

    // MARK: - withReasoningStatus decorator

    private func makeUpstream(_ events: [AIStreamResult]) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func collect(_ stream: AsyncThrowingStream<AIStreamResult, Error>) async throws -> [AIStreamResult] {
        var out: [AIStreamResult] = []
        for try await event in stream {
            out.append(event)
        }
        return out
    }

    func testInjectsStatusAfterReasoningAndPassesOriginalsThrough() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "reasoning", text: nil, reasoning: "Reading the file"),
            AIStreamResult(type: "content", text: "done"),
            AIStreamResult(type: "message_stop", text: nil)
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        // The reasoning event passes through and a `status` is injected right after it.
        XCTAssertEqual(out.map(\.type), ["reasoning", "status", "content", "message_stop"])
        XCTAssertEqual(out[1].text, "Reading the file")
    }

    func testNoStatusWhenNoReasoning() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "content", text: "hello"),
            AIStreamResult(type: "message_stop", text: nil)
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        XCTAssertEqual(out.map(\.type), ["content", "message_stop"])
    }

    func testReasoningAccumulatesAcrossDeltas() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "reasoning", text: nil, reasoning: "Read"),
            AIStreamResult(type: "reasoning", text: nil, reasoning: "ing X")
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        let statuses = out.filter { $0.type == "status" }.map(\.text)
        XCTAssertEqual(statuses, ["Read", "Reading X"])
    }

    func testBufferResetsAfterContent() async throws {
        let upstream = makeUpstream([
            AIStreamResult(type: "reasoning", text: nil, reasoning: "first thought"),
            AIStreamResult(type: "content", text: "answer"),
            AIStreamResult(type: "reasoning", text: nil, reasoning: "second thought")
        ])
        let out = try await collect(AgentReasoningStatusStream.withReasoningStatus(upstream))
        let statuses = out.filter { $0.type == "status" }.map(\.text)
        // Second status reflects only the post-content reasoning, not the accumulated first.
        XCTAssertEqual(statuses, ["first thought", "second thought"])
    }
}
