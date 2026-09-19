import Foundation
@testable import RepoPromptApp
import XCTest

final class JevRoutingClientTests: XCTestCase {
    func testModelValidationUsesDocumentedEndpointAndBearerKey() async throws {
        let transport = RecordingJevTransport(status: 200, body: #"{"models":[{"name":"jev"}]}"#)
        let response = try await JevRoutingClient(transport: transport).listModels(apiKey: "secret", timeout: .seconds(5))
        XCTAssertEqual(response.models.map(\.name), ["jev"])
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.001)
    }

    func testJudgeUsesSingleSystemOneChoiceRequestWithoutProviderIdentity() async throws {
        let body = #"{"model":"jev-1.13.0","answers":{"route":{"type":"choice","choice":"opaque-a","probabilities":{"opaque-a":0.6,"opaque-b":0.4},"confidence":0.8}},"usage":{"input_tokens":4,"output_tokens":1}}"#
        let transport = RecordingJevTransport(status: 200, body: body)
        let wire = JevRoutingWireRequest(
            model: JevRouterCredentialService.pinnedModel,
            state: "task",
            questions: ["route": .init(
                type: "choice",
                instructions: "Choose one supplied task-handling rubric.",
                criteria: ["opaque-a": "Explore", "opaque-b": "Engineer"]
            )]
        )
        _ = try await JevRoutingClient(transport: transport).judge(request: wire, apiKey: "secret", timeout: .seconds(5))
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        let encoded = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(encoded.contains("opaque-a"))
        XCTAssertFalse(encoded.contains("codex"))
        XCTAssertFalse(encoded.contains("provider"))
        XCTAssertTrue(encoded.contains(#""questions":{"route":{"#))
        XCTAssertTrue(encoded.contains(#""criteria":{"#))
    }

    func testOuterDeadlineCancelsTheRequestWithoutRetry() async {
        let transport = DelayedJevTransport()
        let client = JevRoutingClient(transport: transport, sleep: { _ in })
        do {
            _ = try await client.listModels(apiKey: "secret", timeout: .seconds(5))
            XCTFail("Expected the outer deadline to fail")
        } catch {
            XCTAssertEqual(error as? JevRoutingClientError, .timeout)
        }
    }

    func testDocumentedErrorsAreClassifiedWithoutRetry() async {
        for (status, expected) in [
            (401, JevRoutingClientError.authentication),
            (422, .invalidRequest),
            (429, .rateLimited),
            (529, .overloaded)
        ] {
            let transport = RecordingJevTransport(status: status, body: "{}")
            do {
                _ = try await JevRoutingClient(transport: transport).listModels(apiKey: "secret", timeout: .seconds(5))
                XCTFail("Expected status \(status) to fail")
            } catch {
                XCTAssertEqual(error as? JevRoutingClientError, expected)
                XCTAssertEqual(transport.requestCount, 1)
            }
        }
    }
}

private final class RecordingJevTransport: JevHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: Data
    private var requests: [URLRequest] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    var lastRequest: URLRequest? {
        lock.withLock { requests.last }
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

private actor DelayedJevTransport: JevHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
