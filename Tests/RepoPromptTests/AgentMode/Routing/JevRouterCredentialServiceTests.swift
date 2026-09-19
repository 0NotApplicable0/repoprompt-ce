import Foundation
@testable import RepoPromptApp
import XCTest

final class JevRouterCredentialServiceTests: XCTestCase {
    func testLateValidationCannotOverwriteNewerCandidate() async {
        let storage = TestSecureStorageBackend()
        let client = ControlledJevClient()
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: client
        )
        let firstID = UUID()
        let secondID = UUID()
        let first = Task { await service.validateAndSave("candidate-a", operationID: firstID) }
        await client.waitUntilStarted("candidate-a")
        let second = Task { await service.validateAndSave("candidate-b", operationID: secondID) }
        await client.waitUntilStarted("candidate-b")

        await client.complete("candidate-b")
        guard case .saved = await second.value else { return XCTFail("Newer candidate did not save") }
        await client.complete("candidate-a")
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .superseded)
        XCTAssertEqual(storage.value(for: .jevRouterAPIKey), "candidate-b")
    }

    func testStoredKeyUsesExplicitNoninteractiveAccessMode() async {
        let storage = TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])
        let client = ImmediateJevClient()
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: client
        )
        _ = await service.validateStoredKey(
            operationID: UUID(),
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )
        XCTAssertTrue(storage.calls.contains(.init(
            operation: .get,
            account: .jevRouterAPIKey,
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        )))
        guard case .policyUnavailable = await service.readinessSnapshot() else {
            return XCTFail("A valid key must not bypass missing policy calibration")
        }
    }

    func testMissingStoredKeyInvalidatesPreviouslyValidatedReadiness() async throws {
        let storage = TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])
        let service = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: storage),
            client: ImmediateJevClient()
        )
        guard case .saved = await service.validateStoredKey(operationID: UUID()) else {
            return XCTFail("Expected initial stored-key validation")
        }
        try storage.delete(for: SecureStorageAccount.jevRouterAPIKey.identifier, accessMode: .interactive)

        let result = await service.validateStoredKey(operationID: UUID())
        XCTAssertEqual(result, .missingKey)
        guard case .needsConfiguration = await service.readinessSnapshot() else {
            return XCTFail("Missing stored credential must fail closed")
        }
    }
}

private actor ControlledJevClient: JevRoutingClientProtocol {
    private var started: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var completions: [String: CheckedContinuation<JevModelList, Error>] = [:]

    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        started.insert(apiKey)
        startWaiters.removeValue(forKey: apiKey)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { completions[apiKey] = $0 }
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) async throws -> JevRoutingWireResponse {
        throw JevRoutingClientError.invalidRequest
    }

    func waitUntilStarted(_ key: String) async {
        if started.contains(key) { return }
        await withCheckedContinuation { startWaiters[key, default: []].append($0) }
    }

    func complete(_ key: String) {
        completions.removeValue(forKey: key)?.resume(returning: .init(models: [.init(id: JevRouterCredentialService.pinnedModel)]))
    }
}

private struct ImmediateJevClient: JevRoutingClientProtocol {
    func listModels(apiKey: String, timeout: Duration) async throws -> JevModelList {
        .init(models: [.init(id: JevRouterCredentialService.pinnedModel)])
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) async throws -> JevRoutingWireResponse {
        throw JevRoutingClientError.invalidRequest
    }
}
