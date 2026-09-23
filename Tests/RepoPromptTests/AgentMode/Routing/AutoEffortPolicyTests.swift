@testable import RepoPromptApp
import XCTest

final class AutoEffortPolicyTests: XCTestCase {
    func testCodexAdmissionRequiresExactFamilyAndAdvertisedEfforts() {
        XCTAssertEqual(
            AutoEffortModelPolicy.codexEfforts(
                modelRaw: "gpt-6-astra-high",
                advertised: [.none, .low, .medium, .high, .ultra]
            ),
            ["low", "medium", "high"]
        )
        XCTAssertTrue(AutoEffortModelPolicy.codexEfforts(
            modelRaw: "gpt-5.6-sol",
            advertised: [.low, .medium, .high]
        ).isEmpty)
        XCTAssertTrue(AutoEffortModelPolicy.codexEfforts(
            modelRaw: "default",
            advertised: [.low, .medium]
        ).isEmpty)
    }

    func testClaudeAdmissionRejectsAliasAndOlderModel() {
        XCTAssertEqual(
            AutoEffortModelPolicy.claudeEfforts(
                modelRaw: "claude-opus-5-5:high",
                advertised: [.max, .high, .low]
            ),
            ["low", "high", "max"]
        )
        XCTAssertTrue(AutoEffortModelPolicy.claudeEfforts(
            modelRaw: "opus",
            advertised: [.low, .medium, .high]
        ).isEmpty)
        XCTAssertTrue(AutoEffortModelPolicy.claudeEfforts(
            modelRaw: "claude-opus-4-7",
            advertised: [.low, .medium, .high]
        ).isEmpty)
    }

    func testEphemeralChoiceRejectsToggleModelAndManualEffortChanges() {
        let selection = AutoEffortTurnSelection(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            effortRaw: "low"
        )
        XCTAssertTrue(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            enabled: true
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "high",
            enabled: true
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .claudeCode,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            enabled: true
        ))
        XCTAssertFalse(selection.isCurrent(
            provider: .codexExec,
            selectedModelRaw: "gpt-6-sol",
            manualEffortRaw: "medium",
            enabled: false
        ))
    }

    func testJevPolicyHasOnlyEffortQuestionAndRejectsInvalidChoices() {
        let batch = JevAutoEffortJudge.batch(efforts: ["low", "medium", "high"])
        XCTAssertEqual(batch?.questionIDs, ["effort"])
        XCTAssertEqual(batch?.wireQuestions()["effort"]?.criteria.keys.sorted(), ["high", "low", "medium"])
        XCTAssertNil(JevAutoEffortJudge.batch(efforts: ["low"]))
        XCTAssertNil(JevAutoEffortJudge.batch(efforts: ["low", "low"]))
        XCTAssertNil(JevAutoEffortJudge.batch(efforts: ["low", "ultra"]))
    }

    func testJevWireRequestUsesOnlyMaskedCurrentTurnAndFixedModel() async throws {
        let client = CapturingAutoEffortJevClient()
        let credentials = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend(values: [.jevRouterAPIKey: "stored"])),
            client: client
        )
        guard case .saved = await credentials.validateStoredKey(operationID: UUID()) else {
            return XCTFail("Stored Jev key did not validate")
        }
        let masked = try XCTUnwrap(AutoEffortTaskSummary.make(from: "Review login password=private123"))
        let chosen = await JevAutoEffortJudge(credentials: credentials).chooseEffort(
            maskedTaskExcerpt: masked,
            selectedModelID: "gpt-6-sol",
            efforts: ["low", "medium"]
        )
        XCTAssertEqual(chosen, "medium")
        let request = await client.lastRequest
        XCTAssertEqual(request?.model, JevRouterCredentialService.pinnedModel)
        XCTAssertEqual(
            request?.state,
            "SELECTED_MODEL_ID:\ngpt-6-sol\n\nMASKED_CURRENT_USER_TURN_EXCERPT:\n\(masked)"
        )
        XCTAssertFalse(request?.state.contains("private123") == true)
        XCTAssertEqual(request.map { Set($0.questions.keys) }, Set(["effort"]))
    }
}

private actor CapturingAutoEffortJevClient: JevRoutingClientProtocol {
    private(set) var lastRequest: JevRoutingWireRequest?

    func listModels(apiKey: String, timeout: Duration) -> JevModelList {
        .init(models: [.init(name: "jev-latest")])
    }

    func judge(
        request: JevRoutingWireRequest,
        apiKey: String,
        timeout: Duration
    ) -> JevRoutingWireResponse {
        lastRequest = request
        return .init(
            model: JevRouterCredentialService.pinnedModel,
            answers: [
                "effort": .init(
                    type: "choice",
                    choice: "medium",
                    probabilities: ["low": 0.2, "medium": 0.8],
                    confidence: 0.8
                )
            ],
            usage: .init(inputTokens: 12, outputTokens: 4)
        )
    }
}
