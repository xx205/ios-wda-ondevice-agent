import Foundation

enum ConsoleRedaction {
  static func redactSensitiveText(_ text: String) -> String {
    if text.isEmpty {
      return text
    }

    var out = text
    let replacements: [(pattern: String, replacement: String)] = [
      (#"(?i)"api_key"\s*:\s*"[^"]*""#, #""api_key":"<redacted>""#),
      (#"(?i)"authorization"\s*:\s*"[^"]*""#, #""authorization":"<redacted>""#),
      (#"(?i)"x-ondevice-agent-token"\s*:\s*"[^"]*""#, #""X-OnDevice-Agent-Token":"<redacted>""#),
      (#"(?i)"ondevice_agent_token"\s*:\s*"[^"]*""#, #""ondevice_agent_token":"<redacted>""#),
      (#"(?i)"agent_token"\s*:\s*"[^"]*""#, #""agent_token":"<redacted>""#),
      (#"(?i)authorization:\s*bearer\s+[A-Za-z0-9._\\-]+"#, #"Authorization: Bearer <redacted>"#),
      (#"(?i)\bbearer\s+[A-Za-z0-9._\\-]{10,}"#, #"Bearer <redacted>"#),
      (#"(?i)data:image\\?/[^"\s]*base64,[^"\s]+"#, #"data:image/png;base64,<omitted>"#),
      (#"(?i)\bondevice_agent_token=([A-Za-z0-9%._\\-]{6,})"#, #"ondevice_agent_token=<redacted>"#),
      (#"(?i)([?&]token=)([A-Za-z0-9%._\\-]{6,})"#, #"$1<redacted>"#),
    ]

    for item in replacements {
      guard let regex = try? NSRegularExpression(pattern: item.pattern) else {
        continue
      }
      let range = NSRange(out.startIndex..<out.endIndex, in: out)
      out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: item.replacement)
    }
    return out
  }
}

