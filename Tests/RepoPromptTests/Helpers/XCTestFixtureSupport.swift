import Foundation
import XCTest

extension XCTestCase {
    func makeTestDirectory(
        name: String = #function,
        namespace: String = "RepoPromptTests",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(Self.sanitizedFixtureName(name))-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            XCTFail("create test directory \(url.path): \(error)", file: file, line: line)
            throw error
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func makeTestPath(
        name: String = #function,
        namespace: String = "RepoPromptTests"
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("\(Self.sanitizedFixtureName(name))-\(UUID().uuidString)")
            .standardizedFileURL
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private static func sanitizedFixtureName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return sanitized.isEmpty ? "Fixture" : sanitized
    }
}

enum SwiftFixtureSource {
    static func emptyStruct(_ name: String, trailingNewline: Bool = true) -> String {
        "struct \(name) {}" + (trailingNewline ? "\n" : "")
    }

    static func sourceReferencingTarget(
        source: String = "Source",
        target: String = "Target",
        sourcePath: String? = nil,
        targetPath: String? = nil
    ) -> [String: String] {
        [
            sourcePath ?? "Sources/\(source).swift": "struct \(source) { let target: \(target) }\n",
            targetPath ?? "Sources/\(target).swift": emptyStruct(target)
        ]
    }
}

@MainActor
private final class BoundedGateWaiters {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }
}

@MainActor
final class BoundedGate {
    private let enteredWaiters = BoundedGateWaiters()
    private let releaseWaiters = BoundedGateWaiters()
    private var entered = false
    private var released = false

    func hold(seconds: Double = 15) async {
        entered = true
        enteredWaiters.resumeAll()
        guard !released else { return }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.release() }
        }
        await releaseWaiters.wait()
        timeout.cancel()
    }

    func release() {
        released = true
        releaseWaiters.resumeAll()
    }

    func waitUntilEntered(seconds: Double = 10) async -> Bool {
        if entered { return true }
        let waiters = enteredWaiters
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [self] in
                if !entered { await waiters.wait() }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first && entered
        }
    }
}

struct BoundedWaitTimeout: Error, CustomStringConvertible {
    let label: String
    var description: String {
        "timed out: \(label)"
    }
}

@MainActor
func awaitBounded(
    seconds: Double = 10,
    label: String,
    until condition: @MainActor () -> Bool = { true },
    wait: @escaping @MainActor () async -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Bool {
    let finished = await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor in
            await wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    guard finished else {
        XCTFail("timed out: \(label)", file: file, line: line)
        return false
    }
    return condition()
}

@MainActor
func awaitBoundedResult<T: Sendable>(
    seconds: Double = 60,
    label: String,
    operation: @escaping @MainActor () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Result<T, Error> {
    let result = await withTaskGroup(of: Result<T, Error>.self) { group in
        group.addTask { @MainActor in
            do {
                return try await .success(operation())
            } catch {
                return .failure(error)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .failure(BoundedWaitTimeout(label: label))
        }
        let first = await group.next() ?? .failure(BoundedWaitTimeout(label: label))
        group.cancelAll()
        return first
    }
    if case let .failure(error) = result, error is BoundedWaitTimeout {
        XCTFail("timed out: \(label)", file: file, line: line)
    }
    return result
}
