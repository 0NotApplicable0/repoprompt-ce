import Foundation

actor JevRouterCredentialService {
    enum ValidationResult: Equatable {
        case saved(generation: UInt64, supportedModel: String)
        case missingKey
        case superseded
        case failed(String)
    }

    static let pinnedModel = "jev-1.13.0"
    static let unavailablePolicyVersion = "jev-routing-policy-unavailable"

    private let secureKeys: SecureKeysService
    private let client: any JevRoutingClientProtocol
    private var generation: UInt64 = 0
    private var activeValidationID: UUID?
    private var hasValidatedKey = false
    private var isValidating = false

    init(
        secureKeys: SecureKeysService = SecureKeysService(),
        client: any JevRoutingClientProtocol = JevRoutingClient()
    ) {
        self.secureKeys = secureKeys
        self.client = client
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        if isValidating { return .validating(generation: generation) }
        guard hasValidatedKey else {
            return .needsConfiguration(generation: generation, reason: "Validate a TypeSafe API key.")
        }
        return .policyUnavailable(
            generation: generation,
            reason: "Jev routing remains disabled until a reviewed calibration policy is available."
        )
    }

    func validateAndSave(_ candidate: String, operationID: UUID) async -> ValidationResult {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missingKey }
        activeValidationID = operationID
        isValidating = true
        defer {
            if activeValidationID == operationID {
                activeValidationID = nil
                isValidating = false
            }
        }
        do {
            let models = try await client.listModels(apiKey: trimmed, timeout: JevRoutingClient.outerDeadline)
            guard activeValidationID == operationID, !Task.isCancelled else { return .superseded }
            guard models.models.contains(where: { $0.id == Self.pinnedModel }) else {
                return .failed("The account does not expose the pinned Jev evaluator \(Self.pinnedModel).")
            }
            try secureKeys.saveAPIKey(trimmed, for: .jevRouterAPIKey, accessMode: .interactive)
            guard activeValidationID == operationID, !Task.isCancelled else { return .superseded }
            generation &+= 1
            hasValidatedKey = true
            return .saved(generation: generation, supportedModel: Self.pinnedModel)
        } catch is CancellationError {
            return .superseded
        } catch {
            guard activeValidationID == operationID, !Task.isCancelled else { return .superseded }
            return .failed(Self.redactedMessage(for: error))
        }
    }

    func validateStoredKey(operationID: UUID, accessMode: KeychainAccessMode = .nonInteractive(reason: .backgroundAvailabilityCheck)) async -> ValidationResult {
        activeValidationID = operationID
        isValidating = true
        defer {
            if activeValidationID == operationID {
                activeValidationID = nil
                isValidating = false
            }
        }
        do {
            let storedKey = try await secureKeys.getAPIKey(for: .jevRouterAPIKey, accessMode: accessMode)
            guard activeValidationID == operationID, !Task.isCancelled else { return .superseded }
            guard let key = storedKey, !key.isEmpty else {
                invalidateValidatedCredential()
                return .missingKey
            }
            let models = try await client.listModels(apiKey: key, timeout: JevRoutingClient.outerDeadline)
            guard activeValidationID == operationID, !Task.isCancelled else { return .superseded }
            guard models.models.contains(where: { $0.id == Self.pinnedModel }) else {
                return .failed("The account does not expose the pinned Jev evaluator \(Self.pinnedModel).")
            }
            generation &+= 1
            hasValidatedKey = true
            return .saved(generation: generation, supportedModel: Self.pinnedModel)
        } catch is CancellationError {
            return .superseded
        } catch {
            guard activeValidationID == operationID, !Task.isCancelled else { return .superseded }
            if error as? JevRoutingClientError == .authentication {
                invalidateValidatedCredential()
            }
            return .failed(Self.redactedMessage(for: error))
        }
    }

    func delete(operationID: UUID) throws {
        activeValidationID = operationID
        isValidating = true
        defer {
            if activeValidationID == operationID {
                activeValidationID = nil
                isValidating = false
            }
        }
        try secureKeys.deleteAPIKey(for: .jevRouterAPIKey, accessMode: .interactive)
        invalidateValidatedCredential(forceGenerationChange: true)
    }

    func loadForRouting() async throws -> (key: String, generation: UInt64) {
        guard hasValidatedKey else { throw JevRoutingClientError.authentication }
        let capturedGeneration = generation
        guard let key = try await secureKeys.getAPIKey(
            for: .jevRouterAPIKey,
            accessMode: .nonInteractive(reason: .backgroundAvailabilityCheck)
        ), !key.isEmpty, hasValidatedKey, generation == capturedGeneration else {
            throw JevRoutingClientError.authentication
        }
        return (key, capturedGeneration)
    }

    func cancelValidation() {
        activeValidationID = nil
        isValidating = false
    }

    private func invalidateValidatedCredential(forceGenerationChange: Bool = false) {
        if hasValidatedKey || forceGenerationChange {
            generation &+= 1
        }
        hasValidatedKey = false
    }

    private static func redactedMessage(for error: Error) -> String {
        switch error as? JevRoutingClientError {
        case .authentication: "Authentication failed."
        case .rateLimited: "TypeSafe rate limited validation."
        case .overloaded: "TypeSafe is temporarily overloaded."
        case .timeout: "TypeSafe validation timed out."
        case .invalidRequest, .invalidResponse, .decoding: "TypeSafe returned an unexpected response."
        case .service: "TypeSafe validation failed."
        case nil: "Validation failed."
        }
    }
}
