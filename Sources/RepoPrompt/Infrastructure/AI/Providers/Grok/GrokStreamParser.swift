import Foundation

/// Tolerant parser converting `grok --output-format json` stdout into `AIStreamResult` events.
///
/// `grok` v0.2.56 with `--output-format json` prints exactly ONE final JSON object on success:
///   `{"text": "...", "stopReason": "EndTurn", "sessionId": "...", "requestId": "..."}`
/// (a `"thought"` field may also appear). On failure it prints an error object:
///   `{"type": "error", "message": "..."}`
///
/// Parsing rules:
///   - If the top-level object has `"type" == "error"`, surface its `message` as an `error`
///     stream result (rendered as an error item by the consumer, mirroring the Codex CLI path).
///   - Otherwise emit the `text` field as assistant `content`.
///
/// It is intentionally tolerant of future/alternate structured output: it first tries a single
/// JSON object with a known text field, then JSON Lines, and finally falls back to treating
/// stdout as plain UTF-8 text. It never throws and never emits a `message_stop` (the provider
/// owns completion). Unknown shapes degrade to plain text.
enum GrokStreamParser {
    /// Text-bearing keys across plausible grok structured shapes. `text` is grok's primary
    /// field; the rest keep the parser tolerant of alternate/legacy shapes.
    private static let textKeys = ["text", "response", "content", "message", "output"]

    /// Parse the full captured stdout into zero or more stream results.
    static func parseFinalOutput(_ data: Data) -> [AIStreamResult] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1) Whole-output JSON object — grok's `--output-format json` single-object contract.
        // Yields either an `error` result (top-level `type == "error"`) or a `content` result.
        if let single = resultFromJSONObjectString(trimmed) {
            return [single]
        }

        // 2) JSON Lines: every non-empty line is a JSON object that yields a result. Only take
        // this branch when *all* lines parse; a partial parse falls through to plain text so we
        // never drop unparsed lines.
        //
        // Split on any newline variant (LF, CRLF, CR). `\r\n` is a single Swift grapheme, so a
        // `Character`-based `split(separator: "\n")` would NOT break CRLF-terminated JSONL into
        // separate lines; `components(separatedBy: .newlines)` (scalar-based) handles all variants
        // — mirroring `GrokModelRegistry.parseModels`.
        let lines = trimmed
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        if lines.count > 1, lines.allSatisfy({ looksLikeJSONObject($0[...]) }) {
            let results = lines.compactMap { resultFromJSONObjectString($0) }
            if !results.isEmpty, results.count == lines.count {
                return results
            }
        }

        // 3) Plain text (tolerant fallback for non-JSON stdout).
        return [contentResult(trimmed)]
    }

    // MARK: - Streaming (`--output-format streaming-json`)

    /// Parse ONE line of grok's `--output-format streaming-json` NDJSON stream into a live stream
    /// result, or `nil` for lines that carry nothing renderable.
    ///
    /// grok streaming-json events (one JSON object per line):
    ///   - `{"type":"thought","data":"…"}` → incremental reasoning delta (`reasoning`)
    ///   - `{"type":"text","data":"…"}`    → incremental assistant content delta (`content`)
    ///   - `{"type":"end","stopReason":"…","sessionId":"…"}` → terminal (`message_stop`)
    ///   - `{"type":"error","message":"…"}` → error (`error`)
    ///
    /// Note: grok does NOT surface tool calls on this stream (they are internal to the CLI), so
    /// this parser intentionally maps only reasoning/content/terminal/error events. Unknown event
    /// types degrade to `nil`.
    static func parseStreamingEvent(_ data: Data) -> AIStreamResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (object["type"] as? String)?.lowercased()
        else { return nil }

        switch type {
        case "thought":
            guard let text = object["data"] as? String, !text.isEmpty else { return nil }
            return AIStreamResult(type: "reasoning", text: nil, reasoning: text)
        case "text":
            guard let text = object["data"] as? String, !text.isEmpty else { return nil }
            return contentResult(text)
        case "end":
            return AIStreamResult(
                type: "message_stop",
                text: nil,
                providerSessionID: object["sessionId"] as? String,
                stopReason: object["stopReason"] as? String
            )
        case "error":
            let message = (object["message"] as? String)
                ?? (object["data"] as? String)
                ?? "Grok CLI reported an error."
            return errorResult(message)
        default:
            return nil
        }
    }

    static func contentResult(_ text: String) -> AIStreamResult {
        AIStreamResult(
            type: "content",
            text: text,
            reasoning: nil,
            promptTokens: nil,
            completionTokens: nil,
            cost: nil
        )
    }

    static func errorResult(_ message: String) -> AIStreamResult {
        AIStreamResult(
            type: "error",
            text: message,
            reasoning: nil,
            promptTokens: nil,
            completionTokens: nil,
            cost: nil
        )
    }

    private static func looksLikeJSONObject(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
    }

    /// Decode a single JSON object string into a stream result. Returns an `error` result when
    /// the object's top-level `type` is `"error"`, otherwise the first non-empty text field as
    /// `content`. Returns `nil` when the string is not a JSON object or carries no usable text.
    private static func resultFromJSONObjectString(_ string: String) -> AIStreamResult? {
        // Trim surrounding whitespace/newlines (notably a trailing CRLF `\r`) so a JSONL line
        // split on `\n` parses cleanly — JSONSerialization rejects trailing bytes after the value.
        let string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // grok failure shape: `{"type": "error", "message": "..."}` — surface as an error.
        if let type = object["type"] as? String,
           type.caseInsensitiveCompare("error") == .orderedSame
        {
            let message = (object["message"] as? String)
                ?? (object["text"] as? String)
                ?? "Grok CLI reported an error."
            return errorResult(message)
        }

        for key in textKeys {
            if let value = object[key] as? String, !value.isEmpty {
                return contentResult(value)
            }
        }
        return nil
    }
}
