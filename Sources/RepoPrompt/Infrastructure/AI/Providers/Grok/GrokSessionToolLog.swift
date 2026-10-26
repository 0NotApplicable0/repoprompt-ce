import Foundation

/// Stateful parser converting grok-composer's ACP `updates.jsonl` session-update lines into
/// `tool_call`/`tool_result` stream results — with real arguments and a result summary — so the
/// Agent Mode UI renders detailed tool cards.
///
/// grok-composer logs an Agent Client Protocol (`session/update`) stream to `updates.jsonl`:
///   - `tool_call`        — the call's `title` (tool name) + `rawInput` (path / command / glob)
///   - `tool_call_update` — refinements and, on terminal `status`, `content`/`rawOutput` (result)
///
/// Each `toolCallId` maps to a stable invocation id so the result attaches to the right card.
/// Marked `@unchecked Sendable`: only ever touched from the single tailer task.
final class GrokToolEventParser: @unchecked Sendable {
    private struct Call { let id: UUID
        let name: String
    }

    private var calls: [String: Call] = [:]
    private var completedCalls: Set<String> = []
    private var reasoningBuffer = ""
    private static let summaryCharacterLimit = 600

    func parse(_ line: Data) -> AIStreamResult? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let update = (object["params"] as? [String: Any])?["update"] as? [String: Any],
              let sessionUpdate = update["sessionUpdate"] as? String
        else { return nil }

        switch sessionUpdate {
        case "agent_thought_chunk":
            // grok-composer routes its reasoning here in agentic mode (not reliably to stdout).
            // Accumulate and emit a `status` so the running-status row scrolls with the thinking.
            guard let text = Self.chunkText(update["content"]), !text.isEmpty else { return nil }
            reasoningBuffer += text
            return AgentReasoningStatusStream.statusPreview(from: reasoningBuffer)
                .map { AIStreamResult(type: "status", text: $0) }
        case "agent_message_chunk":
            // Assistant content has started — the reasoning preview is no longer relevant.
            reasoningBuffer = ""
            return nil
        case "tool_call":
            guard let callID = update["toolCallId"] as? String else { return nil }
            reasoningBuffer = ""
            let title = (update["title"] as? String)?.trimmingCharacters(in: .whitespaces)
            let kind = (update["kind"] as? String).flatMap { $0.isEmpty ? nil : $0.capitalized }
            let call = register(callID, name: title.flatMap { $0.isEmpty ? nil : $0 } ?? kind ?? "tool")
            return AIStreamResult(
                type: "tool_call",
                text: nil,
                toolName: call.name,
                toolArgs: Self.argsSummary(update["rawInput"]),
                toolInvocationID: call.id,
                toolArgsJSON: Self.jsonString(update["rawInput"])
            )
        case "tool_call_update":
            guard let callID = update["toolCallId"] as? String else { return nil }
            // Decide whether this update completes the call. grok-composer is inconsistent: read/
            // search tools send a terminal `status` ("completed"/"failed"), but shell tools report
            // their result under `status: "in_progress"` with a `rawOutput`+`exit_code` and never a
            // `completed`. So treat EITHER a terminal status OR a present `exit_code` as completion.
            // Earlier intermediate updates (no status, no output) merely refine title/args → skip.
            let status = (update["status"] as? String)?.lowercased()
            let isTerminalStatus = status == "completed" || status == "failed" || status == "error"
            let exit = Self.exitCode(update)
            guard isTerminalStatus || exit != nil else { return nil }
            // Emit a result only once per call (a tool may send both an in_progress-with-output
            // update and a later terminal one).
            guard completedCalls.insert(callID).inserted else { return nil }
            // Terminal updates carry no `title`; reuse the opening tool_call's name so the
            // consumer (which requires a non-nil toolName to attach the result) completes the card.
            let fallback = (update["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "tool"
            let call = calls[callID] ?? register(callID, name: fallback)
            let isError = status == "failed" || status == "error" || (exit.map { $0 != 0 } ?? false)
            return AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: call.name,
                toolOutput: Self.resultSummary(from: update),
                toolInvocationID: call.id,
                toolResultJSON: Self.jsonString(update["rawOutput"]),
                toolIsError: isError
            )
        default:
            return nil
        }
    }

    private func register(_ callID: String, name: String) -> Call {
        if let existing = calls[callID] { return existing }
        let call = Call(id: UUID(), name: name)
        calls[callID] = call
        return call
    }

    /// Short human-readable argument for the card — the command, path (+ line range), or pattern.
    private static func argsSummary(_ rawInput: Any?) -> String? {
        guard let input = rawInput as? [String: Any] else { return jsonString(rawInput).map(truncate) }
        if let command = input["command"] as? String, !command.isEmpty {
            return truncate(command)
        }
        if let path = (input["path"] ?? input["file_path"]) as? String, !path.isEmpty {
            if let range = lineRange(input) {
                return truncate("\(path) (\(range))")
            }
            return truncate(path)
        }
        for key in ["glob_pattern", "pattern", "query", "url"] {
            if let value = input[key] as? String, !value.isEmpty {
                return truncate(value)
            }
        }
        return jsonString(rawInput).map(truncate)
    }

    /// `lines 1–80` for a Read with `limit` (and optional 0-based `offset`, shown 1-based).
    private static func lineRange(_ input: [String: Any]) -> String? {
        guard let limit = intValue(input["limit"]), limit > 0 else { return nil }
        let offset = intValue(input["offset"]) ?? 0
        return "lines \(offset + 1)–\(offset + limit)"
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    /// A concise result summary: an `exit N` prefix for shell tools, then the ACP `content` text
    /// (falling back to the raw output JSON).
    private static func resultSummary(from update: [String: Any]) -> String? {
        var body: String?
        if let content = update["content"] as? [[String: Any]] {
            let text = content
                .compactMap { ($0["content"] as? [String: Any])?["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { body = text }
        }
        if body == nil { body = jsonString(update["rawOutput"]) }
        if let exit = exitCode(update) {
            body = body.map { "exit \(exit) · \($0)" } ?? "exit \(exit)"
        }
        return body.map(truncate)
    }

    /// The shell exit code from `rawOutput.exit_code`, when present.
    private static func exitCode(_ update: [String: Any]) -> Int? {
        guard let raw = update["rawOutput"] as? [String: Any] else { return nil }
        return intValue(raw["exit_code"])
    }

    /// Extract the text from an ACP content chunk: a `{text}` object, a `{content:{text}}` wrapper,
    /// or an array of either.
    private static func chunkText(_ content: Any?) -> String? {
        if let dict = content as? [String: Any] {
            if let text = dict["text"] as? String { return text }
            if let inner = dict["content"] as? [String: Any], let text = inner["text"] as? String { return text }
        }
        if let array = content as? [[String: Any]] {
            let joined = array.compactMap {
                (($0["content"] as? [String: Any])?["text"] as? String) ?? ($0["text"] as? String)
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let string = content as? String { return string }
        return nil
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func truncate(_ string: String) -> String {
        string.count <= summaryCharacterLimit ? string : String(string.prefix(summaryCharacterLimit)) + "…"
    }
}

/// Locates the ACP `updates.jsonl` for the grok session created by the current run.
///
/// grok writes each run's events to `~/.grok/sessions/<percent-encoded-cwd>/<session-id>/`, but the
/// session id is only reported at the end of the run. So we snapshot the existing session
/// directories at launch and, on `locate()`, return the `updates.jsonl` of the newest directory
/// that appeared afterward. Assumes a single grok run per working directory at a time — true for
/// Agent Mode tabs.
struct GrokSessionToolLog {
    private let sessionsRoot: URL
    private let preexisting: Set<String>

    init?(workspacePath: String?, environment: [String: String]) {
        guard let cwd = workspacePath?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty,
              let encoded = cwd.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/").inverted)
        else { return nil }

        let grokHome: URL = if let home = environment["GROK_HOME"], !home.isEmpty {
            URL(fileURLWithPath: home)
        } else {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        }
        sessionsRoot = grokHome.appendingPathComponent("sessions").appendingPathComponent(encoded)
        preexisting = Self.sessionDirNames(in: sessionsRoot)
    }

    func locate() -> URL? {
        let fresh = Self.sessionDirNames(in: sessionsRoot).subtracting(preexisting)
        guard !fresh.isEmpty else { return nil }
        let newest = fresh
            .map { sessionsRoot.appendingPathComponent($0) }
            .max { Self.modified($0) < Self.modified($1) }
        guard let dir = newest else { return nil }
        let log = dir.appendingPathComponent("updates.jsonl")
        return FileManager.default.fileExists(atPath: log.path) ? log : nil
    }

    private static func sessionDirNames(in root: URL) -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(
            entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent)
        )
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
