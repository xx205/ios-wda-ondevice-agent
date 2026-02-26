import SwiftUI

struct RunView: View {
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

