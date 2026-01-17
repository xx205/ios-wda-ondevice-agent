import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var selectedTab: Tab = .control

  enum Tab: String {
    case control
    case logs
    case chat
    case notes
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      ControlView()
        .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
        .tag(Tab.control)

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

private struct ControlView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var isEditingTask = false
  @State private var isEditingSystemPrompt = false

  private var isRunning: Bool { store.status?.running ?? false }

  var body: some View {
    NavigationStack {
      Form {
        Section("Status") {
          HStack {
            Text("Runner")
            Spacer()
            Text(isRunning ? "Running" : "Stopped")
              .foregroundStyle(isRunning ? .green : .secondary)
          }
          if let msg = store.status?.lastMessage, !msg.isEmpty {
            Text(msg)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if let err = store.lastError, !err.isEmpty {
            Text(err)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }

        Section("Connection") {
          TextField("http://127.0.0.1:8100", text: $store.wdaURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
          Button("Refresh") {
            Task { await store.refresh() }
          }
        }

        Section("Model") {
          TextField("Base URL (OpenAI-compatible)", text: $store.draft.baseUrl)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))

          TextField("Model", text: $store.draft.model)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))

          Picker("API Mode", selection: $store.draft.apiMode) {
            Text("Responses (stateful)").tag(ConsoleStore.Defaults.apiMode)
            Text("Chat Completions").tag("chat_completions")
          }
        }

        Section("API Key") {
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

          Toggle("Show API key", isOn: $store.draft.showApiKey)
          Toggle("Remember API key on device", isOn: $store.draft.rememberApiKey)
        }

        Section("Task") {
          Button("Edit Task") { isEditingTask = true }
          if !store.draft.task.isEmpty {
            Text(store.draft.task)
              .font(.footnote)
              .lineLimit(6)
          }
        }

        Section("Limits") {
          TextField("Max Steps (>0)", text: $store.draft.maxSteps)
            .keyboardType(.numberPad)
          TextField("Timeout seconds (>0)", text: $store.draft.timeoutSeconds)
            .keyboardType(.decimalPad)
          TextField("Step Delay seconds (>0)", text: $store.draft.stepDelaySeconds)
            .keyboardType(.decimalPad)

          let tokensLabel = (store.draft.apiMode == ConsoleStore.Defaults.apiMode) ? "Max Output Tokens (>0)" : "Max Completion Tokens (>0)"
          TextField(tokensLabel, text: $store.draft.maxCompletionTokens)
            .keyboardType(.numberPad)
        }

        Section("System Prompt") {
          Toggle("Use custom system prompt", isOn: $store.draft.useCustomSystemPrompt)
          Button("Edit System Prompt") { isEditingSystemPrompt = true }
          if !store.draft.systemPrompt.isEmpty {
            Text(store.draft.systemPrompt)
              .font(.footnote)
              .lineLimit(6)
          }
        }

        Section("Advanced") {
          TextField("Reasoning effort (optional)", text: $store.draft.reasoningEffort)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))

          if store.isDoubaoSeedResponsesMode() {
            Toggle("Enable Session Cache (Doubao Seed)", isOn: $store.draft.doubaoSeedEnableSessionCache)
          }

          Toggle("Debug raw conversation", isOn: $store.draft.debugLogRawAssistant)
          Toggle("Insecure: skip TLS verify (model)", isOn: $store.draft.insecureSkipTLSVerify)
        }

        let errors = store.validationErrors()
        if !errors.isEmpty {
          Section("Validation") {
            ForEach(errors, id: \.self) { e in
              Text(e).foregroundStyle(.red)
            }
          }
        }

        Section {
          Button("Save Config") {
            Task { await store.saveConfig() }
          }
          .disabled(!store.validationErrors().isEmpty)

          Button("Start") {
            Task { await store.startAgent() }
          }
          .disabled(!store.validationErrors().isEmpty)

          Button("Stop", role: .destructive) {
            Task { await store.stopAgent() }
          }
          .disabled(!isRunning)

          Button("Reset Runtime", role: .destructive) {
            Task { await store.resetRuntime() }
          }
        }
      }
      .navigationTitle("On‑Device Agent")
      .sheet(isPresented: $isEditingTask) {
        TextEditorSheet(title: "Task", text: $store.draft.task)
      }
      .sheet(isPresented: $isEditingSystemPrompt) {
        TextEditorSheet(title: "System Prompt", text: $store.draft.systemPrompt)
      }
    }
  }
}

private struct LogsView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(store.logs.joined(separator: "\n"))
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      .navigationTitle("Logs")
    }
  }
}

private struct ChatView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      List(store.chatItems) { item in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Step \(item.step ?? 0) · \(item.kind)")
              .font(.headline)
            if let attempt = item.attempt {
              Text("(\(attempt))").foregroundStyle(.secondary)
            }
            Spacer()
            if let ts = item.ts {
              Text(ts).font(.caption).foregroundStyle(.secondary)
            }
          }

          if store.chatMode == .raw {
            Text(item.raw ?? "")
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
          } else {
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
      .navigationTitle("Chat")
      .toolbar {
        Picker("Mode", selection: $store.chatMode) {
          ForEach(ConsoleStore.ChatMode.allCases) { m in
            Text(m.title).tag(m)
          }
        }
      }
    }
  }
}

private struct NotesView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(store.status?.notes ?? "")
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      .navigationTitle("Notes")
    }
  }
}

private struct TextEditorSheet: View {
  let title: String
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

