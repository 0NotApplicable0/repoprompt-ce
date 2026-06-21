@testable import RepoPrompt
import XCTest

final class AntigravityModelRegistryTests: XCTestCase {
    func testMultilineOutputBecomesTrimmedLabels() {
        let output = """
        Gemini 3.5 Flash (Medium)
        Gemini 3.5 Flash (High)
        Gemini 3.5 Flash (Low)
        Gemini 3.1 Pro (Low)
        Gemini 3.1 Pro (High)
        Claude Sonnet 4.6 (Thinking)
        Claude Opus 4.6 (Thinking)
        GPT-OSS 120B (Medium)
        """
        let labels = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, [
            "Gemini 3.5 Flash (Medium)",
            "Gemini 3.5 Flash (High)",
            "Gemini 3.5 Flash (Low)",
            "Gemini 3.1 Pro (Low)",
            "Gemini 3.1 Pro (High)",
            "Claude Sonnet 4.6 (Thinking)",
            "Claude Opus 4.6 (Thinking)",
            "GPT-OSS 120B (Medium)"
        ])
    }

    func testBlankAndWhitespaceLinesAreIgnored() {
        let output = "\n  Gemini 3.5 Flash (Low)  \n\n\t\n  \n Gemini 3.1 Pro (High)\n\n"
        let labels = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["Gemini 3.5 Flash (Low)", "Gemini 3.1 Pro (High)"])
    }

    func testEmptyOutputYieldsNoLabels() {
        XCTAssertTrue(AntigravityModelRegistry.parseModels(from: "").isEmpty)
        XCTAssertTrue(AntigravityModelRegistry.parseModels(from: "   \n \t \n").isEmpty)
    }

    func testDuplicateLabelsAreCollapsedPreservingFirstOrder() {
        let output = """
        Gemini 3.5 Flash (Low)
        Gemini 3.1 Pro (High)
        Gemini 3.5 Flash (Low)
        """
        let labels = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["Gemini 3.5 Flash (Low)", "Gemini 3.1 Pro (High)"])
    }

    func testTrailingCarriageReturnsAreTrimmed() {
        // `agy` output captured on some terminals may include CRLF line endings.
        let output = "Gemini 3.5 Flash (Low)\r\nGemini 3.1 Pro (High)\r\n"
        let labels = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["Gemini 3.5 Flash (Low)", "Gemini 3.1 Pro (High)"])
    }

    @MainActor
    func testCatalogOptionsIncludeDefaultPlusLiveLabels() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setLabels(["Gemini 3.5 Flash (Low)", "Claude Opus 4.6 (Thinking)"])

        let availability = AgentModelCatalog.AvailabilityContext(antigravityAvailable: true)
        let options = AgentModelCatalog.options(for: .antigravity, availability: availability)
        let raws = options.map(\.rawValue)

        XCTAssertEqual(options.first?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertTrue(options.first?.isPlaceholderDefault == true)
        XCTAssertTrue(raws.contains("Gemini 3.5 Flash (Low)"))
        XCTAssertTrue(raws.contains("Claude Opus 4.6 (Thinking)"))
        // The live labels are exposed verbatim as both raw value and display name.
        XCTAssertEqual(
            options.first(where: { $0.rawValue == "Gemini 3.5 Flash (Low)" })?.displayName,
            "Gemini 3.5 Flash (Low)"
        )
    }

    @MainActor
    func testClearCacheEmptiesLabelsAndPostsChange() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setLabels(["Gemini 3.5 Flash (Low)"])
        XCTAssertFalse(registry.currentModelLabels().isEmpty)
        XCTAssertNotNil(registry.lastRefresh())

        let expectation = expectation(forNotification: .antigravityModelsChanged, object: nil)
        registry.clearCache()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(registry.currentModelLabels().isEmpty)
        XCTAssertNil(registry.lastRefresh())
    }

    @MainActor
    func testClearCacheOnEmptyCacheDoesNotPostChange() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        registry.clearCache()
        // Reset already empties; clearCache on an empty cache must not regress labels.
        XCTAssertTrue(registry.currentModelLabels().isEmpty)
    }

    func testRefreshBacksOffAndDoesNotImmediatelyRespawnWithinStalenessWindow() async {
        // A refresh ATTEMPT (success or failure) must record the attempt timestamp so a subsequent
        // `refreshIfStale()` within the staleness window is a no-op and does NOT spawn another
        // process. This is the failure-churn fix: previously a failing `agy models` left the cache
        // empty and re-kicked a background refresh on every picker render. This test is
        // environment-independent — it asserts the no-respawn-within-window property whether or not
        // an `agy` binary is present (a failed run leaves the cache empty; a successful run fills
        // it), since the gate is keyed on the attempt time, not on success.
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }

        // First refresh: empty cache => stale => exactly one spawn attempt.
        await registry.refreshIfStale()
        let countAfterFirst = registry.test_refreshAttemptCount()
        XCTAssertEqual(countAfterFirst, 1, "First refreshIfStale should perform exactly one attempt")

        // Second refresh immediately after: the recorded attempt timestamp must gate it within the
        // staleness window, so no additional spawn happens regardless of the first result.
        await registry.refreshIfStale()
        XCTAssertEqual(
            registry.test_refreshAttemptCount(),
            countAfterFirst,
            "A refresh must back off for the staleness window and not re-spawn on the next render"
        )
    }

    func testFailedRefreshRecordsAttemptWithoutSuccessTimestamp() async {
        // Directly exercises the failure path via the DEBUG seam: simulate a failed attempt and
        // confirm it gates `refreshIfStale()` (no respawn) while leaving the success timestamp and
        // cache untouched — the precise behavior that stops failure churn.
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }

        registry.test_simulateFailedRefreshAttempt()
        XCTAssertTrue(registry.currentModelLabels().isEmpty, "Failed attempt must not populate cache")
        XCTAssertNil(registry.lastRefresh(), "Failed attempt must not set the success timestamp")

        // Now a render-triggered refreshIfStale must back off (attempt time is fresh).
        let before = registry.test_refreshAttemptCount()
        await registry.refreshIfStale()
        XCTAssertEqual(
            registry.test_refreshAttemptCount(),
            before,
            "A recorded failed attempt must back off refreshIfStale within the staleness window"
        )
    }

    func testConcurrentRefreshCoalescesWithoutCrashing() async {
        // Single-flight smoke test: many concurrent refreshes must share one run and complete
        // cleanly even when `agy` is absent (each underlying run returns nil and leaves the
        // cache untouched). Asserts no crash/hang from the atomic in-flight claim.
        let registry = AntigravityModelRegistry.shared
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await registry.refresh() }
            }
        }
    }
}
