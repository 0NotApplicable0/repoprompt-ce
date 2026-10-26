import Foundation

/// Generic stream decorator that surfaces a CLI agent's incremental `reasoning` as a live
/// running-status signal.
///
/// The Agent Mode consumer ignores `reasoning` events for non-Claude-native agents (grok,
/// antigravity, future CLI agents) but renders `status` events on the transient running-status row.
/// This decorator passes every upstream event through unchanged and, for each `reasoning` event,
/// accumulates the text and injects a compact single-line `status` preview so the row scrolls with
/// the agent's current thought — which, for tool-using agents, also narrates the actions it takes
/// (read/grep/etc.). The reasoning buffer resets once the agent produces an answer or acts, so each
/// thinking burst starts fresh.
///
/// Reusable by any headless provider whose `AIStreamResult` stream carries `reasoning` deltas:
/// wrap the provider's stream with ``withReasoningStatus(_:previewLimit:)`` before returning it.
enum AgentReasoningStatusStream {
    /// Wrap `upstream` so `reasoning` events also drive `status` events on the running-status row.
    static func withReasoningStatus(
        _ upstream: AsyncThrowingStream<AIStreamResult, Error>,
        previewLimit: Int = 160
    ) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                do {
                    for try await event in upstream {
                        // Pass the original event through unchanged.
                        continuation.yield(event)

                        switch event.type {
                        case "reasoning":
                            guard let chunk = event.reasoning, !chunk.isEmpty else { break }
                            buffer += chunk
                            if let preview = statusPreview(from: buffer, limit: previewLimit) {
                                continuation.yield(AIStreamResult(type: "status", text: preview))
                            }
                        case "content", "tool_call", "tool_result":
                            // The agent has produced output or acted — drop the stale thinking
                            // buffer so the next reasoning burst renders on its own.
                            buffer = ""
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compact single-line preview of accumulated reasoning for the running-status row.
    /// Collapses all whitespace to single spaces and keeps the trailing `limit` characters so the
    /// row scrolls with the latest thinking; returns `nil` when there is nothing displayable.
    static func statusPreview(from reasoning: String, limit: Int = 160) -> String? {
        let collapsed = reasoning.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return "…" + trimmed.suffix(limit)
    }
}
