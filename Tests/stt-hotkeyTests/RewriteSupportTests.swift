import XCTest
@testable import stt_hotkey

final class RewriteSupportTests: XCTestCase {
    func testRewriteConfigDefaults() throws {
        let config = try RewriteConfig.fromEnvValues([:])
        XCTAssertEqual(config.model, "gpt-5.2")
        XCTAssertNil(config.prompt)
        XCTAssertNil(config.reasoningEffort)
        XCTAssertNil(config.verbosity)
        XCTAssertTrue(config.fallbackToRaw)
    }

    func testRewriteConfigValidatesReasoningEffort() {
        XCTAssertThrowsError(try RewriteConfig.fromEnvValues([
            "REWRITE_REASONING_EFFORT": "superhigh"
        ])) { error in
            XCTAssertEqual(error as? RewriteSupportError, .invalidReasoningEffort("superhigh"))
        }
    }

    func testRewriteConfigValidatesVerbosity() {
        XCTAssertThrowsError(try RewriteConfig.fromEnvValues([
            "REWRITE_VERBOSITY": "verbose"
        ])) { error in
            XCTAssertEqual(error as? RewriteSupportError, .invalidVerbosity("verbose"))
        }
    }

    func testRewriteFallbackBooleanParsing() throws {
        let config = try RewriteConfig.fromEnvValues([
            "REWRITE_FALLBACK_TO_RAW": "false"
        ])
        XCTAssertFalse(config.fallbackToRaw)
    }

    func testRequestBuilderIncludesOptionalFields() throws {
        let config = RewriteConfig(
            model: "gpt-5-mini",
            prompt: "Rewrite this.",
            reasoningEffort: .minimal,
            verbosity: .high,
            fallbackToRaw: true
        )

        let bodyData = try RewriteRequestBuilder.makeBody(input: "raw text", config: config)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(object["model"] as? String, "gpt-5-mini")
        XCTAssertEqual(object["instructions"] as? String, "Rewrite this.")
        XCTAssertEqual(object["input"] as? String, "raw text")

        let reasoning = try XCTUnwrap(object["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "minimal")

        let text = try XCTUnwrap(object["text"] as? [String: Any])
        XCTAssertEqual(text["verbosity"] as? String, "high")
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "rewrite_output")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["rewritten_prompt"])
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(required, ["rewritten_prompt"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testRequestBuilderOmitsOptionalFieldsWhenNotSet() throws {
        let config = RewriteConfig(
            model: "gpt-5.2",
            prompt: "Rewrite this.",
            reasoningEffort: nil,
            verbosity: nil,
            fallbackToRaw: true
        )

        let bodyData = try RewriteRequestBuilder.makeBody(input: "raw text", config: config)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertNil(object["reasoning"])
        let text = try XCTUnwrap(object["text"] as? [String: Any])
        XCTAssertNil(text["verbosity"])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
    }

    func testResponseParserReadsOutputContentText() throws {
        let payload = """
        {
          "output": [
            {
              "content": [
                { "type": "output_text", "text": "{\\"rewritten_prompt\\":\\"rewritten prompt\\"}" }
              ]
            }
          ]
        }
        """
        let data = Data(payload.utf8)
        let text = try RewriteResponseParser.parseText(from: data)
        XCTAssertEqual(text, "rewritten prompt")
    }

    func testResponseParserReadsTopLevelOutputParsed() throws {
        let payload = """
        {
          "output_parsed": {
            "rewritten_prompt": "best rewrite"
          }
        }
        """
        let data = Data(payload.utf8)
        let text = try RewriteResponseParser.parseText(from: data)
        XCTAssertEqual(text, "best rewrite")
    }

    func testResponseParserFailsOnEmptyResponse() {
        let payload = """
        {
          "output": [
            {
              "content": [
                { "type": "output_text", "text": "{\\"not_rewritten_prompt\\":\\"value\\"}" }
              ]
            }
          ]
        }
        """
        let data = Data(payload.utf8)
        XCTAssertThrowsError(try RewriteResponseParser.parseText(from: data)) { error in
            XCTAssertEqual(error as? RewriteSupportError, .emptyResponse)
        }
    }

    func testResponseParserFailsOnMalformedJSON() {
        let data = Data("{not-json".utf8)
        XCTAssertThrowsError(try RewriteResponseParser.parseText(from: data)) { error in
            XCTAssertEqual(error as? RewriteSupportError, .invalidResponse)
        }
    }
}
