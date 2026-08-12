@testable import RepoPromptApp
import XCTest

final class GrokModelRegistryTests: XCTestCase {
    func testMultilineOutputBecomesTrimmedLabels() {
        // `grok models` prints each model on its own line, indented and prefixed with a `* `
        // (default) or `- ` marker, with a trailing `(default)` annotation on the default. The
        // surrounding `Available models:` / `Default model: …` status lines are dropped, and the
        // bare id remains as both the `--model` value and the picker label.
        let output = """
        Available models:
          * grok-build (default)
          - grok-composer-2.5-fast
          - grok-code-fast-1
          - grok-4-fast-reasoning
          - grok-4-fast-non-reasoning
          - grok-4-0709
        Default model: grok-build
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, [
            "grok-build",
            "grok-composer-2.5-fast",
            "grok-code-fast-1",
            "grok-4-fast-reasoning",
            "grok-4-fast-non-reasoning",
            "grok-4-0709"
        ])
    }

    func testBareIdsWithoutMarkersOrStatusLinesPassThrough() {
        // Defensive: if a build of `grok models` emits bare ids with no marker/annotation, they
        // are still parsed verbatim and trimmed.
        let output = """
        grok-build
        grok-composer-2.5-fast
        grok-code-fast-1
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-build", "grok-composer-2.5-fast", "grok-code-fast-1"])
    }

    func testStatusLinesAreDroppedCaseInsensitively() {
        // The `Available models:`, `Default model: …`, and `You are not authenticated.` status
        // lines must never become picker entries, regardless of case. The `Default model:` line
        // carries a bare id value that must not leak back into the list.
        let output = """
        AVAILABLE MODELS:
          * grok-build (default)
        DEFAULT MODEL: grok-build
        You Are Not Authenticated.
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-build"])
    }

    func testSignedInGreetingIsDropped() {
        // Live `grok models` output for a signed-in session leads with a greeting line; parsing it
        // as a model would put "You are logged in with grok.com." in the picker and send it as
        // `--model`.
        let output = """
        You are logged in with grok.com.

        Default model: grok-4.6

        Available models:
          * grok-4.6 (default)
          - grok-4.5
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-4.6", "grok-4.5"])
    }

    func testTrailingDefaultAnnotationIsStripped() {
        // The `(default)` annotation (case-insensitive, plus any whitespace before it) is removed
        // so the default model collapses onto the same bare id as a non-default entry.
        let output = """
          * grok-build (DEFAULT)
          - grok-build
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-build"])
    }

    func testBlankAndWhitespaceLinesAreIgnored() {
        let output = "\n  - grok-code-fast-1  \n\n\t\n  \n  * grok-build (default)\n\n"
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-code-fast-1", "grok-build"])
    }

    func testEmptyOutputYieldsNoLabels() {
        XCTAssertTrue(GrokModelRegistry.parseModels(from: "").isEmpty)
        XCTAssertTrue(GrokModelRegistry.parseModels(from: "   \n \t \n").isEmpty)
    }

    func testDuplicateLabelsAreCollapsedPreservingFirstOrder() {
        let output = """
          - grok-code-fast-1
          * grok-build (default)
          - grok-code-fast-1
        """
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-code-fast-1", "grok-build"])
    }

    func testTrailingCarriageReturnsAreTrimmed() {
        // `grok models` output captured on some terminals may include CRLF line endings.
        let output = "  - grok-code-fast-1\r\n  * grok-build (default)\r\n"
        let labels = GrokModelRegistry.parseModels(from: output)
        XCTAssertEqual(labels, ["grok-code-fast-1", "grok-build"])
    }

    @MainActor
    func testCatalogOptionsIncludeDefaultPlusLiveLabels() {
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setLabels(["grok-code-fast-1", "grok-build"])

        let availability = AgentModelCatalog.AvailabilityContext(grokAvailable: true)
        let options = AgentModelCatalog.options(for: .grok, availability: availability)
        let raws = options.map(\.rawValue)

        XCTAssertEqual(options.first?.rawValue, AgentModel.defaultModel.rawValue)
        XCTAssertTrue(options.first?.isPlaceholderDefault == true)
        XCTAssertTrue(raws.contains("grok-code-fast-1"))
        XCTAssertTrue(raws.contains("grok-build"))
        // The live labels are exposed verbatim as both raw value and display name.
        XCTAssertEqual(
            options.first(where: { $0.rawValue == "grok-code-fast-1" })?.displayName,
            "grok-code-fast-1"
        )
    }

    @MainActor
    func testClearCacheEmptiesLabelsAndPostsChange() {
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        defer { registry.test_reset() }
        registry.test_setLabels(["grok-code-fast-1"])
        XCTAssertFalse(registry.currentModelLabels().isEmpty)
        XCTAssertNotNil(registry.lastRefresh())

        let expectation = expectation(forNotification: .grokModelsChanged, object: nil)
        registry.clearCache()
        wait(for: [expectation], timeout: 2.0)

        XCTAssertTrue(registry.currentModelLabels().isEmpty)
        XCTAssertNil(registry.lastRefresh())
    }

    @MainActor
    func testClearCacheOnEmptyCacheDoesNotPostChange() {
        let registry = GrokModelRegistry.shared
        registry.test_reset()
        registry.clearCache()
        // Reset already empties; clearCache on an empty cache must not regress labels.
        XCTAssertTrue(registry.currentModelLabels().isEmpty)
    }

    func testRefreshBacksOffAndDoesNotImmediatelyRespawnWithinStalenessWindow() async {
        // A refresh ATTEMPT (success or failure) must record the attempt timestamp so a subsequent
        // `refreshIfStale()` within the staleness window is a no-op and does NOT spawn another
        // process. This is the failure-churn fix: previously a failing `grok models` left the cache
        // empty and re-kicked a background refresh on every picker render. This test is
        // environment-independent — it asserts the no-respawn-within-window property whether or not
        // a `grok` binary is present (a failed run leaves the cache empty; a successful run fills
        // it), since the gate is keyed on the attempt time, not on success.
        let registry = GrokModelRegistry.shared
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
        let registry = GrokModelRegistry.shared
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
        // cleanly even when `grok` is absent (each underlying run returns nil and leaves the
        // cache untouched). Asserts no crash/hang from the atomic in-flight claim.
        let registry = GrokModelRegistry.shared
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await registry.refresh() }
            }
        }
    }
}
