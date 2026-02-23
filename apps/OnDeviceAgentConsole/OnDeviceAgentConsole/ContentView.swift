import SwiftUI
import UniformTypeIdentifiers

// MARK: - Platform shims

#if canImport(PhotosUI)
import PhotosUI
#endif

#if os(iOS)
import AVFoundation
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum OnDeviceAgentKeyboard {
  case `default`
  case numberPad
  case decimalPad
  case URL
}

extension View {
  @ViewBuilder
  func onDeviceAgentKeyboard(_ keyboard: OnDeviceAgentKeyboard) -> some View {
    #if canImport(UIKit)
    switch keyboard {
    case .default:
      self.keyboardType(.default)
    case .numberPad:
      self.keyboardType(.numberPad)
    case .decimalPad:
      self.keyboardType(.decimalPad)
    case .URL:
      self.keyboardType(.URL)
    }
    #else
    self
    #endif
  }
}

private func OnDeviceAgentDismissKeyboard() {
  #if canImport(UIKit)
  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  #endif
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
    #if os(macOS)
    let sidebarSelection = Binding<Tab?>(
      get: { selectedTab },
      set: { newValue in
        if let newValue { selectedTab = newValue }
      }
    )
    NavigationSplitView {
      List(selection: sidebarSelection) {
        Label("Run", systemImage: "slider.horizontal.3").tag(Tab.run)
        Label("Logs", systemImage: "doc.plaintext").tag(Tab.logs)
        Label("Chat", systemImage: "text.bubble").tag(Tab.chat)
        Label("Notes", systemImage: "note.text").tag(Tab.notes)
      }
      .listStyle(.sidebar)
      .frame(minWidth: 190)
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch selectedTab {
          case .run:
            RunView()
          case .logs:
            LogsView()
          case .chat:
            ChatView()
          case .notes:
            NotesView()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    #else
    TabView(selection: $selectedTab) {
      VStack(spacing: 0) {
        RunView()
      }
        .tabItem { Label("Run", systemImage: "slider.horizontal.3") }
        .tag(Tab.run)

      VStack(spacing: 0) {
        LogsView()
      }
        .tabItem { Label("Logs", systemImage: "doc.plaintext") }
        .tag(Tab.logs)

      VStack(spacing: 0) {
        ChatView()
      }
        .tabItem { Label("Chat", systemImage: "text.bubble") }
        .tag(Tab.chat)

      VStack(spacing: 0) {
        NotesView()
      }
        .tabItem { Label("Notes", systemImage: "note.text") }
        .tag(Tab.notes)
    }
    #endif
  }
}

private struct LiveProgressPanel: View {
  let progress: ConsoleStore.LiveProgress
  let onJumpToStep: (() -> Void)?

  init(progress: ConsoleStore.LiveProgress, onJumpToStep: (() -> Void)? = nil) {
    self.progress = progress
    self.onJumpToStep = onJumpToStep
  }

  private func phaseText(_ phase: ConsoleStore.LiveProgress.Phase) -> String {
    switch phase {
    case .idle:
      return NSLocalizedString("Idle", comment: "")
    case .stopping:
      return NSLocalizedString("Stopping…", comment: "")
    case .callingModel:
      return NSLocalizedString("Calling model…", comment: "")
    case .parsingOutput:
      return NSLocalizedString("Parsing output…", comment: "")
    case .executingAction:
      return NSLocalizedString("Executing action…", comment: "")
    }
  }

  var body: some View {
    if progress.running {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text("Live")
            .font(.headline)

          Spacer()

          if let onJumpToStep, progress.step != nil {
            Button("Jump") {
              onJumpToStep()
            }
            #if os(macOS)
            .buttonStyle(.link)
            #endif
            .font(.footnote)
          }
        }

        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let step = progress.step {
            Text(String(format: NSLocalizedString("Step %d", comment: ""), step))
              .font(.system(.footnote, design: .monospaced))
          }

          Text(phaseText(progress.phase))
            .font(.footnote)
            .foregroundStyle(.secondary)

          if let action = progress.action, !action.isEmpty {
            Text(action)
              .font(.system(.footnote, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }

        if let next = progress.nextPlanItem, !next.isEmpty {
          Text(String(format: NSLocalizedString("Next: %@", comment: ""), next))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        if let t = progress.tokens {
          Text(
            String(
              format: NSLocalizedString(
                "Δ(in=%d, out=%d, cached=%d, total=%d)  cum(in=%d, out=%d, cached=%d, total=%d)",
                comment: ""
              ),
              t.delta.input,
              t.delta.output,
              t.delta.cached,
              t.delta.total,
              t.cumulative.input,
              t.cumulative.output,
              t.cumulative.cached,
              t.cumulative.total
            )
          )
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
        }
      }
      .padding(12)
      .background(Color.secondary.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(.vertical, 4)
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
	  @State private var isRunDetailsExpanded = false
	  @State private var isModelExpanded = false
	  @State private var isLimitsExpanded = false
	  @State private var isPromptExpanded = false
	  @State private var isAdvancedExpanded = false
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
	              let runErrors = store.runValidationErrors()
	              let canStart = !isRunning && runErrors.isEmpty && connectionErr.isEmpty
	              let shouldShowDetails =
	                showLANHint || showUsage || !lastMessage.isEmpty || !connectionErr.isEmpty || !actionErr.isEmpty || !runErrors.isEmpty

	              VStack(alignment: .leading, spacing: 14) {
	                InlineEditHeader("Task") { isEditingTask = true }

	                if store.draft.task.isEmpty {
	                  Text("Enter a task…")
	                    .font(.footnote)
	                    .foregroundStyle(.secondary)
	                } else {
	                  Text(store.draft.task)
	                    .font(.footnote)
	                    .lineLimit(6)
	                }

	                ActionButtonField("Start run", disabled: !canStart) {
	                  Task { await store.startAgent() }
	                }

	                ActionButtonField("Stop run", disabled: !isRunning, role: .destructive) {
	                  Task { await store.stopAgent() }
	                }

	                if store.liveProgress.running {
	                  LiveProgressPanel(progress: store.liveProgress)
	                }
	              }
	              .padding(12)
	              .background(Color.secondary.opacity(0.06))
	              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	              .padding(.vertical, 4)
	              .listRowSeparator(.hidden)

	              ConfigField(
	                title: "Runner URL",
	                help: "Runner is the WebDriverAgentRunner-Runner app on your iPhone. This URL connects the Console to Runner (port 8100).\n• On iPhone, use: http://127.0.0.1:8100\n• For LAN debugging, use the iPhone’s Wi‑Fi IP (make sure Runner’s Wireless Data is enabled).",
	                placeholder: ConsoleStore.Defaults.wdaURL,
	                text: $store.wdaURL,
                keyboard: .URL,
                collapsibleHelp: true
              )

              DisclosureGroup(isExpanded: $isRunDetailsExpanded) {
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
                      .fixedSize(horizontal: false, vertical: true)
                      .lineSpacing(2)
                    }
                    .padding(.vertical, 2)
                  }

                  if !lastMessage.isEmpty {
                    Text(lastMessage)
                      .font(.footnote)
                      .foregroundStyle(.secondary)
                  }
                  if !connectionErr.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("Runner unavailable")
                        .font(.headline)
                        .foregroundStyle(.red)

                      Text(
                        String(
                          format: NSLocalizedString(
                            "Cannot connect to Runner at %@. Make sure Runner is running, then try again.",
                            comment: ""
                          ),
                          store.wdaURL
                        )
                      )
                      .font(.footnote)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                      .lineSpacing(2)

                      Text(connectionErr)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                    }
                  }
                  if !actionErr.isEmpty {
                    Text(String(format: NSLocalizedString("Execution error: %@", comment: ""), actionErr))
                      .font(.footnote)
                      .foregroundStyle(.red)
                  }
                  if !runErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("Action required")
                        .font(.headline)
                        .foregroundStyle(.red)

                      ForEach(runErrors, id: \.self) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                          Text("•")
                          Text(verbatim: NSLocalizedString(e, comment: ""))
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                      }
                    }
                    .padding(.vertical, 2)
                  }

                  if showUsage, let usage {
                    DisclosureGroup("Token Usage") {
                      VStack(alignment: .leading, spacing: 2) {
                        Text(
                          "doubao_seed_enable_session_cache: \((store.status?.config.doubaoSeedEnableSessionCache ?? false) ? "true" : "false")"
                        )
                        Text("cache_hit: \(usage.cachedTokens > 0 ? "true" : "false")")
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
                      .padding(.top, 4)
                    }
                  }

                }
              } label: {
                Text("Details")
                  .font(.headline)
              }
              .onAppear {
                if shouldShowDetails {
                  isRunDetailsExpanded = true
                }
              }
              .onChange(of: shouldShowDetails) { v in
                if v {
                  isRunDetailsExpanded = true
                }
              }
            },
            label: {
              DisclosureHeader("Quick Start") {
                let runErrors = store.runValidationErrors()
                let connectionErr = store.connectionError ?? ""
                if isRunning {
                  Text("Running").foregroundStyle(.green)
                } else if !connectionErr.isEmpty {
                  Text("Runner unavailable").foregroundStyle(.red)
                } else if !runErrors.isEmpty {
                  Text("Needs setup").foregroundStyle(.orange)
                } else {
                  Text("Ready").foregroundStyle(.green)
                }
              }
            }
          )
        }

        Section {
          DisclosureGroup(isExpanded: $isPromptExpanded) {
            VStack(alignment: .leading, spacing: 10) {
              ToggleField(
                "Use custom system prompt",
                help: "When enabled, Runner will use the Prompt text below.",
                isOn: $store.draft.useCustomSystemPrompt
              )

              InlineEditHeader("Prompt text") {
                Task {
                  await store.refresh()
                  isEditingSystemPrompt = true
                }
              }

              Text("Date placeholders (replaced at runtime):")
                .font(.footnote)
                .foregroundStyle(.secondary)

              VStack(alignment: .leading, spacing: 2) {
                Text("{{DATE_ZH}} → \(ConsoleStore.datePlaceholderZH())")
                Text("{{DATE_EN}} → \(ConsoleStore.datePlaceholderEN())")
              }
              .font(.system(.footnote, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)

              if !store.draft.systemPrompt.isEmpty {
                Text(store.draft.systemPrompt)
                  .font(.system(.footnote, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .lineLimit(6)
              }
            }
            .padding(.vertical, 2)
          } label: {
            DisclosureHeader("System Prompt")
          }
        }

        Section {
          DisclosureGroup(isExpanded: $isModelExpanded) {
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

	                  let apiKeyPlaceholderKey = store.status?.config.apiKeySet == true ? "(set on device)" : "sk-..."
	                  let apiKeyPlaceholder = NSLocalizedString(apiKeyPlaceholderKey, comment: "")
	                  if store.draft.showApiKey {
	                    TextField("", text: $store.draft.apiKey, prompt: Text(verbatim: apiKeyPlaceholder))
	                      .font(.system(.body, design: .monospaced))
	                    #if canImport(UIKit)
	                    .textInputAutocapitalization(.never)
	                    .autocorrectionDisabled()
	                    #endif
	                  } else {
	                    SecureField("", text: $store.draft.apiKey, prompt: Text(verbatim: apiKeyPlaceholder))
	                      .font(.system(.body, design: .monospaced))
	                    #if canImport(UIKit)
	                    .textInputAutocapitalization(.never)
	                    .autocorrectionDisabled()
	                    #endif
	                  }

              Text("Required (unless already saved on device). Leave empty to keep the existing key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            ToggleField("Show API key", isOn: $store.draft.showApiKey)
            ToggleField("Remember API key on device", isOn: $store.draft.rememberApiKey)
          } label: {
            DisclosureHeader("Model service")
          }
        }

        Section {
          DisclosureGroup(isExpanded: $isLimitsExpanded) {
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
          } label: {
            DisclosureHeader("Limits & stability")
          }
        }

        Section {
          DisclosureGroup(isExpanded: $isAdvancedExpanded) {
	              VStack(alignment: .leading, spacing: 6) {
	                  Text("Agent token (for LAN)")
	                    .font(.headline)

	                  let agentTokenPlaceholderKey = store.status?.config.agentTokenSet == true ? "(set on Runner)" : "optional for localhost"
	                  let agentTokenPlaceholder = NSLocalizedString(agentTokenPlaceholderKey, comment: "")
	                  TextField("", text: $store.draft.agentToken, prompt: Text(verbatim: agentTokenPlaceholder))
	                    .font(.system(.body, design: .monospaced))
	                  #if canImport(UIKit)
	                  .textInputAutocapitalization(.never)
	                  .autocorrectionDisabled()
	                  #endif
	                  .font(.system(.body, design: .monospaced))

                Text("Protects /agent/* over Wi‑Fi/LAN. If empty, Runner only allows localhost.")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            ActionButtonField(
              "Update token",
              help: "Update token generates a new token and syncs it to Runner."
            ) {
              Task {
                _ = await store.updateAgentToken()
              }
            }

            ActionButtonField(
              "Copy access link",
              help: store.canCopyOneTimeAccessLink
                ? "Copy access link copies a one-time access link using current token."
                : "Copy access link requires token. Tap “Update token” first.",
              disabled: !store.canCopyOneTimeAccessLink
            ) {
              _ = store.copyOneTimeAccessLink()
            }

            if !store.canBuildOneTimeAccessLink {
              Text("Cannot build access link. If Runner URL is localhost, set Runner URL to the iPhone’s Wi‑Fi IP so the link works over LAN.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if store.isDoubaoSeedResponsesMode() {
              ToggleField(
                "Enable Session Cache (Doubao Seed)",
                help: "Responses only. Enables session caching for doubao-seed models to reduce tokens and improve stability.",
                isOn: $store.draft.doubaoSeedEnableSessionCache
              )
            }

            ToggleField(
              "Restart history when a plan item completes",
              help: "Responses only. Starts a new conversation segment whenever a plan checklist item is marked done (keeps Notes/Plan; resets previous_response_id).",
              isOn: $store.draft.restartResponsesByPlan
            )
            .disabled(store.draft.apiMode != ConsoleStore.Defaults.apiMode)

            ToggleField(
              "Half-resolution screenshots",
              help: "Shrinks screenshots by 50% before sending to the model, reducing Token usage and often speeding up responses.",
              isOn: $store.draft.halfResScreenshot
            )

            ToggleField(
              "Use W3C actions for swipe",
              help: "Recommended for games: makes swipe closer to a real finger gesture.",
              isOn: $store.draft.useW3CActionsForSwipe
            )

            ToggleField(
              "Annotate screenshots with actions",
              help: "Overlays click/swipe markers on per-step screenshots in Chat.",
              isOn: $store.annotateStepScreenshots
            )

            ToggleField(
              "Debug raw conversation",
              help: "Off by default. Stores per-step API request/response JSON with sensitive fields redacted (API key / Authorization / image base64).",
              isOn: $store.draft.debugLogRawAssistant
            )

            ToggleField(
              "Insecure TLS (model requests only)",
              help: "Debug only. Skips certificate verification for model-service HTTPS requests and increases MITM risk.",
              isOn: $store.draft.insecureSkipTLSVerify
            )

            ActionButtonField(
              "Import Config (QR)",
              help: "Scans a QR code and shows a review step before applying changes."
            ) {
              isImportingConfig = true
            }

            ActionButtonField(
              "Export Config (QR)",
              help: "Exports the current config as a QR code image for sharing or backup.",
              disabled: !store.validationErrors().isEmpty
            ) {
              isExportingConfig = true
            }

            ActionButtonField(
              "Save Config",
              help: "Saves the current config to Runner (persistent on device).",
              disabled: !store.validationErrors().isEmpty
            ) {
              Task { await store.saveConfig() }
            }
          } label: {
            DisclosureHeader("Advanced (optional)")
          }
        }

        Section {
          DisclosureGroup(isExpanded: $isDangerExpanded) {
            VStack(alignment: .leading, spacing: 14) {
              ActionButtonField(
                "Reset Runtime",
                help: "Stops the agent and clears logs/chat/screenshots/notes/token usage. Keeps saved config.",
                role: .destructive
              ) {
                Task { await store.resetRuntime() }
              }

              Divider()

              ActionButtonField(
                "Factory Reset",
                help: "Stops the agent, clears runtime, and restores Runner config to defaults (forgets API key, custom prompt, and other saved settings).",
                role: .destructive
              ) {
                Task { await store.factoryReset() }
              }
            }
          } label: {
            DisclosureHeader("Reset")
          }
          }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        #endif
        .navigationTitle("On‑Device Agent")
        #if canImport(UIKit)
        .scrollDismissesKeyboard(.interactively)
        #endif
      .task {
        await store.checkLocalNetworkAccess(force: true)
      }
      .toolbar {
        #if canImport(UIKit)
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") {
            OnDeviceAgentDismissKeyboard()
          }
        }
        #endif
      }
		      #if canImport(UIKit)
			      .fullScreenCover(isPresented: $isEditingTask) {
			        TextEditorSheet(title: "Task", text: $store.draft.task)
			          .onAppear { store.suspendAutoRefresh() }
			          .onDisappear {
			            store.resumeAutoRefresh()
			          }
			      }
			      .fullScreenCover(isPresented: $isEditingSystemPrompt) {
			        SystemPromptEditorSheet(
			          title: "System Prompt",
			          systemPrompt: $store.draft.systemPrompt,
			          defaultTemplate: store.defaultSystemPromptTemplate
			        )
			        .onAppear { store.suspendAutoRefresh() }
			        .onDisappear {
			          store.resumeAutoRefresh()
			        }
			      }
			      #else
			      .sheet(isPresented: $isEditingTask) {
			        TextEditorSheet(title: "Task", text: $store.draft.task)
			          .onAppear { store.suspendAutoRefresh() }
			          .onDisappear {
			            store.resumeAutoRefresh()
			          }
			      }
			      .sheet(isPresented: $isEditingSystemPrompt) {
			        SystemPromptEditorSheet(
			          title: "System Prompt",
			          systemPrompt: $store.draft.systemPrompt,
			          defaultTemplate: store.defaultSystemPromptTemplate
			        )
			        .onAppear { store.suspendAutoRefresh() }
			        .onDisappear {
			          store.resumeAutoRefresh()
			        }
			      }
			      #endif
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
  let keyboard: OnDeviceAgentKeyboard

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      #if os(macOS)
      TextField("", text: $text, prompt: Text(placeholder))
        .onDeviceAgentKeyboard(keyboard)
        .multilineTextAlignment(.trailing)
        .font(.system(.body, design: .monospaced))
      #else
      TextField(placeholder, text: $text)
        .onDeviceAgentKeyboard(keyboard)
        #if canImport(UIKit)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .multilineTextAlignment(.trailing)
        .font(.system(.body, design: .monospaced))
      #endif

      Text(help)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .lineSpacing(2)
    }
    .padding(.vertical, 2)
  }
}

private struct ToggleField: View {
  let title: LocalizedStringKey
  let help: LocalizedStringKey?
  @Binding var isOn: Bool

  init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
    self.title = title
    help = nil
    _isOn = isOn
  }

  init(_ title: LocalizedStringKey, help: LocalizedStringKey, isOn: Binding<Bool>) {
    self.title = title
    self.help = help
    _isOn = isOn
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: $isOn) {
        Text(title)
          .font(.headline)
      }

      if let help {
        Text(help)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(2)
      }
    }
    .padding(.vertical, 2)
  }
}

	private struct ActionButtonField: View {
	  let title: LocalizedStringKey
	  let help: LocalizedStringKey?
	  let role: ButtonRole?
  let disabled: Bool
  let action: () -> Void

  init(_ title: LocalizedStringKey, help: LocalizedStringKey? = nil, disabled: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) {
    self.title = title
    self.help = help
    self.disabled = disabled
    self.role = role
    self.action = action
  }

	  var body: some View {
	    VStack(alignment: .leading, spacing: 6) {
	      HStack(spacing: 0) {
	            Button(role: role, action: action) {
	          Text(title)
	            .font(.headline)
	            #if os(macOS)
	            .foregroundStyle(role == .destructive ? .red : Color.accentColor)
	            #endif
	        }
	        #if canImport(UIKit)
	        .buttonStyle(.borderless)
	        #endif
	        #if os(macOS)
	        .buttonStyle(.link)
	        .controlSize(.regular)
	        .font(.headline)
	        #endif
	        .disabled(disabled)

	        Spacer(minLength: 0)
	      }

      if let help {
        Text(help)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(2)
      }
    }
    .padding(.vertical, 2)
  }
}

	private struct InlineEditHeader: View {
	  let title: LocalizedStringKey
	  let onEdit: () -> Void

  init(_ title: LocalizedStringKey, onEdit: @escaping () -> Void) {
    self.title = title
    self.onEdit = onEdit
  }

	  var body: some View {
	    HStack {
	      Text(title)
	        .font(.headline)
	      Spacer()
	      Button("Edit", action: onEdit)
	        .font(.footnote)
	        #if canImport(UIKit)
	        .buttonStyle(.borderless)
	        #endif
	        #if os(macOS)
	        .buttonStyle(.link)
	        #endif
	    }
	  }
	}

private struct ConfigField: View {
  let title: LocalizedStringKey
  let help: String
  let placeholder: String
  @Binding var text: String
  let keyboard: OnDeviceAgentKeyboard
  let collapsibleHelp: Bool
  let helpTitle: LocalizedStringKey = "Help"

  init(
    title: LocalizedStringKey,
    help: String,
    placeholder: String,
    text: Binding<String>,
    keyboard: OnDeviceAgentKeyboard,
    collapsibleHelp: Bool = false
  ) {
    self.title = title
    self.help = help
    self.placeholder = placeholder
    _text = text
    self.keyboard = keyboard
    self.collapsibleHelp = collapsibleHelp
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      #if os(macOS)
      TextField("", text: $text, prompt: Text(placeholder))
        .onDeviceAgentKeyboard(keyboard)
        .font(.system(.body, design: .monospaced))
      #else
      TextField(placeholder, text: $text)
        .onDeviceAgentKeyboard(keyboard)
        #if canImport(UIKit)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .font(.system(.body, design: .monospaced))
      #endif

      let helpText = NSLocalizedString(help, comment: "")
      if !helpText.isEmpty {
        if collapsibleHelp {
          DisclosureGroup(helpTitle) {
            Text(verbatim: helpText)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .lineSpacing(2)
              .padding(.top, 4)
          }
        } else {
          Text(verbatim: helpText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
        }
      }
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
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(2)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct LogsView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var searchText: String = ""
  @State private var tagFilter: LogTagFilter = .all
  @State private var levelFilter: LogLevelFilter = .all
  @State private var followLatest: Bool = true
  @State private var isFiltersPresented: Bool = false

  private enum LogTagFilter: String, CaseIterable, Identifiable {
    case all
    case agent
    case action
    case model
    case tokens
    case runner

    var id: String { rawValue }

    var title: LocalizedStringKey {
      switch self {
      case .all: return "All"
      case .agent: return "Agent"
      case .action: return "Action"
      case .model: return "Model"
      case .tokens: return "Tokens"
      case .runner: return "Runner"
      }
    }
  }

  private enum LogLevelFilter: String, CaseIterable, Identifiable {
    case all
    case debug
    case info
    case warn
    case error

    var id: String { rawValue }

    var title: LocalizedStringKey {
      switch self {
      case .all: return "All"
      case .debug: return "Debug"
      case .info: return "Info"
      case .warn: return "Warn"
      case .error: return "Error"
      }
    }
  }

  private struct LogEntry: Identifiable {
    let index: Int
    let raw: String
    let ts: String
    let level: String
    let tag: String
    let event: String
    let msg: String
    let dict: [String: Any]?

    var id: Int { index }

    var levelKey: String {
      level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var tagKey: String {
      tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var title: String {
      if event == "step" {
        let step = int("step")
        let action = str("action")
        if let step, !action.isEmpty {
          return String(format: NSLocalizedString("Step %d · %@", comment: ""), step, action)
        }
      }
      if event == "token_usage" {
        return NSLocalizedString("Token Usage", comment: "")
      }
      if !msg.isEmpty { return msg }
      let err = str("error")
      if !err.isEmpty { return err }
      return event.isEmpty ? raw : event
    }

    var subtitle: String? {
      if event == "token_usage" {
        let req = int("req") ?? 0
        let dIn = int("d_in") ?? 0
        let dOut = int("d_out") ?? 0
        let dCached = int("d_cached") ?? 0
        let dTotal = int("d_total") ?? 0
        let cIn = int("c_in") ?? 0
        let cOut = int("c_out") ?? 0
        let cCached = int("c_cached") ?? 0
        let cTotal = int("c_total") ?? 0
        if req > 0 || cTotal > 0 {
          return String(
            format: NSLocalizedString("Δ(in=%d, out=%d, cached=%d, total=%d)  cum(in=%d, out=%d, cached=%d, total=%d)", comment: ""),
            dIn, dOut, dCached, dTotal, cIn, cOut, cCached, cTotal
          )
        }
      }
      if event == "run_finished" {
        if let success = bool("success") {
          return success ? NSLocalizedString("Run ended", comment: "") : msg
        }
      }
      let err = str("error")
      if !err.isEmpty, title != err { return err }
      return nil
    }

    func str(_ key: String) -> String {
      (dict?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func int(_ key: String) -> Int? {
      let v = dict?[key]
      if let i = v as? Int { return i }
      if let n = v as? NSNumber { return n.intValue }
      if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
      return nil
    }

    func bool(_ key: String) -> Bool? {
      let v = dict?[key]
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

    var badgeColor: Color {
      switch levelKey {
      case "error": return .red
      case "warn": return .orange
      case "debug": return .secondary
      default: return .blue
      }
    }
  }

  private func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
  }

  private func parseLogEntry(index: Int, raw: String) -> LogEntry {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
       let data = trimmed.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data, options: []),
       let dict = obj as? [String: Any]
    {
      let ts = (dict["ts"] as? String) ?? ""
      let lvl = (dict["lvl"] as? String) ?? ""
      let tag = (dict["tag"] as? String) ?? ""
      let ev = (dict["event"] as? String) ?? ""
      let msg = (dict["msg"] as? String) ?? ""
      return LogEntry(index: index, raw: trimmed, ts: ts, level: lvl, tag: tag, event: ev, msg: msg, dict: dict)
    }
    return LogEntry(index: index, raw: trimmed, ts: "", level: "", tag: "", event: "", msg: trimmed, dict: nil)
  }

  private var entries: [LogEntry] {
    store.logs.enumerated().map { parseLogEntry(index: $0.offset, raw: $0.element) }
  }

  private var filteredEntries: [LogEntry] {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return entries.filter { e in
      if levelFilter != .all, e.levelKey != levelFilter.rawValue { return false }
      if tagFilter != .all, e.tagKey != tagFilter.rawValue { return false }
      if q.isEmpty { return true }
      return e.raw.lowercased().contains(q) || e.title.lowercased().contains(q) || (e.subtitle ?? "").lowercased().contains(q)
    }
  }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        Group {
          if store.logs.isEmpty, (store.logsError ?? "").isEmpty {
            ContentUnavailableView(
              NSLocalizedString("No logs yet", comment: ""),
              systemImage: "doc.plaintext",
              description: Text(NSLocalizedString("Logs will appear while the agent runs.", comment: ""))
            )
            .padding(.horizontal, 20)
          } else if filteredEntries.isEmpty {
            ContentUnavailableView(
              NSLocalizedString("No results", comment: ""),
              systemImage: "magnifyingglass",
              description: Text(NSLocalizedString("Try adjusting search or filters.", comment: ""))
            )
            .padding(.horizontal, 20)
          } else {
            List(filteredEntries) { e in
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                  if !e.ts.isEmpty {
                    Text(e.ts)
                      .font(.system(.caption, design: .monospaced))
                      .foregroundStyle(.secondary)
                  }
                  if !e.levelKey.isEmpty {
                    Text(e.levelKey.uppercased())
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(e.badgeColor)
                      .padding(.horizontal, 8)
                      .padding(.vertical, 2)
                      .background(e.badgeColor.opacity(0.12))
                      .clipShape(Capsule())
                  }
                  if !e.tagKey.isEmpty {
                    Text(e.tagKey)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if !e.event.isEmpty {
                    Text(e.event)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }

                Text(e.title)
                  .font(.callout)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)

                if let sub = e.subtitle, !sub.isEmpty {
                  Text(sub)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .contextMenu {
                Button(NSLocalizedString("Copy", comment: "")) { copyToPasteboard(e.raw) }
              }
              .id(e.id)
            }
            .listStyle(.plain)
          }
        }
        .navigationTitle("Logs")
        .searchable(text: $searchText)
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button {
              isFiltersPresented = true
            } label: {
              Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(NSLocalizedString("Filters", comment: ""))
          }
        }
	        .sheet(isPresented: $isFiltersPresented) {
	          NavigationStack {
	            Form {
	              Section {
	                Toggle(NSLocalizedString("Follow latest", comment: ""), isOn: $followLatest)
	              }

	              Section {
	                Picker(NSLocalizedString("Tag", comment: ""), selection: $tagFilter) {
	                  ForEach(LogTagFilter.allCases) { f in
	                    Text(f.title).tag(f)
	                  }
	                }
	                #if os(iOS)
	                  .pickerStyle(.navigationLink)
	                #endif

	                Picker(NSLocalizedString("Level", comment: ""), selection: $levelFilter) {
	                  ForEach(LogLevelFilter.allCases) { f in
	                    Text(f.title).tag(f)
	                  }
	                }
	                #if os(iOS)
	                  .pickerStyle(.navigationLink)
	                #endif
	              }

	              Section {
	                Button(NSLocalizedString("Jump to latest", comment: "")) {
	                  guard let last = filteredEntries.last else { return }
                  withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                  isFiltersPresented = false
                }
                Button(NSLocalizedString("Copy all", comment: "")) {
                  copyToPasteboard(store.logs.joined(separator: "\n"))
                  isFiltersPresented = false
                }
              }
            }
            .navigationTitle("Filters")
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { isFiltersPresented = false }
              }
            }
          }
        }
        .onChange(of: store.logs.count) { _ in
          guard !isFiltersPresented else { return }
          guard followLatest, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
          guard let last = filteredEntries.last else { return }
          withAnimation {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
        .overlay(alignment: .topLeading) {
          if let err = store.logsError, !err.isEmpty {
            Text(String(format: NSLocalizedString("Logs stale: %@", comment: ""), err))
              .font(.footnote)
              .foregroundStyle(.red)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
          }
        }
      }
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

private struct ChatView: View {
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
  #if canImport(PhotosUI)
  @State private var photoPickerItem: PhotosPickerItem?
  #endif
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

          #if os(iOS)
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
          #else
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
              Text("Camera scan is iOS-only. Use Import File / Import Image.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
            )
            .frame(height: 340)
            .padding(.horizontal, 16)
          #endif

          HStack(spacing: 12) {
            #if canImport(PhotosUI)
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
              Label("Import Image", systemImage: "photo")
            }
            .buttonStyle(.bordered)
            #endif

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
    #if canImport(PhotosUI)
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
    #endif
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
        guard let img = PlatformImage(data: data) else {
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
  @State private var qrImage: PlatformImage?
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
            Image(platformImage: img)
              .interpolation(.none)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: 320, maxHeight: 320)
              .frame(maxWidth: .infinity)
          } else if errorText == nil {
            ProgressView()
              .frame(maxWidth: .infinity)
          }

          #if canImport(UIKit)
          Button("Share QR Image") {
            isSharing = true
          }
          .buttonStyle(.borderedProminent)
          .disabled(shareURL == nil)
          #else
          if let url = shareURL {
            ShareLink(item: url) {
              Text("Share QR Image")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          } else {
            Button("Share QR Image") {}
              .buttonStyle(.borderedProminent)
              .disabled(true)
          }
          #endif

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
    #if canImport(UIKit)
    .sheet(isPresented: $isSharing) {
      if let url = shareURL {
        OnDeviceAgentActivityView(activityItems: [url])
      }
    }
    #endif
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

#if os(iOS)
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
#endif
