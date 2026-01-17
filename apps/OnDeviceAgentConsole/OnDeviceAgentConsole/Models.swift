import Foundation

struct WDAEnvelope<T: Decodable>: Decodable {
  let value: T
}

struct AgentStatus: Decodable {
  let running: Bool
  let lastMessage: String
  let config: AgentConfig
  let notes: String
  let logLines: Int

  enum CodingKeys: String, CodingKey {
    case running
    case lastMessage = "last_message"
    case config
    case notes
    case logLines = "log_lines"
  }
}

struct AgentConfig: Decodable {
  let task: String
  let baseUrl: String
  let model: String
  let apiMode: String

  let apiKeySet: Bool
  let rememberApiKey: Bool

  let useCustomSystemPrompt: Bool
  let systemPrompt: String

  let debugLogRawAssistant: Bool
  let reasoningEffort: String
  let doubaoSeedEnableSessionCache: Bool

  let maxSteps: Int
  let maxCompletionTokens: Int
  let timeoutSeconds: Double
  let stepDelaySeconds: Double

  let insecureSkipTlsVerify: Bool

  enum CodingKeys: String, CodingKey {
    case task
    case baseUrl = "base_url"
    case model
    case apiMode = "api_mode"
    case apiKeySet = "api_key_set"
    case rememberApiKey = "remember_api_key"
    case useCustomSystemPrompt = "use_custom_system_prompt"
    case systemPrompt = "system_prompt"
    case debugLogRawAssistant = "debug_log_raw_assistant"
    case reasoningEffort = "reasoning_effort"
    case doubaoSeedEnableSessionCache = "doubao_seed_enable_session_cache"
    case maxSteps = "max_steps"
    case maxCompletionTokens = "max_completion_tokens"
    case timeoutSeconds = "timeout_seconds"
    case stepDelaySeconds = "step_delay_seconds"
    case insecureSkipTlsVerify = "insecure_skip_tls_verify"
  }
}

struct AgentLogsPayload: Decodable {
  let lines: [String]
}

struct AgentChatPayload: Decodable {
  let items: [AgentChatItem]
}

struct AgentChatItem: Decodable, Identifiable {
  let ts: String?
  let step: Int?
  let kind: String
  let attempt: Int?
  let text: String?
  let content: String?
  let reasoning: String?
  let raw: String?

  var id: String {
    "\(step ?? -1)-\(kind)-\(attempt ?? 0)-\(ts ?? "")"
  }
}

struct AgentStartPayload: Decodable {
  let ok: Bool?
  let error: String?
  let status: AgentStatus?
}

struct AgentConfigRequest: Encodable {
  var base_url: String
  var model: String
  var api_mode: String
  var use_custom_system_prompt: Bool
  var system_prompt: String
  var remember_api_key: Bool
  var debug_log_raw_assistant: Bool
  var doubao_seed_enable_session_cache: Bool
  var task: String
  var max_steps: Int
  var max_completion_tokens: Int
  var reasoning_effort: String
  var timeout_seconds: Double
  var step_delay_seconds: Double
  var insecure_skip_tls_verify: Bool
  var api_key: String?
}

