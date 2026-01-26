import Foundation

@MainActor
final class ConsoleStore: ObservableObject {
  enum ConfigImportError: LocalizedError {
    case notValidUTF8
    case invalidJSON(String)
    case notJSONObject

    var errorDescription: String? {
      switch self {
      case .notValidUTF8:
        return "QR content is not valid UTF-8"
      case .invalidJSON(let msg):
        return "Invalid JSON: \(msg)"
      case .notJSONObject:
        return "JSON root must be an object"
      }
    }
  }

  enum Defaults {
    static let wdaURL = "http://127.0.0.1:8100"
    static let apiMode = "responses_stateful"
    static let maxSteps = 60
    static let timeoutSeconds = 90.0
    static let stepDelaySeconds = 0.5
    static let maxCompletionTokens = 32768

    static let defaultTask =
      "在小红书上找影视飓风10篇点赞量超过1万的笔记，统计封面上的字，收集到飞书的表格里。"
  }

  enum ChatMode: String, CaseIterable, Identifiable {
    case message
    case raw

    var id: String { rawValue }

    var title: String {
      switch self {
      case .message: return "Message"
      case .raw: return "Raw"
      }
    }
  }

  struct Draft {
    var baseUrl: String = ""
    var model: String = ""
    var apiMode: String = Defaults.apiMode

    var apiKey: String = ""
    var showApiKey: Bool = false
    var rememberApiKey: Bool = false

    var task: String = Defaults.defaultTask

    var maxSteps: String = "\(Defaults.maxSteps)"
    var timeoutSeconds: String = "\(Defaults.timeoutSeconds)"
    var stepDelaySeconds: String = "\(Defaults.stepDelaySeconds)"
    var maxCompletionTokens: String = "\(Defaults.maxCompletionTokens)"

    var reasoningEffort: String = ""
    var debugLogRawAssistant: Bool = true
    var insecureSkipTLSVerify: Bool = false

    var useCustomSystemPrompt: Bool = false
    var systemPrompt: String = ""

    var doubaoSeedEnableSessionCache: Bool = true
  }

  @Published var wdaURL: String = Defaults.wdaURL
  @Published var draft: Draft = Draft()

  @Published var status: AgentStatus?
  @Published var logs: [String] = []
  @Published var chatItems: [AgentChatItem] = []
  @Published var connectionError: String?
  @Published var lastActionError: String?
  @Published var logsError: String?
  @Published var chatError: String?
  @Published var chatMode: ChatMode = .message

  private var didHydrateFromDevice: Bool = false
  private var refreshTask: Task<Void, Never>?
  private var refreshInFlight: Bool = false
  private var refreshPending: Bool = false
  private var stateGeneration: UInt64 = 0

  func importConfigFromQRCode(_ raw: String) throws {
    guard let data = raw.data(using: .utf8) else {
      throw ConfigImportError.notValidUTF8
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw ConfigImportError.invalidJSON(error.localizedDescription)
    }
    guard let dict = json as? [String: Any] else {
      throw ConfigImportError.notJSONObject
    }

    stateGeneration &+= 1

    func str(_ key: String) -> String? {
      guard let v = dict[key] else { return nil }
      if let s = v as? String { return s }
      if let n = v as? NSNumber { return n.stringValue }
      return nil
    }

    func bool(_ key: String) -> Bool? {
      guard let v = dict[key] else { return nil }
      if let b = v as? Bool { return b }
      if let n = v as? NSNumber { return n.boolValue }
      if let s = v as? String {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "y", "on":
          return true
        case "false", "0", "no", "n", "off":
          return false
        default:
          return nil
        }
      }
      return nil
    }

    func int(_ key: String) -> Int? {
      guard let v = dict[key] else { return nil }
      if let i = v as? Int { return i }
      if let n = v as? NSNumber { return n.intValue }
      if let s = v as? String {
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }

    func dbl(_ key: String) -> Double? {
      guard let v = dict[key] else { return nil }
      if let d = v as? Double { return d }
      if let n = v as? NSNumber { return n.doubleValue }
      if let s = v as? String {
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }

    if let v = str("base_url") { draft.baseUrl = v }
    if let v = str("model") { draft.model = v }
    if let v = str("api_mode") { draft.apiMode = v }
    if let v = str("task") { draft.task = v }

    if let v = bool("remember_api_key") { draft.rememberApiKey = v }
    if let v = bool("debug_log_raw_assistant") { draft.debugLogRawAssistant = v }
    if let v = bool("insecure_skip_tls_verify") { draft.insecureSkipTLSVerify = v }
    if let v = bool("doubao_seed_enable_session_cache") { draft.doubaoSeedEnableSessionCache = v }

    if let v = bool("use_custom_system_prompt") { draft.useCustomSystemPrompt = v }
    if let v = str("system_prompt") { draft.systemPrompt = v }
    if let v = str("reasoning_effort") { draft.reasoningEffort = v }

    if let v = int("max_steps") { draft.maxSteps = "\(v)" }
    if let v = int("max_completion_tokens") { draft.maxCompletionTokens = "\(v)" }
    if let v = dbl("timeout_seconds") { draft.timeoutSeconds = "\(v)" }
    if let v = dbl("step_delay_seconds") { draft.stepDelaySeconds = "\(v)" }

    if let v = str("api_key") { draft.apiKey = v }

    // Do not overwrite imported values with the first device hydration.
    didHydrateFromDevice = true
  }

  func boot() async {
    if refreshTask != nil {
      return
    }
    await refresh()
    refreshTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await self.refresh()
      }
    }
  }

  func refresh() async {
    if refreshInFlight {
      refreshPending = true
      return
    }

    refreshInFlight = true
    defer { refreshInFlight = false }

    repeat {
      refreshPending = false
      await refreshOnce()
    } while refreshPending
  }

  private func refreshOnce() async {
    let gen = stateGeneration

    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let st = try await client.getStatus()

      guard gen == stateGeneration else { return }
      status = st
      connectionError = nil

      do {
        let newLogs = try await client.getLogs()
        guard gen == stateGeneration else { return }
        logs = newLogs
        logsError = nil
      } catch {
        guard gen == stateGeneration else { return }
        logsError = error.localizedDescription
      }

      do {
        let newChat = try await client.getChat()
        guard gen == stateGeneration else { return }
        chatItems = newChat
        chatError = nil
      } catch {
        guard gen == stateGeneration else { return }
        chatError = error.localizedDescription
      }

      if !didHydrateFromDevice {
        hydrateFromDevice(st.config)
        didHydrateFromDevice = true
      }
    } catch {
      guard gen == stateGeneration else { return }
      connectionError = error.localizedDescription
    }
  }

  func saveConfig() async {
    stateGeneration &+= 1
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let req = try makeConfigRequest()
      status = try await client.postConfig(req)
      connectionError = nil
      lastActionError = nil
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  func startAgent() async {
    stateGeneration &+= 1
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let req = try makeConfigRequest()
      let resp = try await client.start(req)
      if resp.ok == false {
        lastActionError = resp.error ?? "Start failed"
      } else {
        lastActionError = nil
        connectionError = nil
      }
      if let st = resp.status {
        status = st
      } else {
        status = try await client.getStatus()
      }
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  func stopAgent() async {
    stateGeneration &+= 1
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      status = try await client.stop()
      connectionError = nil
      lastActionError = nil
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  func resetRuntime() async {
    stateGeneration &+= 1
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      status = try await client.reset()
      connectionError = nil
      lastActionError = nil
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  func validationErrors() -> [String] {
    var errs: [String] = []

    if draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errs.append("Base URL is required")
    }
    if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errs.append("Model is required")
    }
    if draft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errs.append("Task is required")
    }

    let maxStepsRaw = draft.maxSteps.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeoutRaw = draft.timeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
    let stepDelayRaw = draft.stepDelaySeconds.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxTokensRaw = draft.maxCompletionTokens.trimmingCharacters(in: .whitespacesAndNewlines)

    if Int(maxStepsRaw) == nil || (Int(maxStepsRaw) ?? 0) <= 0 {
      errs.append("Max Steps must be > 0")
    }
    if Double(timeoutRaw) == nil || (Double(timeoutRaw) ?? 0) <= 0 {
      errs.append("Timeout (seconds) must be > 0")
    }
    if Double(stepDelayRaw) == nil || (Double(stepDelayRaw) ?? 0) <= 0 {
      errs.append("Step Delay (seconds) must be > 0")
    }
    if Int(maxTokensRaw) == nil || (Int(maxTokensRaw) ?? 0) <= 0 {
      errs.append("Max Tokens must be > 0")
    }

    return errs
  }

  func isDoubaoSeedResponsesMode() -> Bool {
    if draft.apiMode != Defaults.apiMode {
      return false
    }
    return draft.model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("doubao-seed")
  }

  struct ConfigExport: Encodable {
    var base_url: String
    var model: String
    var api_mode: String

    var remember_api_key: Bool
    var debug_log_raw_assistant: Bool
    var insecure_skip_tls_verify: Bool
    var doubao_seed_enable_session_cache: Bool

    var task: String
    var max_steps: Int
    var max_completion_tokens: Int
    var timeout_seconds: Double
    var step_delay_seconds: Double

    var use_custom_system_prompt: Bool
    var system_prompt: String?
    var reasoning_effort: String?
  }

  func exportConfigJSONForQRCode() throws -> String {
    var req = try makeConfigRequest()
    req.api_key = nil

    let sys = req.system_prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let includeSystemPrompt = req.use_custom_system_prompt && !sys.isEmpty

    let eff = req.reasoning_effort.trimmingCharacters(in: .whitespacesAndNewlines)
    let export = ConfigExport(
      base_url: req.base_url,
      model: req.model,
      api_mode: req.api_mode,
      remember_api_key: req.remember_api_key,
      debug_log_raw_assistant: req.debug_log_raw_assistant,
      insecure_skip_tls_verify: req.insecure_skip_tls_verify,
      doubao_seed_enable_session_cache: req.doubao_seed_enable_session_cache,
      task: req.task,
      max_steps: req.max_steps,
      max_completion_tokens: req.max_completion_tokens,
      timeout_seconds: req.timeout_seconds,
      step_delay_seconds: req.step_delay_seconds,
      use_custom_system_prompt: req.use_custom_system_prompt,
      system_prompt: includeSystemPrompt ? req.system_prompt : nil,
      reasoning_effort: eff.isEmpty ? nil : eff
    )

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let data = try enc.encode(export)
    guard let s = String(data: data, encoding: .utf8) else {
      throw ConfigImportError.notValidUTF8
    }
    return s
  }

  private func makeConfigRequest() throws -> AgentConfigRequest {
    let baseUrl = draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
    let task = draft.task
    let apiMode = draft.apiMode.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !baseUrl.isEmpty, !model.isEmpty, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentClientError.badResponse
    }

    let maxStepsRaw = draft.maxSteps.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxTokensRaw = draft.maxCompletionTokens.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeoutRaw = draft.timeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
    let stepDelayRaw = draft.stepDelaySeconds.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let maxSteps = Int(maxStepsRaw), maxSteps > 0 else {
      throw AgentClientError.badResponse
    }
    guard let maxTokens = Int(maxTokensRaw), maxTokens > 0 else {
      throw AgentClientError.badResponse
    }
    guard let timeout = Double(timeoutRaw), timeout > 0 else {
      throw AgentClientError.badResponse
    }
    guard let stepDelay = Double(stepDelayRaw), stepDelay > 0 else {
      throw AgentClientError.badResponse
    }

    let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

    return AgentConfigRequest(
      base_url: baseUrl,
      model: model,
      api_mode: apiMode,
      use_custom_system_prompt: draft.useCustomSystemPrompt,
      system_prompt: draft.systemPrompt,
      remember_api_key: draft.rememberApiKey,
      debug_log_raw_assistant: draft.debugLogRawAssistant,
      doubao_seed_enable_session_cache: draft.doubaoSeedEnableSessionCache,
      task: task,
      max_steps: maxSteps,
      max_completion_tokens: maxTokens,
      reasoning_effort: draft.reasoningEffort,
      timeout_seconds: timeout,
      step_delay_seconds: stepDelay,
      insecure_skip_tls_verify: draft.insecureSkipTLSVerify,
      api_key: key.isEmpty ? nil : key
    )
  }

  private func hydrateFromDevice(_ cfg: AgentConfig) {
    if draft.baseUrl.isEmpty { draft.baseUrl = cfg.baseUrl }
    if draft.model.isEmpty { draft.model = cfg.model }
    if !cfg.task.isEmpty { draft.task = cfg.task }
    if !cfg.apiMode.isEmpty { draft.apiMode = cfg.apiMode }

    draft.rememberApiKey = cfg.rememberApiKey
    draft.debugLogRawAssistant = cfg.debugLogRawAssistant
    draft.insecureSkipTLSVerify = cfg.insecureSkipTlsVerify

    draft.maxSteps = "\(cfg.maxSteps)"
    draft.maxCompletionTokens = "\(cfg.maxCompletionTokens)"
    draft.timeoutSeconds = "\(cfg.timeoutSeconds)"
    draft.stepDelaySeconds = "\(cfg.stepDelaySeconds)"

    draft.useCustomSystemPrompt = cfg.useCustomSystemPrompt
    if !cfg.systemPrompt.isEmpty {
      draft.systemPrompt = cfg.systemPrompt
    }
    draft.reasoningEffort = cfg.reasoningEffort
    draft.doubaoSeedEnableSessionCache = cfg.doubaoSeedEnableSessionCache
  }
}
