import Foundation

enum AgentClientError: LocalizedError {
  case invalidWdaURL(String)
  case httpStatus(Int, String)
  case decodingFailed(String)
  case badResponse
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidWdaURL(let raw):
      return String(format: NSLocalizedString("Invalid Runner URL: %@", comment: ""), raw)
    case .httpStatus(let code, let body):
      if body.isEmpty {
        return "HTTP \(code)"
      }
      return "HTTP \(code): \(body)"
    case .decodingFailed(let body):
      if body.isEmpty {
        return NSLocalizedString("Cannot decode JSON response", comment: "")
      }
      return String(format: NSLocalizedString("Cannot decode JSON response: %@", comment: ""), body)
    case .badResponse:
      return NSLocalizedString("Bad response", comment: "")
    case .server(let message):
      if message.isEmpty {
        return NSLocalizedString("Server error", comment: "")
      }
      return message
    }
  }
}

final class AgentClient {
  private struct AgentTokenOnlyConfigRequest: Encodable {
    let agent_token: String
  }

  static let defaultSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = 8
    cfg.timeoutIntervalForResource = 8
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  static let eventStreamSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = 30
    cfg.timeoutIntervalForResource = 60 * 60
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  private let baseURL: URL
  private let agentToken: String
  private let session: URLSession
  private let decoder: JSONDecoder

  init(wdaURL: String, agentToken: String = "", session: URLSession = AgentClient.defaultSession) throws {
    let trimmed = wdaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
      throw AgentClientError.invalidWdaURL(wdaURL)
    }
    self.baseURL = url
    self.agentToken = agentToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.session = session
    self.decoder = JSONDecoder()
  }

  private func endpoint(_ path: String) -> URL {
    // `path` should start with "/"
    URL(string: path, relativeTo: baseURL)!.absoluteURL
  }

  private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
    var req = URLRequest(url: endpoint(path))
    req.httpMethod = method
    if !agentToken.isEmpty {
      req.setValue(agentToken, forHTTPHeaderField: "X-OnDevice-Agent-Token")
    }
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return req
  }

  func openEventStream(includeDefaultSystemPrompt: Bool = false) async throws -> URLSession.AsyncBytes {
    let path = includeDefaultSystemPrompt ? "/agent/events?include_default_system_prompt=1" : "/agent/events"
    var req = request("GET", path)
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

    let (bytes, resp) = try await AgentClient.eventStreamSession.bytes(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw AgentClientError.badResponse
    }
    if !(200..<300).contains(http.statusCode) {
      throw AgentClientError.httpStatus(http.statusCode, "")
    }
    return bytes
  }

  private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try Self.decodeWDAEnvelopeOrDirect(type, from: data, decoder: decoder)
  }

  static func decodeWDAEnvelopeOrDirect<T: Decodable>(
    _ type: T.Type,
    from data: Data,
    decoder: JSONDecoder = JSONDecoder()
  ) throws -> T {
    do {
      return try decoder.decode(WDAEnvelope<T>.self, from: data).value
    } catch {
      // Some implementations may return the object directly (without { "value": ... } envelope).
      if let direct = try? decoder.decode(T.self, from: data) {
        return direct
      }
      throw error
    }
  }

  private func fetch<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
    let (data, resp) = try await session.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
      throw AgentClientError.badResponse
    }
    if !(200..<300).contains(http.statusCode) {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw AgentClientError.httpStatus(http.statusCode, body)
    }
    do {
      return try decodeEnvelope(type, from: data)
    } catch {
      var body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
      let limit = 2000
      if body.count > limit {
        body = String(body.prefix(limit)) + "…"
      }
      throw AgentClientError.decodingFailed(body)
    }
  }

  func getStatus(includeDefaultSystemPrompt: Bool = false) async throws -> AgentStatus {
    let path = includeDefaultSystemPrompt
      ? "/agent/status?include_default_system_prompt=1"
      : "/agent/status"
    return try await fetch(request("GET", path), as: AgentStatus.self)
  }

  func getLogs() async throws -> [String] {
    let payload = try await fetch(request("GET", "/agent/logs"), as: AgentLogsPayload.self)
    return payload.lines
  }

  func getChat() async throws -> [AgentChatItem] {
    let payload = try await fetch(request("GET", "/agent/chat"), as: AgentChatPayload.self)
    return payload.items
  }

  func getStepScreenshotPNG(step: Int) async throws -> Data {
    let payload = try await fetch(request("GET", "/agent/step_screenshot?step=\(step)"), as: AgentStepScreenshotPayload.self)
    if !payload.ok {
      throw AgentClientError.server(payload.error.isEmpty ? "Screenshot not found" : payload.error)
    }
    guard !payload.pngBase64.isEmpty, let data = Data(base64Encoded: payload.pngBase64) else {
      throw AgentClientError.server("Invalid screenshot payload")
    }
    return data
  }

  func getStepScreenshotsBase64(
    steps: [Int],
    limit: Int? = nil,
    format: String? = nil,
    quality: Double? = nil
  ) async throws -> AgentStepScreenshotsPayload {
    var comps = URLComponents(url: endpoint("/agent/step_screenshots"), resolvingAgainstBaseURL: false)!
    var items: [URLQueryItem] = []
    if !steps.isEmpty {
      items.append(URLQueryItem(name: "steps", value: steps.map(String.init).joined(separator: ",")))
    }
    if let limit {
      items.append(URLQueryItem(name: "limit", value: String(limit)))
    }
    if let format, !format.isEmpty {
      items.append(URLQueryItem(name: "format", value: format))
    }
    if let quality {
      items.append(URLQueryItem(name: "quality", value: String(quality)))
    }
    if !items.isEmpty {
      comps.queryItems = items
    }

    var req = URLRequest(url: comps.url!)
    req.httpMethod = "GET"
    if !agentToken.isEmpty {
      req.setValue(agentToken, forHTTPHeaderField: "X-OnDevice-Agent-Token")
    }
    return try await fetch(req, as: AgentStepScreenshotsPayload.self)
  }

  func postConfig(_ cfg: AgentConfigRequest) async throws -> AgentStatus {
    let body = try JSONEncoder().encode(cfg)
    return try await fetch(request("POST", "/agent/config", body: body), as: AgentStatus.self)
  }

  func postAgentTokenOnly(_ token: String) async throws -> AgentStatus {
    let body = try JSONEncoder().encode(AgentTokenOnlyConfigRequest(agent_token: token))
    return try await fetch(request("POST", "/agent/config", body: body), as: AgentStatus.self)
  }

  func start(_ cfg: AgentConfigRequest) async throws -> AgentStartPayload {
    let body = try JSONEncoder().encode(cfg)
    return try await fetch(request("POST", "/agent/start", body: body), as: AgentStartPayload.self)
  }

  func stop() async throws -> AgentStatus {
    try await fetch(request("POST", "/agent/stop", body: Data("{}".utf8)), as: AgentStatus.self)
  }

  func reset() async throws -> AgentStatus {
    try await fetch(request("POST", "/agent/reset", body: Data("{}".utf8)), as: AgentStatus.self)
  }

  func factoryReset() async throws -> AgentStatus {
    try await fetch(request("POST", "/agent/factory_reset", body: Data("{}".utf8)), as: AgentStatus.self)
  }
}
