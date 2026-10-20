import Foundation
import os
import RepoPromptShared

enum AgentTaskRoutingLogScope: String, Codable, Equatable {
    case primarySession
    case subagent
    case headless
}

enum AgentTaskRoutingLogStage: String, Codable, Equatable {
    case model
    case effort
    case autoEffort
}

enum AgentTaskRoutingLogOutcome: String, Codable, Equatable {
    case selected
    case abstained
    case failed
    case cancelled
    case localSingleCandidate
}

enum AgentTaskRoutingAppliedOutcome: String, Codable, Equatable {
    case applied
    case fallback
    case rejected
    case notStarted
}

private extension KeyedEncodingContainer {
    mutating func encodeOrNull(_ value: (some Encodable)?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

struct AgentTaskRoutingLogTarget: Codable, Equatable {
    struct Parameter: Codable, Equatable {
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
        effort = target.reasoningEffortRaw ?? {
            switch AgentProviderKind(rawValue: target.agentRaw) {
            case .claudeCode: ClaudeModelSpecifier(raw: target.modelRaw).explicitEffortLevel?.rawValue
            case .codexExec: CodexModelSpecifier(raw: target.modelRaw).reasoningEffort?.rawValue
            default: nil
            }
        }()
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        modelParameters = try container.decodeIfPresent([Parameter].self, forKey: .modelParameters) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeOrNull(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeOrNull(effort, forKey: .effort)
        try container.encode(modelParameters, forKey: .modelParameters)
    }
}

struct AgentTaskRoutingLogCandidate: Codable, Equatable {
    let key: String
    let provider: String?
    let model: String
    let effort: String?
    let modelParameters: [AgentTaskRoutingLogTarget.Parameter]

    init(key: String, target: AgentTaskRoutingLogTarget) {
        self.key = key
        provider = target.provider
        model = target.model
        effort = target.effort
        modelParameters = target.modelParameters
    }

    private enum CodingKeys: String, CodingKey { case key, provider, model, effort, modelParameters }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        modelParameters = try container.decodeIfPresent([AgentTaskRoutingLogTarget.Parameter].self, forKey: .modelParameters) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeOrNull(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encodeOrNull(effort, forKey: .effort)
        try container.encode(modelParameters, forKey: .modelParameters)
    }
}

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

struct AgentTaskRoutingDecisionEvent: Codable, Equatable {
    let schema: Int
    let timestamp: String
    let requestID: String
    let sessionID: String?
    let scope: AgentTaskRoutingLogScope
    let stage: AgentTaskRoutingLogStage
    let outcome: AgentTaskRoutingLogOutcome
    let backend: String?
    let jevModel: String?
    let policyVersion: String?
    let candidates: [AgentTaskRoutingLogCandidate]
    let chosenKey: String?
    let chosenTarget: AgentTaskRoutingLogTarget?
    let probabilities: [String: Double]?
    let confidence: Double?
    let reasonCode: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let latencyMs: Double?
    let failure: String?
    let rationale: String?
    let makerExclusions: [String: [String]]?
    let routingOverride: AgentTaskRoutingExplorationRecord?

    init(
        requestID: UUID,
        sessionID: UUID?,
        scope: AgentTaskRoutingLogScope,
        draft: AgentTaskRoutingDecisionDraft,
        timestamp: Date
    ) {
        schema = AgentTaskRoutingDecisionLog.schemaVersion
        self.timestamp = AgentTaskRoutingDecisionLog.format(timestamp)
        self.requestID = requestID.uuidString
        self.sessionID = sessionID?.uuidString
        self.scope = scope
        stage = draft.stage
        outcome = draft.outcome
        backend = draft.backend
        jevModel = draft.jevModel
        policyVersion = draft.policyVersion
        candidates = draft.candidates
        chosenKey = draft.chosenKey
        chosenTarget = draft.chosenTarget
        probabilities = draft.probabilities
        confidence = draft.confidence
        reasonCode = draft.reasonCode
        inputTokens = draft.inputTokens
        outputTokens = draft.outputTokens
        latencyMs = draft.latencyMs
        failure = draft.failure
        makerExclusions = draft.makerExclusions
        routingOverride = draft.routingOverride
        rationale = nil
    }

    private enum CodingKeys: String, CodingKey {
        case event, schema, timestamp, requestID, sessionID, scope, stage, outcome, backend, jevModel
        case policyVersion, candidates, chosenKey, chosenTarget, probabilities, confidence, reasonCode
        case inputTokens, outputTokens, latencyMs, failure, rationale, makerExclusions
        case routingOverride = "override"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        requestID = try container.decode(String.self, forKey: .requestID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        scope = try container.decode(AgentTaskRoutingLogScope.self, forKey: .scope)
        stage = try container.decode(AgentTaskRoutingLogStage.self, forKey: .stage)
        outcome = try container.decode(AgentTaskRoutingLogOutcome.self, forKey: .outcome)
        backend = try container.decodeIfPresent(String.self, forKey: .backend)
        jevModel = try container.decodeIfPresent(String.self, forKey: .jevModel)
        policyVersion = try container.decodeIfPresent(String.self, forKey: .policyVersion)
        candidates = try container.decode([AgentTaskRoutingLogCandidate].self, forKey: .candidates)
        chosenKey = try container.decodeIfPresent(String.self, forKey: .chosenKey)
        chosenTarget = try container.decodeIfPresent(AgentTaskRoutingLogTarget.self, forKey: .chosenTarget)
        probabilities = try container.decodeIfPresent([String: Double].self, forKey: .probabilities)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        reasonCode = try container.decodeIfPresent(String.self, forKey: .reasonCode)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
        makerExclusions = try container.decodeIfPresent([String: [String]].self, forKey: .makerExclusions)
        routingOverride = try container.decodeIfPresent(AgentTaskRoutingExplorationRecord.self, forKey: .routingOverride)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("decision", forKey: .event)
        try container.encode(schema, forKey: .schema)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(requestID, forKey: .requestID)
        try container.encodeOrNull(sessionID, forKey: .sessionID)
        try container.encode(scope.rawValue, forKey: .scope)
        try container.encode(stage.rawValue, forKey: .stage)
        try container.encode(outcome.rawValue, forKey: .outcome)
        try container.encodeOrNull(backend, forKey: .backend)
        try container.encodeOrNull(jevModel, forKey: .jevModel)
        try container.encodeOrNull(policyVersion, forKey: .policyVersion)
        try container.encode(candidates, forKey: .candidates)
        try container.encodeOrNull(chosenKey, forKey: .chosenKey)
        try container.encodeOrNull(chosenTarget, forKey: .chosenTarget)
        try container.encodeOrNull(probabilities, forKey: .probabilities)
        try container.encodeOrNull(confidence, forKey: .confidence)
        try container.encodeOrNull(reasonCode, forKey: .reasonCode)
        try container.encodeOrNull(inputTokens, forKey: .inputTokens)
        try container.encodeOrNull(outputTokens, forKey: .outputTokens)
        try container.encodeOrNull(latencyMs, forKey: .latencyMs)
        try container.encodeOrNull(failure, forKey: .failure)
        try container.encodeOrNull(makerExclusions, forKey: .makerExclusions)
        try container.encodeOrNull(routingOverride, forKey: .routingOverride)
        try container.encodeNil(forKey: .rationale)
    }
}

struct AgentTaskRoutingAppliedEvent: Codable, Equatable {
    let schema: Int
    let timestamp: String
    let requestID: String
    let sessionID: String?
    let scope: AgentTaskRoutingLogScope
    let outcome: AgentTaskRoutingAppliedOutcome
    let provider: String?
    let model: String?
    let effort: String?
    let modelParameters: [AgentTaskRoutingLogTarget.Parameter]
    let picked: AgentTaskRoutingLogTarget?

    init(
        requestID: UUID,
        sessionID: UUID?,
        scope: AgentTaskRoutingLogScope,
        outcome: AgentTaskRoutingAppliedOutcome,
        applied: AgentTaskRoutingLogTarget?,
        picked: AgentTaskRoutingLogTarget?,
        timestamp: Date
    ) {
        schema = AgentTaskRoutingDecisionLog.schemaVersion
        self.timestamp = AgentTaskRoutingDecisionLog.format(timestamp)
        self.requestID = requestID.uuidString
        self.sessionID = sessionID?.uuidString
        self.scope = scope
        self.outcome = outcome
        provider = applied?.provider
        model = applied?.model
        effort = applied?.effort
        modelParameters = applied?.modelParameters ?? []
        self.picked = picked
    }

    private enum CodingKeys: String, CodingKey {
        case event, schema, timestamp, requestID, sessionID, scope, outcome
        case provider, model, effort, modelParameters, picked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        requestID = try container.decode(String.self, forKey: .requestID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        scope = try container.decode(AgentTaskRoutingLogScope.self, forKey: .scope)
        outcome = try container.decode(AgentTaskRoutingAppliedOutcome.self, forKey: .outcome)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        modelParameters = try container.decodeIfPresent([AgentTaskRoutingLogTarget.Parameter].self, forKey: .modelParameters) ?? []
        picked = try container.decodeIfPresent(AgentTaskRoutingLogTarget.self, forKey: .picked)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("applied", forKey: .event)
        try container.encode(schema, forKey: .schema)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(requestID, forKey: .requestID)
        try container.encodeOrNull(sessionID, forKey: .sessionID)
        try container.encode(scope.rawValue, forKey: .scope)
        try container.encode(outcome.rawValue, forKey: .outcome)
        try container.encodeOrNull(provider, forKey: .provider)
        try container.encodeOrNull(model, forKey: .model)
        try container.encodeOrNull(effort, forKey: .effort)
        try container.encode(modelParameters, forKey: .modelParameters)
        try container.encodeOrNull(picked, forKey: .picked)
    }
}

enum AgentTaskRoutingLogLine: Codable, Equatable {
    case decision(AgentTaskRoutingDecisionEvent)
    case applied(AgentTaskRoutingAppliedEvent)

    private enum CodingKeys: String, CodingKey {
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .event)
        switch kind {
        case "decision":
            self = try .decision(AgentTaskRoutingDecisionEvent(from: decoder))
        case "applied":
            self = try .applied(AgentTaskRoutingAppliedEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: container,
                debugDescription: "Unknown routing decision log event: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .decision(event):
            try event.encode(to: encoder)
        case let .applied(event):
            try event.encode(to: encoder)
        }
    }
}

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

    func record(_ event: some Encodable) async {
        guard let line = try? encoder.encode(event) else {
            droppedCount += 1
            errorSink("encode")
            return
        }
        await append(line + Data([0x0A]))
    }

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

    func flush() async {
        while !isIdle {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
    }

    func flushForTesting() async {
        await flush()
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

enum AgentTaskRoutingStartSettlement {
    case accepted(actual: AgentRoutingExecutableTarget?, sessionID: UUID?)
    case started(sessionID: UUID?, applied: AgentRoutingExecutableTarget)
    case rejected
    case notStarted

    @MainActor
    init(recorder: AgentRunStartOutcomeRecorder, actual: AgentRoutingExecutableTarget?, sessionID: UUID?) {
        self = recorder.outcome.didStart ? .accepted(actual: actual, sessionID: sessionID) : .rejected
    }
}

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

    func attachMakerExclusions(_ map: [String: [String]]) {
        guard makerExclusions == nil, !map.isEmpty else { return }
        makerExclusions = map
    }

    func recordPick(_ target: AgentRoutingExecutableTarget?) {
        picked = target
    }

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
            outcome = (picked != nil && picked.map(AgentTaskRoutingLogTarget.init) == actual.map(AgentTaskRoutingLogTarget.init)) ? .applied : .fallback
        case let .started(startedSessionID, applied):
            appliedTarget = applied
            eventSessionID = startedSessionID ?? sessionID
            outcome = (picked.map(AgentTaskRoutingLogTarget.init) == AgentTaskRoutingLogTarget(applied)) ? .applied : .fallback
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

    nonisolated func runStartScope<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await AgentTaskRoutingJudgeLogging.currentTaskLocal.withValue(self) {
            try await body()
        }
    }

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

@MainActor
final class AgentTaskRoutingRouteContextHolder {
    var context: AgentTaskRoutingRouteContext?
}

final class AgentTaskRoutingStartSink: @unchecked Sendable {
    struct Armed {
        fileprivate let sink: AgentTaskRoutingStartSink

        @MainActor
        func complete(recorder: AgentRunStartOutcomeRecorder, actual: AgentRoutingExecutableTarget?, sessionID: UUID?) {
            sink.settle(AgentTaskRoutingStartSettlement(recorder: recorder, actual: actual, sessionID: sessionID))
        }

        func settleRejected() {
            sink.settle(.rejected)
        }
    }

    private let lock = NSLock()
    private var armed = false
    private var settled: AgentTaskRoutingStartSettlement?
    private var waiter: CheckedContinuation<AgentTaskRoutingStartSettlement, Never>?

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

    static var live: AgentTaskRoutingRouteScope? {
        guard let scope = current, !scope.sink.isSettled else { return nil }
        return scope
    }
}

enum AgentTaskRoutingJudgeLogging {
    static let currentTaskLocal = BoxedTaskLocal<AgentTaskRoutingRouteContext?>(nil)
    static var current: AgentTaskRoutingRouteContext? {
        currentTaskLocal.get()
    }
}
