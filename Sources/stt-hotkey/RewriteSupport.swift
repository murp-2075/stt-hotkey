import Foundation

enum RewriteReasoningEffort: String, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    static var allowedValuesDescription: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }
}

enum RewriteVerbosity: String, CaseIterable {
    case low
    case medium
    case high

    static var allowedValuesDescription: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }
}

enum RewriteSupportError: LocalizedError, Equatable {
    case invalidReasoningEffort(String)
    case invalidVerbosity(String)
    case missingPrompt
    case invalidResponse
    case httpError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidReasoningEffort(let value):
            return "Invalid REWRITE_REASONING_EFFORT '\(value)'. Allowed: \(RewriteReasoningEffort.allowedValuesDescription)."
        case .invalidVerbosity(let value):
            return "Invalid REWRITE_VERBOSITY '\(value)'. Allowed: \(RewriteVerbosity.allowedValuesDescription)."
        case .missingPrompt:
            return "Missing REWRITE_PROMPT."
        case .invalidResponse:
            return "Invalid rewrite response."
        case .httpError(let status, let body):
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Rewrite request failed (HTTP \(status))."
            }
            return "Rewrite request failed (HTTP \(status)): \(body)"
        case .emptyResponse:
            return "Rewrite response did not contain text."
        }
    }
}

struct RewriteConfig: Equatable {
    let model: String
    let prompt: String?
    let reasoningEffort: RewriteReasoningEffort?
    let verbosity: RewriteVerbosity?
    let fallbackToRaw: Bool

    static func fromEnvValues(_ values: [String: String]) throws -> RewriteConfig {
        let model = normalized(values["REWRITE_MODEL"]) ?? "gpt-5.2"
        let prompt = normalized(values["REWRITE_PROMPT"])

        let reasoningEffort: RewriteReasoningEffort?
        if let raw = normalized(values["REWRITE_REASONING_EFFORT"])?.lowercased() {
            guard let parsed = RewriteReasoningEffort(rawValue: raw) else {
                throw RewriteSupportError.invalidReasoningEffort(raw)
            }
            reasoningEffort = parsed
        } else {
            reasoningEffort = nil
        }

        let verbosity: RewriteVerbosity?
        if let raw = normalized(values["REWRITE_VERBOSITY"])?.lowercased() {
            guard let parsed = RewriteVerbosity(rawValue: raw) else {
                throw RewriteSupportError.invalidVerbosity(raw)
            }
            verbosity = parsed
        } else {
            verbosity = nil
        }

        let fallbackToRaw = parseBool(values["REWRITE_FALLBACK_TO_RAW"], defaultValue: true)
        return RewriteConfig(
            model: model,
            prompt: prompt,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity,
            fallbackToRaw: fallbackToRaw
        )
    }

    static func parseBool(_ raw: String?, defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        let normalizedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedRaw.isEmpty { return defaultValue }
        if ["1", "true", "yes", "y", "on"].contains(normalizedRaw) {
            return true
        }
        if ["0", "false", "no", "n", "off"].contains(normalizedRaw) {
            return false
        }
        return defaultValue
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RewriteRequestBuilder {
    static func makeBody(input: String, config: RewriteConfig) throws -> Data {
        guard let prompt = config.prompt, !prompt.isEmpty else {
            throw RewriteSupportError.missingPrompt
        }

        let rewrittenPromptSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "rewritten_prompt": [
                    "type": "string",
                    "description": "Single best rewritten prompt."
                ]
            ],
            "required": ["rewritten_prompt"],
            "additionalProperties": false
        ]

        var text: [String: Any] = [
            "format": [
                "type": "json_schema",
                "name": "rewrite_output",
                "schema": rewrittenPromptSchema,
                "strict": true
            ]
        ]

        if let verbosity = config.verbosity {
            text["verbosity"] = verbosity.rawValue
        }

        var payload: [String: Any] = [
            "model": config.model,
            "instructions": prompt,
            "input": input,
            "text": text
        ]

        if let reasoningEffort = config.reasoningEffort {
            payload["reasoning"] = ["effort": reasoningEffort.rawValue]
        }

        return try JSONSerialization.data(withJSONObject: payload)
    }
}

enum RewriteResponseParser {
    static func parseText(from data: Data) throws -> String {
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RewriteSupportError.invalidResponse
        }

        guard let object = rootObject as? [String: Any] else {
            throw RewriteSupportError.invalidResponse
        }

        if let rewritten = rewrittenPrompt(fromParsedObject: object["output_parsed"]) {
            return rewritten
        }

        if let outputText = stringValue(object["output_text"]),
           let rewritten = rewrittenPrompt(fromJSONString: outputText) {
            return rewritten
        }

        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                if let rewritten = rewrittenPrompt(fromOutputItem: item) {
                    return rewritten
                }
            }
        }

        throw RewriteSupportError.emptyResponse
    }

    private static func rewrittenPrompt(fromOutputItem item: [String: Any]) -> String? {
        if let rewritten = rewrittenPrompt(fromParsedObject: item["parsed"]) {
            return rewritten
        }

        if let text = stringValue(item["text"]),
           let rewritten = rewrittenPrompt(fromJSONString: text) {
            return rewritten
        }

        if let outputText = stringValue(item["output_text"]),
           let rewritten = rewrittenPrompt(fromJSONString: outputText) {
            return rewritten
        }

        if let content = item["content"] as? [[String: Any]] {
            for part in content {
                if let rewritten = rewrittenPrompt(fromParsedObject: part["parsed"]) {
                    return rewritten
                }
                if let text = stringValue(part["text"]),
                   let rewritten = rewrittenPrompt(fromJSONString: text) {
                    return rewritten
                }
                if let outputText = stringValue(part["output_text"]),
                   let rewritten = rewrittenPrompt(fromJSONString: outputText) {
                    return rewritten
                }
            }
        }
        return nil
    }

    private static func rewrittenPrompt(fromParsedObject value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        return stringValue(object["rewritten_prompt"])
    }

    private static func rewrittenPrompt(fromJSONString jsonText: String) -> String? {
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return stringValue(object["rewritten_prompt"])
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }
}

@MainActor
final class OpenAIRewriter {
    func rewrite(text: String, apiKey: String, config: RewriteConfig) async throws -> String {
        let body = try RewriteRequestBuilder.makeBody(input: text, config: config)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RewriteSupportError.invalidResponse
        }

        if http.statusCode >= 400 {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw RewriteSupportError.httpError(http.statusCode, body)
        }

        return try RewriteResponseParser.parseText(from: responseData)
    }
}
