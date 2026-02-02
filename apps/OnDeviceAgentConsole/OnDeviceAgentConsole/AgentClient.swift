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
      return "Invalid WDA URL: \(raw)"
    case .httpStatus(let code, let body):
      if body.isEmpty {
        return "HTTP \(code)"
      }
      return "HTTP \(code): \(body)"
    case .decodingFailed(let body):
      if body.isEmpty {
        return "Cannot decode JSON response"
      }
      return "Cannot decode JSON response: \(body)"
    case .badResponse:
      return "Bad response"
    case .server(let message):
      return message.isEmpty ? "Server error" : message
    }
  }
}

final class AgentClient {
  static let defaultSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = 8
    cfg.timeoutIntervalForResource = 8
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  private let baseURL: URL
  private let session: URLSession
  private let decoder: JSONDecoder

  init(wdaURL: String, session: URLSession = AgentClient.defaultSession) throws {
    let trimmed = wdaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
      throw AgentClientError.invalidWdaURL(wdaURL)
    }
    self.baseURL = url
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
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return req
  }

  private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
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

  func getStatus() async throws -> AgentStatus {
    try await fetch(request("GET", "/agent/status"), as: AgentStatus.self)
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

  func postConfig(_ cfg: AgentConfigRequest) async throws -> AgentStatus {
    let body = try JSONEncoder().encode(cfg)
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
