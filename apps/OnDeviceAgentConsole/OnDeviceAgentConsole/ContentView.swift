import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private func OnDeviceAgentDismissKeyboard() {
  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct ContentView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var selectedTab: Tab = .run

  enum Tab: String {
    case run
    case logs
    case chat
    case notes
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      RunView()
        .tabItem { Label("Run", systemImage: "slider.horizontal.3") }
        .tag(Tab.run)

      LogsView()
        .tabItem { Label("Logs", systemImage: "doc.plaintext") }
        .tag(Tab.logs)

      ChatView()
        .tabItem { Label("Chat", systemImage: "text.bubble") }
        .tag(Tab.chat)

      NotesView()
        .tabItem { Label("Notes", systemImage: "note.text") }
        .tag(Tab.notes)
    }
  }
}

private struct RunView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var isEditingTask = false
  @State private var isEditingSystemPrompt = false
  @State private var isImportingConfig = false
  @State private var isExportingConfig = false
  @State private var isQuickStartExpanded = true
  @State private var isModelExpanded = false
  @State private var isLimitsExpanded = false
  @State private var isPromptExpanded = false
  @State private var isAdvancedExpanded = false
  @State private var isRunnerExpanded = false
  @State private var isDangerExpanded = false

  private var isRunning: Bool { store.status?.running ?? false }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          DisclosureGroup(
            isExpanded: $isQuickStartExpanded,
            content: {
              let showLANHint = (store.localNetworkAccess?.loopbackOK == true) && (store.localNetworkAccess?.lanOK == false)
              let usage = store.status?.tokenUsage
              let showUsage = (usage?.requests ?? 0) > 0 || (usage?.totalTokens ?? 0) > 0
              let lastMessage = store.status?.lastMessage ?? ""
              let connectionErr = store.connectionError ?? ""
              let actionErr = store.lastActionError ?? ""
              let showStatusPanel = showLANHint || showUsage || !lastMessage.isEmpty || !connectionErr.isEmpty || !actionErr.isEmpty

              if showStatusPanel {
                VStack(alignment: .leading, spacing: 10) {
                  if showLANHint, let net = store.localNetworkAccess {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("Wi‑Fi unreachable")
                        .font(.headline)
                        .foregroundStyle(.orange)

                      Text(
                        String(
                          format: NSLocalizedString(
                            "Runner is reachable on 127.0.0.1 but not on Wi‑Fi (%@). If Wi‑Fi access fails: Settings → Apps → Runner → Wireless Data → choose WLAN/WLAN & Cellular Data, then reopen Runner.",
                            comment: ""
                          ),
                          net.wifiIPv4
                        )
                      )
                      .font(.footnote)
                      .foregroundStyle(.secondary)

                      Button("Check again") {
                        Task { await store.checkLocalNetworkAccess(force: true) }
                      }
                      .font(.footnote)
                    }
                    .padding(.vertical, 2)
                  }

                  if showUsage, let usage {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("Token Usage")
                        .font(.headline)

                      VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: NSLocalizedString("Requests: %d", comment: ""), usage.requests))
                        Text(
                          String(
                            format: NSLocalizedString("Input: %d  Output: %d", comment: ""),
                            usage.inputTokens,
                            usage.outputTokens
                          )
                        )
                        Text(
                          String(
                            format: NSLocalizedString("Cached: %d  Total: %d", comment: ""),
                            usage.cachedTokens,
                            usage.totalTokens
                          )
                        )
                      }
                      .font(.system(.footnote, design: .monospaced))
                      .foregroundStyle(.secondary)
                      .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                  }

                  if !lastMessage.isEmpty {
                    Text(lastMessage)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
                  }
                  if !connectionErr.isEmpty {
                    Text(String(format: NSLocalizedString("Connection error: %@", comment: ""), connectionErr))
                      .font(.footnote)
                      .foregroundStyle(.red)
                  }
                  if !actionErr.isEmpty {
                    Text(String(format: NSLocalizedString("Execution error: %@", comment: ""), actionErr))
                      .font(.footnote)
                      .foregroundStyle(.red)
                  }
                }
              }
              HStack {
                Text("Task")
                  .font(.headline)
                Spacer()
                Button("Edit") { isEditingTask = true }
                  .font(.footnote)
              }

              if store.draft.task.isEmpty {
                Text("Enter a task…")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              } else {
                Text(store.draft.task)
                  .font(.footnote)
                  .lineLimit(6)
              }

              let errors = store.validationErrors()
              if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(errors, id: \.self) { e in
                    Text(e).foregroundStyle(.red)
                  }
                }
              }

              Button("Start run") {
                Task { await store.startAgent() }
              }
              .disabled(!store.validationErrors().isEmpty)

              Button("Stop run", role: .destructive) {
                Task { await store.stopAgent() }
              }
              .disabled(!isRunning)

              Text(
                "Tip: If Runner was just installed or updated, iOS may reset Runner’s Wireless Data permission to Off.\nIf Wi‑Fi access fails: Settings → Apps → Runner → Wireless Data → choose WLAN/WLAN & Cellular Data, then reopen Runner."
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            },
            label: {
              HStack(spacing: 10) {
                Text("Run")
                  .font(.headline)
                Spacer()
                Text(isRunning ? "Running" : "Not running")
                  .foregroundStyle(isRunning ? .green : .secondary)
              }
            }
          )
        }

        Section {
          DisclosureGroup("System Prompt", isExpanded: $isPromptExpanded) {
            Toggle("Use custom system prompt", isOn: $store.draft.useCustomSystemPrompt)

            Text("Custom system prompt only takes effect when the checkbox is enabled. Date placeholders (replaced at runtime):")
              .font(.footnote)
              .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
              Text("{{DATE_ZH}} → \(ConsoleStore.datePlaceholderZH())")
              Text("{{DATE_EN}} → \(ConsoleStore.datePlaceholderEN())")
            }
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            Button("Edit System Prompt") {
              Task {
                await store.refresh()
                isEditingSystemPrompt = true
              }
            }
            if !store.draft.systemPrompt.isEmpty {
              Text(store.draft.systemPrompt)
                .font(.footnote)
                .lineLimit(6)
            }
          }
        }

        Section {
          DisclosureGroup("Model service", isExpanded: $isModelExpanded) {
            ConfigField(
              title: "Service URL (Base URL, OpenAI-compatible)",
              help: "Required. Examples:\nDoubao: https://ark.cn-beijing.volces.com/api/v3/responses\nOpenAI: https://api.openai.com/v1",
              placeholder: "https://…",
              text: $store.draft.baseUrl,
              keyboard: .URL
            )

            ConfigField(
              title: "Model",
              help: "Required. Example: doubao-seed-1-8-251228",
              placeholder: "doubao-seed-…",
              text: $store.draft.model,
              keyboard: .default
            )

            ConfigPicker(
              title: "API Mode",
              help: (store.draft.apiMode == ConsoleStore.Defaults.apiMode)
                ? "Doubao Seed: use Responses. Most OpenAI-compatible services: try Responses first; if unsupported, switch to Chat Completions."
                : "Use Chat Completions when Responses is unsupported. More compatible, but usually uses more tokens.",
              selection: $store.draft.apiMode,
              options: [
                ("Responses", ConsoleStore.Defaults.apiMode),
                ("Chat Completions", "chat_completions"),
              ]
            )

            VStack(alignment: .leading, spacing: 6) {
              Text("API Key")
                .font(.headline)

              if store.draft.showApiKey {
                TextField(store.status?.config.apiKeySet == true ? "(set on device)" : "sk-...", text: $store.draft.apiKey)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .font(.system(.body, design: .monospaced))
              } else {
                SecureField(store.status?.config.apiKeySet == true ? "(set on device)" : "sk-...", text: $store.draft.apiKey)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .font(.system(.body, design: .monospaced))
              }

              Text("Optional if already set on device. Leave empty to keep the existing key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            Toggle("Show API key", isOn: $store.draft.showApiKey)
            Toggle("Remember API key on device", isOn: $store.draft.rememberApiKey)
          }
        }

        Section {
          DisclosureGroup("Limits & stability", isExpanded: $isLimitsExpanded) {
            LimitField(
              title: "Max Steps",
              help: "Hard stop after this many actions. Prevents runaway loops.",
              placeholder: "",
              text: $store.draft.maxSteps,
              keyboard: .numberPad
            )

            LimitField(
              title: "Timeout (seconds)",
              help: "Per-step model request timeout. Increase if the model is slow.",
              placeholder: "",
              text: $store.draft.timeoutSeconds,
              keyboard: .decimalPad
            )

            LimitField(
              title: "Step Delay (seconds)",
              help: "Sleep between executed actions. Increase to reduce flakiness.",
              placeholder: "",
              text: $store.draft.stepDelaySeconds,
              keyboard: .decimalPad
            )

            let tokensTitle: LocalizedStringKey = "Per-step max output (Token)"
            let tokensHelp: LocalizedStringKey =
              (store.draft.apiMode == ConsoleStore.Defaults.apiMode)
              ? "Per-step output cap (Responses: max_output_tokens). Does not limit screenshot/input Token."
              : "Per-step output cap (Chat Completions: max_completion_tokens). Does not limit screenshot/input Token."
            LimitField(
              title: tokensTitle,
              help: tokensHelp,
              placeholder: "",
              text: $store.draft.maxCompletionTokens,
              keyboard: .numberPad
            )

            LimitField(
              title: "Reasoning effort (optional)",
              help: "Optional. Only some models support this (e.g. doubao-seed). Leave empty to use the model default. Examples: minimal / low / medium / high.",
              placeholder: "e.g. medium",
              text: $store.draft.reasoningEffort,
              keyboard: .default
            )
          }
        }

        Section {
          DisclosureGroup("Advanced (optional)", isExpanded: $isAdvancedExpanded) {
            if store.isDoubaoSeedResponsesMode() {
              Toggle("Enable Session Cache (Doubao Seed)", isOn: $store.draft.doubaoSeedEnableSessionCache)
              Text("Responses only. Enables session caching for doubao-seed models to reduce tokens and improve stability.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Toggle("Half-resolution screenshots", isOn: $store.draft.halfResScreenshot)
            Text("Shrinks screenshots by 50% before sending to the model, reducing Token usage and often speeding up responses.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Toggle("Use W3C actions for swipe", isOn: $store.draft.useW3CActionsForSwipe)
            Text("Recommended for games: makes swipe closer to a real finger gesture.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Toggle("Annotate screenshots with actions", isOn: $store.annotateStepScreenshots)
            Text("Overlays click/swipe markers on per-step screenshots in Chat.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Toggle("Debug raw conversation", isOn: $store.draft.debugLogRawAssistant)
            Text("Stores per-step API request/response JSON (images are placeholders). May contain sensitive info.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Toggle("Insecure: skip TLS verify (model)", isOn: $store.draft.insecureSkipTLSVerify)
            Text("Allows HTTPS endpoints with invalid certificates. Debug only.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Button("Import Config (QR)") {
              isImportingConfig = true
            }
            Text("Scans a QR code and shows a review step before applying changes.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Button("Export Config (QR)") {
              isExportingConfig = true
            }
            .disabled(!store.validationErrors().isEmpty)
            Text("Exports the current config as a QR code image for sharing or backup.")
              .font(.footnote)
              .foregroundStyle(.secondary)

            Button("Save Config") {
              Task { await store.saveConfig() }
            }
            .disabled(!store.validationErrors().isEmpty)
            Text("Saves the current config to Runner (persistent on device).")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          DisclosureGroup("Runner (WebDriverAgentRunner-Runner)", isExpanded: $isRunnerExpanded) {
            ConfigField(
              title: "Runner address",
              help: "The address used to connect to Runner (port 8100). On iPhone, use http://127.0.0.1:8100.",
              placeholder: ConsoleStore.Defaults.wdaURL,
              text: $store.wdaURL,
              keyboard: .URL
            )

            Button("Check status") {
              Task { await store.refresh() }
            }
          }
        }

        Section {
          DisclosureGroup("Reset", isExpanded: $isDangerExpanded) {
            Text(
              "Reset clears local runtime data (logs/chat/screenshots/Notes/token usage); Factory Reset also clears saved settings and the remembered API key; neither affects your model service."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
              VStack(alignment: .leading, spacing: 6) {
                Text("Reset Runtime")
                  .font(.headline)

                Text("Stops the agent and clears logs/chat/screenshots/notes/token usage. Keeps saved config.")
                  .font(.footnote)
                  .foregroundStyle(.secondary)

                Button("Reset Runtime", role: .destructive) {
                  Task { await store.resetRuntime() }
                }
              }

              Divider()

              VStack(alignment: .leading, spacing: 6) {
                Text("Factory Reset")
                  .font(.headline)

                Text("Stops the agent, clears runtime, and restores Runner config to defaults (forgets API key, custom prompt, and other saved settings).")
                  .font(.footnote)
                  .foregroundStyle(.secondary)

                Button("Factory Reset", role: .destructive) {
                  Task { await store.factoryReset() }
                }
              }
            }
            .padding(.vertical, 2)
          }
        }
      }
      .navigationTitle("On‑Device Agent")
      .scrollDismissesKeyboard(.interactively)
      .task {
        await store.checkLocalNetworkAccess(force: true)
      }
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") {
            OnDeviceAgentDismissKeyboard()
          }
        }
      }
      .sheet(isPresented: $isEditingTask) {
        TextEditorSheet(title: "Task", text: $store.draft.task)
          .onAppear { store.suspendAutoRefresh() }
          .onDisappear { store.resumeAutoRefresh() }
      }
      .sheet(isPresented: $isEditingSystemPrompt) {
        SystemPromptEditorSheet(
          title: "System Prompt",
          systemPrompt: $store.draft.systemPrompt,
          defaultTemplate: store.status?.config.defaultSystemPrompt ?? ""
        )
        .onAppear { store.suspendAutoRefresh() }
        .onDisappear { store.resumeAutoRefresh() }
      }
      .sheet(isPresented: $isImportingConfig) {
        QRCodeImportSheet(isPresented: $isImportingConfig) { raw in
          do {
            try store.importConfigFromQRCode(raw)
            return nil
          } catch {
            return error.localizedDescription
          }
        }
        .onAppear { store.suspendAutoRefresh() }
        .onDisappear { store.resumeAutoRefresh() }
      }
      .sheet(isPresented: $isExportingConfig) {
        QRCodeExportSheet(isPresented: $isExportingConfig)
          .onAppear { store.suspendAutoRefresh() }
          .onDisappear { store.resumeAutoRefresh() }
      }
    }
  }
}

private struct LimitField: View {
  let title: LocalizedStringKey
  let help: LocalizedStringKey
  let placeholder: LocalizedStringKey
  @Binding var text: String
  let keyboard: UIKeyboardType

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      TextField(placeholder, text: $text)
        .keyboardType(keyboard)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .multilineTextAlignment(.trailing)
        .font(.system(.body, design: .monospaced))

      Text(help)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

private struct ConfigField: View {
  let title: LocalizedStringKey
  let help: String
  let placeholder: String
  @Binding var text: String
  let keyboard: UIKeyboardType

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      TextField(placeholder, text: $text)
        .keyboardType(keyboard)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(.body, design: .monospaced))

      Text(verbatim: NSLocalizedString(help, comment: ""))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

private struct ConfigPicker: View {
  typealias Option = (title: LocalizedStringKey, value: String)

  let title: LocalizedStringKey
  let help: String?
  @Binding var selection: String
  let options: [Option]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      Picker("", selection: $selection) {
        ForEach(options, id: \.value) { opt in
          Text(opt.title).tag(opt.value)
        }
      }
      .pickerStyle(.segmented)

      if let help {
        Text(verbatim: NSLocalizedString(help, comment: ""))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct LogsView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      Group {
        if store.logs.isEmpty, (store.logsError ?? "").isEmpty {
          ContentUnavailableView(
            NSLocalizedString("No logs yet", comment: ""),
            systemImage: "doc.plaintext",
            description: Text(NSLocalizedString("Logs will appear while the agent runs.", comment: ""))
          )
          .padding(.horizontal, 20)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if let err = store.logsError, !err.isEmpty {
                Text(String(format: NSLocalizedString("Logs stale: %@", comment: ""), err))
                  .font(.footnote)
                  .foregroundStyle(.red)
              }

              Text(store.logs.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
          }
        }
      }
      .navigationTitle("Logs")
    }
  }
}

// MARK: - Chat export (HTML)

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
  var screenshotsPNG: [Int: Data]
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
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>On-device agent chat export</title>
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
        <h1>Chat export</h1>
        <div class="meta">Exported at <span class="mono">\(esc(snapshot.exportedAt))</span></div>
        <div class="meta">Runner URL <span class="mono">\(esc(snapshot.runnerURL.isEmpty ? "(empty)" : snapshot.runnerURL))</span></div>
        <div class="meta">Screenshot annotations \(snapshot.annotate ? "enabled" : "disabled")</div>
    """)

    if let usage = snapshot.tokenUsage {
      parts.append("""
        <div class="card">
          <div class="meta">Token usage</div>
          <pre>\(esc("requests: \(usage.requests)\ninput_tokens: \(usage.inputTokens)\noutput_tokens: \(usage.outputTokens)\ncached_tokens: \(usage.cachedTokens)\ntotal_tokens: \(usage.totalTokens)"))</pre>
        </div>
      """)
    }

    if !snapshot.configText.isEmpty {
      parts.append("""
        <div class="card">
          <div class="meta">Config (api_key excluded)</div>
          <pre>\(esc(snapshot.configText))</pre>
        </div>
      """)
    }

    if !snapshot.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("""
        <div class="card">
          <div class="meta">Notes</div>
          <pre>\(esc(snapshot.notes))</pre>
        </div>
      """)
    }

    parts.append("<div class=\"card\"><div class=\"meta\">Messages</div></div>")

    for it in snapshot.items {
      let step = it.step
      let kind = it.kind.uppercased()
      let attempt = it.attempt
      let ts = it.ts

      var hdrParts: [String] = []
      hdrParts.append("Step \(step) · \(kind)")
      if let attempt { hdrParts.append("(attempt \(attempt))") }

      parts.append("<div class=\"item\">")
      parts.append("<div class=\"hdr\"><div class=\"k\">\(esc(hdrParts.joined(separator: " ")))</div>")
      if !ts.isEmpty {
        parts.append("<div class=\"ts\">\(esc(ts))</div>")
      }
      parts.append("</div>")

      if it.kind == "request", attempt == nil, let png = snapshot.screenshotsPNG[step] {
        let b64 = png.base64EncodedString()
        parts.append("<div class=\"shot\">")
        parts.append("<img src=\"data:image/png;base64,\(b64)\" alt=\"step \(step) screenshot\" />")
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
        parts.append("<div class=\"sec\"><div class=\"label\">text</div><pre>\(esc(it.text))</pre></div>")
      }
      if !it.content.isEmpty {
        parts.append("<div class=\"sec\"><div class=\"label\">content</div><pre>\(esc(it.content))</pre></div>")
      }
      if !it.reasoning.isEmpty {
        parts.append("<div class=\"sec\"><div class=\"label\">reasoning</div><pre>\(esc(it.reasoning))</pre></div>")
      }

      if !it.raw.isEmpty {
        parts.append("<details class=\"sec\"><summary>Raw</summary><pre>\(esc(it.raw))</pre></details>")
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

private struct ChatView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var isSharing = false
  @State private var shareURL: URL?
  @State private var exportError: String?
  @State private var isExporting = false
  @State private var exportProgressText: String?

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
            List(store.chatItems) { item in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(String(format: NSLocalizedString("Step %d · %@", comment: ""), item.step ?? 0, item.kind))
                    .font(.headline)
                  if let attempt = item.attempt {
                    Text("(\(attempt))").foregroundStyle(.secondary)
                  }
                  Spacer()
                  if let ts = item.ts {
                    Text(ts).font(.caption).foregroundStyle(.secondary)
                  }
                }

                if store.chatMode == .rawJSON {
                  Text(item.raw ?? "")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                } else {
                  if item.kind == "request", item.attempt == nil, let step = item.step {
                    if let img = store.stepScreenshots[step] {
                      AnnotatedScreenshotCard(
                        image: img,
                        annotation: store.annotateStepScreenshots ? store.stepActionAnnotations[step] : nil
                      )
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
                  if let text = item.text, !text.isEmpty {
                    Text(text)
                      .font(.system(.footnote, design: .monospaced))
                      .textSelection(.enabled)
                  }
                  if let content = item.content, !content.isEmpty {
                    Text(content)
                      .font(.system(.footnote, design: .monospaced))
                      .textSelection(.enabled)
                  }
                  if let reasoning = item.reasoning, !reasoning.isEmpty {
                    Divider()
                    Text(reasoning)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
                      .textSelection(.enabled)
                  }
                }
              }
              .padding(.vertical, 4)
            }
          }
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
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
	      }
	      .navigationTitle("Chat")
    }
    .sheet(isPresented: $isSharing) {
      if let url = shareURL {
        OnDeviceAgentActivityView(activityItems: [url])
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
            await prefetchStepScreenshotsForExport()
            exportProgressText = NSLocalizedString("Building HTML…", comment: "")
            let snapshot = buildChatHTMLSnapshot()
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
    for item in store.chatItems {
      out.append(exportHeader(for: item))
      if let text = item.text, !text.isEmpty { out.append(text) }
      if let content = item.content, !content.isEmpty { out.append(content) }
      if let reasoning = item.reasoning, !reasoning.isEmpty {
        out.append("\n--- reasoning ---\n")
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
      if let raw = item.raw, !raw.isEmpty { obj["raw"] = raw }
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

    private func prefetchStepScreenshotsForExport() async {
      let steps: [Int] = {
        var s: Set<Int> = []
        for it in store.chatItems {
          if it.kind == "request", it.attempt == nil, let step = it.step {
            s.insert(step)
          }
        }
        return s.sorted()
      }()

      let total = steps.count
      if total == 0 {
        return
      }
      var loaded = 0
      for step in steps {
        exportProgressText = String(
          format: NSLocalizedString("Preparing screenshots… %d/%d", comment: ""),
          loaded,
          total
        )
        await store.ensureStepScreenshotLoaded(step: step)
        loaded += 1
      }
      exportProgressText = String(
        format: NSLocalizedString("Preparing screenshots… %d/%d", comment: ""),
        total,
        total
      )
    }

    private func buildChatHTMLSnapshot() -> ChatExportHTMLSnapshot {
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
          raw: it.raw ?? "",
          text: it.text ?? "",
          content: it.content ?? "",
          reasoning: it.reasoning ?? ""
        )
      }

      let stepsNeedingScreenshots: Set<Int> = Set(
        store.chatItems.compactMap { it in
          if it.kind == "request", it.attempt == nil, let step = it.step { return step }
          return nil
        }
      )
      var screenshotsPNG: [Int: Data] = [:]
      for step in stepsNeedingScreenshots {
        if let img = store.stepScreenshots[step], let data = img.pngData() {
          screenshotsPNG[step] = data
        }
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
        screenshotsPNG: screenshotsPNG,
        annotationsByStep: annotationsByStep
      )
    }
}

private struct NotesView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      let notes = store.status?.notes ?? ""
      Group {
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView(
            NSLocalizedString("No notes yet", comment: ""),
            systemImage: "note.text",
            description: Text(NSLocalizedString("The agent writes here via the Note action.", comment: ""))
          )
          .padding(.horizontal, 20)
        } else {
          ScrollView {
            Text(notes)
              .font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
          }
        }
      }
      .navigationTitle("Notes")
    }
  }
}

private struct TextEditorSheet: View {
  let title: LocalizedStringKey
  @Binding var text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 8)
        .navigationTitle(title)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}

private struct SystemPromptEditorSheet: View {
  let title: LocalizedStringKey
  @Binding var systemPrompt: String
  let defaultTemplate: String
  @Environment(\.dismiss) private var dismiss

  @State private var draft: String = ""

  var body: some View {
    NavigationStack {
      TextEditor(text: $draft)
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 8)
        .navigationTitle(title)
        .onAppear {
          if draft.isEmpty {
            draft = systemPrompt.isEmpty ? defaultTemplate : systemPrompt
          }
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Restore Default Template") {
              draft = defaultTemplate
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              // If the user never had a custom prompt and didn't change the default template,
              // keep systemPrompt empty to avoid persisting the built-in template as "custom".
              if draft == defaultTemplate {
                systemPrompt = ""
              } else {
                systemPrompt = draft
              }
              dismiss()
            }
          }
        }
    }
  }
}

// MARK: - QR Import

private struct QRCodeImportSheet: View {
  @Binding var isPresented: Bool
  let onScan: (String) -> String?

  @State private var errorText: String?
  @State private var scannerID = UUID()
  @State private var photoPickerItem: PhotosPickerItem?
  @State private var isImportingImageFile = false

  @State private var mode: Mode = .scan
  @State private var draftText: String = ""
  @State private var draftErrors: [String] = []

  private enum Mode {
    case scan
    case review
  }

  private func handleScannedPayload(_ s: String) {
    errorText = nil
    draftText = s
    draftErrors = ConsoleStore.validateQRCodeConfigRaw(s)
    mode = .review
  }

  private func applyDraft() {
    if let err = onScan(draftText), !err.isEmpty {
      errorText = err
      return
    }
    isPresented = false
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        if mode == .scan {
          Text("Scan a QR code containing a JSON config object. You will review and confirm before applying.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

          QRCodeScannerView { result in
            switch result {
            case .success(let s):
              handleScannedPayload(s)
            case .failure(let e):
              errorText = e.localizedDescription
            }
          }
          .id(scannerID)
          .frame(height: 340)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .padding(.horizontal, 16)

          HStack(spacing: 12) {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
              Label("Import Image", systemImage: "photo")
            }
            .buttonStyle(.bordered)

            Button {
              isImportingImageFile = true
            } label: {
              Label("Import File", systemImage: "folder")
            }
            .buttonStyle(.bordered)
          }
          .padding(.horizontal, 16)

          if let err = errorText, !err.isEmpty {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 16)

            Button("Scan Again") {
              errorText = nil
              scannerID = UUID()
            }
          }
        } else {
          VStack(alignment: .leading, spacing: 10) {
            Text("Review & edit")
              .font(.headline)
              .frame(maxWidth: .infinity, alignment: .leading)

            TextEditor(text: $draftText)
              .font(.system(.body, design: .monospaced))
              .frame(minHeight: 260)
              .overlay(
                RoundedRectangle(cornerRadius: 12)
                  .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
              )

            if !draftErrors.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text("Validation errors")
                  .font(.headline)
                  .foregroundStyle(.red)
                ForEach(draftErrors, id: \.self) { e in
                  Text("• \(e)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let err = errorText, !err.isEmpty {
              Text(err)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
              Button("Back to Scan") {
                errorText = nil
                mode = .scan
                scannerID = UUID()
              }
              .buttonStyle(.bordered)

              Spacer()

              Button("Apply") { applyDraft() }
                .buttonStyle(.borderedProminent)
                .disabled(!draftErrors.isEmpty)
            }
          }
          .padding(.horizontal, 16)
          .onChange(of: draftText) { t in
            errorText = nil
            draftErrors = ConsoleStore.validateQRCodeConfigRaw(t)
          }
        }
      }
      .navigationTitle("Import Config (QR)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isPresented = false }
        }
      }
    }
    .onChange(of: photoPickerItem) { item in
      guard let item else { return }
      Task {
        do {
	          guard let data = try await item.loadTransferable(type: Data.self) else {
	            errorText = NSLocalizedString("Cannot load image", comment: "")
	            return
	          }
          await importImageData(data)
        } catch {
          errorText = error.localizedDescription
        }
      }
    }
    .fileImporter(isPresented: $isImportingImageFile, allowedContentTypes: [.image]) { result in
      switch result {
      case .success(let url):
        Task { await importImageURL(url) }
      case .failure(let err):
        errorText = err.localizedDescription
      }
    }
  }

  private func importImageURL(_ url: URL) async {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try Data(contentsOf: url)
      await importImageData(data)
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func importImageData(_ data: Data) async {
	    guard let img = UIImage(data: data) else {
	      errorText = NSLocalizedString("Invalid image", comment: "")
	      return
	    }
    let payload = await OnDeviceAgentDecodeQRCodeFromImage(img)
	    guard let payload, !payload.isEmpty else {
	      errorText = NSLocalizedString("No QR code found in image", comment: "")
	      return
	    }
    handleScannedPayload(payload)
  }
}

// MARK: - QR Export

private struct QRCodeExportSheet: View {
  @EnvironmentObject private var store: ConsoleStore
  @Binding var isPresented: Bool
  @State private var errorText: String?
  @State private var qrImage: UIImage?
  @State private var jsonText: String = ""
  @State private var shareURL: URL?
  @State private var isSharing: Bool = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("This QR encodes the current config as JSON (api_key is excluded).")
            .font(.footnote)
            .foregroundStyle(.secondary)

          if let err = errorText, !err.isEmpty {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.red)
          }

          if let img = qrImage {
            Image(uiImage: img)
              .interpolation(.none)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 320, maxHeight: 320)
              .frame(maxWidth: .infinity)
          } else if errorText == nil {
            ProgressView()
              .frame(maxWidth: .infinity)
          }

          Button("Share QR Image") {
            isSharing = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(shareURL == nil)

          if !jsonText.isEmpty {
            Divider()
            Text("JSON payload")
              .font(.headline)
            Text(jsonText)
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle("Export Config (QR)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { isPresented = false }
        }
      }
      .onAppear {
        generate()
      }
    }
    .sheet(isPresented: $isSharing) {
      if let url = shareURL {
        OnDeviceAgentActivityView(activityItems: [url])
      }
    }
  }

  private func generate() {
    errorText = nil
    qrImage = nil
    shareURL = nil
    jsonText = ""

    do {
      let json = try store.exportConfigJSONForQRCode()
      jsonText = json
	      guard let img = OnDeviceAgentMakeQRCodeImage(from: json) else {
	        errorText = NSLocalizedString("Failed to generate QR image (payload may be too large).", comment: "")
	        return
	      }
      qrImage = img
      let ts = Int(Date().timeIntervalSince1970)
      shareURL = try OnDeviceAgentWriteTempPNG(img, filename: "agent_config_qr_\(ts).png")
    } catch {
      errorText = error.localizedDescription
    }
  }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
  enum ScanError: LocalizedError {
    case cameraUnavailable
    case permissionDenied

    var errorDescription: String? {
      switch self {
      case .cameraUnavailable:
        return NSLocalizedString("Camera unavailable", comment: "")
      case .permissionDenied:
        return NSLocalizedString("Camera permission denied", comment: "")
      }
    }
  }

  let onResult: (Result<String, Error>) -> Void

  func makeUIViewController(context: Context) -> QRCodeScannerViewController {
    let vc = QRCodeScannerViewController()
    vc.onResult = onResult
    return vc
  }

  func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onResult: ((Result<String, Error>) -> Void)?

  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var didSendResult: Bool = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    Task { await self.setupIfPermitted() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopSession()
  }

  private func stopSession() {
    if session.isRunning {
      session.stopRunning()
    }
  }

  private func setupPreview() {
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(layer)
    previewLayer = layer
    layer.frame = view.bounds
  }

  private func setupSession() throws {
    guard let device = AVCaptureDevice.default(for: .video) else {
      throw QRCodeScannerView.ScanError.cameraUnavailable
    }
    let input = try AVCaptureDeviceInput(device: device)
    if session.canAddInput(input) {
      session.addInput(input)
    }

    let output = AVCaptureMetadataOutput()
    if session.canAddOutput(output) {
      session.addOutput(output)
      output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
      output.metadataObjectTypes = [.qr]
    }

    setupPreview()
    session.startRunning()
  }

  @MainActor
  private func setupIfPermitted() async {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      break
    case .notDetermined:
      let ok = await AVCaptureDevice.requestAccess(for: .video)
      if !ok {
        onResult?(.failure(QRCodeScannerView.ScanError.permissionDenied))
        return
      }
    default:
      onResult?(.failure(QRCodeScannerView.ScanError.permissionDenied))
      return
    }

    do {
      try setupSession()
    } catch {
      onResult?(.failure(error))
    }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard !didSendResult else { return }
    guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject else { return }
    guard obj.type == .qr else { return }
    guard let s = obj.stringValue, !s.isEmpty else { return }
    didSendResult = true
    stopSession()
    onResult?(.success(s))
  }
}
