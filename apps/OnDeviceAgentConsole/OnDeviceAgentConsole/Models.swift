import Foundation

struct WDAEnvelope<T: Decodable>: Decodable {
  let value: T
}

private extension KeyedDecodingContainer {
  func decodeStringOrEmpty(forKey key: Key) -> String {
    if let s = try? decode(String.self, forKey: key) {
      return s
    }
    if let i = try? decode(Int.self, forKey: key) {
      return String(i)
    }
    if let d = try? decode(Double.self, forKey: key) {
      return String(d)
    }
    if let b = try? decode(Bool.self, forKey: key) {
      return b ? "true" : "false"
    }
    return ""
  }

  func decodeBoolLike(forKey key: Key, default defaultValue: Bool = false) -> Bool {
    if let b = try? decode(Bool.self, forKey: key) {
      return b
    }
    if let i = try? decode(Int.self, forKey: key) {
      return i != 0
    }
    if let s = try? decode(String.self, forKey: key) {
      switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "y", "on":
        return true
      case "false", "0", "no", "n", "off":
        return false
      default:
        break
      }
    }
    return defaultValue
  }

  func decodeIntLike(forKey key: Key, default defaultValue: Int = 0) -> Int {
    if let i = try? decode(Int.self, forKey: key) {
      return i
    }
    if let d = try? decode(Double.self, forKey: key) {
      return Int(d)
    }
    if let s = try? decode(String.self, forKey: key) {
      if let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return i
      }
    }
    return defaultValue
  }

  func decodeDoubleLike(forKey key: Key, default defaultValue: Double = 0) -> Double {
    if let d = try? decode(Double.self, forKey: key) {
      return d
    }
    if let i = try? decode(Int.self, forKey: key) {
      return Double(i)
    }
    if let s = try? decode(String.self, forKey: key) {
      if let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return d
      }
    }
    return defaultValue
  }
}

struct AgentStatus: Decodable, Equatable {
  let running: Bool
  let lastMessage: String
  let config: AgentConfig
  let notes: String
  let tokenUsage: TokenUsage
  let logLines: Int

  enum CodingKeys: String, CodingKey {
    case running
    case lastMessage = "last_message"
    case config
    case notes
    case tokenUsage = "token_usage"
    case logLines = "log_lines"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    running = c.decodeBoolLike(forKey: .running)
    lastMessage = c.decodeStringOrEmpty(forKey: .lastMessage)
    config = (try? c.decode(AgentConfig.self, forKey: .config)) ?? AgentConfig()
    notes = c.decodeStringOrEmpty(forKey: .notes)
    tokenUsage = (try? c.decode(TokenUsage.self, forKey: .tokenUsage)) ?? TokenUsage()
    logLines = c.decodeIntLike(forKey: .logLines)
  }
}

struct TokenUsage: Decodable, Equatable {
  let requests: Int
  let inputTokens: Int
  let outputTokens: Int
  let cachedTokens: Int
  let totalTokens: Int

  enum CodingKeys: String, CodingKey {
    case requests
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cachedTokens = "cached_tokens"
    case totalTokens = "total_tokens"
  }

  init() {
    requests = 0
    inputTokens = 0
    outputTokens = 0
    cachedTokens = 0
    totalTokens = 0
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    requests = c.decodeIntLike(forKey: .requests)
    inputTokens = c.decodeIntLike(forKey: .inputTokens)
    outputTokens = c.decodeIntLike(forKey: .outputTokens)
    cachedTokens = c.decodeIntLike(forKey: .cachedTokens)
    totalTokens = c.decodeIntLike(forKey: .totalTokens)
  }
}

struct AgentConfig: Decodable, Equatable {
  let task: String
  let baseUrl: String
  let model: String
  let apiMode: String

  let apiKeySet: Bool
  let agentTokenSet: Bool
  let rememberApiKey: Bool

  let useCustomSystemPrompt: Bool
  let systemPrompt: String
  let defaultSystemPrompt: String

  let debugLogRawAssistant: Bool
  let reasoningEffort: String
  let doubaoSeedEnableSessionCache: Bool
  let halfResScreenshot: Bool
  let useW3CActionsForSwipe: Bool
  let restartResponsesByPlan: Bool

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
    case agentTokenSet = "agent_token_set"
    case rememberApiKey = "remember_api_key"
    case useCustomSystemPrompt = "use_custom_system_prompt"
    case systemPrompt = "system_prompt"
    case defaultSystemPrompt = "default_system_prompt"
    case debugLogRawAssistant = "debug_log_raw_assistant"
    case reasoningEffort = "reasoning_effort"
    case doubaoSeedEnableSessionCache = "doubao_seed_enable_session_cache"
    case halfResScreenshot = "half_res_screenshot"
    case useW3CActionsForSwipe = "use_w3c_actions_for_swipe"
    case restartResponsesByPlan = "restart_responses_by_plan"
    case maxSteps = "max_steps"
    case maxCompletionTokens = "max_completion_tokens"
    case timeoutSeconds = "timeout_seconds"
    case stepDelaySeconds = "step_delay_seconds"
    case insecureSkipTlsVerify = "insecure_skip_tls_verify"
  }

  init() {
    task = ""
    baseUrl = ""
    model = ""
    apiMode = ""
    apiKeySet = false
    agentTokenSet = false
    rememberApiKey = false
    useCustomSystemPrompt = false
    systemPrompt = ""
    defaultSystemPrompt = ""
    debugLogRawAssistant = false
    reasoningEffort = ""
    doubaoSeedEnableSessionCache = false
    halfResScreenshot = false
    useW3CActionsForSwipe = true
    restartResponsesByPlan = false
    maxSteps = 0
    maxCompletionTokens = 0
    timeoutSeconds = 0
    stepDelaySeconds = 0
    insecureSkipTlsVerify = false
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    task = c.decodeStringOrEmpty(forKey: .task)
    baseUrl = c.decodeStringOrEmpty(forKey: .baseUrl)
    model = c.decodeStringOrEmpty(forKey: .model)
    apiMode = c.decodeStringOrEmpty(forKey: .apiMode)

    apiKeySet = c.decodeBoolLike(forKey: .apiKeySet)
    agentTokenSet = c.decodeBoolLike(forKey: .agentTokenSet)
    rememberApiKey = c.decodeBoolLike(forKey: .rememberApiKey)

    useCustomSystemPrompt = c.decodeBoolLike(forKey: .useCustomSystemPrompt)
    systemPrompt = c.decodeStringOrEmpty(forKey: .systemPrompt)
    defaultSystemPrompt = c.decodeStringOrEmpty(forKey: .defaultSystemPrompt)

    debugLogRawAssistant = c.decodeBoolLike(forKey: .debugLogRawAssistant)
    reasoningEffort = c.decodeStringOrEmpty(forKey: .reasoningEffort)
    doubaoSeedEnableSessionCache = c.decodeBoolLike(forKey: .doubaoSeedEnableSessionCache, default: true)
    halfResScreenshot = c.decodeBoolLike(forKey: .halfResScreenshot)
    useW3CActionsForSwipe = c.decodeBoolLike(forKey: .useW3CActionsForSwipe, default: true)
    restartResponsesByPlan = c.decodeBoolLike(forKey: .restartResponsesByPlan)

    maxSteps = c.decodeIntLike(forKey: .maxSteps)
    maxCompletionTokens = c.decodeIntLike(forKey: .maxCompletionTokens)
    timeoutSeconds = c.decodeDoubleLike(forKey: .timeoutSeconds)
    stepDelaySeconds = c.decodeDoubleLike(forKey: .stepDelaySeconds)

    insecureSkipTlsVerify = c.decodeBoolLike(forKey: .insecureSkipTlsVerify)
  }
}

struct AgentLogsPayload: Decodable {
  let lines: [String]
}

struct AgentChatPayload: Decodable {
  let items: [AgentChatItem]
}

struct AgentEventSnapshot: Decodable {
  let status: AgentStatus
  let logs: [String]
  let chat: [AgentChatItem]
}

struct AgentChatItem: Decodable, Identifiable, Equatable {
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

struct AgentStepScreenshotPayload: Decodable {
  let ok: Bool
  let error: String
  let step: Int
  let pngBase64: String

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case step
    case pngBase64 = "png_base64"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ok = c.decodeBoolLike(forKey: .ok)
    error = c.decodeStringOrEmpty(forKey: .error)
    step = c.decodeIntLike(forKey: .step)
    pngBase64 = c.decodeStringOrEmpty(forKey: .pngBase64)
  }
}

struct AgentStepScreenshotsPayload: Decodable {
  let ok: Bool
  let error: String
  let format: String
  let mimeType: String
  let images: [String: String]
  let missing: [Int]

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case format
    case mimeType = "mime_type"
    case images
    case missing
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ok = c.decodeBoolLike(forKey: .ok)
    error = c.decodeStringOrEmpty(forKey: .error)
    format = c.decodeStringOrEmpty(forKey: .format)
    mimeType = c.decodeStringOrEmpty(forKey: .mimeType)
    images = (try? c.decode([String: String].self, forKey: .images)) ?? [:]
    missing = (try? c.decode([Int].self, forKey: .missing)) ?? []
  }
}

struct AgentStartPayload: Decodable {
  let ok: Bool?
  let error: String?
  let status: AgentStatus?

  enum CodingKeys: String, CodingKey {
    case ok
    case error
    case status
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if c.contains(.ok) {
      ok = c.decodeBoolLike(forKey: .ok)
    } else {
      ok = nil
    }
    error = (try? c.decode(String.self, forKey: .error)) ?? nil
    status = (try? c.decode(AgentStatus.self, forKey: .status)) ?? nil
  }
}

struct AgentConfigRequest: Encodable {
  var base_url: String
  var model: String
  var api_mode: String
  var agent_token: String?
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
  var half_res_screenshot: Bool
  var use_w3c_actions_for_swipe: Bool
  var restart_responses_by_plan: Bool
  var api_key: String?
}
