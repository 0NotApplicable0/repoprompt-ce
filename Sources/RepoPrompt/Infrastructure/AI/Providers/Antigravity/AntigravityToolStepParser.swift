import Foundation

/// Converts one agy trajectory `steps` row into Agent Mode tool-card events.
///
/// agy stores tool activity as nested protobuf `step_payload` (nothing on stdout):
/// `payload → field 5 (step) → field 4 (tool) → {1: callId, 2: toolName, 3: argsJSON}`. A row is a
/// tool call iff that tool name exists. We emit a `tool_call` always and a `tool_result` ONLY when
/// the step is terminal (`status == 3` for success, `status == 7` for failure) — never fabricating
/// completion for an in-flight tool. One invocation id per call id keeps the card stable across
/// polls. Output bodies are not extracted (agy stores them as an opaque binary blob). Fail-open:
/// any missing field is classified as a non-tool row.
/// `@unchecked Sendable`: touched only from the single trajectory tailer task.
final class AntigravityToolStepParser: @unchecked Sendable {
    static let terminalStatus: Int64 = 3
    static let failedTerminalStatus: Int64 = 7

    enum ParseOutcome {
        case nonTool
        case suppressedMCP(isTerminal: Bool)
        case visible(ParsedToolStep)
    }

    struct ParsedToolStep {
        let invocationID: UUID
        let call: AIStreamResult
        let result: AIStreamResult?
    }

    private var invocationIDs: [String: UUID] = [:]
    private static let summaryLimit = 600
    private static let deniedMCPResultJSON =
        #"{"status":"failed","error":"Antigravity denied tool permission in headless mode."}"#
    private static let failedNativeResultJSON =
        #"{"status":"failed","error":"Antigravity reported a failed tool step."}"#

    func parse(
        status: Int64,
        payload: Data,
        failureKind: AntigravityTrajectoryStore.FailureKind? = nil
    ) -> ParsedToolStep? {
        guard case let .visible(parsed) = parseRow(
            status: status,
            payload: payload,
            failureKind: failureKind
        ) else { return nil }
        return parsed
    }

    func parseRow(
        status: Int64,
        payload: Data,
        failureKind: AntigravityTrajectoryStore.FailureKind? = nil
    ) -> ParseOutcome {
        let top = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(payload)
        guard let step = top[5] else { return .nonTool }
        let stepFields = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(step)
        guard let tool = stepFields[4] else { return .nonTool } // non-tool step (no tool message)
        let toolFields = AntigravityTrajectoryProtoScanner.lengthDelimitedFields(tool)
        guard let nameData = toolFields[2], let toolName = String(data: nameData, encoding: .utf8),
              !toolName.isEmpty else { return .nonTool }

        let isFailed = status == Self.failedTerminalStatus
        let isTerminal = status == Self.terminalStatus || isFailed
        let argsJSON = toolFields[3].flatMap { String(data: $0, encoding: .utf8) }
        let isMCPWrapper = toolName == "call_mcp_tool"

        // agy wraps RepoPrompt MCP calls as `call_mcp_tool`; those already surface as cards via
        // expected-PID MCP tool tracking with the real tool name + arguments, so skip the generic
        // trajectory duplicate (avoids a doubled, less-detailed card). A confirmed permission
        // denial never reaches RepoPrompt's MCP server, so surface only that narrowly classified
        // fallback. Other status-7 wrappers remain suppressed: status 7 is a generic failure and
        // expected-PID MCP tracking remains authoritative. Keep pending wrappers distinct from
        // non-tool rows so the trajectory watermark waits for their final status.
        if isMCPWrapper,
           !(isFailed && failureKind == .headlessPermissionDenied)
        {
            return .suppressedMCP(isTerminal: isTerminal)
        }

        let callID = toolFields[1].flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString
        let invocationID = invocationIDs[callID] ?? {
            let id = UUID()
            invocationIDs[callID] = id
            return id
        }()

        let mcpIdentity = isMCPWrapper ? argsJSON.flatMap(Self.mcpIdentity(fromArgsJSON:)) : nil
        let visibleToolName = mcpIdentity?.toolName ?? toolName
        let summary = mcpIdentity?.summary ?? argsJSON.flatMap(Self.summary(fromArgsJSON:))

        let call = AIStreamResult(
            type: "tool_call", text: nil,
            toolName: visibleToolName,
            toolArgs: summary.map(Self.truncate),
            toolInvocationID: invocationID,
            toolArgsJSON: argsJSON
        )
        let result: AIStreamResult? = isTerminal
            ? AIStreamResult(
                type: "tool_result",
                text: nil,
                toolName: visibleToolName,
                toolOutput: isFailed
                    ? (isMCPWrapper ? Self.deniedMCPResultJSON : Self.failedNativeResultJSON)
                    : nil,
                toolInvocationID: invocationID,
                toolResultJSON: isFailed
                    ? (isMCPWrapper ? Self.deniedMCPResultJSON : Self.failedNativeResultJSON)
                    : nil,
                toolIsError: isFailed
            )
            : nil
        return .visible(ParsedToolStep(invocationID: invocationID, call: call, result: result))
    }

    private struct MCPIdentity {
        let toolName: String?
        let serverName: String?

        var summary: String? {
            switch (serverName, toolName) {
            case let (server?, tool?): "\(server)/\(tool)"
            case let (server?, nil): server
            case (nil, _): nil
            }
        }
    }

    private static func mcpIdentity(fromArgsJSON json: String) -> MCPIdentity? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func nonemptyString(_ key: String) -> String? {
            guard let value = obj[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let identity = MCPIdentity(
            toolName: nonemptyString("ToolName"),
            serverName: nonemptyString("ServerName")
        )
        return identity.toolName == nil && identity.serverName == nil ? nil : identity
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
