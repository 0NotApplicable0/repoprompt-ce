import Foundation

/// Provider-local authority for stream creation and producer ownership. A replacement request can
/// arrive while its predecessor is still preparing, parked on the app-wide AGY run gate, or between
/// gate acquisition and producer activation. Keeping the generation and exact producer task in one
/// actor makes those transitions atomic: invalidation can never miss a producer that activates later.
actor AntigravityStreamRequestCoordinator {
    typealias Stream = AsyncThrowingStream<AIStreamResult, Error>

    struct Token: Equatable {
        fileprivate let value: UInt64
    }

    struct Request {
        let token: Token
        let task: Task<Stream, Error>
    }

    struct DisposalTasks {
        let requests: [Task<Stream, Error>]
        let producers: [Task<Void, Never>]
    }

    private var generation: UInt64 = 0
    private var requestTasks: [UInt64: Task<Stream, Error>] = [:]
    private var producerTasks: [UInt64: Task<Void, Never>] = [:]
    private var isDisposed = false

    func begin() -> Token {
        cancelOutstandingTasks()
        generation &+= 1
        return Token(value: generation)
    }

    /// Creates and registers the entire preparation/gate/handoff request in one actor turn. Disposal
    /// can therefore cancel a task parked on the run gate and join it before returning.
    func startRequest(
        operation: @escaping @Sendable (Token) async throws -> Stream
    ) -> Request? {
        guard !isDisposed, !Task.isCancelled else { return nil }
        let token = begin()
        let task = Task<Stream, Error> { [weak self] in
            do {
                let stream = try await operation(token)
                await self?.requestDidFinish(token)
                return stream
            } catch {
                await self?.requestDidFinish(token)
                throw error
            }
        }
        requestTasks[token.value] = task
        return Request(token: token, task: task)
    }

    /// Focused activation-test invalidation. Production disposal uses `beginDisposal()` so every
    /// retained request and producer can be joined.
    func invalidate() -> Task<Void, Never>? {
        generation &+= 1
        cancelOutstandingTasks()
        return producerTasks.values.first
    }

    func beginDisposal() -> DisposalTasks {
        isDisposed = true
        generation &+= 1
        cancelOutstandingTasks()
        return DisposalTasks(
            requests: Array(requestTasks.values),
            producers: Array(producerTasks.values)
        )
    }

    /// Invalidates `token` only while it is still the current request. A stale caller must never
    /// cancel a replacement request or producer.
    func cancel(_ token: Token) {
        guard token.value == generation else { return }
        generation &+= 1
        requestTasks[token.value]?.cancel()
        producerTasks[token.value]?.cancel()
    }

    func isCurrent(_ token: Token) -> Bool {
        !isDisposed && token.value == generation
    }

    /// Atomically validates the request and installs its producer. Because the task is created on
    /// this actor and the actor does not suspend before storing it, replacement/disposal either sees
    /// the producer or makes activation fail; there is no unowned producer window.
    func activate(
        _ token: Token,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !isDisposed, token.value == generation, !Task.isCancelled else { return nil }
        let task = Task { [weak self] in
            await operation()
            await self?.producerDidFinish(token)
        }
        producerTasks[token.value] = task
        return task
    }

    private func requestDidFinish(_ token: Token) {
        requestTasks[token.value] = nil
    }

    private func producerDidFinish(_ token: Token) {
        producerTasks[token.value] = nil
    }

    private func cancelOutstandingTasks() {
        for request in requestTasks.values {
            request.cancel()
        }
        for producer in producerTasks.values {
            producer.cancel()
        }
    }
}

/// Headless provider for Google's Antigravity CLI (`agy`).
///
/// `agy` exposes a one-shot headless mode (`--print <prompt>`) that prints a plain-text
/// response on stdout (no JSON/streaming flag). This provider mirrors the
/// mechanics of `CodexExecAgentProvider` — a plain, non-ACP `HeadlessAgentProvider` — but is
/// intentionally simpler: it accumulates stdout, parses it tolerantly into content, and
/// synthesizes a `message_stop`. RepoPrompt MCP tool calls surface via
/// `AgentToolTrackingController` plus expected-PID routing (the MCP server attributes calls by
/// the spawned process id), not via stdout parsing.
///
/// Authentication is the user's responsibility: a prior interactive `agy` sign-in (Google
/// OAuth, stored under `~/.gemini`) is required. RepoPrompt injects no credentials; the parent
/// process environment is passed through unchanged.
final class AntigravityAgentProvider: HeadlessAgentProvider {
    private static let antigravityMCPClientID = AgentProviderKind.antigravityMCPClientID
    /// Generous one-shot process timeout. `agy`'s own `--print-timeout` is set slightly lower
    /// so the CLI reports a clean timeout before the runner force-kills the process.
    private static let processTimeoutSeconds: TimeInterval = 3900
    private static let printTimeoutSeconds = 3600

    private let runner: CLIProcessRunner
    private let config: AntigravityAgentConfig
    private let workspacePath: String?
    private let toolTracking = AgentToolTrackingController()
    private let streamRequests = AntigravityStreamRequestCoordinator()

    private var enableDebugLogging: Bool {
        config.enableDebugLogging
    }

    init(runner: CLIProcessRunner, config: AntigravityAgentConfig, workspacePath: String? = nil) {
        self.runner = runner
        self.config = config
        self.workspacePath = workspacePath
    }

    // MARK: - Argument construction

    /// `agy` has no system-prompt channel; combine the system prompt and user message into the
    /// single `--print` value with an explicit blank-line delimiter.
    static let executionCompletionGuidance = """
    Antigravity execution guidance:
    - Tests and shell commands are allowed when they are relevant to the task.
    - If a tool, command, or test starts as a background or async task, do not end the turn by \
    saying you will stop calling tools and wait for it to complete.
    - Before giving a final response, wait for, poll, or otherwise retrieve the command's final \
    output and exit status.
    - If the final command output cannot be retrieved, say verification is still pending or \
    unavailable instead of presenting the task as complete.
    """

    static func combinedPrompt(system: String, user: String) -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else {
            return """
            \(Self.executionCompletionGuidance)

            \(user)
            """
        }
        return """
        \(trimmedSystem)

        \(Self.executionCompletionGuidance)

        \(user)
        """
    }

    /// Max prompt size (UTF-8 bytes) to inline as the `--print <prompt>` argv value.
    ///
    /// `agy` honors `--model` only when the prompt is the `--print` *argument value*; when the
    /// prompt arrives via a bare `--print` + STDIN, `agy` silently drops `--model` and falls back
    /// to its persisted current-session model (verified against `agy` v1.0.10). So the prompt is
    /// inlined into argv to make model selection work — but only while it fits comfortably under
    /// macOS `ARG_MAX` (1 MiB total for argv + the inherited environment). Prompts larger than
    /// this fall back to STDIN, where `agy` ignores the model but the run still proceeds instead
    /// of failing with `E2BIG`. The margin below `ARG_MAX` covers the environment block and the
    /// remaining flags.
    static let maxInlinePromptBytes = 256 * 1024

    /// Whether `prompt` is small enough to inline as the `--print` argv value (honoring `--model`)
    /// rather than delivering it over STDIN. Measured in UTF-8 bytes, matching the argv encoding.
    static func shouldInlinePrompt(_ prompt: String) -> Bool {
        prompt.utf8.count <= maxInlinePromptBytes
    }

    /// Build the `agy` argv.
    ///
    /// When `inlinePrompt` is non-nil the prompt is delivered as the `--print` argument value
    /// (`agy --print <prompt> ...`), which is the only invocation form where `agy` honors
    /// `--model` — a bare `--print` reading the prompt from STDIN makes `agy` ignore the requested
    /// model. When `inlinePrompt` is nil the prompt is delivered over STDIN instead (bare
    /// `--print`), used for prompts too large to inline safely under `ARG_MAX`. All values are
    /// passed via argv (posix_spawn, no shell) so they are safe from shell interpretation.
    static func buildArguments(
        config: AntigravityAgentConfig,
        workspacePath: String?,
        logFilePath: String?,
        resumeConversationID: String? = nil,
        inlinePrompt: String? = nil
    ) -> [String] {
        var args = ["--print"]
        if let inlinePrompt {
            args.append(inlinePrompt)
        }
        if let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty, model.lowercased() != "default"
        {
            args += ["--model", model]
        }
        if let workspacePath, !workspacePath.isEmpty {
            args += ["--add-dir", workspacePath]
        }
        // These flags control independent boundaries. The sandbox restricts terminal access;
        // skip-permissions is an explicit opt-in required only for unattended tool approvals.
        if config.useSandbox {
            args.append("--sandbox")
        }
        if config.dangerouslySkipPermissions {
            args.append("--dangerously-skip-permissions")
        }
        args += ["--print-timeout", "\(printTimeoutSeconds)s"]
        // Resume turns chain the same conversation so a long run continues across poll budgets;
        // `agy --print --conversation <id>` resumes it with a fresh ~1494-poll budget.
        if let resumeConversationID, !resumeConversationID.isEmpty {
            args += ["--conversation", resumeConversationID]
        }
        if let logFilePath, !logFilePath.isEmpty {
            args += ["--log-file", logFilePath]
        }
        return args
    }

    // MARK: - Preparation

    static func mcpPreparationFailureMessage(
        for result: MCPIntegrationHelper.AntigravityInstallResult
    ) -> String? {
        guard !result.success else { return nil }
        return result.failureMessage
            ?? "Failed to install RepoPrompt MCP config for Antigravity CLI."
    }

    static let safeManagedUnavailableMessage = "Antigravity cannot run under Safe Managed because its global MCP configuration and persisted tool grants cannot be isolated per run. In Sub-agent Permissions, choose Custom per provider or Inherit provider settings, then select an explicit Antigravity permission level."

    static func preparationPolicyFailureMessage(for config: AntigravityAgentConfig) -> String? {
        config.supportsHeadlessRun ? nil : safeManagedUnavailableMessage
    }

    func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
        if let policyFailure = Self.preparationPolicyFailureMessage(for: config) {
            throw AIProviderError.invalidConfiguration(detail: policyFailure)
        }
        let actualRunID = runID ?? UUID()
        guard await ServerNetworkManager.shared.isRunning() else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }
        let ensureResult = MCPIntegrationHelper.ensureAntigravityServerForDiscovery()
        if let failureMessage = Self.mcpPreparationFailureMessage(for: ensureResult) {
            throw AIProviderError.invalidConfiguration(detail: failureMessage)
        }
        return HeadlessAgentContext(
            runID: actualRunID,
            configURL: nil,
            environment: ProcessInfo.processInfo.environment
        )
    }

    // MARK: - Streaming

    /// Outcome of one `agy --print` invocation (one "turn" of the auto-resume loop).
    enum TurnOutcome: Equatable {
        case completed // agy finished within its budget
        case capped // agy hit its hardcoded ~5-min / 1494-poll print-mode limit
        case incomplete // agy exited cleanly before printing a final response
    }

    /// Sent on each resume turn so agy continues the unfinished task rather than restarting.
    static let resumeContinuationPrompt = """
    You stopped because of a ~5-minute headless time limit, not because the task was finished. \
    Continue exactly where you left off and keep working until the task is fully complete. Do not \
    restart from the beginning and do not re-summarize earlier work — pick up from your last step \
    and finish the remaining work.
    """

    /// Pure decision: should the loop resume after this turn? Resume only when a turn did not
    /// produce a final response, resume is enabled (`maxResumes > 0`), the resume budget isn't
    /// exhausted, and a conversation id is known to resume.
    static func shouldResume(outcome: TurnOutcome, turn: Int, maxResumes: Int, hasConversationID: Bool) -> Bool {
        (outcome == .capped || outcome == .incomplete) && maxResumes > 0 && turn < maxResumes && hasConversationID
    }

    func streamAgentMessage(_ message: AgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        guard let request = await streamRequests.startRequest(operation: { [weak self] streamRequest in
            guard let self else { throw CancellationError() }
            return try await self.makeStream(
                message,
                runID: runID,
                streamRequest: streamRequest
            )
        }) else {
            throw CancellationError()
        }
        return try await withTaskCancellationHandler(operation: {
            try await request.task.value
        }, onCancel: { [streamRequests] in
            Task {
                await streamRequests.cancel(request.token)
            }
        })
    }

    private func makeStream(
        _ message: AgentMessage,
        runID: UUID?,
        streamRequest: AntigravityStreamRequestCoordinator.Token
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        // Reject unsupported Safe Managed runs synchronously. Returning a stream first would let
        // the caller report the provider as ready and wait for routing before it consumed the
        // buffered policy error from the stream task.
        if let policyFailure = Self.preparationPolicyFailureMessage(for: config) {
            throw AIProviderError.invalidConfiguration(detail: policyFailure)
        }
        // Complete MCP/config preparation before returning the stream for the same reason. The
        // headless runner treats successful stream construction as provider readiness and waits
        // for MCP routing before consuming elements, so buffering a preparation failure inside
        // the stream would hide the actionable error behind that routing timeout.
        let context = try await prepare(runID: runID)
        try Task.checkCancellation()
        guard await streamRequests.isCurrent(streamRequest) else {
            throw CancellationError()
        }
        // Acquire the single-run slot before stream construction signals provider readiness. If a
        // queued run returned a stream first, the runner's bounded MCP-routing lease could expire
        // while another long AGY run still held this gate, dropping the queued run's routing policy
        // before it ever launched.
        try await Self.acquireRunGate(
            AntigravityRunGate.shared,
            requestIsCurrent: { [streamRequests] in
                await streamRequests.isCurrent(streamRequest)
            }
        )
        return try await withTaskCancellationHandler(operation: {
            let (raw, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
            let producerTask: Task<Void, Never>
            do {
                producerTask = try await Self.activateProducer(
                    requests: streamRequests,
                    request: streamRequest,
                    runGate: AntigravityRunGate.shared
                ) { [weak self] in
                    guard let self else {
                        continuation.finish()
                        await AntigravityRunGate.shared.unlock()
                        return
                    }
                    var runGateLocked = true
                    var toolLogTask: Task<AntigravityTrajectoryStore.FailureKind?, Never>?
                    var turnLogFileURLs: [URL] = []
                    // Keep every turn log available until the tailer completes its final bounded
                    // drain. Removing the completed turn's log at loop exit could otherwise erase
                    // the only conversation-id authority before a late trajectory DB appears.
                    defer {
                        for logFileURL in turnLogFileURLs {
                            Self.removeLogFile(logFileURL)
                        }
                    }
                    do {
                        guard await streamRequests.isCurrent(streamRequest) else {
                            throw CancellationError()
                        }
                        let combinedPrompt = Self.combinedPrompt(
                            system: message.systemPrompt,
                            user: message.userMessage
                        )

                        await toolTracking.startTracking(
                            runID: context.runID,
                            clientNameHint: Self.antigravityMCPClientID,
                            continuation: continuation
                        )

                        // agy emits no tool calls on stdout — tail the conversation trajectory DB for
                        // live tool cards. Each turn's unique log announces its exact conversation id,
                        // so external agy runs cannot redirect the tailer or auto-resume path.
                        let activeToolLog = AntigravityTrajectoryToolLog(environment: context.environment)
                        toolLogTask = Task {
                            await AntigravityTrajectoryToolLogStream.tail(
                                into: continuation,
                                locate: { activeToolLog.locate() }
                            )
                        }

                        // Auto-resume loop: agy's headless `--print` caps at ~5 min / 1494 polls. On a
                        // cap, resume the same conversation (`--conversation <id>`, fresh budget) and
                        // continue — up to `config.maxPrintResumes` times — so a long run can finish.
                        let maxResumes = config.maxPrintResumes
                        var resumeConversationID: String?
                        var turn = 0
                        while true {
                            try Task.checkCancellation()
                            let logFileURL = Self.makeLogFileURL(runID: UUID())
                            if let logFileURL {
                                turnLogFileURLs.append(logFileURL)
                            }
                            activeToolLog.beginTurn(logFileURL: logFileURL)

                            // agy honors `--model` only when the prompt is the `--print` argv value,
                            // not when it arrives via STDIN. Inline the prompt when it fits under
                            // ARG_MAX; otherwise fall back to STDIN (model ignored, but the run
                            // still proceeds instead of failing with E2BIG).
                            let turnPrompt = turn == 0 ? combinedPrompt : Self.resumeContinuationPrompt
                            let inlinePrompt = Self.shouldInlinePrompt(turnPrompt)
                            let args = Self.buildArguments(
                                config: config,
                                workspacePath: workspacePath,
                                logFilePath: logFileURL?.path,
                                resumeConversationID: resumeConversationID,
                                inlinePrompt: inlinePrompt ? turnPrompt : nil
                            )
                            if enableDebugLogging {
                                let flags = args.filter { $0.hasPrefix("--") }
                                print("[DEBUG] Antigravity: launching agy turn \(turn) (\(args.count) args; inlinePrompt: \(inlinePrompt); flags: \(flags.joined(separator: " ")))")
                            }

                            let outcome = try await runPrintTurn(
                                args: args,
                                prompt: inlinePrompt ? "" : turnPrompt,
                                logFileURL: logFileURL,
                                toolLog: activeToolLog,
                                expectedPIDRunID: context.runID,
                                isFirstTurn: turn == 0,
                                continuation: continuation
                            )

                            if outcome == .completed { break }

                            // Not complete: capture this turn's exact log-announced conversation id
                            // and resume it. The forked DB can lag the process exit by a poll cycle, so
                            // retry locate() briefly (matching the tailer's 200ms cadence) before
                            // deciding — otherwise a transient miss is misreported as "task too large".
                            var nextID: String?
                            for _ in 0 ..< 15 {
                                if let id = activeToolLog.locate()?.deletingPathExtension().lastPathComponent, !id.isEmpty {
                                    nextID = id
                                    break
                                }
                                try await Task.sleep(nanoseconds: 200_000_000)
                            }
                            if Self.shouldResume(
                                outcome: outcome, turn: turn, maxResumes: maxResumes,
                                hasConversationID: nextID != nil
                            ) {
                                resumeConversationID = nextID
                                turn += 1
                                continue
                            }
                            if nextID == nil, maxResumes > 0, turn < maxResumes {
                                throw AIProviderError.invalidConfiguration(
                                    detail: Self.missingConversationMessage(outcome: outcome) + " but its conversation "
                                        + "database could not be found to resume. Ensure `agy` is authenticated "
                                        + "and ~/.gemini/antigravity-cli/conversations is writable."
                                )
                            }
                            throw AIProviderError.invalidConfiguration(
                                detail: Self.exhaustedMessage(outcome: outcome, maxResumes: maxResumes, resumed: turn)
                            )
                        }

                        // Cancellation tells the tailer to perform its final bounded DB drain. Await
                        // that synchronization edge before releasing attribution or closing output.
                        let finalFailureKind = await Self.cancelAndAwaitToolLogTask(toolLogTask)
                        if finalFailureKind == .conversationContextLost {
                            throw AIProviderError.invalidConfiguration(detail: Self.conversationContextLostMessage)
                        }
                        await Self.releaseRunGateAfterCleanup(AntigravityRunGate.shared) {
                            await self.toolTracking.stopTracking(ifTracking: context.runID)
                            continuation.yield(
                                AIStreamResult(
                                    type: "message_stop",
                                    text: nil,
                                    reasoning: nil,
                                    promptTokens: nil,
                                    completionTokens: nil,
                                    cost: nil
                                )
                            )
                            continuation.finish()
                        }
                        runGateLocked = false
                    } catch is CancellationError {
                        await runner.cancelAll()
                        _ = await Self.cancelAndAwaitToolLogTask(toolLogTask)
                        if runGateLocked {
                            await Self.releaseRunGateAfterCleanup(AntigravityRunGate.shared) {
                                await self.toolTracking.stopTracking(ifTracking: context.runID)
                                continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "Antigravity run cancelled."))
                            }
                            runGateLocked = false
                        }
                    } catch {
                        let finalFailureKind = await Self.cancelAndAwaitToolLogTask(toolLogTask)
                        let terminalError = Self.terminalError(
                            error,
                            finalTrajectoryFailureKind: finalFailureKind
                        )
                        if runGateLocked {
                            await Self.releaseRunGateAfterCleanup(AntigravityRunGate.shared) {
                                await self.toolTracking.stopTracking(ifTracking: context.runID)
                                continuation.finish(throwing: terminalError)
                            }
                            runGateLocked = false
                        }
                    }
                }
            } catch {
                continuation.finish()
                throw error
            }
            Self.installTerminationHandler(on: continuation, producerTask: producerTask)
            return AgentReasoningStatusStream.withReasoningStatus(raw)
        }, onCancel: {
            Task {
                await streamRequests.cancel(streamRequest)
            }
        })
    }

    /// Acquires the single-run permit and closes the cancellation race between FIFO handoff and
    /// transferring ownership to the stream producer. The hook is a deterministic test seam.
    static func acquireRunGate(
        _ runGate: AntigravityRunGate,
        beforeCancellationCheck: (() async -> Void)? = nil,
        requestIsCurrent: (() async -> Bool)? = nil
    ) async throws {
        try await runGate.lock()
        await beforeCancellationCheck?()
        do {
            try Task.checkCancellation()
            if let requestIsCurrent, await !requestIsCurrent() {
                throw CancellationError()
            }
        } catch {
            await runGate.unlock()
            throw error
        }
    }

    /// Atomically transfers an already-acquired gate permit to an actor-registered producer. The
    /// cancellation handler invalidates the request whether cancellation lands before or after
    /// registration. When activation never occurs this helper retains ownership and releases the
    /// gate; once activation succeeds the producer is solely responsible for cleanup and release.
    static func activateProducer(
        requests: AntigravityStreamRequestCoordinator,
        request: AntigravityStreamRequestCoordinator.Token,
        runGate: AntigravityRunGate,
        beforeActivation: (() async -> Void)? = nil,
        afterActivation: (() async -> Void)? = nil,
        operation: @escaping @Sendable () async -> Void
    ) async throws -> Task<Void, Never> {
        try await withTaskCancellationHandler(operation: {
            await beforeActivation?()
            var producerTask: Task<Void, Never>?
            do {
                try Task.checkCancellation()
                guard let activatedTask = await requests.activate(request, operation: operation) else {
                    throw CancellationError()
                }
                producerTask = activatedTask
                await afterActivation?()
                try Task.checkCancellation()
                guard await requests.isCurrent(request) else {
                    throw CancellationError()
                }
                return activatedTask
            } catch {
                if producerTask == nil {
                    await runGate.unlock()
                } else {
                    await requests.cancel(request)
                }
                throw error
            }
        }, onCancel: {
            Task {
                await requests.cancel(request)
            }
        })
    }

    /// The current run retains the gate until all tracker/continuation cleanup is complete, so a
    /// queued replacement cannot be touched by stale teardown from its predecessor.
    static func releaseRunGateAfterCleanup(
        _ runGate: AntigravityRunGate,
        cleanup: () async -> Void
    ) async {
        await cleanup()
        await runGate.unlock()
    }

    /// A terminated stream may cancel only its captured producer. Looking up the coordinator's
    /// current producer here would let an old continuation cancel a replacement task.
    static func installTerminationHandler(
        on continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        producerTask: Task<Void, Never>
    ) {
        continuation.onTermination = { termination in
            Self.handleTermination(termination, producerTask: producerTask)
        }
    }

    static func handleTermination(
        _ termination: AsyncThrowingStream<AIStreamResult, Error>.Continuation.Termination,
        producerTask: Task<Void, Never>
    ) {
        guard case .cancelled = termination else { return }
        producerTask.cancel()
    }

    private static func cancelAndAwaitToolLogTask(
        _ task: Task<AntigravityTrajectoryStore.FailureKind?, Never>?
    ) async -> AntigravityTrajectoryStore.FailureKind? {
        guard let task else { return nil }
        task.cancel()
        return await task.value
    }

    /// Run ONE `agy --print` invocation: stream its stdout as live `content`, then classify the exit
    /// as `.completed` or `.capped` (poll-cap timeout). Throws on a hard failure (non-zero exit,
    /// runner timeout, or — on the first turn only — no output at all).
    ///
    /// `prompt` is written to the child's STDIN. It is empty when the caller already inlined the
    /// prompt into `args` as the `--print` argument value (the model-honoring path); the child
    /// then reads its prompt from argv and sees an immediate STDIN EOF.
    private func runPrintTurn(
        args: [String],
        prompt: String,
        logFileURL: URL?,
        toolLog: AntigravityTrajectoryToolLog,
        expectedPIDRunID: UUID,
        isFirstTurn: Bool,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async throws -> TurnOutcome {
        var framer = LineFramer()
        var stdoutData = Data()
        var stderrTail = Data()
        var exitStatus: Int32?
        var timedOut = false

        do {
            let stream = try await runner.runStreaming(
                args: args,
                stdin: prompt,
                outputMode: .none,
                timeout: Self.processTimeoutSeconds,
                onProcessStarted: { pid in
                    await ServerNetworkManager.shared.registerExpectedAgentPID(
                        pid, for: Self.antigravityMCPClientID, runID: expectedPIDRunID
                    )
                },
                onProcessTerminated: { pid in
                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                        pid, for: Self.antigravityMCPClientID, runID: expectedPIDRunID
                    )
                }
            )
            for try await event in stream {
                switch event {
                case let .stdout(chunk):
                    stdoutData.append(chunk)
                    framer.feed(chunk) { line in
                        if let text = String(data: line, encoding: .utf8) {
                            // Withhold the poll-cap marker line from streamed content; the turn is
                            // still classified as capped below via the accumulated stdoutData.
                            guard !AntigravityStreamParser.isPollCapMarkerLine(text) else { return }
                            continuation.yield(AntigravityStreamParser.contentResult(text + "\n"))
                        }
                    }
                case let .stderr(chunk):
                    stderrTail.append(chunk)
                    if stderrTail.count > 64 * 1024 {
                        stderrTail = Data(stderrTail.suffix(64 * 1024))
                    }
                case let .terminated(status, didTimeout):
                    exitStatus = status
                    timedOut = didTimeout
                }
            }
            // AsyncThrowingStream iteration may end normally when its consumer task is cancelled.
            // Reify that cancellation before classifying a missing termination event as a CLI error;
            // the structured catch below then awaits runner cleanup before the AGY gate is released.
            try Task.checkCancellation()
            framer.flush { line in
                if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                    guard !AntigravityStreamParser.isPollCapMarkerLine(text) else { return }
                    continuation.yield(AntigravityStreamParser.contentResult(text))
                }
            }
        } catch {
            await runner.cancelAll()
            throw error
        }

        let stderrString = String(decoding: stderrTail, as: UTF8.self)
        let logTail = Self.tailOfLogFile(logFileURL)
        let trajectoryFailureKind = try await toolLog.latestCorrelatedFailureKind()
        return try Self.classifyTurn(
            exitStatus: exitStatus,
            timedOut: timedOut,
            stdoutData: stdoutData,
            stderr: stderrString,
            logTail: logTail,
            isFirstTurn: isFirstTurn,
            trajectoryFailureKind: trajectoryFailureKind
        )
    }

    static func classifyTurn(
        exitStatus: Int32?,
        timedOut: Bool,
        stdoutData: Data,
        stderr: String,
        logTail: String?,
        isFirstTurn: Bool,
        trajectoryFailureKind: AntigravityTrajectoryStore.FailureKind? = nil
    ) throws -> TurnOutcome {
        if let processFailure = processFailure(
            exitStatus: exitStatus,
            timedOut: timedOut,
            stderr: stderr,
            logTail: logTail,
            trajectoryFailureKind: trajectoryFailureKind
        ) {
            throw processFailure
        }
        return try classifySuccessfulTurn(
            stdoutData: stdoutData,
            stderr: stderr,
            logTail: logTail,
            isFirstTurn: isFirstTurn
        )
    }

    static func classifySuccessfulTurn(
        stdoutData: Data,
        stderr: String? = nil,
        logTail: String?,
        isFirstTurn: Bool
    ) throws -> TurnOutcome {
        if isHeadlessPermissionDenial(stderr: stderr, logTail: logTail) {
            throw headlessPermissionDenialError
        }

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        if AntigravityStreamParser.isPrintModePollCapTimeout(stdout: stdoutString, logTail: logTail) {
            return .capped
        }
        let hasMeaningfulOutput = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if !hasMeaningfulOutput {
            if isFirstTurn {
                throw AIProviderError.invalidConfiguration(
                    detail: "Antigravity CLI returned no meaningful output. Ensure you are signed in by running `agy` once interactively."
                )
            }
            return .incomplete
        }
        return .completed
    }

    /// Clear, actionable message when a run keeps capping and the resume budget is exhausted (or
    /// resume is disabled).
    static func cappedExhaustedMessage(maxResumes: Int, resumed: Int) -> String {
        if maxResumes > 0 {
            return "Antigravity kept hitting its ~5-minute headless limit after \(resumed) auto-resume(s); "
                + "the task is too large to finish headlessly — split it into smaller steps."
        }
        return "Antigravity headless print mode stopped at its ~5-minute limit (1494 polls) before finishing. "
            + "Narrow the task or split it into smaller steps."
    }

    static func incompleteExhaustedMessage(maxResumes: Int, resumed: Int) -> String {
        if maxResumes > 0 {
            return "Antigravity exited without printing a final response after \(resumed) auto-resume(s); "
                + "the task may still be working through tool output — split it into smaller steps."
        }
        return "Antigravity exited without printing a final response before finishing. "
            + "Narrow the task or split it into smaller steps."
    }

    static func exhaustedMessage(outcome: TurnOutcome, maxResumes: Int, resumed: Int) -> String {
        switch outcome {
        case .completed:
            ""
        case .capped:
            cappedExhaustedMessage(maxResumes: maxResumes, resumed: resumed)
        case .incomplete:
            incompleteExhaustedMessage(maxResumes: maxResumes, resumed: resumed)
        }
    }

    static func missingConversationMessage(outcome: TurnOutcome) -> String {
        switch outcome {
        case .completed:
            "Antigravity completed"
        case .capped:
            "Antigravity hit its ~5-minute headless limit"
        case .incomplete:
            "Antigravity exited without printing a final response"
        }
    }

    func dispose() async {
        let disposalTasks = await streamRequests.beginDisposal()
        await runner.cancelAll()
        for requestTask in disposalTasks.requests {
            _ = await requestTask.result
        }
        for producerTask in disposalTasks.producers {
            await producerTask.value
        }
    }

    // MARK: - Errors & logging

    static let headlessPermissionDenialMessage = "Antigravity denied a tool because headless mode cannot prompt. In Agent Permissions, choose Sandboxed Auto-Approve (keeps the terminal sandbox but auto-approves every configured MCP server) or Full Access, then retry. For MCP-started sub-agents, use Custom per provider or Inherit provider settings instead of Safe Managed. If auto-approval is already selected, update `agy` or run it interactively to inspect the request."
    static let conversationContextLostMessage = "Antigravity CLI lost the conversation while building its next request. This failure occurred inside AGY, not during authentication or the RepoPrompt MCP connection. Review completed tool actions before retrying. Splitting large file or tool batches may help; also update `agy` if a newer version is available."
    private static let timeoutMessage = "Antigravity CLI timed out."

    private static var headlessPermissionDenialError: AIProviderError {
        AIProviderError.invalidConfiguration(detail: headlessPermissionDenialMessage)
    }

    static func isHeadlessPermissionDenial(stderr: String?, logTail: String?) -> Bool {
        let diagnostics = [stderr, logTail]
            .compactMap(\.self)
            .joined(separator: "\n")
            .lowercased()
        guard !diagnostics.isEmpty else { return false }

        let headlessAutoDenial = diagnostics.contains("headless mode cannot prompt")
            && (diagnostics.contains("required approval") || diagnostics.contains("auto-denied"))
        let rejectedConfirmation = diagnostics.contains("tool confirmation")
            && diagnostics.contains("approved=false")
        return diagnostics.contains("soft-denying tool confirmation")
            || diagnostics.contains("user denied permission for mcp(")
            || headlessAutoDenial
            || rejectedConfirmation
    }

    /// Maps process-level diagnostics without exposing raw stderr or log content in the UI.
    /// Returns nil only for a confirmed, successful exit; callers then classify the turn output.
    static func processFailure(
        exitStatus: Int32?,
        timedOut: Bool,
        stderr: String,
        logTail: String?,
        trajectoryFailureKind: AntigravityTrajectoryStore.FailureKind? = nil
    ) -> Error? {
        if isHeadlessPermissionDenial(stderr: stderr, logTail: logTail) {
            return headlessPermissionDenialError
        }
        if timedOut {
            return AIProviderError.invalidConfiguration(detail: timeoutMessage)
        }
        if trajectoryFailureKind == .conversationContextLost {
            return AIProviderError.invalidConfiguration(detail: conversationContextLostMessage)
        }
        guard let exitStatus else {
            return AIProviderError.invalidConfiguration(
                detail: "Antigravity CLI ended without reporting an exit status. Try again or run `agy` interactively to inspect the failure."
            )
        }
        guard exitStatus != 0 else { return nil }

        let diagnostics = [stderr, logTail]
            .compactMap(\.self)
            .joined(separator: "\n")
        let normalizedDiagnostics = diagnostics.lowercased()
        let authenticationFailureSignatures = [
            "not logged into",
            "failed to get token source",
            "error getting token source",
            "failed to get token from token source"
        ]
        if authenticationFailureSignatures.contains(where: normalizedDiagnostics.contains) {
            return AIProviderError.invalidConfiguration(
                detail: "Antigravity CLI is not authenticated. Run `agy` once interactively to sign in."
            )
        }
        return AIProviderError.invalidConfiguration(
            detail: "Antigravity CLI failed (exit \(exitStatus)). Run `agy` interactively to inspect the failure."
        )
    }

    static func terminalError(
        _ error: Error,
        finalTrajectoryFailureKind: AntigravityTrajectoryStore.FailureKind?
    ) -> Error {
        guard finalTrajectoryFailureKind == .conversationContextLost else { return error }
        if case let AIProviderError.invalidConfiguration(detail) = error,
           detail == headlessPermissionDenialMessage || detail == timeoutMessage
        {
            return error
        }
        return AIProviderError.invalidConfiguration(detail: conversationContextLostMessage)
    }

    private static func makeLogFileURL(runID: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptAntigravity", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("agy-\(runID.uuidString).log")
    }

    private static func tailOfLogFile(_ url: URL?, maxBytes: Int = 4096) -> String? {
        guard let url, maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size > 0 else { return nil }
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private static func removeLogFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
