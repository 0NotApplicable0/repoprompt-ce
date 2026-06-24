import Foundation

/// Headless provider for Google's Antigravity CLI (`agy`).
///
/// `agy` v1.0.9 exposes a one-shot headless mode (`--print <prompt>`) that prints a
/// plain-text response on stdout (no JSON/streaming flag). This provider mirrors the
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
    private var streamTask: Task<Void, Never>?

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
    static func combinedPrompt(system: String, user: String) -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else { return user }
        return """
        \(trimmedSystem)

        \(user)
        """
    }

    /// Build the `agy` argv. The prompt is NOT passed on the command line: `agy --print`
    /// reads it from STDIN when the positional value is omitted (verified against `agy`
    /// v1.0.10). Delivering the (potentially very large) combined system+user prompt over
    /// stdin avoids the `ARG_MAX` limit a single `--print <prompt>` argv would hit. Remaining
    /// flags are passed via argv (posix_spawn, no shell) so values are safe.
    static func buildArguments(
        config: AntigravityAgentConfig,
        workspacePath: String?,
        logFilePath: String?,
        resumeConversationID: String? = nil
    ) -> [String] {
        var args = ["--print"]
        if let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty, model.lowercased() != "default"
        {
            args += ["--model", model]
        }
        if let workspacePath, !workspacePath.isEmpty {
            args += ["--add-dir", workspacePath]
        }
        if config.dangerouslySkipPermissions {
            args.append("--dangerously-skip-permissions")
        } else if config.useSandbox {
            args.append("--sandbox")
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

    func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
        let actualRunID = runID ?? UUID()
        guard await ServerNetworkManager.shared.isRunning() else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }
        let (ensureSuccess, _) = MCPIntegrationHelper.ensureAntigravityServerForDiscovery()
        guard ensureSuccess else {
            throw AIProviderError.invalidConfiguration(detail: "Failed to install RepoPrompt MCP config for Antigravity CLI.")
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
    }

    /// Sent on each resume turn so agy continues the unfinished task rather than restarting.
    static let resumeContinuationPrompt = """
    You stopped because of a ~5-minute headless time limit, not because the task was finished. \
    Continue exactly where you left off and keep working until the task is fully complete. Do not \
    restart from the beginning and do not re-summarize earlier work — pick up from your last step \
    and finish the remaining work.
    """

    /// Pure decision: should the loop resume after this turn? Resume only when a turn capped, resume
    /// is enabled (`maxResumes > 0`), the resume budget isn't exhausted, and a conversation id is
    /// known to resume.
    static func shouldResume(outcome: TurnOutcome, turn: Int, maxResumes: Int, hasConversationID: Bool) -> Bool {
        outcome == .capped && maxResumes > 0 && turn < maxResumes && hasConversationID
    }

    func streamAgentMessage(_ message: AgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let raw = AsyncThrowingStream<AIStreamResult, Error> { continuation in
            self.streamTask?.cancel()
            self.streamTask = Task { [weak self] in
                guard let self else { return }
                await withTaskCancellationHandler(operation: {
                    var runGateLocked = false
                    do {
                        let context = try await self.prepare(runID: runID)
                        let combinedPrompt = Self.combinedPrompt(
                            system: message.systemPrompt,
                            user: message.userMessage
                        )

                        self.toolTracking.startTracking(
                            runID: context.runID,
                            clientNameHint: Self.antigravityMCPClientID,
                            continuation: continuation
                        )

                        // Serialize agy runs in this process: agy hides its conversation id, so DB
                        // attribution relies on a single-run-at-a-time invariant (see AntigravityRunGate).
                        await AntigravityRunGate.shared.lock()
                        runGateLocked = true

                        // agy emits no tool calls on stdout — tail the conversation trajectory DB for
                        // live tool cards. The tailer re-locates the newest DB each poll, so it follows
                        // the run across auto-resume forks.
                        let toolLog = AntigravityTrajectoryToolLog(environment: context.environment)
                        let toolLogTask = Task {
                            await AntigravityTrajectoryToolLogStream.tail(into: continuation, locate: { toolLog.locate() })
                        }
                        defer { toolLogTask.cancel() }

                        // Auto-resume loop: agy's headless `--print` caps at ~5 min / 1494 polls. On a
                        // cap, resume the same conversation (`--conversation <id>`, fresh budget) and
                        // continue — up to `config.maxPrintResumes` times — so a long run can finish.
                        let maxResumes = self.config.maxPrintResumes
                        var resumeConversationID: String?
                        var turn = 0
                        while true {
                            try Task.checkCancellation()
                            let logFileURL = Self.makeLogFileURL(runID: UUID())
                            defer { Self.removeLogFile(logFileURL) }

                            let args = Self.buildArguments(
                                config: self.config,
                                workspacePath: self.workspacePath,
                                logFilePath: logFileURL?.path,
                                resumeConversationID: resumeConversationID
                            )
                            if self.enableDebugLogging {
                                let flags = args.filter { $0.hasPrefix("--") }
                                print("[DEBUG] Antigravity: launching agy turn \(turn) (\(args.count) args; flags: \(flags.joined(separator: " ")))")
                            }

                            let outcome = try await self.runPrintTurn(
                                args: args,
                                prompt: turn == 0 ? combinedPrompt : Self.resumeContinuationPrompt,
                                logFileURL: logFileURL,
                                expectedPIDRunID: context.runID,
                                isFirstTurn: turn == 0,
                                continuation: continuation
                            )

                            if outcome == .completed { break }

                            // Capped: capture this turn's conversation id (newest trajectory DB) and
                            // resume it. The forked DB can lag the process exit by a poll cycle, so
                            // retry locate() briefly (matching the tailer's 200ms cadence) before
                            // deciding — otherwise a transient miss is misreported as "task too large".
                            var nextID: String?
                            for _ in 0 ..< 15 {
                                if let id = toolLog.locate()?.deletingPathExtension().lastPathComponent, !id.isEmpty {
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
                                    detail: "Antigravity hit its ~5-minute headless limit but its conversation "
                                        + "database could not be found to resume. Ensure `agy` is authenticated "
                                        + "and ~/.gemini/antigravity-cli/conversations is writable."
                                )
                            }
                            throw AIProviderError.invalidConfiguration(detail: Self.cappedExhaustedMessage(maxResumes: maxResumes, resumed: turn))
                        }

                        await AntigravityRunGate.shared.unlock()
                        runGateLocked = false
                        await self.toolTracking.stopTracking()
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
                    } catch is CancellationError {
                        if runGateLocked { await AntigravityRunGate.shared.unlock() }
                        await self.runner.cancelAll()
                        await self.toolTracking.stopTracking()
                        continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "Antigravity run cancelled."))
                    } catch {
                        if runGateLocked { await AntigravityRunGate.shared.unlock() }
                        await self.toolTracking.stopTracking()
                        continuation.finish(throwing: error)
                    }
                }, onCancel: { [weak self] in
                    Task { [weak self] in
                        await self?.runner.cancelAll()
                    }
                })
            }
            continuation.onTermination = { [weak self] _ in
                self?.streamTask?.cancel()
            }
        }
        return AgentReasoningStatusStream.withReasoningStatus(raw)
    }

    /// Run ONE `agy --print` invocation: stream its stdout as live `content`, then classify the exit
    /// as `.completed` or `.capped` (poll-cap timeout). Throws on a hard failure (non-zero exit,
    /// runner timeout, or — on the first turn only — no output at all).
    private func runPrintTurn(
        args: [String],
        prompt: String,
        logFileURL: URL?,
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

        let status = exitStatus ?? 0
        if status != 0 || timedOut {
            let stderrString = String(data: stderrTail, encoding: .utf8) ?? ""
            throw mapProcessFailure(
                exitCode: status, timedOut: timedOut, stderr: stderrString,
                logTail: Self.tailOfLogFile(logFileURL)
            )
        }

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        if AntigravityStreamParser.isPrintModePollCapTimeout(stdout: stdoutString, logTail: Self.tailOfLogFile(logFileURL)) {
            return .capped
        }
        if isFirstTurn, stdoutData.isEmpty {
            let hint = Self.tailOfLogFile(logFileURL)
                ?? "Ensure you are signed in: run `agy` once interactively to authenticate."
            throw AIProviderError.invalidConfiguration(detail: "Antigravity CLI returned no output. \(hint)")
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

    func dispose() async {
        streamTask?.cancel()
        await runner.cancelAll()
    }

    // MARK: - Errors & logging

    private func mapProcessFailure(exitCode: Int32, timedOut: Bool, stderr: String, logTail: String?) -> Error {
        if timedOut {
            return AIProviderError.invalidConfiguration(detail: "Antigravity CLI timed out.")
        }
        var detail = "Antigravity CLI failed (exit \(exitCode))."
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            detail += " \(trimmedStderr)"
        }
        if let logTail, !logTail.isEmpty {
            if logTail.localizedCaseInsensitiveContains("not logged into") || logTail.localizedCaseInsensitiveContains("token source") {
                detail += " You may need to sign in: run `agy` once interactively."
            }
            detail += "\n\(logTail)"
        }
        return AIProviderError.invalidConfiguration(detail: detail)
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
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let tail = data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
        guard let text = String(data: tail, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removeLogFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
