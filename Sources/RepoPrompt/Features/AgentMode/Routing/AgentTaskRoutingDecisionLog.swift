import Foundation
import os
import RepoPromptShared

// MARK: - Schema

enum AgentTaskRoutingLogScope: String, Equatable {
    case primarySession
    case subagent
    case headless
}

enum AgentTaskRoutingLogStage: String, Equatable {
    case model
    case effort
    case autoEffort
}

enum AgentTaskRoutingLogOutcome: String, Equatable {
    case selected
    case abstained
    case failed
    case cancelled
    case localSingleCandidate
}

enum AgentTaskRoutingAppliedOutcome: String, Equatable {
    case applied
    case fallback
    case rejected
    case notStarted
}

private extension KeyedEncodingContainer {
    /// Optional fields are always present so the schema is stable; absent values are JSON null.
    mutating func encodeOrNull(_ value: (some Encodable)?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

/// Executable target projection. Only opaque identifiers and catalog values; never task text or paths.
struct AgentTaskRoutingLogTarget: Encodable, Equatable {
    struct Parameter: Encodable, Equatable {
        let providerID: String
        let baseModel: String
        let kind: String
        let configID: String
        let value: String
    }

    let provider: String?
    let model: String
    let effort: String?
    let modelParameters: [Parameter]

    init(_ target: AgentRoutingExecutableTarget) {
        provider = target.agentRaw
        model = target.modelRaw
        effort = target.reasoningEffortRaw
        modelParameters = target.modelParameters.map {
            Parameter(
                providerID: $0.providerID.rawValue,
                baseModel: $0.baseModelRaw,
                kind: $0.kind.rawValue,
                configID: $0.configID,
                value: $0.valueRaw
            )
        }
    }

    init(provider: String?, model: String, effort: String?, modelParameters: [Parameter] = []) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.modelParameters = modelParameters
    }

    private enum CodingKeys: String, CodingKey { case provider, model, effort, modelParameters }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeOrNull(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeOrNull(effort, forKey: .effort)
        try container.encode(modelParameters, forKey: .modelParameters)
    }
}

struct AgentTaskRoutingLogCandidate: Encodable, Equatable {
    let key: String
    let target: AgentTaskRoutingLogTarget

    private enum CodingKeys: String, CodingKey { case key, provider, model, effort, modelParameters }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeOrNull(target.provider, forKey: .provider)
        try container.encode(target.model, forKey: .model)
        try container.encodeOrNull(target.effort, forKey: .effort)
        try container.encode(target.modelParameters, forKey: .modelParameters)
    }
}

/// Everything a decision row carries that the route knows; identity and time are added by the context.
struct AgentTaskRoutingDecisionDraft {
    var stage: AgentTaskRoutingLogStage
    var outcome: AgentTaskRoutingLogOutcome
    var backend: String?
    var jevModel: String?
    var policyVersion: String?
    var candidates: [AgentTaskRoutingLogCandidate] = []
    var chosenKey: String?
    var chosenTarget: AgentTaskRoutingLogTarget?
    var probabilities: [String: Double]?
    var confidence: Double?
    var reasonCode: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var latencyMs: Double?
    var failure: String?
    var makerExclusions: [String: [String]]?
    var routingOverride: AgentTaskRoutingExplorationRecord?

    init(stage: AgentTaskRoutingLogStage, outcome: AgentTaskRoutingLogOutcome) {
        self.stage = stage
        self.outcome = outcome
    }
}

struct AgentTaskRoutingDecisionEvent: Encodable {
    let requestID: UUID
    let sessionID: UUID?
    let scope: AgentTaskRoutingLogScope
    let draft: AgentTaskRoutingDecisionDraft
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case event, schema, timestamp, requestID, sessionID, scope, stage, outcome, backend, jevModel
        case policyVersion, candidates, chosenKey, chosenTarget, probabilities, confidence, reasonCode
        case inputTokens, outputTokens, latencyMs, failure, rationale, makerExclusions
        case routingOverride = "override"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("decision", forKey: .event)
        try container.encode(AgentTaskRoutingDecisionLog.schemaVersion, forKey: .schema)
        try container.encode(AgentTaskRoutingDecisionLog.format(timestamp), forKey: .timestamp)
        try container.encode(requestID.uuidString, forKey: .requestID)
        try container.encodeOrNull(sessionID?.uuidString, forKey: .sessionID)
        try container.encode(scope.rawValue, forKey: .scope)
        try container.encode(draft.stage.rawValue, forKey: .stage)
        try container.encode(draft.outcome.rawValue, forKey: .outcome)
        try container.encodeOrNull(draft.backend, forKey: .backend)
        try container.encodeOrNull(draft.jevModel, forKey: .jevModel)
        try container.encodeOrNull(draft.policyVersion, forKey: .policyVersion)
        try container.encode(draft.candidates, forKey: .candidates)
        try container.encodeOrNull(draft.chosenKey, forKey: .chosenKey)
        try container.encodeOrNull(draft.chosenTarget, forKey: .chosenTarget)
        try container.encodeOrNull(draft.probabilities, forKey: .probabilities)
        try container.encodeOrNull(draft.confidence, forKey: .confidence)
        try container.encodeOrNull(draft.reasonCode, forKey: .reasonCode)
        try container.encodeOrNull(draft.inputTokens, forKey: .inputTokens)
        try container.encodeOrNull(draft.outputTokens, forKey: .outputTokens)
        try container.encodeOrNull(draft.latencyMs, forKey: .latencyMs)
        try container.encodeOrNull(draft.failure, forKey: .failure)
        try container.encodeOrNull(draft.makerExclusions, forKey: .makerExclusions)
        // The decoded Jev response contract exposes no rationale.
        try container.encodeNil(forKey: .rationale)
        try container.encodeOrNull(draft.routingOverride, forKey: .routingOverride)
    }
}

struct AgentTaskRoutingAppliedEvent: Encodable {
    let requestID: UUID
    let sessionID: UUID?
    let scope: AgentTaskRoutingLogScope
    let outcome: AgentTaskRoutingAppliedOutcome
    let applied: AgentTaskRoutingLogTarget?
    let picked: AgentTaskRoutingLogTarget?
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case event, schema, timestamp, requestID, sessionID, scope, outcome
        case provider, model, effort, modelParameters, picked
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("applied", forKey: .event)
        try container.encode(AgentTaskRoutingDecisionLog.schemaVersion, forKey: .schema)
        try container.encode(AgentTaskRoutingDecisionLog.format(timestamp), forKey: .timestamp)
        try container.encode(requestID.uuidString, forKey: .requestID)
        try container.encodeOrNull(sessionID?.uuidString, forKey: .sessionID)
        try container.encode(scope.rawValue, forKey: .scope)
        try container.encode(outcome.rawValue, forKey: .outcome)
        try container.encodeOrNull(applied?.provider, forKey: .provider)
        try container.encodeOrNull(applied?.model, forKey: .model)
        try container.encodeOrNull(applied?.effort, forKey: .effort)
        try container.encode(applied?.modelParameters ?? [], forKey: .modelParameters)
        try container.encodeOrNull(picked, forKey: .picked)
    }
}

// MARK: - Storage

/// Physical file operations. Injected so tests can fail or gate I/O without production-only behavior.
protocol AgentTaskRoutingDecisionLogStorage: Sendable {
    func activeFileSize() async throws -> Int
    func append(_ data: Data) async throws
    func rotate() async throws
}

struct AgentTaskRoutingDecisionLogFileStorage: AgentTaskRoutingDecisionLogStorage {
    let activeURL: URL

    var rotatedURL: URL {
        URL(fileURLWithPath: activeURL.path + ".1")
    }

    func activeFileSize() async throws -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: activeURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    func append(_ data: Data) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: activeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: activeURL.path) {
            guard manager.createFile(atPath: activeURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: activeURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func rotate() async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: rotatedURL.path) {
            try manager.removeItem(at: rotatedURL)
        }
        if manager.fileExists(atPath: activeURL.path) {
            try manager.moveItem(at: activeURL, to: rotatedURL)
        }
    }
}

// MARK: - Log actor

/// Default-on local JSONL record of router decisions and their application.
///
/// Admission is soft backpressure, not a cap: queued plus in-flight bytes count against `admissionBudget`,
/// waiters are served FIFO ahead of newcomers, and a promoted waiter's bytes are reserved and enqueued
/// before its caller resumes. Rotation is a threshold: a row is never split, truncated or dropped while
/// the log is writable. A physical I/O failure drops only that row, counts it, and never affects routing.
actor AgentTaskRoutingDecisionLog {
    static let schemaVersion = 1
    static let defaultMaxBytes = 5 * 1024 * 1024
    static let minimumMaxBytes = 64 * 1024
    static let defaultAdmissionBudget = 1024 * 1024

    struct Snapshot: Equatable {
        let admittedBytes: Int
        let queuedRows: Int
        let waiterCount: Int
        let droppedCount: Int
    }

    private struct Waiter {
        let line: Data
        let continuation: CheckedContinuation<Void, Never>
    }

    private static let osLog = Logger(subsystem: "com.repoprompt.ce", category: "ModelRouterDecisionLog")

    private let storage: any AgentTaskRoutingDecisionLogStorage
    private let maxBytes: Int
    private let admissionBudget: Int
    private let errorSink: @Sendable (String) -> Void
    private let onPromote: (@Sendable (_ rowBytes: Int, _ admittedBytes: Int) -> Void)?
    private let encoder: JSONEncoder
    private let now: @Sendable () -> Date

    private var queue: [Data] = []
    private var admittedBytes = 0
    private var waiters: [Waiter] = []
    private var isDraining = false
    private var activeSize: Int?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var droppedCount = 0

    init(
        fileURL: URL = AgentTaskRoutingDecisionLog.defaultFileURL(),
        maxBytes: Int = AgentTaskRoutingDecisionLog.defaultMaxBytes,
        admissionBudget: Int = AgentTaskRoutingDecisionLog.defaultAdmissionBudget,
        storage: (any AgentTaskRoutingDecisionLogStorage)? = nil,
        errorSink: (@Sendable (String) -> Void)? = nil,
        onPromote: (@Sendable (_ rowBytes: Int, _ admittedBytes: Int) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage ?? AgentTaskRoutingDecisionLogFileStorage(activeURL: fileURL)
        self.maxBytes = max(maxBytes, Self.minimumMaxBytes)
        self.admissionBudget = max(admissionBudget, 1)
        self.errorSink = errorSink ?? { description in
            Self.osLog.error("Model router decision log write failed: \(description, privacy: .public)")
        }
        self.onPromote = onPromote
        self.now = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("ModelRouter", isDirectory: true)
            .appendingPathComponent("jev-decisions.jsonl", isDirectory: false)
    }

    static func format(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func encodeLine(_ event: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)
        return data
    }

    func snapshot() -> Snapshot {
        Snapshot(
            admittedBytes: admittedBytes,
            queuedRows: queue.count,
            waiterCount: waiters.count,
            droppedCount: droppedCount
        )
    }

    /// Encodes an allowlisted event and appends it. Never throws and never fails the caller.
    func record(_ event: some Encodable) async {
        guard let line = try? encoder.encode(event) else {
            droppedCount += 1
            errorSink("encode")
            return
        }
        await append(line + Data([0x0A]))
    }

    /// Non-throwing and deliberately not cancellation-aware: a cancelled route is still logged once.
    func append(_ row: Data) async {
        let size = row.count
        // ponytail: waiters hold precedence; an empty-queue oversized row never bypasses an older waiter.
        if waiters.isEmpty, admittedBytes + size <= admissionBudget || admittedBytes == 0 {
            admittedBytes += size
            queue.append(row)
            wakeDrain()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(line: row, continuation: continuation))
        }
    }

    /// Resolves once every admitted and waiting row has been written or discarded.
    func flush() async {
        if isIdle { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(continuation)
        }
    }

    private var isIdle: Bool {
        queue.isEmpty && waiters.isEmpty && !isDraining
    }

    func makeEvent(
        requestID: UUID,
        sessionID: UUID?,
        scope: AgentTaskRoutingLogScope,
        draft: AgentTaskRoutingDecisionDraft
    ) -> AgentTaskRoutingDecisionEvent {
        AgentTaskRoutingDecisionEvent(
            requestID: requestID, sessionID: sessionID, scope: scope, draft: draft, timestamp: now()
        )
    }

    func makeAppliedEvent(
        requestID: UUID,
        sessionID: UUID?,
        scope: AgentTaskRoutingLogScope,
        outcome: AgentTaskRoutingAppliedOutcome,
        applied: AgentTaskRoutingLogTarget?,
        picked: AgentTaskRoutingLogTarget?
    ) -> AgentTaskRoutingAppliedEvent {
        AgentTaskRoutingAppliedEvent(
            requestID: requestID, sessionID: sessionID, scope: scope, outcome: outcome,
            applied: applied, picked: picked, timestamp: now()
        )
    }

    private func wakeDrain() {
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let batch = queue
            queue.removeAll(keepingCapacity: true)
            let batchBytes = batch.reduce(0) { $0 + $1.count }
            for row in batch {
                await write(row)
            }
            admittedBytes -= batchBytes
            promote()
        }
        isDraining = false
        let idle = idleWaiters
        idleWaiters.removeAll()
        idle.forEach { $0.resume() }
    }

    /// Reserve and enqueue the head waiter's bytes before resuming it, with no suspension point.
    private func promote() {
        while let head = waiters.first, admittedBytes + head.line.count <= admissionBudget || admittedBytes == 0 {
            waiters.removeFirst()
            admittedBytes += head.line.count
            queue.append(head.line)
            onPromote?(head.line.count, admittedBytes)
            head.continuation.resume()
        }
    }

    private func write(_ row: Data) async {
        do {
            var size: Int = if let known = activeSize {
                known
            } else {
                try await storage.activeFileSize()
            }
            if size > 0, size + row.count > maxBytes {
                try await storage.rotate()
                size = 0
            }
            try await storage.append(row)
            activeSize = size + row.count
        } catch {
            droppedCount += 1
            activeSize = nil
            let nsError = error as NSError
            errorSink("\(nsError.domain)#\(nsError.code)")
        }
    }
}

// MARK: - Route context

enum AgentTaskRoutingStartSettlement {
    case accepted(actual: AgentRoutingExecutableTarget?, sessionID: UUID?)
    case rejected
    case notStarted

    @MainActor
    init(recorder: AgentRunStartOutcomeRecorder, actual: AgentRoutingExecutableTarget?, sessionID: UUID?) {
        self = recorder.outcome.didStart ? .accepted(actual: actual, sessionID: sessionID) : .rejected
    }
}

/// Route-owned lifetime: stages written, decision presence and first-writer-wins finalization live here,
/// not in the log, so a delayed application finalizes regardless of how many other routes completed.
actor AgentTaskRoutingRouteContext {
    nonisolated let requestID: UUID
    nonisolated let scope: AgentTaskRoutingLogScope
    nonisolated let log: AgentTaskRoutingDecisionLog

    private var stagesWritten: Set<AgentTaskRoutingLogStage> = []
    private var hasDecision = false
    private var sessionID: UUID?
    private var picked: AgentRoutingExecutableTarget?
    private var finished = false
    private var pendingEmits = 0
    private var makerExclusions: [String: [String]]?

    init(requestID: UUID, scope: AgentTaskRoutingLogScope, log: AgentTaskRoutingDecisionLog) {
        self.requestID = requestID
        self.scope = scope
        self.log = log
    }

    func attachSessionID(_ id: UUID?) {
        sessionID = id
    }

    /// First nonempty map wins; an empty map leaves the slot open.
    func attachMakerExclusions(_ map: [String: [String]]) {
        guard makerExclusions == nil, !map.isEmpty else { return }
        makerExclusions = map
    }

    func recordPick(_ target: AgentRoutingExecutableTarget?) {
        picked = target
    }

    /// Writes at most one decision per stage.
    func emitDecision(_ draft: AgentTaskRoutingDecisionDraft) async {
        guard !finished, stagesWritten.insert(draft.stage).inserted else { return }
        hasDecision = true
        pendingEmits += 1
        var draft = draft
        if draft.stage == .model { draft.makerExclusions = makerExclusions }
        let event = await log.makeEvent(requestID: requestID, sessionID: sessionID, scope: scope, draft: draft)
        await log.record(event)
        pendingEmits -= 1
    }

    /// First writer wins. No applied row exists without an emitted decision.
    func finish(_ settlement: AgentTaskRoutingStartSettlement) async {
        guard !finished else { return }
        finished = true
        while pendingEmits > 0 {
            await Task.yield()
        }
        guard hasDecision else { return }
        let outcome: AgentTaskRoutingAppliedOutcome
        var appliedTarget: AgentRoutingExecutableTarget?
        var eventSessionID: UUID?
        switch settlement {
        case .rejected:
            outcome = .rejected
        case .notStarted:
            outcome = .notStarted
            eventSessionID = sessionID
        case let .accepted(actual, acceptedSessionID):
            appliedTarget = actual
            eventSessionID = acceptedSessionID ?? sessionID
            outcome = (picked != nil && picked == actual) ? .applied : .fallback
        }
        let event = await log.makeAppliedEvent(
            requestID: requestID,
            sessionID: eventSessionID,
            scope: scope,
            outcome: outcome,
            applied: appliedTarget.map(AgentTaskRoutingLogTarget.init),
            picked: picked.map(AgentTaskRoutingLogTarget.init)
        )
        await log.record(event)
    }

    /// Runs `body` with this route's start sink in scope. The completion task awaits the sink and
    /// finishes the application; `body` returning or throwing without arming settles it too.
    nonisolated func runStartScope<T>(
        unarmedOnReturn: (T) -> AgentTaskRoutingStartSettlement,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let sink = AgentTaskRoutingStartSink()
        Task { [self] in
            await finish(sink.awaitSettlement())
        }
        let scope = AgentTaskRoutingRouteScope(context: self, sink: sink)
        do {
            let value = try await AgentTaskRoutingRouteScope.currentTaskLocal.withValue(scope) {
                try await body()
            }
            sink.settleIfUnarmed(unarmedOnReturn(value))
            return value
        } catch {
            sink.settleIfUnarmed(.rejected)
            throw error
        }
    }
}

/// Lets a long start method that mints its context mid-way finish it from one outer catch.
@MainActor
final class AgentTaskRoutingRouteContextHolder {
    var context: AgentTaskRoutingRouteContext?
}

/// Synchronous arm/settle handshake between the composer/MCP start sites and the route context.
final class AgentTaskRoutingStartSink: @unchecked Sendable {
    /// Token returned to exactly one start site.
    struct Armed {
        fileprivate let sink: AgentTaskRoutingStartSink

        @MainActor
        func complete(recorder: AgentRunStartOutcomeRecorder, actual: AgentRoutingExecutableTarget?, sessionID: UUID?) {
            sink.settle(AgentTaskRoutingStartSettlement(recorder: recorder, actual: actual, sessionID: sessionID))
        }

        /// Early exits that never reached the provider pipeline.
        func settleRejected() {
            sink.settle(.rejected)
        }
    }

    private let lock = NSLock()
    private var armed = false
    private var settled: AgentTaskRoutingStartSettlement?
    private var waiter: CheckedContinuation<AgentTaskRoutingStartSettlement, Never>?

    /// Arms the live sink in scope, once. Nil when there is no routed start in scope.
    static func armCurrent() -> Armed? {
        guard let scope = AgentTaskRoutingRouteScope.live, scope.sink.arm() else { return nil }
        return Armed(sink: scope.sink)
    }

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled != nil
    }

    private func arm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !armed, settled == nil else { return false }
        armed = true
        return true
    }

    fileprivate func settle(_ settlement: AgentTaskRoutingStartSettlement) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return
        }
        settled = settlement
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: settlement)
    }

    func settleIfUnarmed(_ settlement: AgentTaskRoutingStartSettlement) {
        lock.lock()
        let isArmed = armed
        lock.unlock()
        if !isArmed { settle(settlement) }
    }

    func awaitSettlement() async -> AgentTaskRoutingStartSettlement {
        await withCheckedContinuation { continuation in
            registerWaiter(continuation)
        }
    }

    private func registerWaiter(_ continuation: CheckedContinuation<AgentTaskRoutingStartSettlement, Never>) {
        lock.lock()
        if let settled {
            lock.unlock()
            continuation.resume(returning: settled)
        } else {
            waiter = continuation
            lock.unlock()
        }
    }
}

struct AgentTaskRoutingRouteScope {
    let context: AgentTaskRoutingRouteContext
    let sink: AgentTaskRoutingStartSink

    static let currentTaskLocal = BoxedTaskLocal<AgentTaskRoutingRouteScope?>(nil)
    static var current: AgentTaskRoutingRouteScope? {
        currentTaskLocal.get()
    }

    /// A scope whose start already settled is stale (inherited by a later task) and is ignored.
    static var live: AgentTaskRoutingRouteScope? {
        guard let scope = current, !scope.sink.isSettled else { return nil }
        return scope
    }
}

/// Carries the context the Auto Effort judge writes its decision through.
enum AgentTaskRoutingJudgeLogging {
    static let currentTaskLocal = BoxedTaskLocal<AgentTaskRoutingRouteContext?>(nil)
    static var current: AgentTaskRoutingRouteContext? {
        currentTaskLocal.get()
    }
}
