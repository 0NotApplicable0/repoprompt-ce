import Foundation

/// Headless provider for xAI's Grok CLI (`grok`).
///
/// `grok` v0.2.56 exposes a one-shot headless mode that reads the prompt from a file
/// (`--prompt-file <PATH>`) and prints a single final JSON object on stdout
/// (`--output-format json`). This provider mirrors the mechanics of
/// `CodexExecAgentProvider` — a plain, non-ACP `HeadlessAgentProvider` — but is
/// intentionally simpler: it accumulates stdout, parses the final JSON tolerantly into
/// content, and synthesizes a `message_stop`. RepoPrompt MCP tool calls surface via
/// `AgentToolTrackingController` plus expected-PID routing (the MCP server attributes calls by
/// the spawned process id), not via stdout parsing.
///
/// Authentication is the user's responsibility: a prior interactive `grok login` sign-in (xAI
/// OAuth, stored under `~/.grok/auth.json`) is required. RepoPrompt injects no credentials; the
/// parent process environment is passed through unchanged.
final class GrokAgentProvider: HeadlessAgentProvider {
    private static let grokMCPClientID = AgentProviderKind.grokMCPClientID
    /// Generous one-shot process timeout. `grok` has no `--print-timeout` equivalent, so the
    /// runner timeout is the sole guard against a hung process.
    private static let processTimeoutSeconds: TimeInterval = 3900

    private let runner: CLIProcessRunner
    private let config: GrokAgentConfig
    private let workspacePath: String?
    private let toolTracking = AgentToolTrackingController()
    private var streamTask: Task<Void, Never>?

    private var enableDebugLogging: Bool {
        config.enableDebugLogging
    }

    init(runner: CLIProcessRunner, config: GrokAgentConfig, workspacePath: String? = nil) {
        self.runner = runner
        self.config = config
        self.workspacePath = workspacePath
    }

    // MARK: - Argument construction

    /// `grok` has no system-prompt channel; combine the system prompt and user message into the
    /// single prompt-file payload with an explicit blank-line delimiter.
    static func combinedPrompt(system: String, user: String) -> String {
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else { return user }
        return """
        \(trimmedSystem)

        \(user)
        """
    }

    /// Build the `grok` argv. The (potentially very large) combined system+user prompt is NOT
    /// passed on the command line or over stdin: it is written to a temp file and referenced via
    /// `--prompt-file <PATH>`, which avoids the `ARG_MAX` limit a positional argv would hit and
    /// keeps stdin free. `--output-format json` is always passed so the single final JSON object
    /// can be parsed deterministically. Remaining flags are passed via argv (posix_spawn, no
    /// shell) so values are safe.
    static func buildArguments(
        config: GrokAgentConfig,
        workspacePath: String?,
        promptFilePath: String,
        debugFilePath: String?
    ) -> [String] {
        var args = ["--prompt-file", promptFilePath, "--output-format", "json"]
        if let model = config.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty, model.lowercased() != "default"
        {
            args += ["--model", model]
        }
        if let workspacePath, !workspacePath.isEmpty {
            args += ["--cwd", workspacePath]
        }
        // Both permission levels must bypass approvals or MCP tool calls stall in headless mode.
        // Full Access additionally drops the kernel sandbox.
        if config.dangerouslySkipPermissions {
            args += ["--permission-mode", "bypassPermissions"]
        } else if config.useSandbox {
            args += ["--sandbox", "workspace", "--permission-mode", "bypassPermissions"]
        } else {
            args += ["--permission-mode", "bypassPermissions"]
        }
        if let debugFilePath, !debugFilePath.isEmpty {
            args += ["--debug", "--debug-file", debugFilePath]
        }
        return args
    }

    // MARK: - Preparation

    func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
        let actualRunID = runID ?? UUID()
        guard await ServerNetworkManager.shared.isRunning() else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }
        let (ensureSuccess, _) = MCPIntegrationHelper.ensureGrokServerForDiscovery()
        guard ensureSuccess else {
            throw AIProviderError.invalidConfiguration(detail: "Failed to install RepoPrompt MCP config for Grok CLI.")
        }
        return HeadlessAgentContext(
            runID: actualRunID,
            configURL: nil,
            environment: ProcessInfo.processInfo.environment
        )
    }

    // MARK: - Streaming

    func streamAgentMessage(_ message: AgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            self.streamTask?.cancel()
            self.streamTask = Task { [weak self] in
                guard let self else { return }
                await withTaskCancellationHandler(operation: {
                    do {
                        let context = try await self.prepare(runID: runID)
                        let debugFileURL = Self.makeDebugFileURL(runID: context.runID)
                        defer { Self.removeFile(debugFileURL) }

                        let combinedPrompt = Self.combinedPrompt(
                            system: message.systemPrompt,
                            user: message.userMessage
                        )

                        // Write the combined prompt to a temp file and clean it up on exit,
                        // mirroring how the Antigravity provider manages its temp log file.
                        guard let promptFileURL = Self.makePromptFileURL(runID: context.runID) else {
                            throw AIProviderError.invalidConfiguration(
                                detail: "Failed to create temporary prompt file for Grok CLI."
                            )
                        }
                        defer { Self.removeFile(promptFileURL) }
                        do {
                            try combinedPrompt.write(to: promptFileURL, atomically: true, encoding: .utf8)
                        } catch {
                            throw AIProviderError.invalidConfiguration(
                                detail: "Failed to write temporary prompt file for Grok CLI: \(error.localizedDescription)"
                            )
                        }

                        let args = Self.buildArguments(
                            config: self.config,
                            workspacePath: self.workspacePath,
                            promptFilePath: promptFileURL.path,
                            debugFilePath: debugFileURL?.path
                        )

                        if self.enableDebugLogging {
                            let flags = args.filter { $0.hasPrefix("--") }
                            print("[DEBUG] Grok: launching grok (\(args.count) args; flags: \(flags.joined(separator: " ")))")
                        }

                        self.toolTracking.startTracking(
                            runID: context.runID,
                            clientNameHint: Self.grokMCPClientID,
                            continuation: continuation
                        )

                        var stdoutData = Data()
                        var stderrTail = Data()
                        var exitStatus: Int32?
                        var timedOut = false

                        do {
                            let expectedPIDRunID = context.runID
                            let stream = try await self.runner.runStreaming(
                                args: args,
                                stdin: nil,
                                outputMode: .none,
                                timeout: Self.processTimeoutSeconds,
                                onProcessStarted: { pid in
                                    await ServerNetworkManager.shared.registerExpectedAgentPID(
                                        pid, for: Self.grokMCPClientID, runID: expectedPIDRunID
                                    )
                                },
                                onProcessTerminated: { pid in
                                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                                        pid, for: Self.grokMCPClientID, runID: expectedPIDRunID
                                    )
                                }
                            )

                            for try await event in stream {
                                switch event {
                                case let .stdout(chunk):
                                    stdoutData.append(chunk)
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
                        } catch {
                            await self.runner.cancelAll()
                            await self.toolTracking.stopTracking()
                            throw error
                        }

                        await self.toolTracking.stopTracking()

                        let status = exitStatus ?? 0
                        if status != 0 || timedOut {
                            let stderrString = String(data: stderrTail, encoding: .utf8) ?? ""
                            throw self.mapProcessFailure(
                                exitCode: status,
                                timedOut: timedOut,
                                stderr: stderrString,
                                logTail: Self.tailOfLogFile(debugFileURL)
                            )
                        }

                        let results = GrokStreamParser.parseFinalOutput(stdoutData)
                        if results.isEmpty {
                            let hint = Self.tailOfLogFile(debugFileURL)
                                ?? "Ensure you are signed in: run `grok login` once to authenticate."
                            throw AIProviderError.invalidConfiguration(
                                detail: "Grok CLI returned no output. \(hint)"
                            )
                        }

                        // grok `--output-format json` surfaces failures as a top-level
                        // `{"type":"error"}` object → an `error` stream result. Treat that as a
                        // FAILED run: yield any non-error content, emit NO `message_stop`, and
                        // finish(throwing:) so the runner records a failed terminal state instead
                        // of `.completed`.
                        if let failure = results.first(where: { $0.type == "error" }) {
                            for result in results where result.type != "error" {
                                continuation.yield(result)
                            }
                            throw AIProviderError.invalidConfiguration(
                                detail: failure.text ?? "Grok CLI reported an error."
                            )
                        }

                        for result in results {
                            continuation.yield(result)
                        }
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
                        await self.runner.cancelAll()
                        await self.toolTracking.stopTracking()
                        continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "Grok run cancelled."))
                    } catch {
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
    }

    func dispose() async {
        streamTask?.cancel()
        await runner.cancelAll()
    }

    // MARK: - Errors & logging

    private func mapProcessFailure(exitCode: Int32, timedOut: Bool, stderr: String, logTail: String?) -> Error {
        if timedOut {
            return AIProviderError.invalidConfiguration(detail: "Grok CLI timed out.")
        }
        var detail = "Grok CLI failed (exit \(exitCode))."
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            detail += " \(trimmedStderr)"
        }
        if let logTail, !logTail.isEmpty {
            if logTail.localizedCaseInsensitiveContains("not authenticated") || logTail.localizedCaseInsensitiveContains("login") {
                detail += " You may need to sign in: run `grok login` once."
            }
            detail += "\n\(logTail)"
        }
        return AIProviderError.invalidConfiguration(detail: detail)
    }

    private static func makePromptFileURL(runID: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrok", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("grok-prompt-\(runID.uuidString).txt")
    }

    private static func makeDebugFileURL(runID: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptGrok", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir.appendingPathComponent("grok-\(runID.uuidString).log")
    }

    private static func tailOfLogFile(_ url: URL?, maxBytes: Int = 4096) -> String? {
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let tail = data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
        guard let text = String(data: tail, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removeFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
