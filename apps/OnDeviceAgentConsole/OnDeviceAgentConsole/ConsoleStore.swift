import Darwin
import Foundation
import Network
import Security
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

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
    static let exportScreenshotLimit = 60
    static let exportScreenshotFormat = "jpeg"
    static let exportScreenshotQuality = 0.7

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
    var agentToken: String = ""
    var showApiKey: Bool = false
    var rememberApiKey: Bool = false

    var task: String = Defaults.defaultTask

    var maxSteps: String = "\(Defaults.maxSteps)"
    var timeoutSeconds: String = "\(Defaults.timeoutSeconds)"
    var stepDelaySeconds: String = "\(Defaults.stepDelaySeconds)"
    var maxCompletionTokens: String = "\(Defaults.maxCompletionTokens)"

    var reasoningEffort: String = ""
    var debugLogRawAssistant: Bool = false
    var insecureSkipTLSVerify: Bool = false
    var halfResScreenshot: Bool = true
    var useW3CActionsForSwipe: Bool = true
    var restartResponsesByPlan: Bool = false

    var useCustomSystemPrompt: Bool = false
    var systemPrompt: String = ""

    var doubaoSeedEnableSessionCache: Bool = true
  }

  @Published var wdaURL: String = Defaults.wdaURL
  @Published var draft: Draft = Draft()

  @Published var status: AgentStatus?
  @Published var defaultSystemPromptTemplate: String = ""
  @Published var logs: [String] = []
  @Published var chatItems: [AgentChatItem] = []
  @Published var liveProgress: LiveProgress = LiveProgress()
  @Published var stepActionAnnotations: [Int: ActionAnnotation] = [:]
  @Published var connectionError: String?
  @Published var lastActionError: String?
  @Published var logsError: String?
  @Published var chatError: String?
  @Published var chatMode: ChatMode = .visual
  @Published var stepScreenshots: [Int: PlatformImage] = [:]
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
  private var eventStreamTask: Task<Void, Never>?
  private var refreshInFlight: Bool = false
  private var refreshPending: Bool = false
  private var autoRefreshSuspendCount: Int = 0
  private var stateGeneration: UInt64 = 0
  private var stepScreenshotLoading: Set<Int> = []
  private var localNetworkCheckInFlight: Bool = false
  private var lastLocalNetworkCheckAt: Date?
  private var lastSeenRunning: Bool = false
  private var networkMonitor: NWPathMonitor?
  private var networkMonitorQueue: DispatchQueue?

  nonisolated fileprivate static func l10n(_ key: String, _ args: CVarArg...) -> String {
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

  struct LiveProgress: Equatable {
    enum Phase: String, Equatable {
      case idle
      case stopping
      case callingModel
      case parsingOutput
      case executingAction
    }

    struct AgentStep: Equatable {
      var step: Int
      var action: String
    }

    struct Tokens: Equatable {
      struct Totals: Equatable {
        var input: Int
        var output: Int
        var cached: Int
        var total: Int
      }

      var requestIndex: Int
      var delta: Totals
      var cumulative: Totals
    }

    var running: Bool = false
    var phase: Phase = .idle
    var step: Int?
    var attempt: Int?
    var action: String?
    var nextPlanItem: String?
    var tokens: Tokens?
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

  private func isLoopbackHost(_ host: String) -> Bool {
    let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "0:0:0:0:0:0:0:1"
  }

  private var isLoopbackRunnerURL: Bool {
    guard let host = wdaURLComponents()?.host else { return false }
    return isLoopbackHost(host)
  }

  private func makeClient() throws -> AgentClient {
    try AgentClient(
      wdaURL: wdaURL,
      agentToken: draft.agentToken.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  func generateAgentToken() {
    var bytes = [UInt8](repeating: 0, count: 24)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status == errSecSuccess {
      let data = Data(bytes)
      var token = data.base64EncodedString()
      token = token.replacingOccurrences(of: "+", with: "-")
      token = token.replacingOccurrences(of: "/", with: "_")
      token = token.replacingOccurrences(of: "=", with: "")
      draft.agentToken = token
      return
    }
    draft.agentToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private var draftAgentTokenTrimmed: String {
    draft.agentToken.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func resolvedOneTimeAccessLinkComponents() -> URLComponents? {
    guard var comps = wdaURLComponents() else { return nil }
    guard let host = comps.host, !host.isEmpty else { return nil }

    if isLoopbackHost(host) {
      #if os(iOS)
      guard let lanHost = localNetworkAccess?.wifiIPv4 ?? Self.wifiIPv4Address(), !lanHost.isEmpty else {
        return nil
      }
      comps.host = lanHost
      #else
      // When Console is not running on the iPhone, we can't infer the iPhone's LAN IP from localhost.
      return nil
      #endif
    }

    comps.path = "/agent"
    comps.queryItems = nil
    comps.fragment = nil
    return comps
  }

  private func oneTimeAccessLink(for token: String) -> String? {
    let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedToken.isEmpty else { return nil }
    guard var comps = resolvedOneTimeAccessLinkComponents() else { return nil }
    comps.queryItems = [URLQueryItem(name: "token", value: normalizedToken)]
    return comps.url?.absoluteString
  }

  var canBuildOneTimeAccessLink: Bool {
    resolvedOneTimeAccessLinkComponents() != nil
  }

  var canCopyOneTimeAccessLink: Bool {
    !draftAgentTokenTrimmed.isEmpty
  }

  var oneTimeAccessLink: String? {
    oneTimeAccessLink(for: draftAgentTokenTrimmed)
  }

  func updateAgentToken() async -> Bool {
    let previousToken = draft.agentToken
    let previousTokenTrimmed = previousToken.trimmingCharacters(in: .whitespacesAndNewlines)
    generateAgentToken()
    let token = draftAgentTokenTrimmed
    guard !token.isEmpty else {
      draft.agentToken = previousToken
      return false
    }
    do {
      // Auth uses the currently-set token (if any); the request body carries the new token.
      let client = try AgentClient(wdaURL: wdaURL, agentToken: previousTokenTrimmed)
      status = try await client.postAgentTokenOnly(token)
      connectionError = nil
      lastActionError = nil
    } catch {
      draft.agentToken = previousToken
      lastActionError = error.localizedDescription
      return false
    }
    return true
  }

  func copyOneTimeAccessLink() -> Bool {
    guard !draftAgentTokenTrimmed.isEmpty else {
      lastActionError = NSLocalizedString("Copy access link requires token. Tap “Update token” first.", comment: "")
      return false
    }
    guard let link = oneTimeAccessLink else {
      lastActionError = NSLocalizedString("Cannot build access link. If Runner URL is localhost, set Runner URL to the iPhone’s Wi‑Fi IP so the link works over LAN.", comment: "")
      return false
    }
    #if canImport(UIKit)
    UIPasteboard.general.string = link
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(link, forType: .string)
    #endif
    lastActionError = nil
    return true
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
    #if !os(iOS)
    localNetworkAccess = nil
    return
    #endif

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

  nonisolated static func validateQRCodeConfigRaw(_ raw: String) -> [String] {
    let dict: [String: Any]
    do {
      dict = try QRCodeConfigCodec.parseDict(raw)
    } catch let e as ConfigImportError {
      switch e {
      case .notValidUTF8:
        return [l10n("QR content is not valid UTF-8")]
      case .invalidJSON(let msg):
        return [l10n("Invalid JSON: %@", msg)]
      case .notJSONObject:
        return [l10n("JSON root must be an object")]
      case .unknownKey(let k):
        return [l10n("Unknown config key: %@", k)]
      case .invalidValue(let key, let msg):
        return [l10n("Invalid value for %@: %@", key, msg)]
      }
    } catch {
      return [l10n("Invalid JSON: %@", error.localizedDescription)]
    }
    return QRCodeConfigCodec.validateDict(dict)
  }

  func importConfigFromQRCode(_ raw: String) throws {
    let dict = try QRCodeConfigCodec.parseDict(raw)
    let errors = QRCodeConfigCodec.validateDict(dict)
    if let first = errors.first {
      throw ConfigImportError.invalidValue(key: "config", message: first)
    }

    stateGeneration &+= 1

    func str(_ key: String) -> String? {
      QRCodeConfigCodec.JSONCoerce.string(dict[key])
    }

    func bool(_ key: String) -> Bool? {
      QRCodeConfigCodec.JSONCoerce.bool(dict[key])
    }

    func int(_ key: String) -> Int? {
      QRCodeConfigCodec.JSONCoerce.int(dict[key])
    }

    func dbl(_ key: String) -> Double? {
      QRCodeConfigCodec.JSONCoerce.double(dict[key])
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
    if let v = bool("restart_responses_by_plan") { draft.restartResponsesByPlan = v }
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

  private func eventStreamKey() -> String {
    let url = wdaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = draft.agentToken.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(url)|\(token)"
  }

  private func runEventStreamLoop() async {
    let service = AgentEventStreamService(
      makeClient: { [weak self] in try self?.makeClient() },
      eventStreamKey: { [weak self] in self?.eventStreamKey() ?? "" },
      isSuspended: { [weak self] in (self?.autoRefreshSuspendCount ?? 0) > 0 },
      includeDefaultSystemPrompt: { [weak self] in
        (self?.defaultSystemPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true
      }
    )
    await service.run(
      onEvent: { [weak self] ev in
        guard let self else { return }
        await self.applyPushEvent(name: ev.name, data: ev.data)
      },
      onConnectionError: { [weak self] msg in
        guard let self else { return }
        if self.connectionError != msg {
          self.connectionError = msg
        }
        if self.localNetworkAccess != nil {
          self.localNetworkAccess = nil
        }
      }
    )
  }

  private func applyPushEvent(name: String, data: String) async {
    if connectionError != nil {
      connectionError = nil
    }
    if let err = lastActionError, !err.isEmpty, Self.isTransientNetworkErrorString(err) {
      lastActionError = nil
    }
    Task { await self.checkLocalNetworkAccess(force: false) }

    switch name {
    case "ping":
      return
    case "snapshot":
      await applySnapshotEvent(data)
    case "status":
      await applyStatusEvent(data)
    case "log":
      applyLogEvent(data)
    case "chat":
      await applyChatEvent(data)
    default:
      return
    }
  }

  private func applySnapshotEvent(_ raw: String) async {
    guard let data = raw.data(using: .utf8) else { return }
    guard let snap = try? JSONDecoder().decode(AgentEventSnapshot.self, from: data) else { return }

    let st = snap.status
    let wasRunning = status?.running ?? false

    if status != st {
      status = st
    }
    if defaultSystemPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let template = st.config.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      if !template.isEmpty {
        defaultSystemPromptTemplate = template
      }
    }

    if logs != snap.logs {
      logs = snap.logs
    }
    if logsError != nil {
      logsError = nil
    }

    if chatItems != snap.chat {
      chatItems = snap.chat
      stepActionAnnotations = ActionAnnotation.buildMap(from: chatItems)
      let stepsInChat = Set(chatItems.compactMap { $0.step })
      stepScreenshots = stepScreenshots.filter { stepsInChat.contains($0.key) }
      stepScreenshotErrors = stepScreenshotErrors.filter { stepsInChat.contains($0.key) }
      stepScreenshotLoading = Set(stepScreenshotLoading.filter { stepsInChat.contains($0) })
    }
    if chatError != nil {
      chatError = nil
    }

    if !didHydrateFromDevice {
      hydrateFromDevice(st.config)
      didHydrateFromDevice = true
    }

    updateDerivedState(wasRunning: wasRunning, st: st)
  }

  private func applyStatusEvent(_ raw: String) async {
    guard let data = raw.data(using: .utf8) else { return }
    guard let st = try? JSONDecoder().decode(AgentStatus.self, from: data) else { return }

    let wasRunning = status?.running ?? false
    if status != st {
      status = st
    }
    if defaultSystemPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let template = st.config.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      if !template.isEmpty {
        defaultSystemPromptTemplate = template
      }
    }

    if !didHydrateFromDevice {
      hydrateFromDevice(st.config)
      didHydrateFromDevice = true
    }

    updateDerivedState(wasRunning: wasRunning, st: st)
  }

  private func applyLogEvent(_ line: String) {
    logs.append(line)
    while logs.count > 300 {
      logs.removeFirst()
    }
    if logsError != nil {
      logsError = nil
    }
    if let st = status {
      updateDerivedState(wasRunning: st.running, st: st)
    }
  }

  private func applyChatEvent(_ raw: String) async {
    guard let data = raw.data(using: .utf8) else { return }
    guard let item = try? JSONDecoder().decode(AgentChatItem.self, from: data) else { return }

    chatItems.append(item)

    if let lastStep = item.step {
      let maxSteps = status?.config.maxSteps ?? 0
      if maxSteps > 0 {
        let minStep = max(0, lastStep - maxSteps + 1)
        while let first = chatItems.first, let s = first.step, s >= 0, s < minStep {
          chatItems.removeFirst()
        }
      }
    }

    stepActionAnnotations = ActionAnnotation.buildMap(from: chatItems)
    let stepsInChat = Set(chatItems.compactMap { $0.step })
    stepScreenshots = stepScreenshots.filter { stepsInChat.contains($0.key) }
    stepScreenshotErrors = stepScreenshotErrors.filter { stepsInChat.contains($0.key) }
    stepScreenshotLoading = Set(stepScreenshotLoading.filter { stepsInChat.contains($0) })

    if chatError != nil {
      chatError = nil
    }
    if let st = status {
      updateDerivedState(wasRunning: st.running, st: st)
    }
  }

  func boot() async {
    if eventStreamTask != nil {
      return
    }
    startNetworkMonitorIfNeeded()
    await refresh()
    eventStreamTask = Task { @MainActor [weak self] in
      await self?.runEventStreamLoop()
    }
  }

  private func startNetworkMonitorIfNeeded() {
    #if os(iOS)
    if networkMonitor != nil {
      return
    }

    let monitor = NWPathMonitor()
    let queue = DispatchQueue(label: "ondevice_agent.console.network_monitor")
    monitor.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        guard let self else { return }
        if path.status != .satisfied || !path.usesInterfaceType(.wifi) {
          if self.localNetworkAccess != nil {
            self.localNetworkAccess = nil
          }
          return
        }
        await self.checkLocalNetworkAccess(force: true)
      }
    }
    monitor.start(queue: queue)
    networkMonitor = monitor
    networkMonitorQueue = queue
    #endif
  }

  private func stopNetworkMonitor() {
    #if os(iOS)
    networkMonitor?.cancel()
    networkMonitor = nil
    networkMonitorQueue = nil
    #endif
  }

  func suspendAutoRefresh() {
    autoRefreshSuspendCount += 1
  }

  func resumeAutoRefresh() {
    autoRefreshSuspendCount = max(0, autoRefreshSuspendCount - 1)
    if autoRefreshSuspendCount == 0 {
      Task { @MainActor [weak self] in
        await self?.refresh()
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
      let client = try makeClient()
      let needDefaultPrompt = defaultSystemPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let st = try await client.getStatus(includeDefaultSystemPrompt: needDefaultPrompt)

      guard gen == stateGeneration else { return }
      let wasRunning = status?.running ?? false
      if status != st {
        status = st
      }
      if needDefaultPrompt {
        let template = st.config.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty {
          defaultSystemPromptTemplate = template
        }
      }
      if connectionError != nil {
        connectionError = nil
      }
      if let err = lastActionError, !err.isEmpty, Self.isTransientNetworkErrorString(err) {
        lastActionError = nil
      }
      Task { await self.checkLocalNetworkAccess(force: false) }

      do {
        let newLogs = try await client.getLogs()
        guard gen == stateGeneration else { return }
        if logs != newLogs {
          logs = newLogs
        }
        if logsError != nil {
          logsError = nil
        }
      } catch {
        guard gen == stateGeneration else { return }
        let msg = error.localizedDescription
        if logsError != msg {
          logsError = msg
        }
      }

      do {
        let newChat = try await client.getChat()
        guard gen == stateGeneration else { return }
        if chatItems != newChat {
          chatItems = newChat
          stepActionAnnotations = ActionAnnotation.buildMap(from: newChat)
          let stepsInChat = Set(newChat.compactMap { $0.step })
          stepScreenshots = stepScreenshots.filter { stepsInChat.contains($0.key) }
          stepScreenshotErrors = stepScreenshotErrors.filter { stepsInChat.contains($0.key) }
          stepScreenshotLoading = Set(stepScreenshotLoading.filter { stepsInChat.contains($0) })
        }
        if chatError != nil {
          chatError = nil
        }
      } catch {
        guard gen == stateGeneration else { return }
        let msg = error.localizedDescription
        if chatError != msg {
          chatError = msg
        }
      }

      if !didHydrateFromDevice {
        hydrateFromDevice(st.config)
        didHydrateFromDevice = true
      }

      updateDerivedState(wasRunning: wasRunning, st: st)
    } catch {
      guard gen == stateGeneration else { return }
      let msg = error.localizedDescription
      if connectionError != msg {
        connectionError = msg
      }
      if localNetworkAccess != nil {
        localNetworkAccess = nil
      }
    }
  }

  func saveConfig() async {
    stateGeneration &+= 1
    do {
      let client = try makeClient()
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
    liveProgress = LiveProgress()
    do {
      let client = try makeClient()
      let req = try makeConfigRequest()
      let resp = try await client.start(req)
      if resp.ok == false {
        lastActionError = resp.error ?? NSLocalizedString("Start failed", comment: "")
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
      let client = try makeClient()
      status = try await client.stop()
      connectionError = nil
      lastActionError = nil
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  func resetRuntime() async {
    stateGeneration &+= 1
    // "Reset Runtime" should clear all runtime artifacts visible in Logs/Chat/Notes.
    logs.removeAll()
    chatItems.removeAll()
    stepScreenshots.removeAll()
    stepScreenshotErrors.removeAll()
    stepScreenshotLoading.removeAll()
    stepActionAnnotations.removeAll()
    liveProgress = LiveProgress()
    do {
      let client = try makeClient()
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
    liveProgress = LiveProgress()
    do {
      let client = try makeClient()
      let st = try await client.factoryReset()
      status = st
      connectionError = nil
      lastActionError = nil

      draft = Draft()
      didHydrateFromDevice = false
      defaultSystemPromptTemplate = ""
      hydrateFromDevice(st.config)
      // Runner never returns the secret API key; after a full reset it is safer to clear it locally too.
      draft.apiKey = ""
      draft.showApiKey = false
    } catch {
      lastActionError = error.localizedDescription
    }
  }

  enum ValidationIssue: Equatable {
    case baseURLRequired
    case modelRequired
    case taskRequired

    case maxStepsInvalid
    case timeoutSecondsInvalid
    case stepDelaySecondsInvalid
    case maxOutputTokensInvalid

    case apiKeyRequired
    case agentTokenRequiredForLAN

    var l10nKey: String {
      switch self {
      case .baseURLRequired: return "Base URL is required"
      case .modelRequired: return "Model is required"
      case .taskRequired: return "Task is required"
      case .maxStepsInvalid: return "Max Steps must be > 0"
      case .timeoutSecondsInvalid: return "Timeout (seconds) must be > 0"
      case .stepDelaySecondsInvalid: return "Step Delay (seconds) must be > 0"
      case .maxOutputTokensInvalid: return "Max Tokens must be > 0"
      case .apiKeyRequired: return "API Key is required"
      case .agentTokenRequiredForLAN: return "Agent token is required for LAN access"
      }
    }
  }

  private func validationIssues() -> [ValidationIssue] {
    ConsoleConfigValidator.validationIssues(draft: draft)
  }

  private func runValidationIssues() -> [ValidationIssue] {
    ConsoleConfigValidator.runValidationIssues(
      draft: draft,
      status: status,
      isLoopbackRunnerURL: isLoopbackRunnerURL
    )
  }

  func validationErrors() -> [String] {
    validationIssues().map(\.l10nKey)
  }

  func runValidationErrors() -> [String] {
    runValidationIssues().map(\.l10nKey)
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
      let client = try makeClient()
      let png = try await client.getStepScreenshotPNG(step: step)
      guard gen == stateGeneration else { return }
      guard let image = PlatformImage(data: png) else {
        stepScreenshotErrors[step] = NSLocalizedString("Invalid screenshot image", comment: "")
        return
      }
      stepScreenshots[step] = image
      stepScreenshotErrors[step] = nil
    } catch {
      guard gen == stateGeneration else { return }
      stepScreenshotErrors[step] = error.localizedDescription
    }
  }

  struct StepScreenshotsBatch: Sendable {
    var mimeType: String
    var format: String
    var imagesBase64: [Int: String]
    var missingSteps: [Int]
  }

  func fetchStepScreenshotsBase64(
    steps: [Int],
    format: String = Defaults.exportScreenshotFormat,
    quality: Double = Defaults.exportScreenshotQuality
  ) async throws -> StepScreenshotsBatch {
    let uniqueSteps = Array(Set(steps.filter { $0 >= 0 })).sorted()
    let client = try makeClient()
    let payload = try await client.getStepScreenshotsBase64(
      steps: uniqueSteps,
      limit: nil,
      format: format,
      quality: quality
    )
    if !payload.ok {
      throw AgentClientError.server(payload.error)
    }

    var images: [Int: String] = [:]
    for (k, v) in payload.images {
      guard let step = Int(k), step >= 0 else { continue }
      images[step] = v
    }
    return StepScreenshotsBatch(
      mimeType: payload.mimeType,
      format: payload.format,
      imagesBase64: images,
      missingSteps: payload.missing
    )
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
    var restart_responses_by_plan: Bool
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
    var req = try makeConfigRequest(requireLANToken: false)
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
      restart_responses_by_plan: req.restart_responses_by_plan,
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

  private func makeConfigRequest(requireLANToken: Bool = true) throws -> AgentConfigRequest {
    let baseUrl = draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
    let task = draft.task
    let apiMode = draft.apiMode.trimmingCharacters(in: .whitespacesAndNewlines)

    if let first = validationIssues().first {
      throw AgentClientError.server(NSLocalizedString(first.l10nKey, comment: ""))
    }

    let maxStepsRaw = draft.maxSteps.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxTokensRaw = draft.maxCompletionTokens.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeoutRaw = draft.timeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
    let stepDelayRaw = draft.stepDelaySeconds.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let maxSteps = Int(maxStepsRaw), maxSteps > 0 else {
      throw AgentClientError.server(NSLocalizedString(ValidationIssue.maxStepsInvalid.l10nKey, comment: ""))
    }
    guard let maxTokens = Int(maxTokensRaw), maxTokens > 0 else {
      throw AgentClientError.server(NSLocalizedString(ValidationIssue.maxOutputTokensInvalid.l10nKey, comment: ""))
    }
    guard let timeout = Double(timeoutRaw), timeout > 0 else {
      throw AgentClientError.server(NSLocalizedString(ValidationIssue.timeoutSecondsInvalid.l10nKey, comment: ""))
    }
    guard let stepDelay = Double(stepDelayRaw), stepDelay > 0 else {
      throw AgentClientError.server(NSLocalizedString(ValidationIssue.stepDelaySecondsInvalid.l10nKey, comment: ""))
    }

    let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentToken = draft.agentToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if requireLANToken, !isLoopbackRunnerURL, agentToken.isEmpty {
      throw AgentClientError.server(NSLocalizedString(ValidationIssue.agentTokenRequiredForLAN.l10nKey, comment: ""))
    }

    return AgentConfigRequest(
      base_url: baseUrl,
      model: model,
      api_mode: apiMode,
      agent_token: agentToken.isEmpty ? nil : agentToken,
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
      restart_responses_by_plan: draft.restartResponsesByPlan,
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
    draft.restartResponsesByPlan = cfg.restartResponsesByPlan

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

  private func updateDerivedState(wasRunning: Bool, st: AgentStatus) {
    if wasRunning, !st.running {
      // Keep UI state derived from latest status/logs/chat.
    }

    lastSeenRunning = st.running
    let next = Self.computeLiveProgress(status: st, logs: logs, chatItems: chatItems)
    if liveProgress != next {
      liveProgress = next
    }
  }

  private static func isTransientNetworkErrorString(_ message: String) -> Bool {
    let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return false }
    let lower = raw.lowercased()

    // English keywords
    if lower.contains("network") || lower.contains("connection") || lower.contains("offline") {
      return true
    }
    if lower.contains("timed out") || lower.contains("timeout") || lower.contains("internet") {
      return true
    }

    // Common Chinese keywords
    if raw.contains("网络") || raw.contains("连接") || raw.contains("离线") || raw.contains("超时") || raw.contains("互联网") {
      return true
    }

    return false
  }

  private static func computeLiveProgress(status: AgentStatus, logs: [String], chatItems: [AgentChatItem]) -> LiveProgress {
    var out = LiveProgress()
    out.running = status.running

    if !status.running {
      out.phase = .idle
      return out
    }

    let lastMessage = status.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lastMessage.contains("stopping") {
      out.phase = .stopping
    }

    let lastAgentStep = parseLatestAgentStep(from: logs)
    out.tokens = parseLatestTokens(from: logs)
    out.nextPlanItem = extractNextPlanItem(from: chatItems)

    let lastChat = chatItems.last(where: { $0.step != nil })
    if let c = lastChat {
      out.step = c.step
      out.attempt = c.attempt
      if out.phase != .stopping {
        out.phase = (c.kind == "request") ? .callingModel : .parsingOutput
      }
    }

    if let s = lastAgentStep {
      if out.step == nil || s.step >= (out.step ?? -1) {
        out.step = s.step
        out.action = s.action
        out.attempt = nil
        if out.phase != .stopping {
          out.phase = .executingAction
        }
      }
    }

    return out
  }

  private static func parseLatestAgentStep(from logs: [String]) -> LiveProgress.AgentStep? {
    for line in logs.reversed() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { continue }
      guard let data = trimmed.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = obj as? [String: Any]
      else { continue }

      guard (dict["event"] as? String) == "step" else { continue }

      func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
      }

      let step = int(dict["step"]) ?? -1
      let action = (dict["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if step < 0 || action.isEmpty { continue }
      return LiveProgress.AgentStep(step: step, action: action)
    }
    return nil
  }

  private static func parseLatestTokens(from logs: [String]) -> LiveProgress.Tokens? {
    for line in logs.reversed() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { continue }
      guard let data = trimmed.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = obj as? [String: Any]
      else { continue }

      guard (dict["event"] as? String) == "token_usage" else { continue }

      func int(_ key: String) -> Int {
        let v = dict[key]
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
      }

      let req = int("req")
      if req <= 0 { continue }

      return LiveProgress.Tokens(
        requestIndex: req,
        delta: .init(input: int("d_in"), output: int("d_out"), cached: int("d_cached"), total: int("d_total")),
        cumulative: .init(input: int("c_in"), output: int("c_out"), cached: int("c_cached"), total: int("c_total"))
      )
    }
    return nil
  }

  private static func parseIntPrefix(from text: Substring) -> Int? {
    var j = text.startIndex
    while j < text.endIndex, text[j].isNumber {
      j = text.index(after: j)
    }
    guard j > text.startIndex else { return nil }
    return Int(text[text.startIndex..<j])
  }

  private static func parseInt(after marker: String, in text: Substring) -> Int? {
    guard let r = text.range(of: marker) else { return nil }
    let after = text[r.upperBound...]
    return parseIntPrefix(from: after)
  }

  private struct PlanChecklistItem {
    var text: String
    var done: Bool
  }

  private static func extractNextPlanItem(from chatItems: [AgentChatItem]) -> String? {
    for it in chatItems.reversed() {
      guard it.kind == "response" else { continue }
      let content = (it.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else { continue }
      guard let dict = parseAssistantJSONObject(from: content) else { continue }
      guard let planObj = dict["plan"] else { continue }
      let items = planChecklist(from: planObj)
      if let next = items.first(where: { !$0.done }) {
        return next.text
      }
    }
    return nil
  }

  private static func parseAssistantJSONObject(from text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let dict = parseJSONDictionary(from: trimmed) {
      return dict
    }
    guard let first = trimmed.firstIndex(of: "{"),
          let last = trimmed.lastIndex(of: "}"),
          first < last
    else { return nil }
    let candidate = String(trimmed[first...last])
    return parseJSONDictionary(from: candidate)
  }

  private static func parseJSONDictionary(from text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = obj as? [String: Any]
    else { return nil }
    return dict
  }

  private static func planChecklist(from obj: Any) -> [PlanChecklistItem] {
    guard let arr = obj as? [Any] else { return [] }
    var out: [PlanChecklistItem] = []
    for item in arr {
      if let s = item as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
          out.append(PlanChecklistItem(text: t, done: false))
        }
        continue
      }
      guard let d = item as? [String: Any] else { continue }
      var text = ""
      if let s = d["text"] as? String {
        text = s.trimmingCharacters(in: .whitespacesAndNewlines)
      } else if let s = d["item"] as? String {
        text = s.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard !text.isEmpty else { continue }
      let done = boolLike(d["done"]) ?? false
      out.append(PlanChecklistItem(text: text, done: done))
    }
    if out.count > 12 {
      return Array(out.prefix(12))
    }
    return out
  }

  private static func boolLike(_ obj: Any?) -> Bool? {
    if let b = obj as? Bool { return b }
    if let i = obj as? Int { return i != 0 }
    if let n = obj as? NSNumber { return n.boolValue }
    if let s = obj as? String {
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
}

// MARK: - QR code config parsing/validation

enum QRConfigKind {
  case string
  case bool
  case positiveInt
  case positiveDouble
  case apiMode
  case optionalString
}

struct QRCodeConfigCodec {
  enum JSONCoerce {
    static func string(_ v: Any?) -> String? {
      guard let v else { return nil }
      if v is NSNull { return nil }
      if let s = v as? String { return s }
      if let n = v as? NSNumber { return n.stringValue }
      return nil
    }

    static func bool(_ v: Any?) -> Bool? {
      guard let v else { return nil }
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

    static func int(_ v: Any?) -> Int? {
      guard let v else { return nil }
      if v is NSNull { return nil }
      if let i = v as? Int { return i }
      if let n = v as? NSNumber { return n.intValue }
      if let s = v as? String {
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }

    static func double(_ v: Any?) -> Double? {
      guard let v else { return nil }
      if v is NSNull { return nil }
      if let d = v as? Double { return d }
      if let n = v as? NSNumber { return n.doubleValue }
      if let s = v as? String {
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return nil
    }
  }

  private static let kinds: [String: QRConfigKind] = [
    "base_url": .string,
    "model": .string,
    "api_mode": .apiMode,
    "api_key": .string,
    "remember_api_key": .bool,
    "debug_log_raw_assistant": .bool,
    "insecure_skip_tls_verify": .bool,
    "half_res_screenshot": .bool,
    "use_w3c_actions_for_swipe": .bool,
    "restart_responses_by_plan": .bool,
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

  static func parseDict(_ raw: String) throws -> [String: Any] {
    guard let data = raw.data(using: .utf8) else {
      throw ConsoleStore.ConfigImportError.notValidUTF8
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw ConsoleStore.ConfigImportError.invalidJSON(error.localizedDescription)
    }
    guard let dict = json as? [String: Any] else {
      throw ConsoleStore.ConfigImportError.notJSONObject
    }
    return dict
  }

  static func validateDict(_ dict: [String: Any]) -> [String] {
    var errors: [String] = []
    for (k, v) in dict {
      guard let kind = kinds[k] else {
        errors.append(ConsoleStore.l10n("Unknown config key: %@", k))
        continue
      }
      switch kind {
      case .string:
        guard JSONCoerce.string(v) != nil else {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be a string", k))
          continue
        }
      case .optionalString:
        if v is NSNull { continue }
        guard JSONCoerce.string(v) != nil else {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be a string or null", k))
          continue
        }
      case .bool:
        guard JSONCoerce.bool(v) != nil else {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be a boolean", k))
          continue
        }
      case .positiveInt:
        guard let n = JSONCoerce.int(v) else {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be an integer", k))
          continue
        }
        if n <= 0 {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be > 0", k))
        }
      case .positiveDouble:
        guard let d = JSONCoerce.double(v) else {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be a number", k))
          continue
        }
        if d <= 0 {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be > 0", k))
        }
      case .apiMode:
        guard let s = JSONCoerce.string(v) else {
          errors.append(ConsoleStore.l10n("Invalid value for %@: must be a string", k))
          continue
        }
        let mode = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode != ConsoleStore.Defaults.apiMode && mode != "chat_completions" {
          errors.append(ConsoleStore.l10n("Invalid value for %@: unsupported api_mode '%@'", k, mode))
        }
      }
    }
    return errors
  }
}

// MARK: - Config validation

struct ConsoleConfigValidator {
  static func validationIssues(draft: ConsoleStore.Draft) -> [ConsoleStore.ValidationIssue] {
    var issues: [ConsoleStore.ValidationIssue] = []

    if draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.baseURLRequired)
    }
    if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.modelRequired)
    }
    if draft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.taskRequired)
    }

    let maxStepsRaw = draft.maxSteps.trimmingCharacters(in: .whitespacesAndNewlines)
    let timeoutRaw = draft.timeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)
    let stepDelayRaw = draft.stepDelaySeconds.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxTokensRaw = draft.maxCompletionTokens.trimmingCharacters(in: .whitespacesAndNewlines)

    if Int(maxStepsRaw) == nil || (Int(maxStepsRaw) ?? 0) <= 0 {
      issues.append(.maxStepsInvalid)
    }
    if Double(timeoutRaw) == nil || (Double(timeoutRaw) ?? 0) <= 0 {
      issues.append(.timeoutSecondsInvalid)
    }
    if Double(stepDelayRaw) == nil || (Double(stepDelayRaw) ?? 0) <= 0 {
      issues.append(.stepDelaySecondsInvalid)
    }
    if Int(maxTokensRaw) == nil || (Int(maxTokensRaw) ?? 0) <= 0 {
      issues.append(.maxOutputTokensInvalid)
    }

    return issues
  }

  static func runValidationIssues(
    draft: ConsoleStore.Draft,
    status: AgentStatus?,
    isLoopbackRunnerURL: Bool
  ) -> [ConsoleStore.ValidationIssue] {
    var issues = validationIssues(draft: draft)

    let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiKeySet = status?.config.apiKeySet ?? false
    if key.isEmpty, !apiKeySet {
      issues.append(.apiKeyRequired)
    }

    if !isLoopbackRunnerURL {
      let token = draft.agentToken.trimmingCharacters(in: .whitespacesAndNewlines)
      if token.isEmpty {
        issues.append(.agentTokenRequiredForLAN)
      }
    }

    return issues
  }
}

struct SSEEvent: Equatable {
  var name: String
  var data: String
}

struct SSEEventParser {
  private var currentEvent: String = ""
  private var dataLines: [String] = []

  mutating func consume(line rawLine: String) -> SSEEvent? {
    let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

    if line.isEmpty {
      let event = currentEvent.isEmpty ? "message" : currentEvent
      let data = dataLines.joined(separator: "\n")
      currentEvent = ""
      dataLines.removeAll(keepingCapacity: true)
      return SSEEvent(name: event, data: data)
    }

    if line.hasPrefix(":") {
      return nil
    }

    if let v = Self.sseValue(line, prefix: "event:") {
      currentEvent = v.trimmingCharacters(in: .whitespacesAndNewlines)
      return nil
    }
    if let v = Self.sseValue(line, prefix: "data:") {
      dataLines.append(v)
      return nil
    }
    return nil
  }

  private static func sseValue(_ line: String, prefix: String) -> String? {
    guard line.hasPrefix(prefix) else { return nil }
    var v = line.dropFirst(prefix.count)
    if v.first == " " {
      v = v.dropFirst()
    }
    return String(v)
  }
}

// MARK: - Event stream service (reduces responsibilities in ConsoleStore)

@MainActor
final class AgentEventStreamService {
  private enum WatchdogError: Error {
    case stalled
  }

  private let makeClient: () throws -> AgentClient?
  private let eventStreamKey: () -> String
  private let isSuspended: () -> Bool
  private let includeDefaultSystemPrompt: () -> Bool

  init(
    makeClient: @escaping () throws -> AgentClient?,
    eventStreamKey: @escaping () -> String,
    isSuspended: @escaping () -> Bool,
    includeDefaultSystemPrompt: @escaping () -> Bool
  ) {
    self.makeClient = makeClient
    self.eventStreamKey = eventStreamKey
    self.isSuspended = isSuspended
    self.includeDefaultSystemPrompt = includeDefaultSystemPrompt
  }

  func run(
    onEvent: @escaping (SSEEvent) async -> Void,
    onConnectionError: @escaping (String) async -> Void
  ) async {
    var backoffMs = 200
    while !Task.isCancelled {
      if isSuspended() {
        try? await Task.sleep(nanoseconds: 200_000_000)
        continue
      }

      let key = eventStreamKey()
      do {
        guard let client = try makeClient() else {
          throw AgentClientError.badResponse
        }
        let bytes = try await client.openEventStream(includeDefaultSystemPrompt: includeDefaultSystemPrompt())
        backoffMs = 200
        try await consume(bytes, key: key, onEvent: onEvent)
      } catch {
        if Task.isCancelled {
          return
        }
        if error is WatchdogError {
          continue
        }
        await onConnectionError(error.localizedDescription)

        let delayMs = min(backoffMs, 5000)
        backoffMs = min(backoffMs * 2, 5000)
        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
      }
    }
  }

  private func consume(
    _ bytes: URLSession.AsyncBytes,
    key: String,
    onEvent: @escaping (SSEEvent) async -> Void
  ) async throws {
    let staleAfterSeconds: TimeInterval = 45
    var lastLineAt = Date()

    var parser = SSEEventParser()
    var didApplySnapshot = false

    func watchdog() async throws {
      while !Task.isCancelled {
        if eventStreamKey() != key {
          return
        }
        if isSuspended() {
          try? await Task.sleep(nanoseconds: 200_000_000)
          continue
        }
        if Date().timeIntervalSince(lastLineAt) > staleAfterSeconds {
          throw WatchdogError.stalled
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }

    var firstError: Error?
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { @MainActor in
        for try await rawLine in bytes.lines {
          if Task.isCancelled {
            return
          }
          if self.eventStreamKey() != key {
            return
          }
          lastLineAt = Date()

          guard let ev = parser.consume(line: rawLine) else { continue }
          if self.isSuspended() {
            continue
          }
          if ev.name == "snapshot" {
            didApplySnapshot = true
            await onEvent(ev)
          } else if didApplySnapshot {
            await onEvent(ev)
          }
        }
      }
      group.addTask { @MainActor in
        try await watchdog()
      }

      do {
        _ = try await group.next()
      } catch {
        firstError = error
      }

      group.cancelAll()
      do {
        try await group.waitForAll()
      } catch {
        if firstError == nil, !(error is CancellationError) {
          firstError = error
        }
      }

      if let firstError {
        throw firstError
      }
    }
  }
}
