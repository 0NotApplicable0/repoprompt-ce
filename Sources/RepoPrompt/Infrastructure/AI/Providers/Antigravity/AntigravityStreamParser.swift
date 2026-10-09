import Foundation

/// Tolerant parser converting `agy --print` stdout into `AIStreamResult` content events.
///
/// `agy` v1.0.9 prints a plain-text response (no `--output-format`/JSON flag), so this
/// parser defaults to treating stdout as plain UTF-8 text. It is intentionally tolerant of
/// future structured output: it first tries a single JSON object with a known text field,
/// then JSON Lines, and finally falls back to plain text. It never throws and never emits a
/// `message_stop` (the provider owns completion). Unknown shapes degrade to plain text.
enum AntigravityStreamParser {
    /// Text-bearing keys across plausible agy / Gemini structured shapes.
    private static let textKeys = ["response", "text", "content", "message", "output"]

    /// Parse the full captured stdout into zero or more `content` results.
    static func parseFinalOutput(_ data: Data) -> [AIStreamResult] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 1) Whole-output JSON object with a known text field.
        if let single = contentFromJSONObjectString(trimmed) {
            return [single]
        }

        // 2) JSON Lines: every non-empty line is a JSON object that yields content. Only
        // take this branch when *all* lines parse; a partial parse falls through to plain
        // text so we never drop unparsed lines.
        //
        // Split on any newline variant (LF, CRLF, CR). `\r\n` is a single Swift grapheme, so a
        // `Character`-based `split(separator: "\n")` would NOT break CRLF-terminated JSONL into
        // separate lines; `components(separatedBy: .newlines)` (scalar-based) handles all variants
        // — mirroring `AntigravityModelRegistry.parseModels`.
        let lines = trimmed
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        if lines.count > 1, lines.allSatisfy({ looksLikeJSONObject($0[...]) }) {
            let results = lines.compactMap { contentFromJSONObjectString($0) }
            if !results.isEmpty, results.count == lines.count {
                return results
            }
        }

        // 3) Plain text (the v1.0.9 print-mode contract).
        return [contentResult(trimmed)]
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

    /// Detects agy's headless `--print` poll-cap timeout (~5 min / 1494 polls). agy prints
    /// "Error: timed out waiting for response" to stdout and logs "Print mode: timed out after
    /// N polls"; the process still exits 0, so this content check is how we recognise it.
    static func isPrintModePollCapTimeout(stdout: String, logTail: String?) -> Bool {
        for text in [stdout, logTail ?? ""] {
            let lower = text.lowercased()
            if lower.contains("timed out waiting for response") { return true }
            if lower.contains("print mode: timed out after"), lower.contains("polls") { return true }
        }
        return false
    }

    /// True if a single stdout line is agy's poll-cap marker. Lets the provider withhold the marker
    /// from streamed content while still classifying the turn as capped via the accumulated stdout.
    static func isPollCapMarkerLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("timed out waiting for response") { return true }
        if lower.contains("print mode: timed out after"), lower.contains("polls") { return true }
        return false
    }

    private static func looksLikeJSONObject(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
    }

    private static func contentFromJSONObjectString(_ string: String) -> AIStreamResult? {
        // Trim surrounding whitespace/newlines (notably a trailing CRLF `\r`) so a JSONL line
        // split on `\n` parses cleanly — JSONSerialization rejects trailing bytes after the value.
        let string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for key in textKeys {
            if let value = object[key] as? String, !value.isEmpty {
                return contentResult(value)
            }
        }
        return nil
    }
}
