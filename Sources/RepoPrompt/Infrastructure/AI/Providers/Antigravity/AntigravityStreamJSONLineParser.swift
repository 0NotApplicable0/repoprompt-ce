import Foundation

enum AntigravityStreamJSONLineParser {
    enum Event: Equatable {
        case assistantDelta(String)
        case result(response: String, status: String?)
        case ignored
        case plain(String)
    }

    static func parse(_ line: String) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return .plain(line) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return .ignored }
        if event == "step_update",
           let step = object["step_update"] as? [String: Any],
           step["step_type"] as? String == "agent_response",
           let text = step["text_delta"] as? String,
           !text.isEmpty { return .assistantDelta(text) }
        if event == "result", let result = object["result"] as? [String: Any],
           let response = result["response"] as? String { return .result(response: response, status: result["status"] as? String) }
        return .ignored
    }
}
