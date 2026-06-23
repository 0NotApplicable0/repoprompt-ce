import Foundation

/// Converts one agy trajectory `steps` row into Agent Mode tool-card events.
///
/// agy stores tool activity as nested protobuf `step_payload` (nothing on stdout):
/// `payload → field 5 (step) → field 4 (tool) → {1: callId, 2: toolName, 3: argsJSON}`. A row is a
/// tool call iff that tool name exists. We emit a `tool_call` always and a `tool_result` ONLY when
/// the step is terminal (`status == 3`) — never fabricating completion for an in-flight tool. One
/// invocation id per call id keeps the card stable across polls. Output bodies are not extracted
/// (agy stores them as an opaque binary blob). Fail-open: any missing field returns nil.
/// `@unchecked Sendable`: touched only from the single trajectory tailer task.
final class AntigravityToolStepParser: @unchecked Sendable {
    static let terminalStatus: Int64 = 3

    struct ParsedToolStep { let invocationID: UUID
        let call: AIStreamResult
        let result: AIStreamResult?
    }

    private var invocationIDs: [String: UUID] = [:]
    private static let summaryLimit = 600

    func parse(status: Int64, payload: Data) -> ParsedToolStep? {
        let top = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(payload)
        guard let step = top[5] else { return nil }
        let stepFields = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(step)
        guard let tool = stepFields[4] else { return nil } // non-tool step (no tool message)
        let toolFields = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(tool)
        guard let nameData = toolFields[2], let toolName = String(data: nameData, encoding: .utf8),
              !toolName.isEmpty else { return nil }

        // agy wraps RepoPrompt MCP calls as `call_mcp_tool`; those already surface as cards via
        // expected-PID MCP tool tracking with the real tool name + arguments, so skip the generic
        // trajectory duplicate (avoids a doubled, less-detailed card).
        if toolName == "call_mcp_tool" { return nil }

        let callID = toolFields[1].flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString
        let invocationID = invocationIDs[callID] ?? {
            let id = UUID()
            invocationIDs[callID] = id
            return id
        }()

        let argsJSON = toolFields[3].flatMap { String(data: $0, encoding: .utf8) }
        let summary = argsJSON.flatMap(Self.summary(fromArgsJSON:))

        let call = AIStreamResult(
            type: "tool_call", text: nil,
            toolName: toolName,
            toolArgs: summary.map(Self.truncate),
            toolInvocationID: invocationID,
            toolArgsJSON: argsJSON
        )
        let result: AIStreamResult? = status == Self.terminalStatus
            ? AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: toolName,
                toolInvocationID: invocationID,
                toolIsError: false
            )
            : nil
        return ParsedToolStep(invocationID: invocationID, call: call, result: result)
    }

    /// The card's argument line. Prefers the SPECIFIC argument — the actual command, file path
    /// (+ line range), or query/pattern — so cards say which file or what command (parity with grok),
    /// and falls back to agy's human-readable `toolSummary`/`toolAction` only when no specific arg
    /// exists.
    private static func summary(fromArgsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let command = (obj["CommandLine"] ?? obj["Command"]) as? String, !command.isEmpty {
            return command
        }
        if let path = (obj["AbsolutePath"] ?? obj["FilePath"] ?? obj["Path"]) as? String, !path.isEmpty {
            if let range = lineRange(obj) { return "\(path) (\(range))" }
            return path
        }
        for key in ["Query", "Pattern", "GlobPattern", "SearchString", "Url"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        for key in ["toolSummary", "toolAction"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    /// `lines 10–40` (or `from line 10`) for a ranged `view_file`, when the args carry line bounds.
    private static func lineRange(_ obj: [String: Any]) -> String? {
        func intValue(_ key: String) -> Int? {
            if let i = obj[key] as? Int { return i }
            if let n = obj[key] as? NSNumber { return n.intValue }
            if let d = obj[key] as? Double { return Int(d) }
            return nil
        }
        guard let start = intValue("StartLine") else { return nil }
        if let end = intValue("EndLine"), end >= start { return "lines \(start)–\(end)" }
        return "from line \(start)"
    }

    private static func truncate(_ s: String) -> String {
        s.count <= summaryLimit ? s : String(s.prefix(summaryLimit)) + "…"
    }
}
