import XCTest

@testable import OnDeviceAgentConsole

final class ConsoleParsersTests: XCTestCase {
  func testSSEEventParserEmitsEvent() {
    var p = SSEEventParser()
    XCTAssertNil(p.consume(line: "event: snapshot"))
    XCTAssertNil(p.consume(line: "data: {\"ok\":true}"))
    XCTAssertNil(p.consume(line: ": comment"))
    let ev = p.consume(line: "")
    XCTAssertEqual(ev, SSEEvent(name: "snapshot", data: "{\"ok\":true}"))
  }

  func testValidateQRCodeConfigRawRejectsUnknownKey() {
    let raw = #"{"base_url":"https://example.com","unknown_key":123}"#
    let errors = ConsoleStore.validateQRCodeConfigRaw(raw)
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].contains("unknown_key"))
  }

  func testValidateQRCodeConfigRawRejectsNonPositive() {
    let raw = #"{"max_steps":0}"#
    let errors = ConsoleStore.validateQRCodeConfigRaw(raw)
    XCTAssertEqual(errors.count, 1)
    XCTAssertTrue(errors[0].contains("max_steps"))
  }

  func testConfigValidatorRequiresApiKeyAndTokenForLAN() throws {
    var draft = ConsoleStore.Draft()
    draft.baseUrl = "https://example.com"
    draft.model = "test-model"
    draft.task = "test-task"
    draft.maxSteps = "1"
    draft.timeoutSeconds = "1"
    draft.stepDelaySeconds = "1"
    draft.maxCompletionTokens = "1"
    draft.apiKey = ""
    draft.agentToken = ""

    let statusJSON = #"""
    {
      "running": false,
      "last_message": "",
      "config": { "api_key_set": false },
      "notes": "",
      "token_usage": {},
      "log_lines": 0
    }
    """#
    let st = try JSONDecoder().decode(AgentStatus.self, from: Data(statusJSON.utf8))

    let issues = ConsoleConfigValidator.runValidationIssues(
      draft: draft,
      status: st,
      isLoopbackRunnerURL: false
    )
    XCTAssertTrue(issues.contains(.apiKeyRequired))
    XCTAssertTrue(issues.contains(.agentTokenRequiredForLAN))
  }

  func testDecodeWDAEnvelopeOrDirectSupportsBothShapes() throws {
    let directJSON = #"{"requests":1,"input_tokens":2,"output_tokens":3,"cached_tokens":4,"total_tokens":5}"#
    let envJSON = #"{"value":\#(directJSON)}"#

    let direct = try AgentClient.decodeWDAEnvelopeOrDirect(
      TokenUsage.self,
      from: Data(directJSON.utf8)
    )
    let env = try AgentClient.decodeWDAEnvelopeOrDirect(
      TokenUsage.self,
      from: Data(envJSON.utf8)
    )

    XCTAssertEqual(direct.requests, 1)
    XCTAssertEqual(env.requests, 1)
    XCTAssertEqual(direct.cachedTokens, 4)
    XCTAssertEqual(env.totalTokens, 5)
  }
}
