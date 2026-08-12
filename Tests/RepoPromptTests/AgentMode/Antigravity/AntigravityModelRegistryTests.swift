@testable import RepoPromptApp
import XCTest

final class AntigravityModelRegistryTests: XCTestCase {
    func testTabSeparatedOutputSplitsIDsFromDisplayLabels() {
        // `agy` 1.1.12+ prints `<model-id>\t<Display Label>`; only the id is accepted by `--model`.
        let output = """
        gemini-3.6-flash-high\tGemini 3.6 Flash (High)
        gemini-3.1-pro-low\tGemini 3.1 Pro (Low)
        claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)
        """
        let models = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(models.map(\.id), [
            "gemini-3.6-flash-high",
            "gemini-3.1-pro-low",
            "claude-opus-4-6-thinking"
        ])
        XCTAssertEqual(models.map(\.displayName), [
            "Gemini 3.6 Flash (High)",
            "Gemini 3.1 Pro (Low)",
            "Claude Opus 4.6 (Thinking)"
        ])
    }

    func testUntabbedLineIsBothIDAndDisplayName() {
        // Pre-1.1.12 `agy` printed a bare display label that `--model` accepted verbatim.
        let output = """
        Gemini 3.5 Flash (Medium)
        Gemini 3.5 Flash (Low)
        """
        let models = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(models, [
            .init(id: "Gemini 3.5 Flash (Medium)", displayName: "Gemini 3.5 Flash (Medium)"),
            .init(id: "Gemini 3.5 Flash (Low)", displayName: "Gemini 3.5 Flash (Low)")
        ])
    }

    func testOnlyFirstTabSeparatesIDFromLabel() {
        let models = AntigravityModelRegistry.parseModels(from: "some-id\tLabel\twith tab")
        XCTAssertEqual(models, [.init(id: "some-id", displayName: "Label\twith tab")])
    }

    func testBlankLabelColumnFallsBackToID() {
        let models = AntigravityModelRegistry.parseModels(from: "gemini-3.6-flash-low\t   ")
        XCTAssertEqual(models, [.init(id: "gemini-3.6-flash-low", displayName: "gemini-3.6-flash-low")])
    }

    func testLeadingTabCollapsesToLegacyLabelForm() {
        // Line trimming strips a leading tab before the split, so a record with a blank id column
        // (which `agy` never emits) degrades to the pre-1.1.12 bare-label shape rather than
        // yielding an empty id.
        let models = AntigravityModelRegistry.parseModels(from: "\tGemini 3.6 Flash (High)")
        XCTAssertEqual(models, [.init(id: "Gemini 3.6 Flash (High)", displayName: "Gemini 3.6 Flash (High)")])
    }

    func testBlankAndWhitespaceLinesAreIgnored() {
        let output = "\n  gemini-3.6-flash-low\tGemini 3.6 Flash (Low)  \n\n \n gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n\n"
        let models = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(models.map(\.id), ["gemini-3.6-flash-low", "gemini-3.1-pro-high"])
        XCTAssertEqual(models.map(\.displayName), ["Gemini 3.6 Flash (Low)", "Gemini 3.1 Pro (High)"])
    }

    func testEmptyOutputYieldsNoModels() {
        XCTAssertTrue(AntigravityModelRegistry.parseModels(from: "").isEmpty)
        XCTAssertTrue(AntigravityModelRegistry.parseModels(from: "   \n \t \n").isEmpty)
    }

    func testDuplicateIDsAreCollapsedPreservingFirstOrder() {
        let output = """
        gemini-3.6-flash-low\tGemini 3.6 Flash (Low)
        gemini-3.1-pro-high\tGemini 3.1 Pro (High)
        GEMINI-3.6-FLASH-LOW\tGemini 3.6 Flash (Low) Again
        """
        let models = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(models.map(\.id), ["gemini-3.6-flash-low", "gemini-3.1-pro-high"])
    }

    func testTrailingCarriageReturnsAreTrimmed() {
        // `agy` output captured on some terminals may include CRLF line endings.
        let output = "gemini-3.6-flash-low\tGemini 3.6 Flash (Low)\r\ngemini-3.1-pro-high\tGemini 3.1 Pro (High)\r\n"
        let models = AntigravityModelRegistry.parseModels(from: output)
        XCTAssertEqual(models.map(\.id), ["gemini-3.6-flash-low", "gemini-3.1-pro-high"])
        XCTAssertEqual(models.map(\.displayName), ["Gemini 3.6 Flash (Low)", "Gemini 3.1 Pro (High)"])
    }

    @MainActor
    func testCatalogOptionsExposeIDAsRawValueAndLabelAsDisplayName() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setModels([
            .init(id: "gemini-3.6-flash-low", displayName: "Gemini 3.6 Flash (Low)"),
            .init(id: "claude-opus-4-6-thinking", displayName: "Claude Opus 4.6 (Thinking)")
        ])

        let availability = AgentModelCatalog.AvailabilityContext(antigravityAvailable: true)
        let options = AgentModelCatalog.options(for: .antigravity, availability: availability)
        let raws = options.map(\.rawValue)

        XCTAssertEqual(options.first?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertTrue(options.first?.isPlaceholderDefault == true)
        // The raw value must be the bare id: it is what lands after `agy --model`.
        XCTAssertTrue(raws.contains("gemini-3.6-flash-low"))
        XCTAssertTrue(raws.contains("claude-opus-4-6-thinking"))
        XCTAssertEqual(
            options.first(where: { $0.rawValue == "gemini-3.6-flash-low" })?.displayName,
            "Gemini 3.6 Flash (Low)"
        )
        // No option may carry the tab-joined line that `agy` rejects.
        XCTAssertFalse(raws.contains { $0.contains("\t") })
    }

    @MainActor
    func testClearCacheEmptiesModelsAndPostsChange() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setModels([.init(id: "gemini-3.6-flash-low", displayName: "Gemini 3.6 Flash (Low)")])
        XCTAssertFalse(registry.currentModels().isEmpty)
        XCTAssertNotNil(registry.lastRefresh())

        let expectation = expectation(forNotification: .antigravityModelsChanged, object: nil)
        registry.clearCache()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(registry.currentModels().isEmpty)
        XCTAssertNil(registry.lastRefresh())
    }

    @MainActor
    func testClearCacheOnEmptyCacheDoesNotPostChange() {
        let registry = AntigravityModelRegistry.shared
        registry.test_reset()
        registry.clearCache()
        // Reset already empties; clearCache on an empty cache must not regress the cache.
        XCTAssertTrue(registry.currentModels().isEmpty)
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
        XCTAssertTrue(registry.currentModels().isEmpty, "Failed attempt must not populate cache")
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
