import Foundation
import SwiftUI

private struct ChatExportTokenUsage: Sendable {
  var requests: Int
  var inputTokens: Int
  var outputTokens: Int
  var cachedTokens: Int
  var totalTokens: Int
}

private struct ChatExportItem: Sendable {
  var kind: String
  var ts: String
  var step: Int
  var attempt: Int?
  var raw: String
  var text: String
  var content: String
  var reasoning: String
}

private struct ChatExportActionAnnotation: Sendable {
  enum Kind: String, Sendable {
    case tap
    case swipe
    case label
  }

  var name: String
  var kind: Kind
  var x1: Double
  var y1: Double
  var x2: Double
  var y2: Double
}

private struct ChatExportHTMLSnapshot: Sendable {
  var exportedAt: String
  var runnerURL: String
  var annotate: Bool
  var tokenUsage: ChatExportTokenUsage?
  var configText: String
  var notes: String
  var items: [ChatExportItem]
  var screenshotMimeType: String
  var screenshotsBase64: [Int: String]
  var annotationsByStep: [Int: ChatExportActionAnnotation]
}

private enum ChatExportHTML {
  static func build(snapshot: ChatExportHTMLSnapshot) -> String {
    func esc(_ s: String) -> String {
      var out = s
      out = out.replacingOccurrences(of: "&", with: "&amp;")
      out = out.replacingOccurrences(of: "<", with: "&lt;")
      out = out.replacingOccurrences(of: ">", with: "&gt;")
      out = out.replacingOccurrences(of: "\"", with: "&quot;")
      return out
    }

    func l(_ key: String) -> String {
      esc(NSLocalizedString(key, comment: ""))
    }

    let lang = Locale.current.languageCode ?? "en"

    func svgOverlay(for annotation: ChatExportActionAnnotation) -> String? {
      switch annotation.kind {
      case .tap:
        let x = max(0, min(1000, annotation.x1))
        let y = max(0, min(1000, annotation.y1))
        return """
        <svg class="overlay" viewBox="0 0 1000 1000" preserveAspectRatio="none" aria-hidden="true">
          <circle cx="\(x)" cy="\(y)" r="22" fill="rgba(255,0,0,0.18)"></circle>
          <circle cx="\(x)" cy="\(y)" r="22" fill="none" stroke="#ff3b30" stroke-width="4"></circle>
          <circle cx="\(x)" cy="\(y)" r="6" fill="#ff3b30"></circle>
        </svg>
        """

      case .swipe:
        let sx = max(0, min(1000, annotation.x1))
        let sy = max(0, min(1000, annotation.y1))
        let ex = max(0, min(1000, annotation.x2))
        let ey = max(0, min(1000, annotation.y2))
        let dx = ex - sx
        let dy = ey - sy
        let angle = atan2(dy, dx)
        let length: Double = 28
        let spread: Double = 0.55
        let p1x = ex - length * cos(angle - spread)
        let p1y = ey - length * sin(angle - spread)
        let p2x = ex - length * cos(angle + spread)
        let p2y = ey - length * sin(angle + spread)
        return """
        <svg class="overlay" viewBox="0 0 1000 1000" preserveAspectRatio="none" aria-hidden="true">
          <line x1="\(sx)" y1="\(sy)" x2="\(ex)" y2="\(ey)" stroke="#ff3b30" stroke-width="6" stroke-linecap="round"></line>
          <circle cx="\(sx)" cy="\(sy)" r="6" fill="#ff3b30"></circle>
          <line x1="\(ex)" y1="\(ey)" x2="\(p1x)" y2="\(p1y)" stroke="#ff3b30" stroke-width="6" stroke-linecap="round"></line>
          <line x1="\(ex)" y1="\(ey)" x2="\(p2x)" y2="\(p2y)" stroke="#ff3b30" stroke-width="6" stroke-linecap="round"></line>
        </svg>
        """

      case .label:
        return nil
      }
    }

    var parts: [String] = []
    parts.append("""
    <!doctype html>
    <html lang="\(esc(lang))">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>\(l("Chat export"))</title>
      <style>
        :root {
          color-scheme: light dark;
          --bg: #0b0b0c;
          --fg: #f5f5f7;
          --muted: rgba(255,255,255,0.72);
          --card: rgba(255,255,255,0.06);
          --border: rgba(255,255,255,0.12);
          --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
        }
        @media (prefers-color-scheme: light) {
          :root {
            --bg: #ffffff;
            --fg: #111111;
            --muted: rgba(0,0,0,0.64);
            --card: rgba(0,0,0,0.04);
            --border: rgba(0,0,0,0.12);
          }
        }
        body { margin: 0; background: var(--bg); color: var(--fg); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        .wrap { max-width: 920px; margin: 0 auto; padding: 20px 16px 48px; }
        h1 { margin: 0 0 6px; font-size: 20px; }
        .meta { color: var(--muted); font-size: 13px; line-height: 1.45; }
        .card { margin-top: 12px; background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 12px; }
        pre { margin: 8px 0 0; padding: 10px; border-radius: 10px; border: 1px solid var(--border); background: rgba(0,0,0,0.12); font-family: var(--mono); font-size: 12px; white-space: pre-wrap; word-break: break-word; }
        details { margin-top: 8px; }
        summary { cursor: pointer; color: var(--muted); }
        .item { margin-top: 14px; }
        .hdr { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
        .hdr .k { font-weight: 600; }
        .hdr .ts { color: var(--muted); font-size: 12px; }
        .shot { position: relative; display: inline-block; max-width: 100%; margin-top: 8px; }
        .shot img { display: block; max-width: 100%; height: auto; border-radius: 12px; border: 1px solid var(--border); }
        .overlay { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; }
        .badge { position: absolute; top: 10px; left: 10px; font-size: 12px; font-weight: 600; padding: 4px 8px; border-radius: 9px; background: rgba(0,0,0,0.55); color: #fff; border: 1px solid rgba(255,255,255,0.12); }
        .sec { margin-top: 10px; }
        .label { font-size: 12px; color: var(--muted); margin-top: 8px; }
      </style>
    </head>
    <body>
      <div class="wrap">
        <h1>\(l("Chat export"))</h1>
        <div class="meta">\(l("Exported at")) <span class="mono">\(esc(snapshot.exportedAt))</span></div>
        <div class="meta">\(l("Runner URL")) <span class="mono">\(esc(snapshot.runnerURL.isEmpty ? NSLocalizedString("(empty)", comment: "") : snapshot.runnerURL))</span></div>
        <div class="meta">\(l("Screenshot annotations")) \(snapshot.annotate ? l("enabled") : l("disabled"))</div>
    """)

    if let usage = snapshot.tokenUsage {
      let usageText = [
        String(format: NSLocalizedString("Requests: %d", comment: ""), usage.requests),
        String(format: NSLocalizedString("Input tokens: %d", comment: ""), usage.inputTokens),
        String(format: NSLocalizedString("Output tokens: %d", comment: ""), usage.outputTokens),
        String(format: NSLocalizedString("Cached tokens: %d", comment: ""), usage.cachedTokens),
        String(format: NSLocalizedString("Total tokens: %d", comment: ""), usage.totalTokens),
      ].joined(separator: "\n")
      parts.append("""
        <div class="card">
          <div class="meta">\(l("Token Usage"))</div>
          <pre>\(esc(usageText))</pre>
        </div>
      """)
    }

    if !snapshot.configText.isEmpty {
      parts.append("""
        <div class="card">
          <div class="meta">\(l("Config (api_key excluded)"))</div>
          <pre>\(esc(snapshot.configText))</pre>
        </div>
      """)
    }

    if !snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("""
        <div class="card">
          <div class="meta">\(l("Notes"))</div>
          <pre>\(esc(snapshot.notes))</pre>
        </div>
      """)
    }

    parts.append("<div class=\"card\"><div class=\"meta\">\(l("Messages"))</div></div>")

    for it in snapshot.items {
      let step = it.step
      let kindUpper = it.kind.uppercased()
      let kindLabel: String = {
        switch it.kind.lowercased() {
        case "request":
          return NSLocalizedString("Request", comment: "")
        case "response":
          return NSLocalizedString("Response", comment: "")
        default:
          return kindUpper
        }
      }()
      let attempt = it.attempt
      let ts = it.ts

      var hdrParts: [String] = []
      hdrParts.append(String(format: NSLocalizedString("Step %d · %@", comment: ""), step, kindLabel))
      if let attempt {
        hdrParts.append(String(format: NSLocalizedString("(attempt %d)", comment: ""), attempt))
      }

      parts.append("<div class=\"item\">")
      parts.append("<div class=\"hdr\"><div class=\"k\">\(esc(hdrParts.joined(separator: " ")))</div>")
      if !ts.isEmpty {
        parts.append("<div class=\"ts\">\(esc(ts))</div>")
      }
      parts.append("</div>")

      if it.kind == "request", attempt == nil, let b64 = snapshot.screenshotsBase64[step], !b64.isEmpty {
        let mime = snapshot.screenshotMimeType.isEmpty ? "image/png" : snapshot.screenshotMimeType
        parts.append("<div class=\"shot\">")
        parts.append("<img src=\"data:\(mime);base64,\(b64)\" alt=\"\(esc(String(format: NSLocalizedString("Step %d screenshot", comment: ""), step)))\" />")
        if snapshot.annotate,
           let ann = snapshot.annotationsByStep[step],
           let svg = svgOverlay(for: ann)
        {
          parts.append(svg)
          parts.append("<div class=\"badge\">\(esc(ann.name))</div>")
        }
        parts.append("</div>")
      }

      if !it.text.isEmpty {
        parts.append("<div class=\"sec\"><div class=\"label\">\(l("Text"))</div><pre>\(esc(it.text))</pre></div>")
      }
      if !it.content.isEmpty {
        parts.append("<div class=\"sec\"><div class=\"label\">\(l("Content"))</div><pre>\(esc(it.content))</pre></div>")
      }
      if !it.reasoning.isEmpty {
        parts.append("<div class=\"sec\"><div class=\"label\">\(l("Reasoning"))</div><pre>\(esc(it.reasoning))</pre></div>")
      }

      if !it.raw.isEmpty {
        parts.append("<details class=\"sec\"><summary>\(l("Raw JSON"))</summary><pre>\(esc(it.raw))</pre></details>")
      }

      parts.append("</div>")
    }

    parts.append("""
      </div>
    </body>
    </html>
    """)
    return parts.joined(separator: "\n")
  }
}

struct ChatView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var isSharing = false
  @State private var shareURL: URL?
  @State private var exportError: String?
  @State private var isExporting = false
  @State private var exportProgressText: String?

  private struct StepGroup: Identifiable {
    var step: Int
    var items: [AgentChatItem]

    var id: Int { step }

    var primaryRequest: AgentChatItem? {
      items.first { $0.kind == "request" && $0.attempt == nil }
    }

    var latestResponse: AgentChatItem? {
      // Items preserve chronological order. The last response per step is the one that was used to execute the action.
      items.last { $0.kind == "response" }
    }

    var attemptNumbers: [Int] {
      let attempts = Set(items.compactMap { $0.attempt })
      return attempts.sorted()
    }

    var timestamp: String? {
      // Prefer the latest item's timestamp.
      for it in items.reversed() {
        if let ts = it.ts, !ts.isEmpty { return ts }
      }
      return nil
    }
  }

  private struct ParsedRequestText {
    var previousFailure: String?
    var task: String?
    var planChecklist: String?
    var workingNotes: String?
    var screenInfoJSON: String?
    var other: String?
  }

  private static func prettyPrintedJSONIfPossible(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
      return text
    }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          JSONSerialization.isValidJSONObject(obj),
          let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let pretty = String(data: prettyData, encoding: .utf8)
    else {
      return text
    }
    return pretty
  }

  private static func parseRequestText(_ text: String) -> ParsedRequestText {
    var out = ParsedRequestText()
    let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    enum Section {
      case prefix
      case plan
      case notes
      case screen
    }

    var section: Section = .prefix
    var prefixLines: [String] = []
    var planLines: [String] = []
    var noteLines: [String] = []
    var screenLines: [String] = []

    for line in rawLines {
      let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if t == "** Plan Checklist **" {
        section = .plan
        continue
      }
      if t == "** Working Notes **" {
        section = .notes
        continue
      }
      if t == "** Screen Info **" {
        section = .screen
        continue
      }

      switch section {
      case .prefix:
        prefixLines.append(line)
      case .plan:
        planLines.append(line)
      case .notes:
        noteLines.append(line)
      case .screen:
        screenLines.append(line)
      }
    }

    func cleaned(_ lines: [String]) -> String? {
      let s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      return s.isEmpty ? nil : s
    }

    // The prefix can include a recoverable failure hint injected by Runner.
    if let firstNonEmpty = prefixLines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      let firstLine = prefixLines[firstNonEmpty].trimmingCharacters(in: .whitespacesAndNewlines)
      if firstLine.hasPrefix("上一步执行失败：") || firstLine.lowercased().hasPrefix("previous step failed") {
        var body: [String] = []
        var i = firstNonEmpty + 1
        while i < prefixLines.count {
          let l = prefixLines[i]
          if l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            break
          }
          body.append(l)
          i += 1
        }
        out.previousFailure = cleaned(body)

        // Remove the failure block from prefix.
        prefixLines.removeSubrange(firstNonEmpty..<min(i, prefixLines.count))
      }
    }

    // Step 0 doesn't include explicit markers; it's typically: <task>\n\n<screenInfoJSON>
    if screenLines.isEmpty {
      if let idx = prefixLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") }) {
        let taskLines = Array(prefixLines.prefix(upTo: idx))
        let screen = Array(prefixLines.suffix(from: idx))
        out.task = cleaned(taskLines)
        out.screenInfoJSON = cleaned(screen)
        out.other = nil
      } else {
        out.task = cleaned(prefixLines)
      }
    } else {
      out.screenInfoJSON = cleaned(screenLines)
      out.other = cleaned(prefixLines)
    }

    out.planChecklist = cleaned(planLines)
    out.workingNotes = cleaned(noteLines)
    return out
  }

  private var stepGroups: [StepGroup] {
    var order: [Int] = []
    var grouped: [Int: [AgentChatItem]] = [:]
    for it in store.chatItems {
      let s = it.step ?? -1
      if grouped[s] == nil {
        order.append(s)
        grouped[s] = []
      }
      grouped[s, default: []].append(it)
    }
    return order.map { StepGroup(step: $0, items: grouped[$0] ?? []) }
  }

  private struct StepCard: View {
    @EnvironmentObject private var store: ConsoleStore
    let group: StepGroup

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(String(format: NSLocalizedString("Step %d", comment: ""), group.step))
            .font(.headline)

          if let ann = store.stepActionAnnotations[group.step] {
            Text(ann.name)
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(.thinMaterial)
              .clipShape(Capsule())
          }

          Spacer()
          if let ts = group.timestamp {
            Text(ts).font(.caption).foregroundStyle(.secondary)
          }
        }

	        if let req = group.primaryRequest {
	          let parsed = ChatView.parseRequestText(req.text ?? "")
	          VStack(alignment: .leading, spacing: 10) {
	            Text("Input")
	              .font(.caption.weight(.semibold))
	              .foregroundStyle(.secondary)

	            ScreenshotBlock(step: group.step)

            if let msg = parsed.previousFailure, !msg.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Previous step failed")
                  .font(.caption)
                  .foregroundStyle(.orange)
                Text(msg)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }

            if let task = parsed.task, !task.isEmpty {
              LabeledCodeBlock(title: "Task", text: task, style: .body)
            }
            if let plan = parsed.planChecklist, !plan.isEmpty {
              LabeledCodeBlock(title: "Plan Checklist", text: plan, style: .monospaceFootnote)
            }
            if let notes = parsed.workingNotes, !notes.isEmpty {
              LabeledCodeBlock(title: "Working Notes", text: notes, style: .body)
            }
            if let other = parsed.other, !other.isEmpty {
              LabeledCodeBlock(title: "Text", text: other, style: .monospaceFootnote)
            }
            if let screen = parsed.screenInfoJSON, !screen.isEmpty {
              DisclosureGroup("Screen Info (JSON)") {
                Text(screen)
                  .font(.system(.footnote, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .padding(.top, 4)
              }
	              .font(.caption)
	              .foregroundStyle(.secondary)
	            }
	          }
	          .padding(12)
	          .background(Color.secondary.opacity(0.06))
	          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	        }

	        if let resp = group.latestResponse {
	          VStack(alignment: .leading, spacing: 10) {
	            Text("Output")
	              .font(.caption.weight(.semibold))
	              .foregroundStyle(.secondary)

            if let content = resp.content, !content.isEmpty {
              LabeledCodeBlock(title: "Content", text: ChatView.prettyPrintedJSONIfPossible(content), style: .monospaceFootnote)
            }

            if let reasoning = resp.reasoning, !reasoning.isEmpty {
              DisclosureGroup("Reasoning") {
                Text(reasoning)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .padding(.top, 4)
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            if let raw = resp.raw, !raw.isEmpty {
              DisclosureGroup("Raw JSON") {
                Text(raw)
                  .font(.system(.footnote, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .padding(.top, 4)
              }
              .font(.caption)
	              .foregroundStyle(.secondary)
	            }
	          }
	          .padding(12)
	          .background(Color.secondary.opacity(0.06))
	          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	        }

        let attempts = group.attemptNumbers
        if !attempts.isEmpty {
          DisclosureGroup(String(format: NSLocalizedString("Repair attempts (%d)", comment: ""), attempts.count)) {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(attempts, id: \.self) { attempt in
                AttemptBlock(step: group.step, attempt: attempt, items: group.items)
              }
            }
            .padding(.top, 6)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
	      }
	      .frame(maxWidth: .infinity, alignment: .leading)
	      .padding(12)
	      .background(Color.secondary.opacity(0.05))
	      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	      .overlay(
	        RoundedRectangle(cornerRadius: 12, style: .continuous)
	          .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
	      )
	      .padding(.vertical, 6)
	    }

	    private struct ScreenshotBlock: View {
	      @EnvironmentObject private var store: ConsoleStore
	      let step: Int
	      @State private var isViewing = false
	      @State private var presentedImage: PlatformImage?
	      @State private var presentedAnnotation: ActionAnnotation?

	      var body: some View {
	        Group {
	          if let img = store.stepScreenshots[step] {
	            Button {
	              presentedImage = img
	              presentedAnnotation = store.annotateStepScreenshots ? store.stepActionAnnotations[step] : nil
	              isViewing = true
	            } label: {
	              AnnotatedScreenshotCard(
	                image: img,
	                annotation: store.annotateStepScreenshots ? store.stepActionAnnotations[step] : nil
	              )
	            }
	            .buttonStyle(.plain)
	            .sheet(isPresented: $isViewing) {
	              if let presentedImage {
	                ScreenshotViewer(image: presentedImage, annotation: presentedAnnotation)
	              }
	            }
	          } else if let err = store.stepScreenshotErrors[step], !err.isEmpty {
	            HStack(alignment: .top, spacing: 10) {
	              Text(err)
                .font(.footnote)
                .foregroundStyle(.red)
              Spacer()
              Button("Retry") {
                Task { await store.ensureStepScreenshotLoaded(step: step) }
              }
            }
          } else {
            HStack(spacing: 10) {
              ProgressView()
              Text("Loading screenshot…")
                .font(.footnote)
                .foregroundStyle(.secondary)
              Spacer()
            }
            .task {
              await store.ensureStepScreenshotLoaded(step: step)
	          }
	        }
	      }
	    }

	    private struct ScreenshotViewer: View {
	      @Environment(\.dismiss) private var dismiss
	      let image: PlatformImage
	      let annotation: ActionAnnotation?

	      var body: some View {
	        NavigationStack {
	          ScrollView {
	            AnnotatedScreenshotCard(image: image, annotation: annotation)
	              .padding(16)
	          }
	          .navigationTitle(NSLocalizedString("Screenshot", comment: ""))
	          .toolbar {
	            ToolbarItem(placement: .primaryAction) {
	              Button("Done") { dismiss() }
	            }
	          }
	        }
	      }
	    }
    }

    private struct AttemptBlock: View {
      let step: Int
      let attempt: Int
      let items: [AgentChatItem]

      private var req: AgentChatItem? {
        items.first { $0.kind == "request" && $0.attempt == attempt }
      }

      private var resp: AgentChatItem? {
        items.last { $0.kind == "response" && $0.attempt == attempt }
      }

      var body: some View {
        VStack(alignment: .leading, spacing: 8) {
          Text(String(format: NSLocalizedString("(attempt %d)", comment: ""), attempt))
            .font(.headline)
            .foregroundStyle(.primary)

          if let text = req?.text, !text.isEmpty {
            LabeledCodeBlock(title: "Repair prompt", text: text, style: .monospaceFootnote)
          }
          if let content = resp?.content, !content.isEmpty {
            LabeledCodeBlock(title: "Repair output", text: ChatView.prettyPrintedJSONIfPossible(content), style: .monospaceFootnote)
          }
          if let reasoning = resp?.reasoning, !reasoning.isEmpty {
            DisclosureGroup("Reasoning") {
              Text(reasoning)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    }

    private enum CodeStyle {
      case body
      case monospaceFootnote
    }

	    private struct LabeledCodeBlock: View {
	      let title: LocalizedStringKey
	      let text: String
	      let style: CodeStyle

	      var body: some View {
	        VStack(alignment: .leading, spacing: 6) {
	          Text(title)
	            .font(.caption)
	            .foregroundStyle(.secondary)

	          Group {
	            if style == .monospaceFootnote {
	              ScrollView(.horizontal) {
	                Text(text)
	                  .font(font)
	                  .foregroundStyle(foreground)
	                  .textSelection(.enabled)
	                  .padding(10)
	              }
	              .frame(maxWidth: .infinity, alignment: .leading)
	            } else {
	              Text(text)
	                .font(font)
	                .foregroundStyle(foreground)
	                .textSelection(.enabled)
	                .padding(10)
	                .frame(maxWidth: .infinity, alignment: .leading)
	            }
	          }
	          .background(Color.secondary.opacity(0.06))
	          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
	        }
	      }

      private var font: Font {
        switch style {
        case .body:
          return .body
        case .monospaceFootnote:
          return .system(.footnote, design: .monospaced)
        }
      }

      private var foreground: Color {
        switch style {
        case .body:
          return .primary
        case .monospaceFootnote:
          return .secondary
        }
      }
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let err = exportError, !err.isEmpty {
          Text(err)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }

        if let err = store.chatError, !err.isEmpty {
          Text(String(format: NSLocalizedString("Chat stale: %@", comment: ""), err))
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }

        if isExporting {
          HStack(spacing: 10) {
            ProgressView()
            Text(exportProgressText ?? NSLocalizedString("Exporting…", comment: ""))
              .font(.footnote)
              .foregroundStyle(.secondary)
            Spacer()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
        }

        if !store.chatItems.isEmpty {
          Picker("View", selection: $store.chatMode) {
            ForEach(ConsoleStore.ChatMode.allCases) { m in
              Text(m.title).tag(m)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal, 16)
          .padding(.top, 6)
          .padding(.bottom, 10)
        }

        Group {
          if store.chatItems.isEmpty, (store.chatError ?? "").isEmpty, !isExporting, (exportError ?? "").isEmpty {
            ContentUnavailableView(
              NSLocalizedString("No conversation yet", comment: ""),
              systemImage: "text.bubble",
              description: Text(NSLocalizedString("Start a run to see steps here.", comment: ""))
            )
            .padding(.horizontal, 20)
          } else {
            if store.chatMode == .visual {
              ScrollViewReader { proxy in
                VStack(spacing: 0) {
                  LiveProgressPanel(
                    progress: store.liveProgress,
                    onJumpToStep: {
                      guard let step = store.liveProgress.step else { return }
                      withAnimation {
                        proxy.scrollTo(step, anchor: .top)
                      }
                    }
                  )
                  .padding(.horizontal, 16)

                  List(stepGroups) { group in
                    StepCard(group: group)
                      .id(group.step)
                      .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                      .listRowSeparator(.hidden)
                      .listRowBackground(Color.clear)
                  }
                  .listStyle(.plain)
                }
              }
            } else {
              List(store.chatItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                  HStack {
                    Text(String(format: NSLocalizedString("Step %d · %@", comment: ""), item.step ?? 0, item.kind))
                      .font(.headline)
                    if let attempt = item.attempt {
                      Text(String(format: NSLocalizedString("(attempt %d)", comment: ""), attempt))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let ts = item.ts {
                      Text(ts).font(.caption).foregroundStyle(.secondary)
                    }
                  }

                  Text(ConsoleRedaction.redactSensitiveText(item.raw ?? ""))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                }
                .padding(.vertical, 4)
              }
            }
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            if !store.chatItems.isEmpty {
              Menu {
                Button("Export readable text (.txt)") { exportChat(.messageText) }
                Button("Export raw JSONL (.jsonl)") { exportChat(.rawJSONL) }
                Button("Export HTML report (.html)") { exportChat(.htmlReport) }
              } label: {
                Text("Export")
              }
              .disabled(isExporting)
            }
          }
        }
        .navigationTitle("Chat")
      }
    }
    .sheet(isPresented: $isSharing) {
      if let url = shareURL {
        #if canImport(UIKit)
        OnDeviceAgentActivityView(activityItems: [url])
        #else
        VStack(alignment: .leading, spacing: 12) {
          Text("Export ready")
            .font(.headline)

          Text(url.path)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)

          ShareLink(item: url) {
            Text("Share")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)

          Button("Done") {
            isSharing = false
          }
          .frame(maxWidth: .infinity)
        }
        .padding()
        #endif
      }
    }
  }

    private enum ChatExportFormat {
      case messageText
      case rawJSONL
      case htmlReport
    }

    private func exportChat(_ format: ChatExportFormat) {
      if isExporting { return }
      exportError = nil
      exportProgressText = nil
      isExporting = true
      Task {
        defer {
          exportProgressText = nil
          isExporting = false
        }
        do {
          let ts = Int(Date().timeIntervalSince1970)
          let url: URL
          switch format {
          case .messageText:
            url = try OnDeviceAgentWriteTempText(exportChatMessageText(), filename: "agent_chat_\(ts).txt")
          case .rawJSONL:
            url = try OnDeviceAgentWriteTempText(exportChatRawJSONL(), filename: "agent_chat_\(ts).jsonl")
          case .htmlReport:
            exportProgressText = NSLocalizedString("Preparing screenshots…", comment: "")
            let batch = try await fetchStepScreenshotsForExport()
            exportProgressText = NSLocalizedString("Building HTML…", comment: "")
            let snapshot = buildChatHTMLSnapshot(
              screenshotMimeType: batch.mimeType,
              screenshotsBase64: batch.imagesBase64
            )
            let html = await Task.detached(priority: .userInitiated) {
              ChatExportHTML.build(snapshot: snapshot)
            }.value
            url = try OnDeviceAgentWriteTempText(html, filename: "agent_chat_\(ts).html")
          }
          shareURL = url
          isSharing = true
        } catch {
          exportError = error.localizedDescription
        }
      }
    }

    private func exportChatMessageText() -> String {
      var out: [String] = []
      let reasoningLabel = NSLocalizedString("Reasoning", comment: "")
      for item in store.chatItems {
        out.append(exportHeader(for: item))
        if let text = item.text, !text.isEmpty { out.append(text) }
        if let content = item.content, !content.isEmpty { out.append(Self.prettyPrintedJSONIfPossible(content)) }
        if let reasoning = item.reasoning, !reasoning.isEmpty {
          out.append("\n--- \(reasoningLabel) ---\n")
          out.append(reasoning)
        }
        out.append("\n")
      }
      return out.joined(separator: "\n")
    }

  private func exportChatRawJSONL() -> String {
    var lines: [String] = []
    for item in store.chatItems {
      var obj: [String: Any] = ["kind": item.kind]
      if let ts = item.ts, !ts.isEmpty { obj["ts"] = ts }
      if let step = item.step { obj["step"] = step }
      if let attempt = item.attempt { obj["attempt"] = attempt }
      if let raw = item.raw, !raw.isEmpty { obj["raw"] = ConsoleRedaction.redactSensitiveText(raw) }
      if let text = item.text, !text.isEmpty { obj["text"] = text }
      if let content = item.content, !content.isEmpty { obj["content"] = content }
      if let reasoning = item.reasoning, !reasoning.isEmpty { obj["reasoning"] = reasoning }

      if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
         let s = String(data: data, encoding: .utf8)
      {
        lines.append(s)
      }
    }
    return lines.joined(separator: "\n")
  }

  private func exportHeader(for item: AgentChatItem) -> String {
    var parts: [String] = []
    if let ts = item.ts, !ts.isEmpty {
      parts.append(ts)
    }
    parts.append(
      String(
        format: NSLocalizedString("Step %d %@", comment: ""),
        item.step ?? 0,
        item.kind.uppercased()
      )
    )
    if let attempt = item.attempt {
      parts.append(String(format: NSLocalizedString("(attempt %d)", comment: ""), attempt))
    }
      return parts.joined(separator: " ")
    }

    private func fetchStepScreenshotsForExport() async throws -> ConsoleStore.StepScreenshotsBatch {
      let maxN = ConsoleStore.Defaults.exportScreenshotLimit
      let stepsAll: [Int] = {
        var s: Set<Int> = []
        for it in store.chatItems {
          if it.kind == "request", it.attempt == nil, let step = it.step {
            s.insert(step)
          }
        }
        return s.sorted()
      }()

      if stepsAll.isEmpty {
        return ConsoleStore.StepScreenshotsBatch(
          mimeType: "image/png",
          format: "png",
          imagesBase64: [:],
          missingSteps: []
        )
      }

      let steps = Array(stepsAll.suffix(maxN))
      return try await store.fetchStepScreenshotsBase64(steps: steps)
    }

    private func buildChatHTMLSnapshot(
      screenshotMimeType: String,
      screenshotsBase64: [Int: String]
    ) -> ChatExportHTMLSnapshot {
      let exportedAt = ISO8601DateFormatter().string(from: Date())
      let runnerURL = store.wdaURL.trimmingCharacters(in: .whitespacesAndNewlines)
      let annotate = store.annotateStepScreenshots

      let cfgText: String = {
        guard let c = store.status?.config else { return "" }
        var lines: [String] = []
        if !c.baseUrl.isEmpty { lines.append("base_url: \(c.baseUrl)") }
        if !c.model.isEmpty { lines.append("model: \(c.model)") }
        if !c.apiMode.isEmpty { lines.append("api_mode: \(c.apiMode)") }
        if c.maxSteps > 0 { lines.append("max_steps: \(c.maxSteps)") }
        if c.maxCompletionTokens > 0 { lines.append("max_completion_tokens: \(c.maxCompletionTokens)") }
        if c.timeoutSeconds > 0 { lines.append("timeout_seconds: \(c.timeoutSeconds)") }
        if c.stepDelaySeconds > 0 { lines.append("step_delay_seconds: \(c.stepDelaySeconds)") }
        if !c.reasoningEffort.isEmpty { lines.append("reasoning_effort: \(c.reasoningEffort)") }
        lines.append("half_res_screenshot: \(c.halfResScreenshot ? "true" : "false")")
        lines.append("use_w3c_actions_for_swipe: \(c.useW3CActionsForSwipe ? "true" : "false")")
        lines.append("debug_log_raw_assistant: \(c.debugLogRawAssistant ? "true" : "false")")
        lines.append("doubao_seed_enable_session_cache: \(c.doubaoSeedEnableSessionCache ? "true" : "false")")
        lines.append("insecure_skip_tls_verify: \(c.insecureSkipTlsVerify ? "true" : "false")")
        lines.append("use_custom_system_prompt: \(c.useCustomSystemPrompt ? "true" : "false")")
        if !c.systemPrompt.isEmpty { lines.append("system_prompt: (set)") }
        return lines.joined(separator: "\n")
      }()

      let tokenUsage: ChatExportTokenUsage? = {
        guard let u = store.status?.tokenUsage else { return nil }
        if u.requests == 0, u.totalTokens == 0 { return nil }
        return ChatExportTokenUsage(
          requests: u.requests,
          inputTokens: u.inputTokens,
          outputTokens: u.outputTokens,
          cachedTokens: u.cachedTokens,
          totalTokens: u.totalTokens
        )
      }()

      let notes = store.status?.notes ?? ""

      let items: [ChatExportItem] = store.chatItems.map { it in
        ChatExportItem(
          kind: it.kind,
          ts: it.ts ?? "",
          step: it.step ?? 0,
          attempt: it.attempt,
          raw: ConsoleRedaction.redactSensitiveText(it.raw ?? ""),
          text: it.text ?? "",
          content: it.content ?? "",
          reasoning: it.reasoning ?? ""
        )
      }

      var annotationsByStep: [Int: ChatExportActionAnnotation] = [:]
      if annotate {
        for (step, ann) in store.stepActionAnnotations {
          switch ann.kind {
          case .tap(let p):
            annotationsByStep[step] = ChatExportActionAnnotation(
              name: ann.name,
              kind: .tap,
              x1: p.x,
              y1: p.y,
              x2: 0,
              y2: 0
            )
          case .swipe(let s, let e):
            annotationsByStep[step] = ChatExportActionAnnotation(
              name: ann.name,
              kind: .swipe,
              x1: s.x,
              y1: s.y,
              x2: e.x,
              y2: e.y
            )
          case .label:
            annotationsByStep[step] = ChatExportActionAnnotation(
              name: ann.name,
              kind: .label,
              x1: 0,
              y1: 0,
              x2: 0,
              y2: 0
            )
          }
        }
      }

      return ChatExportHTMLSnapshot(
        exportedAt: exportedAt,
        runnerURL: runnerURL,
        annotate: annotate,
        tokenUsage: tokenUsage,
        configText: cfgText,
        notes: notes,
        items: items,
        screenshotMimeType: screenshotMimeType,
        screenshotsBase64: screenshotsBase64,
        annotationsByStep: annotationsByStep
      )
    }

}
