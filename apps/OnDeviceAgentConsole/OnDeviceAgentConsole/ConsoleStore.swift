import Foundation

@MainActor
final class ConsoleStore: ObservableObject {
  enum Defaults {
    static let wdaURL = "http://127.0.0.1:8100"
    static let apiMode = "responses_stateful"
    static let maxSteps = 60
    static let timeoutSeconds = 90.0
    static let stepDelaySeconds = 0.5
    static let maxCompletionTokens = 32768
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

    var task: String = ""

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
  @Published var lastError: String?
  @Published var chatMode: ChatMode = .message

  private var didHydrateFromDevice: Bool = false
  private var refreshTask: Task<Void, Never>?

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
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let st = try await client.getStatus()
      status = st

      do { logs = try await client.getLogs() } catch { /* keep last */ }
      do { chatItems = try await client.getChat() } catch { /* keep last */ }

      if !didHydrateFromDevice {
        hydrateFromDevice(st.config)
        didHydrateFromDevice = true
      }

      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func saveConfig() async {
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let req = try makeConfigRequest()
      status = try await client.postConfig(req)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func startAgent() async {
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let req = try makeConfigRequest()
      let resp = try await client.start(req)
      if resp.ok == false {
        lastError = resp.error ?? "Start failed"
      } else {
        lastError = nil
      }
      if let st = resp.status {
        status = st
      } else {
        status = try await client.getStatus()
      }
    } catch {
      lastError = error.localizedDescription
    }
  }

  func stopAgent() async {
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      status = try await client.stop()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  func resetRuntime() async {
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      status = try await client.reset()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
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

    if Int(draft.maxSteps) == nil || (Int(draft.maxSteps) ?? 0) <= 0 {
      errs.append("Max Steps must be > 0")
    }
    if Double(draft.timeoutSeconds) == nil || (Double(draft.timeoutSeconds) ?? 0) <= 0 {
      errs.append("Timeout (seconds) must be > 0")
    }
    if Double(draft.stepDelaySeconds) == nil || (Double(draft.stepDelaySeconds) ?? 0) <= 0 {
      errs.append("Step Delay (seconds) must be > 0")
    }
    if Int(draft.maxCompletionTokens) == nil || (Int(draft.maxCompletionTokens) ?? 0) <= 0 {
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

  private func makeConfigRequest() throws -> AgentConfigRequest {
    let baseUrl = draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
    let task = draft.task
    let apiMode = draft.apiMode.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !baseUrl.isEmpty, !model.isEmpty, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentClientError.badResponse
    }

    guard let maxSteps = Int(draft.maxSteps), maxSteps > 0 else {
      throw AgentClientError.badResponse
    }
    guard let maxTokens = Int(draft.maxCompletionTokens), maxTokens > 0 else {
      throw AgentClientError.badResponse
    }
    guard let timeout = Double(draft.timeoutSeconds), timeout > 0 else {
      throw AgentClientError.badResponse
    }
    guard let stepDelay = Double(draft.stepDelaySeconds), stepDelay > 0 else {
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
    if draft.task.isEmpty { draft.task = cfg.task }
    if !cfg.apiMode.isEmpty { draft.apiMode = cfg.apiMode }

    draft.rememberApiKey = cfg.rememberApiKey
    draft.debugLogRawAssistant = cfg.debugLogRawAssistant
    draft.insecureSkipTLSVerify = cfg.insecureSkipTlsVerify

    draft.maxSteps = "\(cfg.maxSteps)"
    draft.maxCompletionTokens = "\(cfg.maxCompletionTokens)"
    draft.timeoutSeconds = "\(cfg.timeoutSeconds)"
    draft.stepDelaySeconds = "\(cfg.stepDelaySeconds)"

    draft.useCustomSystemPrompt = cfg.useCustomSystemPrompt
    draft.systemPrompt = cfg.systemPrompt
    draft.reasoningEffort = cfg.reasoningEffort
    draft.doubaoSeedEnableSessionCache = cfg.doubaoSeedEnableSessionCache
  }
}

