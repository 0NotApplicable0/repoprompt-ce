import Foundation

/// Generic tailer that surfaces an agent CLI's tool activity from a JSONL session-event log.
///
/// Some headless CLI agents (grok, …) do NOT emit tool calls on their stdout stream — only the
/// final assistant text. Their per-tool activity is written to a side-channel session log instead.
/// This tailer waits for that log to appear (the agent creates it asynchronously), then reads it
/// incrementally and forwards each parsed tool event (`tool_call`/`tool_result`) to the provider's
/// stream so the Agent Mode UI renders live tool cards.
///
/// It is intentionally agent-agnostic: callers supply `locate` (find the log URL once it exists)
/// and `parse` (one JSONL line → an optional `AIStreamResult`). Runs until the surrounding Task is
/// cancelled (the provider cancels it when the run completes). Best-effort and fail-open: any I/O
/// failure simply ends tailing without affecting the main run.
enum AgentSessionToolLogStream {
    static func tail(
        into continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        locate: @Sendable @escaping () -> URL?,
        parse: @Sendable @escaping (Data) -> AIStreamResult?,
        pollNanos: UInt64 = 200_000_000
    ) async {
        // 1. Wait for the session log to be created (poll; the agent writes it shortly after start).
        var located: URL?
        while !Task.isCancelled, located == nil {
            located = locate()
            if located == nil {
                try? await Task.sleep(nanoseconds: pollNanos)
            }
        }
        guard !Task.isCancelled,
              let url = located,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return }
        defer { try? handle.close() }

        // 2. Tail the growing file: read new bytes, frame into lines, forward parsed tool events.
        var framer = LineFramer()
        while !Task.isCancelled {
            if let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                framer.feed(chunk) { line in
                    if let result = parse(line) {
                        continuation.yield(result)
                    }
                }
            } else {
                try? await Task.sleep(nanoseconds: pollNanos)
            }
        }
    }
}
