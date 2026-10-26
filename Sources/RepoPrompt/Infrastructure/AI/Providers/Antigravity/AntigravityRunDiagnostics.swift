import Foundation
import RepoPromptShared

final class AntigravityTurnDiagnostics {
    static let retainedTurnLimit = 20
    static let stderrByteLimit = 64 * 1024

    private final class RetentionState: @unchecked Sendable {
        let lock = NSLock()
        var activeLogs: Set<URL> = []
    }

    private static let state = RetentionState()

    static var directory: URL {
        MCPFilesystemIdentity.current.applicationSupportRootURL()
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Antigravity", isDirectory: true)
    }

    let logFileURL: URL?
    var stderrTail = Data()
    var completed = false

    init(logFileURL: URL?) {
        self.logFileURL = logFileURL
    }

    static func makeLogFileURL(runID: UUID, directory: URL?) -> URL? {
        state.lock.withLock {
            let directory = directory ?? Self.directory.appendingPathComponent(".active", isDirectory: true)
            do {
                if directory == Self.directory.appendingPathComponent(".active", isDirectory: true) {
                    try secureDiagnosticDirectory(Self.directory)
                }
                try secureDirectory(directory)
                pruneInactiveSources(in: directory)
                let url = directory.appendingPathComponent("agy-\(runID.uuidString).log")
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    return nil
                }
                state.activeLogs.insert(url)
                return url
            } catch {
                return nil
            }
        }
    }

    func finish(in directory: URL) {
        Self.state.lock.withLock {
            let manager = FileManager.default
            if let logFileURL { Self.state.activeLogs.remove(logFileURL) }
            defer {
                Self.pruneBundles(in: directory)
                if let sourceDirectory = logFileURL?.deletingLastPathComponent() {
                    Self.pruneInactiveSources(in: sourceDirectory)
                }
            }
            if completed {
                if let logFileURL { try? manager.removeItem(at: logFileURL) }
                return
            }
            do {
                try Self.secureDiagnosticDirectory(directory)
                let run = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try Self.secureDirectory(run)
                let stderrURL = run.appendingPathComponent("stderr-tail.txt")
                do {
                    try Data(stderrTail.suffix(Self.stderrByteLimit)).write(to: stderrURL, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stderrURL.path)
                } catch {}
                if let logFileURL,
                   let attributes = try? manager.attributesOfItem(atPath: logFileURL.path),
                   attributes[.type] as? FileAttributeType == .typeRegular
                {
                    let destination = run.appendingPathComponent("agy.log")
                    do {
                        try manager.moveItem(at: logFileURL, to: destination)
                        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    } catch {}
                }
            } catch {}
        }
    }

    private static func newestFirst(_ urls: [URL]) -> [URL] {
        let datedURLs: [(url: URL, date: Date)] = urls.map { url in
            let values: URLResourceValues? = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let date: Date = values?.contentModificationDate ?? .distantPast
            return (url: url, date: date)
        }
        func precedes(_ lhs: (url: URL, date: Date), _ rhs: (url: URL, date: Date)) -> Bool {
            if lhs.date == rhs.date {
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }
            return lhs.date > rhs.date
        }
        let sortedURLs: [(url: URL, date: Date)] = datedURLs.sorted(by: precedes)
        return sortedURLs.map(\.url)
    }

    private static func pruneBundles(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return }
        let runs = contents.filter { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        for expired in newestFirst(runs).dropFirst(retainedTurnLimit) {
            try? FileManager.default.removeItem(at: expired)
        }
    }

    private static func pruneInactiveSources(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        let inactive = contents.filter { url in
            guard url.lastPathComponent.hasPrefix("agy-"), url.pathExtension == "log",
                  !state.activeLogs.contains(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        // ponytail: failed transfers retain at most 20 private source logs; active turns are never evicted.
        for expired in newestFirst(inactive).dropFirst(retainedTurnLimit) {
            try? FileManager.default.removeItem(at: expired)
        }
    }

    private static func secureDiagnosticDirectory(_ directory: URL) throws {
        if directory == Self.directory {
            try secureDirectory(directory.deletingLastPathComponent())
        }
        try secureDirectory(directory)
    }

    private static func secureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
