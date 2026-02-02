import Darwin
import Foundation
import UIKit

@MainActor
final class ConsoleStore: ObservableObject {
  enum ConfigImportError: LocalizedError {
    case notValidUTF8
    case invalidJSON(String)
    case notJSONObject
    case unknownKey(String)
    case invalidValue(key: String, message: String)

    var errorDescription: String? {
      switch self {
      case .notValidUTF8:
        return NSLocalizedString("QR content is not valid UTF-8", comment: "")
      case .invalidJSON(let msg):
        return String(format: NSLocalizedString("Invalid JSON: %@", comment: ""), msg)
      case .notJSONObject:
        return NSLocalizedString("JSON root must be an object", comment: "")
      case .unknownKey(let k):
        return String(format: NSLocalizedString("Unknown config key: %@", comment: ""), k)
      case .invalidValue(let key, let msg):
        return String(format: NSLocalizedString("Invalid value for %@: %@", comment: ""), key, msg)
      }
    }
  }

  enum Defaults {
    static let wdaURL = "http://127.0.0.1:8100"
    static let apiMode = "responses"
    static let maxSteps = 60
    static let timeoutSeconds = 90.0
    static let stepDelaySeconds = 0.5
    static let maxCompletionTokens = 32768

    static let defaultTask =
      "在小红书上找影视飓风5篇点赞量超过1万的笔记，统计封面上的字，收集到飞书的表格里。"
  }

  private static let datePlaceholderZHFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_Hans_CN")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy年MM月dd日"
    return f
  }()

  private static let datePlaceholderENFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd (EEE)"
    return f
  }()

  private static let weekdayZH = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

  static func datePlaceholderZH(_ date: Date = Date()) -> String {
    let d = datePlaceholderZHFormatter.string(from: date)
    let w = Calendar(identifier: .gregorian).component(.weekday, from: date)
    let weekday = (1...7).contains(w) ? weekdayZH[w - 1] : ""
    return weekday.isEmpty ? d : "\(d) \(weekday)"
  }

  static func datePlaceholderEN(_ date: Date = Date()) -> String {
    datePlaceholderENFormatter.string(from: date)
  }

  enum ChatMode: String, CaseIterable, Identifiable {
    case visual
    case rawJSON

    var id: String { rawValue }

    var title: String {
      switch self {
      case .visual: return NSLocalizedString("Visual", comment: "")
      case .rawJSON: return NSLocalizedString("Raw JSON", comment: "")
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
    var halfResScreenshot: Bool = true
    var useW3CActionsForSwipe: Bool = true

    var useCustomSystemPrompt: Bool = false
    var systemPrompt: String = ""

    var doubaoSeedEnableSessionCache: Bool = true
  }

  @Published var wdaURL: String = Defaults.wdaURL
  @Published var draft: Draft = Draft()

  @Published var status: AgentStatus?
  @Published var logs: [String] = []
  @Published var chatItems: [AgentChatItem] = []
  @Published var stepActionAnnotations: [Int: ActionAnnotation] = [:]
  @Published var connectionError: String?
  @Published var lastActionError: String?
  @Published var logsError: String?
  @Published var chatError: String?
  @Published var chatMode: ChatMode = .visual
  @Published var stepScreenshots: [Int: UIImage] = [:]
  @Published var stepScreenshotErrors: [Int: String] = [:]
  @Published var localNetworkAccess: LocalNetworkAccessState?

  private static let annotateStepScreenshotsDefaultsKey = "ondevice_agent.annotate_step_screenshots"

  @Published var annotateStepScreenshots: Bool = {
    let d = UserDefaults.standard
    if d.object(forKey: annotateStepScreenshotsDefaultsKey) == nil {
      return true
    }
    return d.bool(forKey: annotateStepScreenshotsDefaultsKey)
  }() {
    didSet {
      UserDefaults.standard.set(
        annotateStepScreenshots,
        forKey: ConsoleStore.annotateStepScreenshotsDefaultsKey
      )
    }
  }

  private var didHydrateFromDevice: Bool = false
  private var refreshTask: Task<Void, Never>?
  private var refreshInFlight: Bool = false
  private var refreshPending: Bool = false
  private var autoRefreshSuspendCount: Int = 0
  private var stateGeneration: UInt64 = 0
  private var stepScreenshotLoading: Set<Int> = []
  private var localNetworkCheckInFlight: Bool = false
  private var lastLocalNetworkCheckAt: Date?

  private static func l10n(_ key: String, _ args: CVarArg...) -> String {
    if args.isEmpty { return NSLocalizedString(key, comment: "") }
    return String(format: NSLocalizedString(key, comment: ""), arguments: args)
  }

  struct LocalNetworkAccessState: Equatable {
    var wifiIPv4: String
    var port: Int
    var loopbackOK: Bool
    var lanOK: Bool
    var checkedAt: Date
  }

  static func wifiIPv4Address() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
      return nil
    }
    defer { freeifaddrs(ifaddr) }

    var candidate: String?
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
      let iface = p.pointee
      defer { ptr = iface.ifa_next }

      guard let addr = iface.ifa_addr else { continue }
      if addr.pointee.sa_family != UInt8(AF_INET) { continue }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let res = getnameinfo(
        addr,
        socklen_t(addr.pointee.sa_len),
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard res == 0 else { continue }
      let ip = String(cString: host)
      guard !ip.isEmpty, ip != "0.0.0.0" else { continue }

      let name = String(cString: iface.ifa_name)
      if name == "en0" {
        return ip
      }
      if candidate == nil, name.hasPrefix("en") {
        candidate = ip
      }
    }
    return candidate
  }

  private func wdaURLComponents() -> URLComponents? {
    let trimmed = wdaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
      return nil
    }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)
  }

  private func statusURL(host: String) -> URL? {
    guard var comps = wdaURLComponents() else { return nil }
    comps.host = host
    if comps.port == nil {
      comps.port = (comps.scheme == "https") ? 443 : 80
    }
    comps.path = "/status"
    comps.query = nil
    comps.fragment = nil
    return comps.url
  }

  private static func probeHTTPGET(_ url: URL, timeoutSeconds: TimeInterval) async -> Bool {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = timeoutSeconds

    let cfg = URLSessionConfiguration.ephemeral
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = timeoutSeconds
    cfg.timeoutIntervalForResource = timeoutSeconds
    cfg.waitsForConnectivity = false
    let session = URLSession(configuration: cfg)

    do {
      let (_, resp) = try await session.data(for: req)
      guard let http = resp as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch {
      return false
    }
  }

  func checkLocalNetworkAccess(force: Bool = false) async {
    if localNetworkCheckInFlight {
      return
    }
    let now = Date()
    if !force, let last = lastLocalNetworkCheckAt {
      let minInterval: TimeInterval = (localNetworkAccess?.loopbackOK == true && localNetworkAccess?.lanOK == false) ? 8 : 60
      if now.timeIntervalSince(last) < minInterval {
        return
      }
    }

    localNetworkCheckInFlight = true
    defer { localNetworkCheckInFlight = false }
    lastLocalNetworkCheckAt = now

    guard let wifiIP = Self.wifiIPv4Address() else {
      localNetworkAccess = nil
      return
    }
    guard let loopbackURL = statusURL(host: "127.0.0.1") else {
      localNetworkAccess = nil
      return
    }
    guard let lanURL = statusURL(host: wifiIP) else {
      localNetworkAccess = nil
      return
    }

    let loopbackOK = await Self.probeHTTPGET(loopbackURL, timeoutSeconds: 1.2)
    if !loopbackOK {
      localNetworkAccess = LocalNetworkAccessState(
        wifiIPv4: wifiIP,
        port: loopbackURL.port ?? 0,
        loopbackOK: false,
        lanOK: false,
        checkedAt: Date()
      )
      return
    }
    let lanOK = await Self.probeHTTPGET(lanURL, timeoutSeconds: 1.2)
    localNetworkAccess = LocalNetworkAccessState(
      wifiIPv4: wifiIP,
      port: lanURL.port ?? 0,
      loopbackOK: true,
      lanOK: lanOK,
      checkedAt: Date()
    )
  }

  static func validateQRCodeConfigRaw(_ raw: String) -> [String] {
    guard let data = raw.data(using: .utf8) else { return [l10n("QR content is not valid UTF-8")] }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      return [l10n("Invalid JSON: %@", error.localizedDescription)]
    }
    guard let dict = json as? [String: Any] else { return [l10n("JSON root must be an object")] }

    enum Kind {
      case string
      case bool
      case positiveInt
      case positiveDouble
      case apiMode
      case optionalString
    }

    let kinds: [String: Kind] = [
      "base_url": .string,
      "model": .string,
      "api_mode": .apiMode,
      "api_key": .string,
      "remember_api_key": .bool,
      "debug_log_raw_assistant": .bool,
      "insecure_skip_tls_verify": .bool,
      "half_res_screenshot": .bool,
      "use_w3c_actions_for_swipe": .bool,
      "doubao_seed_enable_session_cache": .bool,
      "task": .string,
      "max_steps": .positiveInt,
      "max_completion_tokens": .positiveInt,
      "timeout_seconds": .positiveDouble,
      "step_delay_seconds": .positiveDouble,
      "use_custom_system_prompt": .bool,
      "system_prompt": .optionalString,
      "reasoning_effort": .optionalString,
    ]

    func str(_ v: Any) -> String? {
      if v is NSNull { return nil }
      if let s = v as? String { return s }
      if let n = v as? NSNumber { return n.stringValue }
      return nil
    }

    func bool(_ v: Any) -> Bool? {
      if v is NSNull { return nil }
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

    func int(_ v: Any) -> Int? {
      if v is NSNull { return nil }
      if let i = v as? Int { return i }
      if let n = v as? NSNumber { return n.intValue }
      if let s = v as? String {
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }

    func dbl(_ v: Any) -> Double? {
      if v is NSNull { return nil }
      if let d = v as? Double { return d }
      if let n = v as? NSNumber { return n.doubleValue }
      if let s = v as? String {
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }

    var errors: [String] = []
    for (k, v) in dict {
      guard let kind = kinds[k] else {
        errors.append(l10n("Unknown config key: %@", k))
        continue
      }
      switch kind {
      case .string:
        guard str(v) != nil else {
          errors.append(l10n("Invalid value for %@: must be a string", k))
          continue
        }
      case .optionalString:
        if v is NSNull { continue }
        guard str(v) != nil else {
          errors.append(l10n("Invalid value for %@: must be a string or null", k))
          continue
        }
      case .bool:
        guard bool(v) != nil else {
          errors.append(l10n("Invalid value for %@: must be a boolean", k))
          continue
        }
      case .positiveInt:
        guard let n = int(v) else {
          errors.append(l10n("Invalid value for %@: must be an integer", k))
          continue
        }
        if n <= 0 {
          errors.append(l10n("Invalid value for %@: must be > 0", k))
        }
      case .positiveDouble:
        guard let d = dbl(v) else {
          errors.append(l10n("Invalid value for %@: must be a number", k))
          continue
        }
        if d <= 0 {
          errors.append(l10n("Invalid value for %@: must be > 0", k))
        }
      case .apiMode:
        guard let s = str(v) else {
          errors.append(l10n("Invalid value for %@: must be a string", k))
          continue
        }
        let mode = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != Defaults.apiMode && mode != "chat_completions" {
          errors.append(l10n("Invalid value for %@: unsupported api_mode '%@'", k, mode))
        }
      }
    }

    return errors
  }

  func importConfigFromQRCode(_ raw: String) throws {
    let errors = Self.validateQRCodeConfigRaw(raw)
    if let first = errors.first {
      throw ConfigImportError.invalidValue(key: "config", message: first)
    }

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
    if let v = str("task"), !v.isEmpty { draft.task = v }

    if let v = bool("remember_api_key") { draft.rememberApiKey = v }
    if let v = bool("debug_log_raw_assistant") { draft.debugLogRawAssistant = v }
    if let v = bool("insecure_skip_tls_verify") { draft.insecureSkipTLSVerify = v }
    if let v = bool("half_res_screenshot") { draft.halfResScreenshot = v }
    if let v = bool("use_w3c_actions_for_swipe") { draft.useW3CActionsForSwipe = v }
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
    refreshTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if self.autoRefreshSuspendCount > 0 {
          continue
        }
        await self.refresh()
      }
    }
  }

  func suspendAutoRefresh() {
    autoRefreshSuspendCount += 1
  }

  func resumeAutoRefresh() {
    autoRefreshSuspendCount = max(0, autoRefreshSuspendCount - 1)
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
      Task { await self.checkLocalNetworkAccess(force: false) }

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
        stepActionAnnotations = ActionAnnotation.buildMap(from: newChat)
        chatError = nil
        let stepsInChat = Set(newChat.compactMap { $0.step })
        stepScreenshots = stepScreenshots.filter { stepsInChat.contains($0.key) }
        stepScreenshotErrors = stepScreenshotErrors.filter { stepsInChat.contains($0.key) }
        stepScreenshotLoading = Set(stepScreenshotLoading.filter { stepsInChat.contains($0) })
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
      localNetworkAccess = nil
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
    stepScreenshots.removeAll()
    stepScreenshotErrors.removeAll()
    stepScreenshotLoading.removeAll()
    stepActionAnnotations.removeAll()
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
    stepScreenshots.removeAll()
    stepScreenshotErrors.removeAll()
    stepScreenshotLoading.removeAll()
    stepActionAnnotations.removeAll()
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      status = try await client.reset()
      connectionError = nil
      lastActionError = nil
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  func factoryReset() async {
    stateGeneration &+= 1
    logs.removeAll()
    chatItems.removeAll()
    stepScreenshots.removeAll()
    stepScreenshotErrors.removeAll()
    stepScreenshotLoading.removeAll()
    stepActionAnnotations.removeAll()
    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let st = try await client.factoryReset()
      status = st
      connectionError = nil
      lastActionError = nil

      draft = Draft()
      didHydrateFromDevice = false
      hydrateFromDevice(st.config)
      // Runner never returns the secret API key; after a full reset it is safer to clear it locally too.
      draft.apiKey = ""
      draft.showApiKey = false
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

  func ensureStepScreenshotLoaded(step: Int) async {
    if step < 0 {
      return
    }
    if stepScreenshots[step] != nil || stepScreenshotLoading.contains(step) {
      return
    }
    let gen = stateGeneration
    stepScreenshotLoading.insert(step)
    defer { stepScreenshotLoading.remove(step) }

    do {
      let client = try AgentClient(wdaURL: wdaURL)
      let png = try await client.getStepScreenshotPNG(step: step)
      guard gen == stateGeneration else { return }
      guard let image = UIImage(data: png) else {
        stepScreenshotErrors[step] = "Invalid screenshot image"
        return
      }
      stepScreenshots[step] = image
      stepScreenshotErrors[step] = nil
    } catch {
      guard gen == stateGeneration else { return }
      stepScreenshotErrors[step] = error.localizedDescription
    }
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
    var half_res_screenshot: Bool
    var use_w3c_actions_for_swipe: Bool
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
      half_res_screenshot: req.half_res_screenshot,
      use_w3c_actions_for_swipe: req.use_w3c_actions_for_swipe,
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
      half_res_screenshot: draft.halfResScreenshot,
      use_w3c_actions_for_swipe: draft.useW3CActionsForSwipe,
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
    draft.halfResScreenshot = cfg.halfResScreenshot
    draft.useW3CActionsForSwipe = cfg.useW3CActionsForSwipe

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
