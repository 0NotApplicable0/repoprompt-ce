import Foundation

// SEARCH-HELPER: Grok model registry, grok models, live model labels, dynamic models, subscribe
/// Centralized registry for Grok (`grok`) dynamic models.
///
/// Mirrors `AgentCodexModelRegistry` (the canonical store the Codex live-model picker reads),
/// adapted to `grok`'s contract: `grok models` prints one model id per line, each prefixed with a
/// `* ` (the default) or `- ` marker and indented (e.g. `  * grok-build (default)` /
/// `  - grok-composer-2.5-fast`). The bare id is both the value passed to `grok --model "<id>"`
/// and the picker label — there is no slug mapping. Header/status lines such as
/// `Available models:`, `Default model: …`, and `You are not authenticated.` are dropped.
///
/// Owns:
/// - A thread-safe cache of model labels plus the last-refresh timestamp.
/// - An `async refresh()` that resolves `grok` (the same PATH machinery used by
///   `APISettingsViewModel.testGrokConnection()`), runs `grok models` with a short
///   timeout (no LLM/network round-trip), and parses non-empty stdout lines into labels.
/// - Broadcasting a `Notification` (`.grokModelsChanged`) when the cache changes so the
///   Agent Mode model picker re-reads its options (mirrors the Codex/ACP live-model refresh).
///
/// Failure handling is intentionally silent: a missing binary, a not-signed-in session, or a
/// nonzero exit leaves the cache unchanged and never throws to the UI — callers fall back to the
/// static `Default` option.
///
/// Related:
/// - `AgentModelCatalog.options(for: .grok)` (consumes `currentModelLabels()`)
/// - `CodexModelPollingService` / `AgentCodexModelRegistry` (the pattern this mirrors)
final class GrokModelRegistry {
    static let shared = GrokModelRegistry()

    /// Cache is considered stale after this interval, used to gate background refreshes triggered
    /// from `options(...)` so the picker does not spawn a process on every render.
    private static let staleInterval: TimeInterval = 60

    /// Short timeout for `grok models`. The command is local (no LLM call), so a hung binary
    /// should be force-killed quickly rather than stalling a background refresh.
    private static let processTimeoutSeconds: TimeInterval = 8

    private let lock = NSLock()
    private var labels: [String] = []
    private var lastRefreshDate: Date?
    /// Timestamp of the last refresh *attempt*, whether it succeeded or failed. Used to back
    /// off `refreshIfStale()` so a failing `grok models` (missing binary, not signed in, nonzero
    /// exit) does not re-spawn a process on every picker render — it backs off for the staleness
    /// window like a successful refresh does.
    private var lastAttemptDate: Date?
    private var inFlightRefresh: Task<Void, Never>?

    #if DEBUG
        /// DEBUG-only count of `performRefresh` invocations (each leads to at most one `grok models`
        /// process spawn). Lets tests assert that a failed refresh backs off and does not re-spawn
        /// within the staleness window.
        private var refreshAttemptCount = 0
    #endif

    private init() {}

    // MARK: - Synchronous cache reads

    /// Returns the cached model labels (non-blocking). Empty when no successful refresh has run.
    func currentModelLabels() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return labels
    }

    /// Timestamp of the last successful refresh, or `nil` if none has completed.
    func lastRefresh() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefreshDate
    }

    /// Whether a background `refreshIfStale()` should fire. Gated on the last *attempt* (not the
    /// last success) so a failed refresh backs off for `staleInterval` instead of re-firing on
    /// every render; a successful refresh updates both timestamps so the gate still reflects it.
    private var shouldAttemptRefresh: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastAttemptDate else { return true }
        return Date().timeIntervalSince(lastAttemptDate) >= Self.staleInterval
    }

    // MARK: - Refresh

    /// Refresh the cache if it is missing or older than `staleInterval`. Coalesces with any
    /// in-flight refresh so concurrent callers (connection test + picker render) share one run.
    func refreshIfStale() async {
        guard shouldAttemptRefresh else { return }
        await refresh()
    }

    /// Resolve `grok`, run `grok models`, and update the cache from the parsed labels.
    ///
    /// Never throws: any failure (missing binary, not signed in, nonzero exit, timeout) leaves
    /// the existing cache untouched. Coalesces concurrent calls into a single process run.
    func refresh() async {
        // Atomically claim the single-flight slot: either adopt the existing in-flight task
        // or install a new one under one lock section so two concurrent callers cannot both
        // spawn a `grok models` process (TOCTOU between read and store).
        let (task, isOwner) = claimRefreshTask()
        if isOwner {
            await task.value
            clearInFlightRefresh(ifMatches: task)
        } else {
            await task.value
        }
    }

    /// Returns the task to await plus whether the caller owns it (and must clear it on
    /// completion). Coalesces concurrent callers onto one task.
    private func claimRefreshTask() -> (task: Task<Void, Never>, isOwner: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlightRefresh {
            return (existing, false)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await performRefresh()
        }
        inFlightRefresh = task
        return (task, true)
    }

    private func clearInFlightRefresh(ifMatches task: Task<Void, Never>) {
        lock.lock()
        if inFlightRefresh == task {
            inFlightRefresh = nil
        }
        lock.unlock()
    }

    private func performRefresh() async {
        // Record the attempt up front so a failure (nil output / empty parse) still backs off
        // `refreshIfStale()` for the staleness window instead of re-spawning on every render.
        recordAttempt()
        #if DEBUG
            countRefreshAttempt()
        #endif
        guard let output = await Self.runModelsCommand() else { return }
        let parsed = Self.parseModels(from: output)
        guard !parsed.isEmpty else { return }
        applyLabels(parsed)
    }

    private func recordAttempt() {
        lock.lock()
        lastAttemptDate = Date()
        lock.unlock()
    }

    private func applyLabels(_ newLabels: [String]) {
        lock.lock()
        let didChange = newLabels != labels
        labels = newLabels
        let now = Date()
        lastRefreshDate = now
        lastAttemptDate = now
        lock.unlock()

        guard didChange else { return }
        NotificationCenter.default.post(name: .grokModelsChanged, object: nil)
    }

    // MARK: - `grok models` execution

    /// Resolves the `grok` executable and runs `grok models`, returning stdout on a clean (exit 0)
    /// run or `nil` on any failure. Mirrors the resolution + short-timeout Process pattern in
    /// `APISettingsViewModel.testGrokConnection()` / `runGrokVersionProbe(...)`.
    private static func runModelsCommand() async -> String? {
        await CLIEnvironmentCache.shared.invalidate()
        let environmentResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(purpose: .cliRunner)
        )
        let profile = CLILaunchProfiles.grok
        let resolvedCommand = CommandPathResolver.resolve(
            profile.commandName,
            environment: environmentResult.environment,
            additionalPaths: profile.supplementalSearchPaths,
            preferredBasenames: profile.preferredBasenames
        )

        switch CommandPathResolver.launchability(of: resolvedCommand) {
        case .launchable, .bareCommandFallback:
            break
        case .missingPath, .directory, .notExecutable:
            return nil
        }

        return await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: resolvedCommand)
            process.arguments = ["models"]
            process.environment = environmentResult.environment
            process.standardInput = FileHandle.nullDevice
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }

            // Drain stdout concurrently while the process runs. Reading only after the process
            // exits can deadlock if `grok models` writes more than the OS pipe buffer (~64KB):
            // the child blocks on a full pipe, never exits, and the timeout loop force-kills it.
            let drain = Task.detached(priority: .utility) { () -> Data in
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }

            let deadline = Date().addingTimeInterval(Self.processTimeoutSeconds)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                _ = await drain.value
                return nil
            }

            let data = await drain.value
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    // MARK: - Parsing

    /// Header/status lines `grok models` prints around the model list that must never become
    /// picker entries. Matched case-insensitively against the trimmed line (prefix for the
    /// `Default model: …` line, which carries a value).
    private static let droppedLinePrefixes = [
        "you are not authenticated.",
        "available models:",
        "default model:",
    ]

    /// Parses `grok models` stdout into trimmed, de-duplicated model ids in source order.
    ///
    /// `grok models` prints each model on its own line, indented and prefixed with a `* ` (the
    /// default) or `- ` marker, e.g. `  * grok-build (default)` / `  - grok-composer-2.5-fast`.
    /// The leading marker and the trailing `(default)` annotation are stripped so only the bare
    /// id remains — that id is both the `--model` value and the picker label. Blank lines,
    /// duplicates (first occurrence wins), and the `Available models:` / `Default model: …` /
    /// `You are not authenticated.` status lines are dropped so the picker stays clean.
    static func parseModels(from output: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        // Split on any newline variant (LF, CRLF, CR). Note `\r\n` is a single Swift
        // grapheme, so `.newlines` (which includes the CR/LF scalars) is used rather than a
        // `Character`-based split to keep CRLF-terminated `grok` output one entry per line.
        for rawLine in output.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Drop header/status lines (`Available models:`, `Default model: …`, the
            // not-authenticated notice) before any marker stripping so a `Default model: grok-build`
            // line never leaks the bare id back into the list.
            let lowered = line.lowercased()
            if Self.droppedLinePrefixes.contains(where: { lowered.hasPrefix($0) }) { continue }

            // Strip the leading `* ` (default) / `- ` list marker if present.
            if line.hasPrefix("* ") || line.hasPrefix("- ") {
                line = String(line.dropFirst(2))
            }

            // Strip a trailing `(default)` annotation (and any whitespace before it).
            if let range = line.range(of: "(default)", options: [.backwards, .caseInsensitive]) {
                line.removeSubrange(range)
            }

            let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// Clears the cached model labels and last-refresh timestamp. Called on disconnect so a
    /// stale model picker does not survive after the user removes the Grok integration.
    func clearCache() {
        let didChange: Bool
        lock.lock()
        didChange = !labels.isEmpty
        labels = []
        lastRefreshDate = nil
        lastAttemptDate = nil
        lock.unlock()
        guard didChange else { return }
        NotificationCenter.default.post(name: .grokModelsChanged, object: nil)
    }

    #if DEBUG
        func test_setLabels(_ newLabels: [String]) {
            lock.lock()
            labels = newLabels
            let now = Date()
            lastRefreshDate = now
            lastAttemptDate = now
            lock.unlock()
        }

        func test_reset() {
            lock.lock()
            labels = []
            lastRefreshDate = nil
            lastAttemptDate = nil
            refreshAttemptCount = 0
            lock.unlock()
        }

        private func countRefreshAttempt() {
            lock.lock()
            refreshAttemptCount += 1
            lock.unlock()
        }

        /// DEBUG-only: number of `performRefresh` runs (process-spawn attempts) since last reset.
        func test_refreshAttemptCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return refreshAttemptCount
        }

        /// DEBUG-only: mimic the failure path of a refresh — record the attempt timestamp (so
        /// `refreshIfStale()` backs off) without populating the cache or setting the success
        /// timestamp. Exercises the failure-churn backoff deterministically regardless of whether
        /// a `grok` binary is present in the test environment.
        func test_simulateFailedRefreshAttempt() {
            recordAttempt()
        }
    #endif
}
