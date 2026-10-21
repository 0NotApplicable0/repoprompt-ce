import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptProcess
import RepoPromptSecureStorage
import XCTest

/// Contract: every `AntigravityAgentProvider` (production builds one per run) owns its own run
/// gate, so one Antigravity run never parks another run's launch.
final class AntigravityAgentProviderRunGateScopeTests: XCTestCase {
    func testProvidersHaveIndependentRunGates() async throws {
        let gateA = try makeAntigravityProvider().runGateForTesting
        let gateB = try makeAntigravityProvider().runGateForTesting

        XCTAssertFalse(gateA === gateB)
        try await assertCompletes(within: 1) { try await gateA.lock() }
        try await assertCompletes(within: 1) { try await gateB.lock() }

        await gateB.unlock()
        await gateA.unlock()
    }

    func testNoSharedRunGateSymbol() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Antigravity
            .deletingLastPathComponent() // AgentMode
            .deletingLastPathComponent() // RepoPromptTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let gateSource = try String(
            contentsOf: repository.appendingPathComponent("Sources/RepoPrompt/Infrastructure/AI/Providers/Antigravity/AntigravityRunGate.swift"),
            encoding: .utf8
        )
        let providerSource = try String(
            contentsOf: repository.appendingPathComponent("Sources/RepoPrompt/Features/AgentMode/Providers/Antigravity/AntigravityAgentProvider.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(gateSource.contains("static let shared"))
        XCTAssertFalse(providerSource.contains("AntigravityRunGate.shared"))
    }

    func testRunBAcquiresItsGateWhileRunAHoldsItsOwn() async throws {
        let gateA = try makeAntigravityProvider().runGateForTesting
        let gateB = try makeAntigravityProvider().runGateForTesting

        // Run A holds its permit, as it does while its cleanup is stalled inside
        // releaseRunGateAfterCleanup.
        try await gateA.lock()

        try await assertCompletes(within: 1) {
            try await AntigravityAgentProvider.acquireRunGate(gateB)
        }
        let aLocked = await gateA.isLocked
        let aWaiters = await gateA.waiterCount
        let bLocked = await gateB.isLocked
        XCTAssertTrue(aLocked)
        XCTAssertEqual(aWaiters, 0)
        XCTAssertTrue(bLocked)

        await gateB.unlock()
        await gateA.unlock()
    }

    private func makeAntigravityProvider() throws -> AntigravityAgentProvider {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .antigravity,
            modelString: "gemini-placeholder",
            antigravityPermissionLevel: .safeManagedUnavailable
        )
        return try XCTUnwrap(provider as? AntigravityAgentProvider)
    }

    /// Fails instead of hanging when `operation` parks longer than `seconds`.
    private func assertCompletes(
        within seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await operation()
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "operation parked for more than \(seconds) s", file: file, line: line)
    }
}

final class AntigravityRunDiagnosticsTests: XCTestCase {
    private static let privateMarker = "synthetic-account@example.invalid private-diagnostic-marker"

    private enum Scenario: Equatable {
        case failed
        case thrown
        case cancelled
        case capped
        case completed
        case empty
        case stalledFork
        case silentFork
        case progressingFork
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: TimeInterval = 0

        var now: TimeInterval {
            lock.withLock { instant }
        }

        func advance(to instant: TimeInterval) {
            lock.withLock { self.instant = instant }
        }
    }

    private final class EventScript: @unchecked Sendable {
        private let lock = NSLock()
        private let clock: Clock
        private var events: [(TimeInterval, CLIProcessRunner.StreamEvent)]
        private let terminalError: Error?

        init(clock: Clock, events: [(TimeInterval, CLIProcessRunner.StreamEvent)], terminalError: Error?) {
            self.clock = clock
            self.events = events
            self.terminalError = terminalError
        }

        func next() throws -> CLIProcessRunner.StreamEvent? {
            try lock.withLock {
                guard !events.isEmpty else {
                    if let terminalError { throw terminalError }
                    return nil
                }
                let (instant, event) = events.removeFirst()
                clock.advance(to: instant)
                return event
            }
        }
    }

    private final class SilentProcess: @unchecked Sendable {
        let stream: AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>
        private let continuation: AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>.Continuation

        init() {
            let pair = AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
        }

        func cancel() {
            continuation.finish(throwing: CancellationError())
        }
    }

    private final class TrajectoryProgressProbe: AntigravityTrajectoryStoreReading, @unchecked Sendable {
        let clock = Clock()
        private let lock = NSLock()
        private let switchesTurn: Bool
        private var phase = 0
        private var progressCount = 0

        init(switchesTurn: Bool) {
            self.switchesTurn = switchesTurn
        }

        func locate() -> URL? {
            lock.withLock {
                switchesTurn && phase > 0 ? nil : URL(fileURLWithPath: "/synthetic-predecessor.db")
            }
        }

        func steps(after _: Int64, limit _: Int32) -> [AntigravityTrajectoryStore.ToolStep]? {
            lock.withLock {
                [.init(idx: Int64(phase + 1), status: 0, payload: Data("row-\(phase)".utf8))]
            }
        }

        func latestFailureKind() -> AntigravityTrajectoryStore.FailureKind? {
            nil
        }

        func advance() -> Bool {
            lock.withLock {
                phase += 1
                clock.advance(to: TimeInterval(phase * 119))
                return phase == 2
            }
        }

        func recordProgress() {
            lock.withLock { progressCount += 1 }
        }

        var count: Int {
            lock.withLock { progressCount }
        }
    }

    private struct Fixture {
        let root: URL
        let diagnostics: URL
        let activeLogs: URL
        let provider: AntigravityAgentProvider
    }

    private struct Capture {
        var events: [AIStreamResult] = []
        var failure: String?
    }

    func testFailedTurnRetainsLogAndStderrTail() async throws {
        for scenario in [Scenario.failed, .thrown, .cancelled, .capped] {
            let fixture = try makeFixture(scenario)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let captured = await capture(fixture.provider)
            XCTAssertNotNil(captured.failure)
            XCTAssertFalse(captured.failure?.contains(Self.privateMarker) == true)

            let runs = retainedRuns(in: fixture.diagnostics)
            XCTAssertEqual(runs.count, 1)
            guard let run = runs.first else { continue }
            let log = try String(contentsOf: run.appendingPathComponent("agy.log"), encoding: .utf8)
            let stderr = try Data(contentsOf: run.appendingPathComponent("stderr-tail.txt"))
            XCTAssertTrue(log.contains(Self.privateMarker))
            XCTAssertEqual(stderr.count, 64 * 1024)
            XCTAssertTrue(String(decoding: stderr, as: UTF8.self).hasSuffix(Self.privateMarker))
            try assertPermissions(fixture.diagnostics, expected: 0o700)
            try assertPermissions(run, expected: 0o700)
            try assertPermissions(run.appendingPathComponent("agy.log"), expected: 0o600)
            try assertPermissions(run.appendingPathComponent("stderr-tail.txt"), expected: 0o600)
            XCTAssertTrue(retainedRuns(in: fixture.activeLogs).isEmpty)
        }
    }

    func testCompletedTurnRemovesLog() async throws {
        let fixture = try makeFixture(.completed)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let captured = await capture(fixture.provider)

        XCTAssertNil(captured.failure)
        XCTAssertEqual(captured.events.filter { $0.type == "content" }.compactMap(\.text).joined(), "final answer\n")
        XCTAssertEqual(captured.events.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertTrue(retainedRuns(in: fixture.activeLogs).isEmpty)
        XCTAssertTrue(retainedRuns(in: fixture.diagnostics).isEmpty)
    }

    func testRetainedDiagnosticsAreBounded() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0 ..< 22 {
            let fixture = try makeFixture(.failed, root: root, marker: "run-marker-\(index)|")
            let captured = await capture(fixture.provider)
            XCTAssertNotNil(captured.failure)
        }

        let runs = retainedRuns(in: root.appendingPathComponent("diagnostics"))
        XCTAssertEqual(runs.count, 20)
        let logs = try runs.map { try String(contentsOf: $0.appendingPathComponent("agy.log"), encoding: .utf8) }
        XCTAssertFalse(logs.contains { $0.contains("run-marker-0|") })
        XCTAssertFalse(logs.contains { $0.contains("run-marker-1|") })
        XCTAssertTrue(logs.contains { $0.contains("run-marker-21|") })

        let blockedRoot = try makeRoot()
        defer { try? FileManager.default.removeItem(at: blockedRoot) }
        try Data().write(to: blockedRoot.appendingPathComponent("diagnostics"))
        for _ in 0 ..< 22 {
            let fixture = try makeFixture(.failed, root: blockedRoot)
            _ = await capture(fixture.provider)
        }
        let preservedSources = retainedRuns(in: blockedRoot.appendingPathComponent("active"))
        XCTAssertEqual(preservedSources.count, 20)
        for source in preservedSources {
            try assertPermissions(source, expected: 0o600)
        }
    }

    @MainActor
    func testEmptyFirstTurnFailsRunWithReason() async throws {
        let fixture = try makeFixture(.empty)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fallback = AgentModeViewModel.composeClaudeResumeRecoveryHandoffPayload(
            sourceTabName: "diagnostics test", sourceAgentName: "Antigravity CLI",
            transcriptXML: "<transcript></transcript>", initialThreadContextBlock: nil, deliveryID: "test"
        )
        let providers: [(HeadlessAgentProvider, String)] = [
            (fixture.provider, "first turn"),
            (AgentSessionLinkCapturingHeadlessProvider(), "first turn"),
            (AgentSessionLinkCapturingHeadlessProvider(), fallback)
        ]
        for (provider, prompt) in providers {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _, _, _, _ in provider })
            let session = harness.makeSession(agent: .antigravity)
            let runner = harness.makeHeadlessRunner()
            await runner.startRun(
                tabID: session.tabID, session: session,
                initialUserMessage: prompt, initialMessageForRun: prompt, attachments: [],
                makeLease: { harness.makeLease(runID: $0, tabID: session.tabID) }
            )
            await session.agentTask?.value
            XCTAssertEqual(session.runState, .failed)
            XCTAssertNotNil(session.lastTerminalCommitRevision?.failureReason)
            XCTAssertTrue(session.items.contains {
                $0.kind == .error && $0.text.localizedCaseInsensitiveContains("no meaningful output")
            })
            await harness.host.prepareForWindowClose()
        }
    }

    func testForkFallbackWithoutProgressFailsWithinBound() async throws {
        let prompt = AgentModeViewModel.composeClaudeResumeRecoveryHandoffPayload(
            sourceTabName: "diagnostics test", sourceAgentName: "Antigravity CLI",
            transcriptXML: "<transcript></transcript>", initialThreadContextBlock: nil, deliveryID: "test"
        )
        for scenario in [Scenario.stalledFork, .silentFork] {
            let stalled = try makeFixture(scenario)
            defer { try? FileManager.default.removeItem(at: stalled.root) }
            let captured = await capture(stalled.provider, prompt: prompt)
            XCTAssertTrue(captured.failure?.contains("120") == true)
            XCTAssertTrue(captured.failure?.localizedCaseInsensitiveContains("no stdout or trajectory progress") == true)
            XCTAssertFalse(captured.events.contains { $0.type == "message_stop" })
            XCTAssertEqual(retainedRuns(in: stalled.diagnostics).count, 1)
        }

        let progressing = try makeFixture(.progressingFork)
        defer { try? FileManager.default.removeItem(at: progressing.root) }
        let successful = await capture(progressing.provider, prompt: prompt)
        XCTAssertNil(successful.failure)
        XCTAssertTrue(successful.events.contains { $0.type == "message_stop" })

        for switchesTurn in [false, true] {
            let probe = TrajectoryProgressProbe(switchesTurn: switchesTurn)
            let progress = AntigravityTurnProgress(now: { probe.clock.now })
            progress.beginTurn()
            let pair = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
            let task = Task {
                await AntigravityTrajectoryToolLogStream.tail(
                    into: pair.continuation,
                    locate: { probe.locate() },
                    waitBetweenPolls: { _ in
                        let finished = probe.advance()
                        _ = progress.claimIdleTimeout()
                        if finished { withUnsafeCurrentTask { $0?.cancel() } }
                    },
                    waitForFinalDrainRetry: { _ in },
                    storeFactory: { _ in probe },
                    onProgress: {
                        probe.recordProgress()
                        progress.recordProgress()
                    }
                )
            }
            _ = await task.value
            pair.continuation.finish()
            progress.endTurn()
            XCTAssertEqual(progress.hasTimedOut, switchesTurn)
            if switchesTurn { XCTAssertEqual(probe.count, 1) }
        }
    }

    func testRetainedDiagnosticsNotShownInUI() async throws {
        let fixture = try makeFixture(.failed)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let captured = await capture(fixture.provider)
        XCTAssertEqual(retainedRuns(in: fixture.diagnostics).count, 1)
        XCTAssertFalse(captured.failure?.contains(Self.privateMarker) == true)
        XCTAssertFalse(captured.failure?.contains(fixture.diagnostics.path) == true)
        XCTAssertFalse(captured.events.contains {
            ($0.text ?? "").contains(Self.privateMarker) || ($0.reasoning ?? "").contains(Self.privateMarker)
        })
        XCTAssertFalse(captured.events.contains { $0.type == "message_stop" })
    }

    func testStreamJSONFirstTurnFixturePublishesAssistantTextBeforeProcessExit() async throws {
        let fixture = try makeControlledStreamJSONFixture()
        let stream = try await fixture.provider.streamAgentMessage(AgentMessage(userMessage: "diagnostics test"))
        let receivedPong = expectation(description: "decoded pong before process termination")
        let events = EventRecorder()
        let consumer = Task {
            do {
                for try await event in stream {
                    events.append(event)
                    if event.type == "content", event.text == "pong" {
                        receivedPong.fulfill()
                    }
                }
                return nil as String?
            } catch {
                return error.localizedDescription
            }
        }
        let lines = try String(decoding: fixtureData(named: "agy-stream-json-first-turn.ndjson"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 5)
        for line in lines.prefix(3) {
            fixture.process.yield(.stdout(Data((line + "\n").utf8)))
        }
        await fulfillment(of: [receivedPong], timeout: 10)
        XCTAssertFalse(fixture.process.terminationSent)

        for line in lines.dropFirst(3) {
            fixture.process.yield(.stdout(Data((line + "\n").utf8)))
        }
        fixture.process.finish()
        let failure = await consumer.value
        await fixture.provider.dispose()
        try? FileManager.default.removeItem(at: fixture.root)

        XCTAssertNil(failure)
        XCTAssertTrue(consecutive(fixture.arguments.arguments, [
            "--print",
            AntigravityAgentProvider.combinedPrompt(system: "", user: "diagnostics test")
        ]))
        XCTAssertTrue(consecutive(fixture.arguments.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: events.events), "pong\n")
        XCTAssertEqual(events.events.count(where: { $0.type == "message_stop" }), 1)
        XCTAssertFalse(content(in: events.events).contains("{\"event\""))
    }

    func testStreamJSONResumeFixtureReplaysNoHistoryAndMatchesResult() async throws {
        let captured = try await captureStreamJSONFixture(named: "agy-stream-json-resume.ndjson")
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "pong2\n")
        XCTAssertFalse(content(in: captured.events).contains("system_message"))
    }

    func testStreamJSONResultExtendsPartialDeltasEmitsSuffixOnly() async throws {
        let captured = try await captureStreamJSON(
            "{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"agent_response\",\"text_delta\":\"po\"}}\n"
                + "{\"event\":\"result\",\"result\":{\"response\":\"pong\\n\",\"status\":\"SUCCESS\"}}\n"
        )
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "pong\n")
    }

    func testStreamJSONDivergedResultDoesNotDuplicate() async throws {
        let captured = try await captureStreamJSON(
            "{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"agent_response\",\"text_delta\":\"po\"}}\n"
                + "{\"event\":\"result\",\"result\":{\"response\":\"different\\n\",\"status\":\"SUCCESS\"}}\n"
        )
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "po")
    }

    func testStreamJSONResultOnlyFallbackEmitsResponseOnce() async throws {
        let captured = try await captureStreamJSON(
            "{\"event\":\"result\",\"result\":{\"response\":\"pong\\n\",\"status\":\"SUCCESS\"}}\n"
        )
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "pong\n")
    }

    func testStreamJSONPollCapResultClassifiedCappedAndMarkerNotInContent() async throws {
        let captured = try await captureStreamJSON(
            "{\"event\":\"result\",\"result\":{\"response\":\"Error: timed out waiting for response\",\"status\":\"SUCCESS\"}}\n"
        )
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertTrue(captured.failure?.contains("headless print mode stopped") == true)
        XCTAssertFalse(content(in: captured.events).contains("Error: timed out waiting for response"))
    }

    func testStreamJSONInitOnlyFirstTurnIsNoMeaningfulOutput() async throws {
        let captured = try await captureStreamJSON("{\"event\":\"init\",\"conversation_id\":\"fixture\"}\n")
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertTrue(captured.failure?.localizedCaseInsensitiveContains("no meaningful output") == true)
        XCTAssertTrue(content(in: captured.events).isEmpty)
    }

    func testStreamJSONPartialDeltasThenExit3SurfacesFailure() async throws {
        let captured = try await captureStreamJSON(
            "{\"event\":\"step_update\",\"step_update\":{\"step_type\":\"agent_response\",\"text_delta\":\"pong\"}}\n",
            exitStatus: 3
        )
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "pong")
        XCTAssertNotNil(captured.failure)
        XCTAssertFalse(captured.events.contains { $0.type == "message_stop" })
    }

    func testStreamJSONMalformedEventLineDoesNotLeakRawJSON() async throws {
        let captured = try await captureStreamJSON("{\"event\":\"step_update\"\nplain output\n")
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "plain output\n")
        XCTAssertFalse(content(in: captured.events).contains("{\"event\""))
    }

    func testStreamJSONUnterminatedResultLineDoesNotLeakRawJSON() async throws {
        let captured = try await captureStreamJSON(
            "{\"event\":\"result\",\"result\":{\"response\":\"pong\\n\",\"status\":\"SUCCESS\"}}"
        )
        XCTAssertTrue(consecutive(captured.arguments, ["--output-format", "stream-json"]))
        XCTAssertEqual(content(in: captured.events), "pong\n")
        XCTAssertFalse(content(in: captured.events).contains("{\"event\""))
    }

    func testStreamJSONFixtureFilesMatchCapturedBytes() throws {
        let first = try fixtureData(named: "agy-stream-json-first-turn.ndjson")
        let resume = try fixtureData(named: "agy-stream-json-resume.ndjson")
        XCTAssertEqual(first.count, 2308)
        XCTAssertEqual(resume.count, 2503)
        XCTAssertEqual(String(decoding: first, as: UTF8.self).split(whereSeparator: \.isNewline).count, 5)
        XCTAssertEqual(String(decoding: resume, as: UTF8.self).split(whereSeparator: \.isNewline).count, 6)
    }

    func testOversizedPromptUsesTextOutputAndPlainStdout() async throws {
        let prompt = String(repeating: "x", count: AntigravityAgentProvider.maxInlinePromptBytes + 1)
        let captured = try await captureStreamJSON("plain stdout\n", prompt: prompt)
        XCTAssertFalse(captured.arguments.contains("--output-format"))
        XCTAssertEqual(content(in: captured.events), "plain stdout\n")
        XCTAssertNil(captured.failure)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRunDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(_ scenario: Scenario, root: URL? = nil, marker: String = "") throws -> Fixture {
        let root = try root ?? makeRoot()
        let activeLogs = root.appendingPathComponent("active", isDirectory: true)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        let clock = Clock()
        let silentProcess = SilentProcess()
        var runtime = AntigravityAgentProvider.RuntimeOverrides(
            prepareContext: { runID in
                HeadlessAgentContext(runID: runID ?? UUID(), configURL: nil, environment: ["HOME": root.path])
            },
            processEvents: { args, _ in
                let logIndex = try XCTUnwrap(args.firstIndex(of: "--log-file"))
                let logURL = URL(fileURLWithPath: args[logIndex + 1])
                try Data((Self.privateMarker + marker).utf8).write(to: logURL)
                var events: [(TimeInterval, CLIProcessRunner.StreamEvent)] = [
                    (0, .stderr(Data((String(repeating: "x", count: 70 * 1024) + Self.privateMarker).utf8)))
                ]
                var terminalError: Error?
                switch scenario {
                case .failed:
                    events.append((0, .terminated(status: 1, timedOut: false)))
                case .thrown:
                    terminalError = NSError(domain: Self.privateMarker, code: 1)
                case .cancelled:
                    terminalError = CancellationError()
                case .capped:
                    events += [
                        (0, .stdout(Data("Error: timed out waiting for response\n".utf8))),
                        (0, .terminated(status: 0, timedOut: false))
                    ]
                case .completed:
                    events += [(0, .stdout(Data("final answer\n".utf8))), (0, .terminated(status: 0, timedOut: false))]
                case .empty:
                    events.append((0, .terminated(status: 0, timedOut: false)))
                case .stalledFork:
                    events += [(121, .stderr(Data("still waiting".utf8))), (121, .terminated(status: 0, timedOut: false))]
                case .silentFork:
                    return silentProcess.stream
                case .progressingFork:
                    events += [
                        (119, .stdout(Data("working\n".utf8))),
                        (238, .stdout(Data("final answer\n".utf8))),
                        (238, .terminated(status: 0, timedOut: false))
                    ]
                }
                let script = EventScript(clock: clock, events: events, terminalError: terminalError)
                return AsyncThrowingStream(unfolding: { try script.next() })
            },
            logDirectory: activeLogs,
            diagnosticsDirectory: diagnostics,
            now: { clock.now }
        )
        if scenario == .silentFork {
            runtime.waitForProgressCheck = { clock.advance(to: 120) }
            runtime.cancelProcess = { silentProcess.cancel() }
        }
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(command: "/never-launch-agy", additionalPaths: []))
        let provider = AntigravityAgentProvider(
            runner: runner, config: AntigravityAgentConfig(maxPrintResumes: 0), runtimeOverrides: runtime
        )
        return Fixture(root: root, diagnostics: diagnostics, activeLogs: activeLogs, provider: provider)
    }

    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [AIStreamResult] = []

        func append(_ event: AIStreamResult) {
            lock.withLock { value.append(event) }
        }

        var events: [AIStreamResult] {
            lock.withLock { value }
        }
    }

    private final class ControlledProcess: @unchecked Sendable {
        let stream: AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>
        private let continuation: AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>.Continuation
        private let lock = NSLock()
        private var didSendTermination = false

        init() {
            let pair = AsyncThrowingStream<CLIProcessRunner.StreamEvent, Error>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
        }

        func yield(_ event: CLIProcessRunner.StreamEvent) {
            continuation.yield(event)
        }

        func finish() {
            lock.withLock { didSendTermination = true }
            continuation.yield(.terminated(status: 0, timedOut: false))
            continuation.finish()
        }

        var terminationSent: Bool {
            lock.withLock { didSendTermination }
        }
    }

    private final class ArgumentCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []

        func record(_ arguments: [String]) {
            lock.withLock { value = arguments }
        }

        var arguments: [String] {
            lock.withLock { value }
        }
    }

    private struct StreamJSONCapture {
        let arguments: [String]
        let events: [AIStreamResult]
        let failure: String?
    }

    private struct ControlledStreamJSONFixture {
        let root: URL
        let arguments: ArgumentCapture
        let process: ControlledProcess
        let provider: AntigravityAgentProvider
    }

    private func makeControlledStreamJSONFixture() throws -> ControlledStreamJSONFixture {
        let root = try makeRoot()
        let arguments = ArgumentCapture()
        let process = ControlledProcess()
        let runtime = AntigravityAgentProvider.RuntimeOverrides(
            prepareContext: { runID in
                HeadlessAgentContext(runID: runID ?? UUID(), configURL: nil, environment: ["HOME": root.path])
            },
            processEvents: { args, _ in
                arguments.record(args)
                return process.stream
            },
            logDirectory: root.appendingPathComponent("active", isDirectory: true),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics", isDirectory: true),
            now: { 0 }
        )
        let provider = AntigravityAgentProvider(
            runner: CLIProcessRunner(config: CLIProcessConfiguration(command: "/never-launch-agy", additionalPaths: [])),
            config: AntigravityAgentConfig(maxPrintResumes: 0),
            runtimeOverrides: runtime
        )
        return ControlledStreamJSONFixture(root: root, arguments: arguments, process: process, provider: provider)
    }

    private func captureStreamJSONFixture(named name: String) async throws -> StreamJSONCapture {
        try await captureStreamJSON(String(decoding: fixtureData(named: name), as: UTF8.self))
    }

    private func captureStreamJSON(
        _ stdout: String,
        exitStatus: Int32 = 0,
        prompt: String = "diagnostics test"
    ) async throws -> StreamJSONCapture {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = ArgumentCapture()
        let events: [CLIProcessRunner.StreamEvent] = [
            .stdout(Data(stdout.utf8)),
            .terminated(status: exitStatus, timedOut: false)
        ]
        let clock = Clock()
        let script = EventScript(clock: clock, events: events.map { (0, $0) }, terminalError: nil)
        let runtime = AntigravityAgentProvider.RuntimeOverrides(
            prepareContext: { runID in
                HeadlessAgentContext(runID: runID ?? UUID(), configURL: nil, environment: ["HOME": root.path])
            },
            processEvents: { args, _ in
                arguments.record(args)
                return AsyncThrowingStream(unfolding: { try script.next() })
            },
            logDirectory: root.appendingPathComponent("active", isDirectory: true),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics", isDirectory: true),
            now: { clock.now }
        )
        let provider = AntigravityAgentProvider(
            runner: CLIProcessRunner(config: CLIProcessConfiguration(command: "/never-launch-agy", additionalPaths: [])),
            config: AntigravityAgentConfig(maxPrintResumes: 0),
            runtimeOverrides: runtime
        )
        let captured = await capture(provider, prompt: prompt)
        return StreamJSONCapture(arguments: arguments.arguments, events: captured.events, failure: captured.failure)
    }

    private func fixtureData(named name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try Data(contentsOf: directory.appendingPathComponent("Fixtures/\(name)"))
    }

    private func content(in events: [AIStreamResult]) -> String {
        events.filter { $0.type == "content" }.compactMap(\.text).joined()
    }

    private func consecutive(_ array: [String], _ pair: [String]) -> Bool {
        guard pair.count == 2 else { return false }
        return array.indices.dropLast().contains { array[$0] == pair[0] && array[$0 + 1] == pair[1] }
    }

    private func capture(_ provider: AntigravityAgentProvider, prompt: String = "diagnostics test") async -> Capture {
        var captured = Capture()
        do {
            let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: prompt))
            for try await event in stream {
                captured.events.append(event)
            }
        } catch {
            captured.failure = error.localizedDescription
        }
        await provider.dispose()
        return captured
    }

    private func retainedRuns(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func assertPermissions(_ url: URL, expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected, file: file, line: line)
    }
}

final class AntigravityArgumentBuilderTests: XCTestCase {
    private func consecutive(_ array: [String], _ pair: [String]) -> Bool {
        guard pair.count == 2 else { return false }
        for index in array.indices.dropLast() where array[index] == pair[0] && array[index + 1] == pair[1] {
            return true
        }
        return false
    }

    func testCombinedPromptOmitsEmptySystem() {
        let prompt = AntigravityAgentProvider.combinedPrompt(system: "   ", user: "do x")
        XCTAssertTrue(prompt.contains(AntigravityAgentProvider.executionCompletionGuidance))
        XCTAssertTrue(prompt.hasSuffix("do x"))
    }

    func testCombinedPromptJoinsSystemAndUser() {
        let combined = AntigravityAgentProvider.combinedPrompt(system: "be terse", user: "do x")
        XCTAssertTrue(combined.contains("be terse"))
        XCTAssertTrue(combined.contains("do x"))
        XCTAssertTrue(combined.contains("\n\n"))
    }

    func testBuildArgumentsBaseShape() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil
        )
        // The prompt is delivered via STDIN, not argv: argv starts with a bare `--print`.
        XCTAssertEqual(args.first, "--print")
        XCTAssertFalse(args.contains("hello"))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(args.contains("--print-timeout"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("--add-dir"))
        XCTAssertFalse(args.contains("--log-file"))
    }

    func testBuildArgumentsIncludesModelWorkspaceAndLog() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "gemini-3.1-pro-preview"),
            workspacePath: "/tmp/ws",
            logFilePath: "/tmp/agy.log"
        )
        XCTAssertTrue(consecutive(args, ["--model", "gemini-3.1-pro-preview"]))
        XCTAssertTrue(consecutive(args, ["--add-dir", "/tmp/ws"]))
        XCTAssertTrue(consecutive(args, ["--log-file", "/tmp/agy.log"]))
    }

    func testBuildArgumentsOmitsBlankModel() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "   "),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--model"))
    }

    func testBuildArgumentsOmitsDefaultSentinelModel() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "default"),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--model"))
    }

    func testBuildArgumentsReducesPersistedTabJoinedModelToID() {
        // Selections saved while the picker mirrored whole `agy models` lines hold
        // `<id>\t<Display Label>`; `agy` rejects that with `invalid model selection`.
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "gemini-3.6-flash-high\tGemini 3.6 Flash (High)"),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(consecutive(args, ["--model", "gemini-3.6-flash-high"]))
        XCTAssertFalse(args.contains { $0.contains("\t") })
    }

    func testNormalizedModelIDPassesBareIDThrough() {
        XCTAssertEqual(
            AntigravityAgentProvider.normalizedModelID("gemini-3.6-flash-high"),
            "gemini-3.6-flash-high"
        )
    }

    func testNormalizedModelIDKeepsLegacyDisplayLabel() {
        // Pre-1.1.12 `agy` accepted a bare display label, so a persisted label with no id column
        // must pass through untouched rather than being reduced to nothing.
        XCTAssertEqual(
            AntigravityAgentProvider.normalizedModelID("Gemini 3.6 Flash (High)"),
            "Gemini 3.6 Flash (High)"
        )
    }

    // MARK: - Inline prompt (agy honors `--model` only when the prompt is the `--print` argv value)

    func testBuildArgumentsInlinesPromptAsPrintValueWhenProvided() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: "do the thing"
        )
        // agy drops `--model` when the prompt arrives via a bare `--print` + STDIN, so the prompt
        // is delivered as the `--print` argument value: argv leads with `--print <prompt>`.
        XCTAssertEqual(Array(args.prefix(2)), ["--print", "do the thing"])
    }

    func testBuildArgumentsOmitsInlinePromptValueWhenNil() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: nil
        )
        // No inline prompt: the prompt is delivered via STDIN, so `--print` stays bare and the
        // token after it is a flag, not prompt text.
        XCTAssertEqual(args.first, "--print")
        XCTAssertTrue(args.count == 1 || args[1].hasPrefix("--"))
    }

    func testBuildArgumentsInlinePromptStillEmitsModelFlag() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(modelString: "Gemini 3.1 Pro (Low)"),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: "hello"
        )
        XCTAssertEqual(Array(args.prefix(2)), ["--print", "hello"])
        XCTAssertTrue(consecutive(args, ["--model", "Gemini 3.1 Pro (Low)"]))
    }

    func testShouldInlinePromptTrueForSmallPrompt() {
        XCTAssertTrue(AntigravityAgentProvider.shouldInlinePrompt("small prompt"))
        XCTAssertTrue(AntigravityAgentProvider.shouldInlinePrompt(""))
    }

    func testShouldInlinePromptFalseForOversizedPrompt() {
        let oversized = String(repeating: "a", count: AntigravityAgentProvider.maxInlinePromptBytes + 1)
        XCTAssertFalse(AntigravityAgentProvider.shouldInlinePrompt(oversized))
    }

    func testShouldInlinePromptCountsUTF8BytesNotCharacters() {
        // A multi-byte grapheme prompt just over the byte budget in UTF-8 must fall back to STDIN
        // even though its Swift `count` (grapheme count) is far below the budget.
        let emojiCount = AntigravityAgentProvider.maxInlinePromptBytes / 4 + 1 // each is 4 UTF-8 bytes
        let oversized = String(repeating: "😀", count: emojiCount)
        XCTAssertLessThan(oversized.count, AntigravityAgentProvider.maxInlinePromptBytes)
        XCTAssertGreaterThan(oversized.utf8.count, AntigravityAgentProvider.maxInlinePromptBytes)
        XCTAssertFalse(AntigravityAgentProvider.shouldInlinePrompt(oversized))
    }

    func testMaxInlinePromptBytesLeavesArgMaxHeadroom() {
        // Must stay well under macOS ARG_MAX (1 MiB total for argv + environment) so the inlined
        // prompt plus flags plus the inherited environment can never hit E2BIG.
        XCTAssertLessThanOrEqual(AntigravityAgentProvider.maxInlinePromptBytes, 512 * 1024)
    }

    func testSandboxCanBeDisabled() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: false),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsExplicitSandboxOnlyConfigEmitsSandbox() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: true, dangerouslySkipPermissions: false),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    func testBuildArgumentsFullAccessEmitsSkipPermissionsAndNoSandbox() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: false, dangerouslySkipPermissions: true),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--sandbox"))
    }

    func testBuildArgumentsSandboxedAutoApproveEmitsBothFlags() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(useSandbox: true, dangerouslySkipPermissions: true),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(args.contains("--sandbox"))
    }

    func testBuildArgumentsOmitsConversationByDefault() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil
        )
        XCTAssertFalse(args.contains("--conversation"))
    }

    func testBuildArgumentsIncludesConversationWhenResuming() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: "/tmp/agy.log",
            resumeConversationID: "abc-123"
        )
        XCTAssertTrue(consecutive(args, ["--conversation", "abc-123"]))
    }

    func testBuildArgumentsInlineAddsStreamJSONOutputFormat() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(
                modelString: "gemini-3.1-pro-preview", useSandbox: true, dangerouslySkipPermissions: true
            ),
            workspacePath: nil,
            logFilePath: "/tmp/agy.log",
            resumeConversationID: "abc-123",
            inlinePrompt: "stream this"
        )
        XCTAssertTrue(consecutive(args, ["--print", "stream this"]))
        XCTAssertTrue(consecutive(args, ["--output-format", "stream-json"]))
        XCTAssertTrue(consecutive(args, ["--model", "gemini-3.1-pro-preview"]))
        XCTAssertTrue(consecutive(args, ["--conversation", "abc-123"]))
        XCTAssertTrue(args.contains("--sandbox"))
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(consecutive(args, ["--print-timeout", "3600s"]))
        XCTAssertTrue(consecutive(args, ["--log-file", "/tmp/agy.log"]))
    }

    func testBuildArgumentsStdinPathOmitsOutputFormat() {
        let args = AntigravityAgentProvider.buildArguments(
            config: AntigravityAgentConfig(),
            workspacePath: nil,
            logFilePath: nil,
            inlinePrompt: nil
        )
        XCTAssertFalse(args.contains("--output-format"))
    }

    func testConfigDefaultMaxPrintResumesIsBounded() {
        XCTAssertEqual(AntigravityAgentConfig().maxPrintResumes, 6)
    }

    func testConfigClampsNegativeMaxPrintResumesToZero() {
        XCTAssertEqual(AntigravityAgentConfig(maxPrintResumes: -3).maxPrintResumes, 0)
    }

    func testPermissionLevelMapping() {
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.useSandbox)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.dangerouslySkipPermissions)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.isWarning)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.managedDefault.supportsHeadlessRun)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.useSandbox)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.dangerouslySkipPermissions)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.isWarning)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.supportsHeadlessRun)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.useSandbox)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.dangerouslySkipPermissions)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.isWarning)
        XCTAssertTrue(AntigravityAgentToolPreferences.PermissionLevel.fullAccess.supportsHeadlessRun)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.dangerouslySkipPermissions)
        XCTAssertFalse(AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.supportsHeadlessRun)
    }

    func testPermissionLevelHasThreeUserSelectableCases() {
        XCTAssertEqual(
            AntigravityAgentToolPreferences.PermissionLevel.allCases,
            [.managedDefault, .sandboxedAutoApprove, .fullAccess]
        )
        XCTAssertFalse(
            AntigravityAgentToolPreferences.PermissionLevel.allCases.contains(.safeManagedUnavailable)
        )
    }

    func testPermissionLevelFromRawValue() {
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "fullAccess"), .fullAccess)
        XCTAssertEqual(
            AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "sandboxedAutoApprove"),
            .sandboxedAutoApprove
        )
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "managedDefault"), .managedDefault)
        XCTAssertEqual(
            AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "safeManagedUnavailable"),
            .managedDefault
        )
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: nil), .managedDefault)
        XCTAssertEqual(AntigravityAgentToolPreferences.PermissionLevel.from(rawValue: "bogus"), .managedDefault)
    }

    func testRuntimeOnlyPermissionLevelCannotBePersisted() throws {
        let suiteName = "AntigravityArgumentBuilderTests.runtime-only-permission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AntigravityAgentToolPreferences.setPermissionLevel(
            .safeManagedUnavailable,
            defaults: defaults
        )

        XCTAssertEqual(
            AntigravityAgentToolPreferences.permissionLevel(defaults: defaults),
            .managedDefault
        )
    }

    func testPermissionBindingParserRejectsInternalSafeManagedSentinel() {
        XCTAssertNil(AgentProviderPermissionLevelID(
            providerID: .antigravity,
            subagentRawValue: AntigravityAgentToolPreferences.PermissionLevel.safeManagedUnavailable.rawValue
        ))
        XCTAssertEqual(
            AgentProviderPermissionLevelID(
                providerID: .antigravity,
                subagentRawValue: AntigravityAgentToolPreferences.PermissionLevel.sandboxedAutoApprove.rawValue
            ),
            .antigravity(.sandboxedAutoApprove)
        )
    }

    func testSubagentPreferenceSetterCannotPersistInternalSafeManagedSentinel() throws {
        let suiteName = "AntigravityArgumentBuilderTests.subagent-runtime-only-permission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AgentModePermissionPreferences.setProviderSubagentPermissionLevel(
            .antigravity(.safeManagedUnavailable),
            for: .antigravity,
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.string(forKey: AgentModePermissionPreferences.providerPermissionLevelKey(for: .antigravity)),
            AntigravityAgentToolPreferences.PermissionLevel.managedDefault.rawValue
        )
        XCTAssertEqual(
            AgentModePermissionPreferences.providerSubagentPermissionLevel(
                for: .antigravity,
                defaults: defaults
            ),
            .antigravity(.managedDefault)
        )
    }

    @MainActor
    func testRuntimePermissionBindingPropagatesSafeAndExplicitProfiles() throws {
        let suiteName = "AntigravityArgumentBuilderTests.runtime-permissions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: nil,
            codexMCPServerEntries: { [] }
        )

        XCTAssertEqual(
            store.runtimePermission(for: .antigravity, profile: .mcpSafeDefaults)
                .antigravityPermissionLevel,
            .safeManagedUnavailable
        )
        XCTAssertEqual(
            store.runtimePermission(
                for: .antigravity,
                profile: .providerOverride(.antigravity(.sandboxedAutoApprove))
            ).antigravityPermissionLevel,
            .sandboxedAutoApprove
        )
    }

    func testSafeManagedPreparationFailsBeforeLaunchingAntigravity() async {
        let config = AntigravityAgentConfig(supportsHeadlessRun: false)
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(
            command: "/definitely/not/an/agy/binary",
            additionalPaths: []
        ))
        let provider = AntigravityAgentProvider(runner: runner, config: config)

        do {
            _ = try await provider.streamAgentMessage(AgentMessage(userMessage: "do not launch"))
            XCTFail("Safe Managed must fail before returning a runnable stream")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                AntigravityAgentProvider.safeManagedUnavailableMessage
            )
        }
        await provider.dispose()
        XCTAssertEqual(
            AntigravityAgentProvider.preparationPolicyFailureMessage(for: config),
            AntigravityAgentProvider.safeManagedUnavailableMessage
        )
    }

    func testSafeManagedCapabilitySummaryReportsAntigravityUnavailable() throws {
        let suiteName = "AntigravityArgumentBuilderTests.safe-managed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
            for: .antigravity,
            profile: .mcpSafeDefaults,
            availability: .none
        )

        XCTAssertEqual(summary.fileMutation, "Unavailable under Safe Managed")
        XCTAssertEqual(summary.shell, "Not launched")
        XCTAssertTrue(summary.externalMCP.contains("cannot be isolated"))
        XCTAssertTrue(summary.warnings.contains { $0.contains("disabled for Safe Managed") })
    }

    func testSandboxedAutoApproveCapabilitySummaryDisclosesGlobalMCPRisk() throws {
        let suiteName = "AntigravityArgumentBuilderTests.sandboxed-auto-approve.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let summary = AgentPermissionCapabilitySummaryBuilder(defaults: defaults).summary(
            for: .antigravity,
            profile: .providerOverride(.antigravity(.sandboxedAutoApprove)),
            availability: .none
        )

        XCTAssertEqual(summary.shell, "Antigravity terminal sandbox enabled")
        XCTAssertEqual(summary.externalMCP, "All configured MCP tools auto-approved")
        XCTAssertTrue(summary.warnings.contains { $0.contains("third-party MCP side effects") })
    }
}

@MainActor
final class AntigravityLegacySessionFenceTests: XCTestCase {
    private enum IDs {
        static let workspace = UUID(uuidString: "A6710000-0000-0000-0000-000000000001")!
        static let tab = UUID(uuidString: "A6710000-0000-0000-0000-000000000002")!
        static let session = UUID(uuidString: "A6710000-0000-0000-0000-000000000003")!
    }

    private static let legacyModelRaw = "legacy-antigravity-acp-model"
    private static let legacyProviderSessionID = "legacy-antigravity-acp-session"
    private static let legacyRequest = "legacy request"
    private static let legacyResponse = "legacy response"

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let session: AgentModeViewModel.TabSession
        let workspace: WorkspaceModel
        let workspaceManager: WorkspaceManagerViewModel
        let prompt: PromptViewModel
        let apiSettings: APISettingsViewModel
        let storageURL: URL
        let durableTranscript: AgentTranscript
    }

    func testHydratedLegacyAntigravitySessionReplaysHistoryWithoutForeignResumeHandle() async throws {
        try await withFixture { fixture in
            assertHydratedLegacyState(fixture)

            let message = fixture.viewModel.test_buildHeadlessAgentMessage(
                session: fixture.session,
                initialMessageForRun: "continue normally"
            )

            XCTAssertNil(message.resumeSessionID)
            XCTAssertTrue(message.userMessage.contains("<previous_conversation>"))
            XCTAssertTrue(message.userMessage.contains(Self.legacyRequest))
            XCTAssertTrue(message.userMessage.contains(Self.legacyResponse))
            XCTAssertTrue(message.userMessage.contains("<current_instruction>"))
            XCTAssertTrue(message.userMessage.contains("continue normally"))

            try await assertDurableLegacyStateUnchanged(fixture)
        }
    }

    func testHydratedLegacyAntigravityStagedHandoffBypassesHistoryWithoutForeignResumeHandle() async throws {
        try await withFixture { fixture in
            assertHydratedLegacyState(fixture)

            let handoffPayload = "<forked_session delivery_id=\"session-fence-red\">handoff sentinel</forked_session>"
            fixture.session.pendingHandoff.payload = handoffPayload
            let stagedMessage = fixture.viewModel.prependPendingHandoffIfNeeded(
                "continue from handoff",
                session: fixture.session
            )

            XCTAssertTrue(fixture.session.pendingHandoff.isStagedForSend)
            XCTAssertEqual(stagedMessage, handoffPayload + "\n\ncontinue from handoff")

            let message = fixture.viewModel.test_buildHeadlessAgentMessage(
                session: fixture.session,
                initialMessageForRun: stagedMessage
            )

            XCTAssertEqual(message.userMessage, stagedMessage)
            XCTAssertFalse(message.userMessage.contains("<previous_conversation>"))
            XCTAssertNil(message.resumeSessionID)

            try await assertDurableLegacyStateUnchanged(fixture)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture() async throws -> Fixture {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityLegacySessionFenceTests-\(UUID().uuidString)", isDirectory: true)
        var viewModelForCleanup: AgentModeViewModel?
        var workspaceManagerForCleanup: WorkspaceManagerViewModel?
        var apiSettingsForCleanup: APISettingsViewModel?

        do {
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

            let workspace = WorkspaceModel(
                id: IDs.workspace,
                name: "Antigravity legacy session fence",
                repoPaths: [],
                customStoragePath: storageURL,
                ephemeralFlag: true,
                composeTabs: [
                    ComposeTabState(
                        id: IDs.tab,
                        name: "Session fence",
                        activeAgentSessionID: IDs.session
                    )
                ],
                activeComposeTabID: IDs.tab
            )
            let savedTranscript = AgentTranscriptIO.importLegacyItems([
                .user(Self.legacyRequest, sequenceIndex: 0),
                .assistant(Self.legacyResponse, sequenceIndex: 1)
            ])
            let savedAt = Date(timeIntervalSinceReferenceDate: 1000)
            let persistedSession = AgentSession(
                id: IDs.session,
                workspaceID: IDs.workspace,
                composeTabID: IDs.tab,
                name: "Legacy Antigravity session",
                savedAt: savedAt,
                items: [],
                transcript: savedTranscript,
                itemCount: 2,
                transcriptProjectionCounts: AgentTranscriptProjectionBuilder.projectionCounts(for: savedTranscript),
                lastUserMessageAt: savedAt,
                agentKind: AgentProviderKind.antigravity.rawValue,
                agentModel: Self.legacyModelRaw,
                lastRunState: AgentSessionRunState.idle.rawValue,
                providerSessionID: Self.legacyProviderSessionID,
                autoEditEnabled: true
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persistedSession,
                for: workspace,
                preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: 2
            )
            let initiallyLoaded = try await AgentSessionDataService.shared.loadAgentSession(id: IDs.session, for: workspace)
            let initiallyReloaded = try XCTUnwrap(initiallyLoaded)
            let durableTranscript = try XCTUnwrap(initiallyReloaded.transcript)
            XCTAssertEqual(
                initiallyReloaded.workingSourceItems().map(\.text),
                [Self.legacyRequest, Self.legacyResponse]
            )

            let workspaceFiles = WorkspaceFilesViewModel()
            let keyManager = KeyManager(
                secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
            )
            let apiSettings = APISettingsViewModel(
                aiQueriesService: AIQueriesService(keyManager: keyManager),
                keyManager: keyManager,
                loadStoredDataOnInit: false
            )
            apiSettingsForCleanup = apiSettings
            let prompt = PromptViewModel(
                fileManager: workspaceFiles,
                apiSettingsViewModel: apiSettings,
                windowID: -671,
                settingsManager: WindowSettingsManager(windowID: -671)
            )
            let workspaceManager = WorkspaceManagerViewModel(
                fileManager: workspaceFiles,
                promptViewModel: prompt,
                performInitialWorkspaceActivation: false
            )
            workspaceManagerForCleanup = workspaceManager
            workspaceManager.workspaces = [workspace]
            workspaceManager.activeWorkspace = workspace

            let viewModel = AgentModeViewModel(
                testWindowID: -671,
                testWorkspacePath: storageURL.path,
                testWorkspaceDirectory: storageURL,
                applyEditsApprovalStore: ApplyEditsApprovalStore(),
                codexControllerFactory: { _, _, _, _, _, _ in
                    XCTFail("Codex controller factory must not be called")
                    return LifecycleNoopCodexController(recorder: LifecycleRecorder())
                },
                connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                mcpServerEnabler: { true }
            )
            viewModelForCleanup = viewModel
            viewModel.workspaceManager = workspaceManager
            viewModel.promptManager = prompt
            viewModel.test_setCurrentTabIDOverride(IDs.tab)

            let session = AgentModeViewModel.TabSession(tabID: IDs.tab)
            viewModel.test_installLiveSession(session)
            _ = try XCTUnwrap(
                viewModel.test_installPersistentSessionBinding(sessionID: IDs.session, on: session)
            )
            let hydratedSession = await viewModel.ensureSessionReady(tabID: IDs.tab)
            XCTAssertTrue(hydratedSession === session)

            return Fixture(
                viewModel: viewModel,
                session: hydratedSession,
                workspace: workspace,
                workspaceManager: workspaceManager,
                prompt: prompt,
                apiSettings: apiSettings,
                storageURL: storageURL,
                durableTranscript: durableTranscript
            )
        } catch {
            if let viewModelForCleanup {
                await viewModelForCleanup.prepareForWindowClose()
            }
            workspaceManagerForCleanup?.prepareForWindowClose()
            apiSettingsForCleanup?.prepareForWindowClose()
            try? FileManager.default.removeItem(at: storageURL)
            throw error
        }
    }

    private func assertHydratedLegacyState(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(fixture.session.hasLoadedPersistedState, file: file, line: line)
        XCTAssertEqual(fixture.session.activeAgentSessionID, IDs.session, file: file, line: line)
        XCTAssertEqual(fixture.session.selectedAgent, .antigravity, file: file, line: line)
        XCTAssertEqual(fixture.session.selectedModelRaw, Self.legacyModelRaw, file: file, line: line)
        XCTAssertEqual(fixture.session.providerSessionID, Self.legacyProviderSessionID, file: file, line: line)
        XCTAssertEqual(
            fixture.session.items.map(\.text),
            [Self.legacyRequest, Self.legacyResponse],
            file: file,
            line: line
        )
    }

    private func assertDurableLegacyStateUnchanged(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let loaded = try await AgentSessionDataService.shared.loadAgentSession(
            id: IDs.session,
            for: fixture.workspace
        )
        let reloaded = try XCTUnwrap(loaded, file: file, line: line)
        XCTAssertEqual(reloaded.agentModel, Self.legacyModelRaw, file: file, line: line)
        XCTAssertEqual(reloaded.transcript, fixture.durableTranscript, file: file, line: line)
        XCTAssertEqual(
            reloaded.workingSourceItems().map(\.text),
            [Self.legacyRequest, Self.legacyResponse],
            file: file,
            line: line
        )
    }

    private func cleanup(_ fixture: Fixture) async {
        await fixture.viewModel.prepareForWindowClose()
        fixture.workspaceManager.prepareForWindowClose()
        fixture.apiSettings.prepareForWindowClose()
        _ = fixture.prompt
        try? FileManager.default.removeItem(at: fixture.storageURL)
    }
}

/// Regression coverage for the Antigravity (`agy`) MCP client identity.
///
/// `MCPClientIdentity.canonicalFamilyID` matches the gemini-cli family *before* antigravity by
/// ordering (intentional — see the note in `MCPClientIdentity.swift`). These tests lock in that
/// the explicit "antigravity-client" hint RepoPrompt uses for PID-based routing canonicalizes to
/// the antigravity family and is recognized as a known headless agent client, independent of
/// whatever (possibly gemini-derived) name `agy` announces over MCP.
final class AntigravityMCPClientIdentityTests: XCTestCase {
    /// The hint RepoPrompt registers for agy (AgentProviderKind.antigravityMCPClientID).
    private let antigravityClientID = "antigravity-client"

    func testAntigravityClientCanonicalizesToAntigravityFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID(antigravityClientID), "antigravity-client")
    }

    func testBareAntigravityNameCanonicalizesToAntigravityFamily() {
        XCTAssertEqual(MCPClientIdentity.canonicalFamilyID("antigravity"), "antigravity-client")
    }

    func testAntigravityClientIsRecognizedAsHeadlessAgentClient() {
        XCTAssertTrue(MCPClientIdentity.isHeadlessAgentClient(antigravityClientID))
    }

    func testAntigravityClientIsNotMisclassifiedAsGeminiDespiteOrdering() {
        // Even though gemini-cli is matched before antigravity, the explicit "antigravity-client"
        // hint must not be swallowed by the gemini branch.
        XCTAssertNotEqual(MCPClientIdentity.canonicalFamilyID(antigravityClientID), "gemini-cli-mcp-client")
    }

    func testAntigravityClientMatchesItselfAndBareAntigravity() {
        XCTAssertTrue(MCPClientIdentity.matches(antigravityClientID, antigravityClientID))
        XCTAssertTrue(MCPClientIdentity.matches(antigravityClientID, "antigravity"))
        XCTAssertTrue(MCPClientIdentity.sameFamily(antigravityClientID, "antigravity"))
    }
}

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

final class AntigravityPollCapTimeoutTests: XCTestCase {
    func testDetectsStdoutTimedOutMarker() {
        XCTAssertTrue(AntigravityStreamParser.isPrintModePollCapTimeout(
            stdout: "I will read X.\nError: timed out waiting for response\n", logTail: nil
        ))
    }

    func testDetectsLogPollCapSignature() {
        XCTAssertTrue(AntigravityStreamParser.isPrintModePollCapTimeout(
            stdout: "", logTail: "printmode.go:289] Print mode: timed out after 1494 polls (printed=253)"
        ))
    }

    func testNormalOutputIsNotFlagged() {
        XCTAssertFalse(AntigravityStreamParser.isPrintModePollCapTimeout(
            stdout: "Here is the review:\n- looks good\n", logTail: "some normal log line"
        ))
    }

    // MARK: - Auto-resume decision

    func testResumesWhenCappedWithinBudget() {
        XCTAssertTrue(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 0, maxResumes: 6, hasConversationID: true))
        XCTAssertTrue(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 5, maxResumes: 6, hasConversationID: true))
    }

    func testDoesNotResumeWhenCompleted() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .completed, turn: 0, maxResumes: 6, hasConversationID: true))
    }

    func testDoesNotResumeWhenBudgetExhausted() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 6, maxResumes: 6, hasConversationID: true))
    }

    func testDoesNotResumeWhenDisabled() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 0, maxResumes: 0, hasConversationID: true))
    }

    func testDoesNotResumeWithoutConversationID() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(outcome: .capped, turn: 0, maxResumes: 6, hasConversationID: false))
    }

    func testClassifiesResumedEmptyOutputAsIncomplete() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data(), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .incomplete)
    }

    func testClassifiesNonEmptyOutputAsCompleted() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("final answer".utf8), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .completed)
    }

    func testClassifiesPollCapOutputAsCapped() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("Error: timed out waiting for response\n".utf8),
            logTail: nil,
            isFirstTurn: false
        )

        XCTAssertEqual(outcome, .capped)
    }

    func testHeadlessPermissionDenialWinsOverPartialOutputAndPollCap() {
        let rawLog = """
        I0718 tool_confirmation_manager.go:183] Print mode: soft-denying tool confirmation \"McpTool\" at step 3
        I0718 http_helpers.go:228] URL: https://private.invalid/path Trace: secret-trace
        """

        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("partial answer\nError: timed out waiting for response\n".utf8),
            stderr: nil,
            logTail: rawLog,
            isFirstTurn: true
        )) { error in
            guard case let AIProviderError.invalidConfiguration(detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(detail, AntigravityAgentProvider.headlessPermissionDenialMessage)
            XCTAssertFalse(detail.contains("private.invalid"))
            XCTAssertFalse(detail.contains("secret-trace"))
        }
    }

    func testDetectsHeadlessPermissionDenialFromStderr() {
        let stderr = "The tool required approval that headless mode cannot prompt for, so it was auto-denied."

        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("partial answer".utf8),
            stderr: stderr,
            logTail: nil,
            isFirstTurn: false
        )) { error in
            XCTAssertEqual(error.localizedDescription, AntigravityAgentProvider.headlessPermissionDenialMessage)
        }
    }

    func testDetectsVersionVaryingPermissionDenialSignatures() {
        let diagnostics = [
            "Tool confirmation for conversation abc step 3 (type=McpTool approved=false)",
            "user denied permission for mcp(RepoPromptCE)"
        ]

        for diagnostic in diagnostics {
            XCTAssertTrue(
                AntigravityAgentProvider.isHeadlessPermissionDenial(
                    stderr: nil,
                    logTail: diagnostic
                ),
                "Expected denial signature to match: \(diagnostic)"
            )
        }
    }

    func testProcessFailureRecognizesSoftDeniedSuccessfulExit() {
        let rawLog = """
        I0718 tool_confirmation_manager.go:183] Print mode: soft-denying tool confirmation \"McpTool\" at step 3
        I0718 http_helpers.go:228] URL: https://private.invalid/path Trace: secret-trace
        """

        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 0,
            timedOut: false,
            stderr: "",
            logTail: rawLog
        )

        XCTAssertEqual(error?.localizedDescription, AntigravityAgentProvider.headlessPermissionDenialMessage)
        XCTAssertFalse(error?.localizedDescription.contains("private.invalid") == true)
        XCTAssertFalse(error?.localizedDescription.contains("secret-trace") == true)
    }

    func testFirstTurnEmptySuccessReturnsActionableError() {
        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data(),
            logTail: nil,
            isFirstTurn: true
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Antigravity CLI returned no meaningful output. Ensure you are signed in by running `agy` once interactively."
            )
        }
    }

    func testFirstTurnEmptyOutputWithOrdinaryLogRemainsNoOutputError() {
        XCTAssertThrowsError(try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data(" \n\t".utf8),
            logTail: "I0718 manager.go:1095] Slash commands unchanged, skipping update",
            isFirstTurn: true
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Antigravity CLI returned no meaningful output. Ensure you are signed in by running `agy` once interactively."
            )
            XCTAssertNotEqual(error.localizedDescription, AntigravityAgentProvider.headlessPermissionDenialMessage)
        }
    }

    func testTimeoutWithoutPermissionDenialRemainsTimeout() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 0,
            timedOut: true,
            stderr: "ordinary diagnostic",
            logTail: nil
        )

        XCTAssertEqual(error?.localizedDescription, "Antigravity CLI timed out.")
    }

    func testWhitespaceOnlyOutputIsIncompleteOnResume() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data("  \n\t".utf8), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .incomplete)
    }

    func testInvalidUTF8IsNotSuccessfulCompletion() throws {
        let outcome = try AntigravityAgentProvider.classifySuccessfulTurn(
            stdoutData: Data([0xFF, 0xFE]), logTail: nil, isFirstTurn: false
        )

        XCTAssertEqual(outcome, .incomplete)
    }

    func testMissingTerminationStatusIsAnError() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: nil,
            timedOut: false,
            stderr: "",
            logTail: nil
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(error?.localizedDescription.contains("without reporting an exit status") == true)
    }

    func testNonzeroFailureDoesNotExposeRawDiagnostics() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 1,
            timedOut: false,
            stderr: "request failed for https://private.invalid Trace: secret-trace",
            logTail: "internal state"
        )

        XCTAssertEqual(error?.localizedDescription, "Antigravity CLI failed (exit 1). Run `agy` interactively to inspect the failure.")
        XCTAssertFalse(error?.localizedDescription.contains("private.invalid") == true)
        XCTAssertFalse(error?.localizedDescription.contains("secret-trace") == true)
    }

    func testFinalContextLossErrorPrecedence() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 1,
            timedOut: false,
            stderr: "private upstream diagnostics",
            logTail: nil,
            trajectoryFailureKind: .conversationContextLost
        )

        XCTAssertEqual(error?.localizedDescription, AntigravityAgentProvider.conversationContextLostMessage)
        XCTAssertFalse(error?.localizedDescription.contains("private upstream diagnostics") == true)

        let permissionError = AIProviderError.invalidConfiguration(
            detail: AntigravityAgentProvider.headlessPermissionDenialMessage
        )
        XCTAssertEqual(
            AntigravityAgentProvider.terminalError(
                permissionError,
                finalTrajectoryFailureKind: .conversationContextLost
            ).localizedDescription,
            AntigravityAgentProvider.headlessPermissionDenialMessage
        )

        let timeoutError = AIProviderError.invalidConfiguration(detail: "Antigravity CLI timed out.")
        XCTAssertEqual(
            AntigravityAgentProvider.terminalError(
                timeoutError,
                finalTrajectoryFailureKind: .conversationContextLost
            ).localizedDescription,
            "Antigravity CLI timed out."
        )
    }

    func testContextLossOverridesPartialOutputAndSuccessfulExit() {
        XCTAssertThrowsError(try AntigravityAgentProvider.classifyTurn(
            exitStatus: 0,
            timedOut: false,
            stdoutData: Data("I will inspect the requested files.".utf8),
            stderr: "",
            logTail: nil,
            isFirstTurn: true,
            trajectoryFailureKind: .conversationContextLost
        )) { error in
            XCTAssertEqual(error.localizedDescription, AntigravityAgentProvider.conversationContextLostMessage)
        }
    }

    func testQuotaExhaustionReportsResetDelayWithoutRawDiagnostics() {
        let stderr = """
        error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 100h47m55s.
        AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached.","status":"RESOURCE_EXHAUSTED","error_code":429,"error_id":"secret-error-id","url":"https://private.invalid/quota"}
        """
        let logTail = """
        E1007 errorreport.go:224] error getting token source: You are not logged into Antigravity.
        E1007 errorreport.go:224] agent executor error: generating and executing: RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 100h47m55s.
        """

        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 3,
            timedOut: false,
            stderr: stderr,
            logTail: logTail
        )

        XCTAssertEqual(
            error?.localizedDescription,
            "Antigravity CLI quota is exhausted for the selected model. Quota resets in 100h47m55s. Upgrade the subscription or wait for the reset, then retry."
        )
        let description = error?.localizedDescription ?? ""
        XCTAssertFalse(description.contains("secret-error-id"))
        XCTAssertFalse(description.contains("private.invalid"))
        XCTAssertFalse(description.contains("not authenticated"))
        XCTAssertFalse(description.contains("exit 3"))
    }

    func testQuotaExhaustionWithoutResetHintOmitsDelay() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 3,
            timedOut: false,
            stderr: "RESOURCE_EXHAUSTED (code 429): Individual quota reached.",
            logTail: "https://private.invalid Trace: secret-trace"
        )

        XCTAssertEqual(error?.localizedDescription, AntigravityAgentProvider.quotaExhaustedMessage)
        XCTAssertFalse(error?.localizedDescription.contains("private.invalid") == true)
        XCTAssertFalse(error?.localizedDescription.contains("secret-trace") == true)
        XCTAssertFalse(error?.localizedDescription.contains("Resets in") == true)
    }

    func testQuotaResetDelayAcceptsOnlyDurationTokens() {
        XCTAssertEqual(
            AntigravityAgentProvider.quotaResetDelay(in: "Resets in 100h47m55s."),
            "100h47m55s"
        )
        XCTAssertEqual(AntigravityAgentProvider.quotaResetDelay(in: "resets in 12m"), "12m")
        XCTAssertNil(AntigravityAgentProvider.quotaResetDelay(in: "Individual quota reached. Resets in soon."))
        XCTAssertNil(AntigravityAgentProvider.quotaResetDelay(in: "Resets in 100"))
    }

    func testInformationalTokenSourceDoesNotImplyAuthenticationFailure() {
        let error = AntigravityAgentProvider.processFailure(
            exitStatus: 17,
            timedOut: false,
            stderr: "Auto-saving refreshed token from token source callback",
            logTail: nil
        )

        XCTAssertEqual(
            error?.localizedDescription,
            "Antigravity CLI failed (exit 17). Run `agy` interactively to inspect the failure."
        )
    }

    func testResumesIncompleteTurnWhenConversationIDIsAvailable() {
        XCTAssertTrue(AntigravityAgentProvider.shouldResume(
            outcome: .incomplete, turn: 0, maxResumes: 6, hasConversationID: true
        ))
    }

    func testDoesNotResumeIncompleteTurnWithoutConversationID() {
        XCTAssertFalse(AntigravityAgentProvider.shouldResume(
            outcome: .incomplete, turn: 0, maxResumes: 6, hasConversationID: false
        ))
    }

    func testExhaustedMessageMentionsResumeCountWhenEnabled() {
        let msg = AntigravityAgentProvider.cappedExhaustedMessage(maxResumes: 6, resumed: 6)
        XCTAssertTrue(msg.contains("6 auto-resume"))
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("split"))
    }

    func testIncompleteExhaustedMessageDoesNotBlamePrintCap() {
        let msg = AntigravityAgentProvider.incompleteExhaustedMessage(maxResumes: 6, resumed: 6)

        XCTAssertTrue(msg.contains("6 auto-resume"))
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("without printing a final response"))
        XCTAssertFalse(msg.contains("1494 polls"))
    }

    func testExhaustedMessageWhenResumeDisabled() {
        let msg = AntigravityAgentProvider.cappedExhaustedMessage(maxResumes: 0, resumed: 0)
        XCTAssertTrue(msg.contains("1494 polls"))
    }
}

final class AntigravityPromptContractTests: XCTestCase {
    func testCombinedPromptIncludesAsyncCommandCompletionGuidance() {
        let prompt = AntigravityAgentProvider.combinedPrompt(
            system: "System instructions",
            user: "Run focused tests."
        )

        XCTAssertTrue(prompt.contains("Tests and shell commands are allowed"))
        XCTAssertTrue(prompt.contains("background or async task"))
        XCTAssertTrue(prompt.contains("do not end the turn"))
        XCTAssertTrue(prompt.contains("final output and exit status"))
        XCTAssertTrue(prompt.contains("verification is still pending or unavailable"))
    }

    func testCombinedPromptKeepsUserRequestAfterGuidance() throws {
        let user = "Reply exactly RPCE_AGY_OK."
        let prompt = AntigravityAgentProvider.combinedPrompt(
            system: "System instructions",
            user: user
        )

        XCTAssertTrue(prompt.hasSuffix(user))
        XCTAssertLessThan(
            try XCTUnwrap(prompt.range(of: AntigravityAgentProvider.executionCompletionGuidance)?.lowerBound),
            try XCTUnwrap(prompt.range(of: user)?.lowerBound)
        )
    }

    func testCombinedPromptIncludesGuidanceWithoutSystemPrompt() {
        let user = "Run /usr/bin/true."
        let prompt = AntigravityAgentProvider.combinedPrompt(system: "", user: user)

        XCTAssertTrue(prompt.contains(AntigravityAgentProvider.executionCompletionGuidance))
        XCTAssertTrue(prompt.hasSuffix(user))
    }
}

/// Contract: an `AntigravityRunGate` instance (one per provider, so one per run) parks a second
/// `lock()` FIFO, and cancellation/replacement/disposal must either atomically transfer ownership to
/// a registered producer or release the gate without launching stale work. Cross-run independence
/// is pinned in `AntigravityAgentProviderRunGateScopeTests`.
final class AntigravityRunGateTests: XCTestCase {
    private actor EventLog {
        private(set) var events: [String] = []
        func append(_ event: String) {
            events.append(event)
        }
    }

    private actor AsyncBarrier {
        private(set) var isPaused = false
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            isPaused = true
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testSecondAcquirerParksUntilUnlock() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock() // first holder owns the gate

        let log = EventLog()
        let second = Task {
            try await gate.lock()
            await log.append("acquired")
            await gate.unlock()
        }

        // Deterministically wait until `second` is parked on the gate (no sleep): observe the
        // actual waiter count rather than guessing a delay.
        try await AsyncTestWait.waitUntil("second Antigravity run queued") {
            await gate.waiterCount == 1
        }

        // Holder still owns the gate, so the waiter must not have acquired yet.
        let beforeRelease = await log.events
        XCTAssertEqual(beforeRelease, [], "second acquirer must park while the gate is held")

        await log.append("released")
        await gate.unlock() // wake the parked waiter
        try await second.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["released", "acquired"],
            "the waiter must proceed only after the holder releases"
        )

        // Gate is reusable after the waiter cycle completes (no permanent lock).
        try await gate.lock()
        let parkedAfterReuse = await gate.waiterCount
        await gate.unlock()
        XCTAssertEqual(parkedAfterReuse, 0, "an uncontended re-lock must acquire immediately")
    }

    func testCancelledWaiterIsRemovedWithoutReleasingHolder() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock()

        let cancellationFinished = expectation(description: "queued acquisition cancelled")
        let waiter = Task { () -> String in
            defer { cancellationFinished.fulfill() }
            do {
                try await gate.lock()
                await gate.unlock()
                return "acquired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected: \(error.localizedDescription)"
            }
        }

        try await AsyncTestWait.waitUntil("cancelled Antigravity run queued") {
            await gate.waiterCount == 1
        }
        waiter.cancel()
        await fulfillment(of: [cancellationFinished], timeout: 1)

        let waiterCountAfterCancellation = await gate.waiterCount
        let isLockedAfterCancellation = await gate.isLocked
        XCTAssertEqual(waiterCountAfterCancellation, 0, "cancelled work must leave the FIFO queue promptly")
        XCTAssertTrue(isLockedAfterCancellation, "cancelling a waiter must not release the current holder")

        await gate.unlock()
        let waiterResult = await waiter.value
        let isLockedAfterUnlock = await gate.isLocked
        XCTAssertEqual(waiterResult, "cancelled")
        XCTAssertFalse(isLockedAfterUnlock)

        try await gate.lock()
        let isLockedAfterReuse = await gate.isLocked
        XCTAssertTrue(isLockedAfterReuse, "the gate must remain reusable after waiter cancellation")
        await gate.unlock()
    }

    func testCancellationAfterGateHandoffReleasesPermitBeforeStreamTransfer() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock()
        let beforeCancellationCheck = AsyncBarrier()

        let acquirer = Task { () -> Bool in
            do {
                try await AntigravityAgentProvider.acquireRunGate(
                    gate,
                    beforeCancellationCheck: { await beforeCancellationCheck.pause() }
                )
                await gate.unlock()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        try await AsyncTestWait.waitUntil("Antigravity stream acquisition queued") {
            await gate.waiterCount == 1
        }
        await gate.unlock()
        try await AsyncTestWait.waitUntil("Antigravity stream acquired gate before cancellation check") {
            await beforeCancellationCheck.isPaused
        }

        acquirer.cancel()
        await beforeCancellationCheck.release()

        let acquisitionWasCancelled = await acquirer.value
        let isLockedAfterCancellation = await gate.isLocked
        XCTAssertTrue(acquisitionWasCancelled, "cancellation after FIFO handoff must abort stream creation")
        XCTAssertFalse(isLockedAfterCancellation, "the cancelled acquirer must release its transferred permit")

        try await gate.lock()
        let isLockedAfterReuse = await gate.isLocked
        XCTAssertTrue(isLockedAfterReuse, "the gate must remain reusable after transfer cancellation")
        await gate.unlock()
    }

    func testNewerStreamRequestSupersedesWaiterAndReleasesHandoffPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let waiter = Task { () -> Bool in
            do {
                try await AntigravityAgentProvider.acquireRunGate(
                    gate,
                    requestIsCurrent: {
                        await requests.isCurrent(pendingRequest)
                    }
                )
                await gate.unlock()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("pending Antigravity stream creation queued") {
                await gate.waiterCount == 1
            }
        } catch {
            waiter.cancel()
            await gate.unlock()
            _ = await waiter.value
            throw error
        }

        let replacementRequest = await requests.begin()
        let pendingIsCurrent = await requests.isCurrent(pendingRequest)
        let replacementIsCurrent = await requests.isCurrent(replacementRequest)
        XCTAssertFalse(pendingIsCurrent)
        XCTAssertTrue(replacementIsCurrent)
        await gate.unlock()

        let pendingWasSuperseded = await waiter.value
        let gateIsLockedAfterSupersession = await gate.isLocked
        XCTAssertTrue(pendingWasSuperseded)
        XCTAssertFalse(gateIsLockedAfterSupersession, "the stale waiter must release the handed-off permit")

        try await gate.lock()
        let gateIsLockedAfterReuse = await gate.isLocked
        XCTAssertTrue(gateIsLockedAfterReuse, "the replacement must be able to acquire immediately")
        await gate.unlock()
    }

    func testReplacementCannotAcquireUntilPriorRunCleanupFinishes() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock()
        let cleanupBarrier = AsyncBarrier()
        let log = EventLog()

        let releaseTask = Task {
            await AntigravityAgentProvider.releaseRunGateAfterCleanup(gate) {
                await log.append("cleanup-started")
                await cleanupBarrier.pause()
                await log.append("cleanup-finished")
            }
        }
        try await AsyncTestWait.waitUntil("Antigravity cleanup paused while holding gate") {
            await cleanupBarrier.isPaused
        }

        let replacement = Task {
            try await gate.lock()
            await log.append("replacement-acquired")
            await gate.unlock()
        }
        try await AsyncTestWait.waitUntil("replacement Antigravity run queued during cleanup") {
            await gate.waiterCount == 1
        }
        let eventsWhileCleanupPaused = await log.events
        XCTAssertEqual(eventsWhileCleanupPaused, ["cleanup-started"])

        await cleanupBarrier.release()
        await releaseTask.value
        try await replacement.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["cleanup-started", "cleanup-finished", "replacement-acquired"],
            "gate handoff must occur only after all predecessor cleanup"
        )
    }

    func testReplacementDuringProducerActivationPreventsLateLaunchAndReleasesPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let activationBarrier = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: pendingRequest,
                    runGate: gate,
                    beforeActivation: { await activationBarrier.pause() }
                ) {
                    await log.append("stale-producer-launched")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer activation paused") {
                await activationBarrier.isPaused
            }
        } catch {
            activation.cancel()
            await activationBarrier.release()
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let replacementRequest = await requests.begin()
        await activationBarrier.release()

        let activationWasCancelled = await activation.value
        let events = await log.events
        let pendingIsCurrent = await requests.isCurrent(pendingRequest)
        let replacementIsCurrent = await requests.isCurrent(replacementRequest)
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, [])
        XCTAssertFalse(pendingIsCurrent)
        XCTAssertTrue(replacementIsCurrent)
        XCTAssertFalse(gateIsLocked, "stale activation must release the permit it never transferred")

        try await gate.lock()
        await gate.unlock()
    }

    func testInvalidationDuringProducerActivationPreventsLateLaunchAndReleasesPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let activationBarrier = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: pendingRequest,
                    runGate: gate,
                    beforeActivation: { await activationBarrier.pause() }
                ) {
                    await log.append("disposed-producer-launched")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer activation paused before invalidation") {
                await activationBarrier.isPaused
            }
        } catch {
            activation.cancel()
            await activationBarrier.release()
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let producerAtInvalidation = await requests.invalidate()
        XCTAssertNil(producerAtInvalidation, "a pending activation must not pretend to own a producer")
        await activationBarrier.release()

        let activationWasCancelled = await activation.value
        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, [])
        XCTAssertFalse(gateIsLocked, "disposal invalidation must make the pending owner release its permit")

        try await gate.lock()
        await gate.unlock()
    }

    func testCallerCancellationDuringProducerActivationPreventsLateLaunchAndReleasesPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let activationBarrier = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: pendingRequest,
                    runGate: gate,
                    beforeActivation: { await activationBarrier.pause() }
                ) {
                    await log.append("cancelled-producer-launched")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer activation paused before caller cancellation") {
                await activationBarrier.isPaused
            }
        } catch {
            activation.cancel()
            await activationBarrier.release()
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        activation.cancel()
        await activationBarrier.release()

        let activationWasCancelled = await activation.value
        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, [])
        XCTAssertFalse(gateIsLocked, "cancelled activation must release the permit it never transferred")

        try await gate.lock()
        await gate.unlock()
    }

    func testInvalidationCancelsAndJoinsRegisteredProducerCleanup() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let log = EventLog()
        try await gate.lock()
        let request = await requests.begin()

        let producer = try await AntigravityAgentProvider.activateProducer(
            requests: requests,
            request: request,
            runGate: gate
        ) {
            await log.append("producer-started")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            await log.append("producer-cleaned")
            await gate.unlock()
        }
        do {
            try await AsyncTestWait.waitUntil("registered Antigravity producer started") {
                await log.events == ["producer-started"]
            }
        } catch {
            let producerAtFailure = await requests.invalidate()
            await producerAtFailure?.value
            await producer.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let producerAtInvalidation = await requests.invalidate()
        XCTAssertNotNil(producerAtInvalidation)
        await producerAtInvalidation?.value

        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertEqual(events, ["producer-started", "producer-cleaned"])
        XCTAssertFalse(gateIsLocked, "joined producer cleanup must release its transferred permit")
        await producer.value

        try await gate.lock()
        await gate.unlock()
    }

    func testCallerCancellationAfterProducerActivationCancelsAndJoinsProducer() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let afterActivation = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let request = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: request,
                    runGate: gate,
                    afterActivation: { await afterActivation.pause() }
                ) {
                    await log.append("producer-started")
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {}
                    await log.append("producer-cleaned")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer registered before caller cancellation") {
                let isPaused = await afterActivation.isPaused
                let events = await log.events
                return isPaused && events == ["producer-started"]
            }
        } catch {
            activation.cancel()
            await afterActivation.release()
            let disposalTasks = await requests.beginDisposal()
            await Self.join(disposalTasks)
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        activation.cancel()
        let disposalTasks = await requests.beginDisposal()
        await afterActivation.release()
        let activationWasCancelled = await activation.value
        await Self.join(disposalTasks)

        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, ["producer-started", "producer-cleaned"])
        XCTAssertFalse(gateIsLocked)
    }

    func testDisposalCancelsAndJoinsRequestQueuedAtRunGate() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        try await gate.lock() // unrelated holder keeps the request queued

        let request = await requests.startRequest { token in
            try await AntigravityAgentProvider.acquireRunGate(
                gate,
                requestIsCurrent: { await requests.isCurrent(token) }
            )
            await gate.unlock()
            return Self.finishedStream()
        }
        XCTAssertNotNil(request)

        do {
            try await AsyncTestWait.waitUntil("Antigravity request queued before disposal") {
                await gate.waiterCount == 1
            }
        } catch {
            let disposalTasks = await requests.beginDisposal()
            await Self.join(disposalTasks)
            await gate.unlock()
            throw error
        }

        let disposalTasks = await requests.beginDisposal()
        await Self.join(disposalTasks)

        let waiterCount = await gate.waiterCount
        let holderStillOwnsGate = await gate.isLocked
        XCTAssertEqual(waiterCount, 0, "disposal must cancel the exact queued gate waiter")
        XCTAssertTrue(holderStillOwnsGate, "cancelling the queued request must not release another holder")
        await gate.unlock()
    }

    func testDisposalCancelsAndJoinsRequestDuringGateHandoff() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let handoffBarrier = AsyncBarrier()
        try await gate.lock()

        let request = await requests.startRequest { token in
            try await AntigravityAgentProvider.acquireRunGate(
                gate,
                beforeCancellationCheck: { await handoffBarrier.pause() },
                requestIsCurrent: { await requests.isCurrent(token) }
            )
            await gate.unlock()
            return Self.finishedStream()
        }
        XCTAssertNotNil(request)

        do {
            try await AsyncTestWait.waitUntil("Antigravity disposal handoff request queued") {
                await gate.waiterCount == 1
            }
            await gate.unlock()
            try await AsyncTestWait.waitUntil("Antigravity disposal request owns handoff permit") {
                await handoffBarrier.isPaused
            }
        } catch {
            await handoffBarrier.release()
            let disposalTasks = await requests.beginDisposal()
            await Self.join(disposalTasks)
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let disposalTasks = await requests.beginDisposal()
        await handoffBarrier.release()
        await Self.join(disposalTasks)

        let gateIsLocked = await gate.isLocked
        XCTAssertFalse(gateIsLocked, "cancelled handoff owner must release its transferred permit")
        try await gate.lock()
        await gate.unlock()
    }

    func testTerminationCancelsOnlyItsExactProducerAndOnlyWhenConsumerCancels() async {
        let firstProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let replacementProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }

        AntigravityAgentProvider.handleTermination(.cancelled, producerTask: firstProducer)

        XCTAssertTrue(firstProducer.isCancelled)
        XCTAssertFalse(replacementProducer.isCancelled, "an old continuation must not cancel its replacement")

        AntigravityAgentProvider.handleTermination(.finished(nil), producerTask: replacementProducer)
        XCTAssertFalse(replacementProducer.isCancelled, "producer completion must not self-cancel and start cancellation cleanup")

        replacementProducer.cancel()
        await firstProducer.value
        await replacementProducer.value
    }

    private static func finishedStream() -> AsyncThrowingStream<AIStreamResult, Error> {
        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        continuation.finish()
        return stream
    }

    private static func join(_ disposalTasks: AntigravityStreamRequestCoordinator.DisposalTasks) async {
        for requestTask in disposalTasks.requests {
            _ = await requestTask.result
        }
        for producerTask in disposalTasks.producers {
            await producerTask.value
        }
    }
}
