import Foundation

// SEARCH-HELPER: Antigravity model registry, agy models, live model labels, dynamic models, subscribe
/// Centralized registry for Antigravity (`agy`) dynamic models.
///
/// Mirrors `AgentCodexModelRegistry` (the canonical store the Codex live-model picker reads),
/// adapted to `agy`'s contract: as of `agy` 1.1.12 `agy models` prints one tab-separated
/// `<model-id>\t<Display Label>` record per line (e.g. `gemini-3.6-flash-high\tGemini 3.6 Flash
/// (High)`), and `agy --model` accepts only the *id* field — passing the display label, or the
/// whole line, fails the run with `invalid model selection`. Older `agy` builds printed one bare
/// display label per line and accepted that label verbatim, so a line with no tab is treated as
/// both the id and the display name.
///
/// Owns:
/// - A thread-safe cache of models plus the last-refresh timestamp.
/// - An `async refresh()` that resolves `agy` (the same PATH machinery used by
///   `APISettingsViewModel.testAntigravityConnection()`), runs `agy models` with a short
///   timeout (no LLM/network round-trip), and parses non-empty stdout lines into models.
/// - Broadcasting a `Notification` (`.antigravityModelsChanged`) when the cache changes so the
///   Agent Mode model picker re-reads its options (mirrors the Codex/ACP live-model refresh).
///
/// Failure handling is intentionally silent: a missing binary, a not-signed-in session, or a
/// nonzero exit leaves the cache unchanged and never throws to the UI — callers fall back to the
/// static `Default` option.
///
/// Related:
/// - `AgentModelCatalog.options(for: .antigravity)` (consumes `currentModels()`)
/// - `CodexModelPollingService` / `AgentCodexModelRegistry` (the pattern this mirrors)
final class AntigravityModelRegistry {
    static let shared = AntigravityModelRegistry()

    /// One live `agy models` entry. `id` is the only form `agy --model` accepts; `displayName`
    /// is the human-facing label shown in the picker. They are equal for pre-1.1.12 `agy`
    /// output, which carried no id column.
    struct Model: Equatable {
        let id: String
        let displayName: String
    }

    /// Cache is considered stale after this interval, used to gate background refreshes triggered
    /// from `options(...)` so the picker does not spawn a process on every render.
    private static let staleInterval: TimeInterval = 60

    /// Short timeout for `agy models`. The command is local (no LLM call), so a hung binary
    /// should be force-killed quickly rather than stalling a background refresh.
    private static let processTimeoutSeconds: TimeInterval = 8

    private let lock = NSLock()
    private var models: [Model] = []
    private var lastRefreshDate: Date?
    /// Timestamp of the last refresh *attempt*, whether it succeeded or failed. Used to back
    /// off `refreshIfStale()` so a failing `agy models` (missing binary, not signed in, nonzero
    /// exit) does not re-spawn a process on every picker render — it backs off for the staleness
    /// window like a successful refresh does.
    private var lastAttemptDate: Date?
    private var inFlightRefresh: Task<Void, Never>?

    #if DEBUG
        /// DEBUG-only count of `performRefresh` invocations (each leads to at most one `agy models`
        /// process spawn). Lets tests assert that a failed refresh backs off and does not re-spawn
        /// within the staleness window.
        private var refreshAttemptCount = 0
    #endif

    private init() {}

    // MARK: - Synchronous cache reads

    /// Returns the cached models (non-blocking). Empty when no successful refresh has run.
    func currentModels() -> [Model] {
        lock.lock()
        defer { lock.unlock() }
        return models
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

    /// Resolve `agy`, run `agy models`, and update the cache from the parsed labels.
    ///
    /// Never throws: any failure (missing binary, not signed in, nonzero exit, timeout) leaves
    /// the existing cache untouched. Coalesces concurrent calls into a single process run.
    func refresh() async {
        // Atomically claim the single-flight slot: either adopt the existing in-flight task
        // or install a new one under one lock section so two concurrent callers cannot both
        // spawn an `agy models` process (TOCTOU between read and store).
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
        applyModels(parsed)
    }

    private func recordAttempt() {
        lock.lock()
        lastAttemptDate = Date()
        lock.unlock()
    }

    private func applyModels(_ newModels: [Model]) {
        lock.lock()
        let didChange = newModels != models
        models = newModels
        let now = Date()
        lastRefreshDate = now
        lastAttemptDate = now
        lock.unlock()

        guard didChange else { return }
        NotificationCenter.default.post(name: .antigravityModelsChanged, object: nil)
    }

    // MARK: - `agy models` execution

    /// Resolves the `agy` executable and runs `agy models`, returning stdout on a clean (exit 0)
    /// run or `nil` on any failure. Mirrors the resolution + short-timeout Process pattern in
    /// `APISettingsViewModel.testAntigravityConnection()` / `runAntigravityVersionProbe(...)`.
    private static func runModelsCommand() async -> String? {
        await CLIEnvironmentCache.shared.invalidate()
        let environmentResult = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(purpose: .cliRunner)
        )
        let profile = CLILaunchProfiles.antigravity
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
            // exits can deadlock if `agy models` writes more than the OS pipe buffer (~64KB):
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

    /// Parses `agy models` stdout into trimmed, non-empty models in source order.
    ///
    /// Each line is `<model-id>\t<Display Label>` (agy 1.1.12+). Only the first tab separates the
    /// two fields, so a label containing tabs still resolves. A line with no tab is older `agy`
    /// output, where the single field is both the id and the display name. Blank/whitespace-only
    /// lines are dropped and duplicate ids are collapsed (first occurrence wins) so the picker
    /// stays clean.
    static func parseModels(from output: String) -> [Model] {
        var seen = Set<String>()
        var result: [Model] = []
        // Split on any newline variant (LF, CRLF, CR). Note `\r\n` is a single Swift
        // grapheme, so `.newlines` (which includes the CR/LF scalars) is used rather than a
        // `Character`-based split to keep CRLF-terminated `agy` output one record per line.
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let id: String
            let displayName: String
            if let tabIndex = line.firstIndex(of: "\t") {
                id = String(line[line.startIndex ..< tabIndex])
                    .trimmingCharacters(in: .whitespaces)
                let trailing = String(line[line.index(after: tabIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                // A record whose label column is blank still selects fine by id.
                displayName = trailing.isEmpty ? id : trailing
            } else {
                id = line
                displayName = line
            }

            guard !id.isEmpty, seen.insert(id.lowercased()).inserted else { continue }
            result.append(Model(id: id, displayName: displayName))
        }
        return result
    }

    /// Clears the cached models and last-refresh timestamp. Called on disconnect so a
    /// stale model picker does not survive after the user removes the Antigravity integration.
    func clearCache() {
        let didChange: Bool
        lock.lock()
        didChange = !models.isEmpty
        models = []
        lastRefreshDate = nil
        lastAttemptDate = nil
        lock.unlock()
        guard didChange else { return }
        NotificationCenter.default.post(name: .antigravityModelsChanged, object: nil)
    }

    #if DEBUG
        func test_setModels(_ newModels: [Model]) {
            lock.lock()
            models = newModels
            let now = Date()
            lastRefreshDate = now
            lastAttemptDate = now
            lock.unlock()
        }

        func test_reset() {
            lock.lock()
            models = []
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
        /// an `agy` binary is present in the test environment.
        func test_simulateFailedRefreshAttempt() {
            recordAttempt()
        }
    #endif
}
