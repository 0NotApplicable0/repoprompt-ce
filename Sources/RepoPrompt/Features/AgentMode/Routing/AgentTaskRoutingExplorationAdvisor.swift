import Foundation
import os

private let explorationOSLog = Logger(subsystem: "com.repoprompt.ce", category: "ModelRouterExploration")

struct AgentTaskRoutingExplorationRecord: Equatable, Codable {
    enum Kind: String, Codable {
        case exploration, none, explorationUnavailable
    }

    let kind: Kind
    let randomness: String
    let counter: UInt64
    let position: Int
    let originalKey: String
    let appliedKey: String
    let durable: Bool
}

private struct ExplorationFailure: Error {
    let code: String
    var counter: UInt64?
}

private struct ExplorationCounterDocument: Codable {
    let schema: Int
    let counters: [String: UInt64]
}

private struct ExplorationSchemaProbe: Decodable {
    let schema: Int
}

actor AgentTaskRoutingExplorationAdvisor {
    private static let cycleLength: UInt64 = 20
    private static let lockDeadlineNanoseconds: UInt64 = 250_000_000
    private static let lockRetryMicroseconds: useconds_t = 10000

    private let fileURL: URL?
    private let errorSink: @Sendable (String) -> Void
    private var lastIssued: [AgentTaskRoutingScope: UInt64] = [:]
    private var failureReported = false

    init(fileURL: URL?, errorSink: (@Sendable (String) -> Void)? = nil) {
        self.fileURL = fileURL
        self.errorSink = errorSink ?? { code in
            explorationOSLog.error("Exploration counter degraded: \(code, privacy: .public)")
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("ModelRouter", isDirectory: true)
            .appendingPathComponent("exploration-counters.json", isDirectory: false)
    }

    nonisolated static func position(counter: UInt64) -> Int {
        Int((max(counter, 1) - 1) % cycleLength) + 1
    }

    nonisolated static func exploringPositions(for randomness: AgentRoutingRandomness) -> [Int] {
        switch randomness {
        case .off: []
        case .low: [10]
        case .medium: [5, 15]
        case .high: [3, 8, 13, 18]
        }
    }

    nonisolated static func runnerUp(chosenKey: String, orderedKeys: [String], scores: [String: Double]?) -> String? {
        guard let scores, orderedKeys.count >= 2, Set(orderedKeys).count == orderedKeys.count,
              Set(scores.keys) == Set(orderedKeys),
              scores.values.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }),
              let chosenScore = scores[chosenKey]
        else { return nil }
        var best: (key: String, score: Double)?
        for key in orderedKeys where key != chosenKey {
            guard let score = scores[key] else { return nil }
            if score > (best?.score ?? -1) { best = (key, score) }
        }
        guard let best, chosenScore > best.score else { return nil }
        return best.key
    }

    func decide(
        scope: AgentTaskRoutingScope,
        randomness: AgentRoutingRandomness,
        chosenKey: String,
        orderedKeys: [String],
        scores: [String: Double]?
    ) -> AgentTaskRoutingExplorationRecord {
        let (counter, durable) = issue(scope)
        lastIssued[scope] = counter
        let position = Self.position(counter: counter)
        let exploring = Self.exploringPositions(for: randomness).contains(position)
        let runnerUp = exploring
            ? Self.runnerUp(chosenKey: chosenKey, orderedKeys: orderedKeys, scores: scores) : nil
        return AgentTaskRoutingExplorationRecord(
            kind: exploring ? (runnerUp == nil ? .explorationUnavailable : .exploration) : .none,
            randomness: randomness.rawValue,
            counter: counter,
            position: position,
            originalKey: chosenKey,
            appliedKey: runnerUp ?? chosenKey,
            durable: durable
        )
    }

    func counter(for scope: AgentTaskRoutingScope) -> UInt64 {
        lastIssued[scope] ?? 0
    }

    private func issue(_ scope: AgentTaskRoutingScope) -> (counter: UInt64, durable: Bool) {
        let floor = lastIssued[scope] ?? 0
        let degraded = floor == .max ? floor : floor + 1
        guard let fileURL else { return (degraded, false) }
        do {
            let next = try commit(scope, floor: floor, to: fileURL)
            failureReported = false
            return (next, true)
        } catch {
            let failure = error as? ExplorationFailure
            if !failureReported {
                failureReported = true
                errorSink(failure?.code ?? "unexpected_error")
            }
            return (failure?.counter ?? degraded, false)
        }
    }

    // ponytail: flock contention blocks this actor's executor for at most 250 ms; use async acquisition if profiling warrants it.
    private func commit(_ scope: AgentTaskRoutingScope, floor: UInt64, to fileURL: URL) throws -> UInt64 {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw ExplorationFailure(code: "directory_failed")
        }
        let lock = try acquireLock(at: fileURL.path + ".lock")
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        var counters = try loadCounters(at: fileURL)
        let base = max(counters[scope.rawValue] ?? 0, floor)
        guard base < .max else { throw ExplorationFailure(code: "counter_overflow", counter: .max) }
        counters[scope.rawValue] = base + 1
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(ExplorationCounterDocument(schema: 1, counters: counters))
                .write(to: fileURL, options: .atomic)
            // ponytail: non-secret counters land with umask mode before chmod; use a 0600 temporary + rename if needed.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw ExplorationFailure(code: "write_failed")
        }
        return base + 1
    }

    private func acquireLock(at path: String) throws -> Int32 {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ExplorationFailure(code: "lock_open_failed_\(errno)") }
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.lockDeadlineNanoseconds
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(descriptor)
                throw ExplorationFailure(code: "lock_failed_\(code)")
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                close(descriptor)
                throw ExplorationFailure(code: "lock_timeout")
            }
            if code == EWOULDBLOCK { usleep(Self.lockRetryMicroseconds) }
        }
        return descriptor
    }

    private func loadCounters(at url: URL) throws -> [String: UInt64] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let schema = try? decoder.decode(ExplorationSchemaProbe.self, from: data).schema, schema > 1 {
                throw ExplorationFailure(code: "future_schema")
            }
            if let document = try? decoder.decode(ExplorationCounterDocument.self, from: data), document.schema == 1 {
                return document.counters
            }
        }
        guard rename(url.path, url.path + ".corrupt") == 0 else {
            throw ExplorationFailure(code: "quarantine_failed_\(errno)")
        }
        errorSink("corrupt_quarantined")
        return [:]
    }
}
