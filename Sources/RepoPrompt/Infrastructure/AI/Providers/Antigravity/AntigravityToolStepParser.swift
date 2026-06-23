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

    private static func summary(fromArgsJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["toolSummary", "CommandLine", "AbsolutePath", "Query", "toolAction"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private static func truncate(_ s: String) -> String {
        s.count <= summaryLimit ? s : String(s.prefix(summaryLimit)) + "…"
    }
}
