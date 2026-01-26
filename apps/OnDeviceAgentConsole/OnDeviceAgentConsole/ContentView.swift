import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision

private func OnDeviceAgentDismissKeyboard() {
  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private func OnDeviceAgentWriteTempText(_ text: String, filename: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  guard let data = text.data(using: .utf8) else {
    throw NSError(domain: "OnDeviceAgentConsole", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot encode text as UTF-8"])
  }
  try data.write(to: url, options: .atomic)
  return url
}

private func OnDeviceAgentWriteTempPNG(_ image: UIImage, filename: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  guard let data = image.pngData() else {
    throw NSError(domain: "OnDeviceAgentConsole", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
  }
  try data.write(to: url, options: .atomic)
  return url
}

private func OnDeviceAgentMakeQRCodeImage(from text: String) -> UIImage? {
  guard let data = text.data(using: .utf8) else { return nil }
  guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
  filter.setValue(data, forKey: "inputMessage")
  filter.setValue("M", forKey: "inputCorrectionLevel")
  guard let output = filter.outputImage else { return nil }

  let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
  let ctx = CIContext(options: nil)
  guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
  return UIImage(cgImage: cg)
}

private func OnDeviceAgentCGImageOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
  switch o {
  case .up: return .up
  case .down: return .down
  case .left: return .left
  case .right: return .right
  case .upMirrored: return .upMirrored
  case .downMirrored: return .downMirrored
  case .leftMirrored: return .leftMirrored
  case .rightMirrored: return .rightMirrored
  @unknown default: return .up
  }
}

private func OnDeviceAgentDecodeQRCodeFromImage(_ image: UIImage) async -> String? {
  await Task.detached(priority: .userInitiated) {
    guard let cg = image.cgImage else { return nil }
    let req = VNDetectBarcodesRequest()
    req.symbologies = [.qr]
    let handler = VNImageRequestHandler(cgImage: cg, orientation: OnDeviceAgentCGImageOrientation(image.imageOrientation), options: [:])
    do {
      try handler.perform([req])
    } catch {
      return nil
    }
    guard let results = req.results else { return nil }
    return results.first(where: { $0.symbology == .qr })?.payloadStringValue
  }.value
}

private struct OnDeviceAgentActivityView: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

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
  @State private var isImportingConfig = false
  @State private var isExportingConfig = false

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
          if let err = store.connectionError, !err.isEmpty {
            Text("Connection: \(err)")
              .font(.footnote)
              .foregroundStyle(.red)
          }
          if let err = store.lastActionError, !err.isEmpty {
            Text("Action: \(err)")
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
          LimitField(
            title: "Max Steps",
            help: "Hard stop after this many actions. Prevents runaway loops.",
            text: $store.draft.maxSteps,
            keyboard: .numberPad
          )

          LimitField(
            title: "Timeout (seconds)",
            help: "Per-step model request timeout. Increase if the model is slow.",
            text: $store.draft.timeoutSeconds,
            keyboard: .decimalPad
          )

          LimitField(
            title: "Step Delay (seconds)",
            help: "Sleep between executed actions. Increase to reduce flakiness.",
            text: $store.draft.stepDelaySeconds,
            keyboard: .decimalPad
          )

          let tokensTitle = (store.draft.apiMode == ConsoleStore.Defaults.apiMode) ? "Max Output Tokens" : "Max Completion Tokens"
          let tokensHelp = (store.draft.apiMode == ConsoleStore.Defaults.apiMode)
            ? "Responses API: max_output_tokens. Larger lets the model think/plan longer."
            : "Chat Completions: max_completion_tokens. Larger lets the model think/plan longer."
          LimitField(
            title: tokensTitle,
            help: tokensHelp,
            text: $store.draft.maxCompletionTokens,
            keyboard: .numberPad
          )
        }

        Section("System Prompt") {
          Toggle("Use custom system prompt", isOn: $store.draft.useCustomSystemPrompt)
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
          Button("Import Config (QR)") {
            isImportingConfig = true
          }

          Button("Export Config (QR)") {
            isExportingConfig = true
          }
          .disabled(!store.validationErrors().isEmpty)

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
      .scrollDismissesKeyboard(.interactively)
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
      }
      .sheet(isPresented: $isEditingSystemPrompt) {
        SystemPromptEditorSheet(
          title: "System Prompt",
          systemPrompt: $store.draft.systemPrompt,
          defaultTemplate: store.status?.config.defaultSystemPrompt ?? ""
        )
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
      }
      .sheet(isPresented: $isExportingConfig) {
        QRCodeExportSheet(isPresented: $isExportingConfig)
      }
    }
  }
}

private struct LimitField: View {
  let title: String
  let help: String
  @Binding var text: String
  let keyboard: UIKeyboardType

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      TextField("", text: $text)
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

private struct LogsView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if let err = store.logsError, !err.isEmpty {
            Text("Logs stale: \(err)")
              .font(.footnote)
              .foregroundStyle(.red)
          }

          Text(store.logs.joined(separator: "\n"))
            .font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle("Logs")
    }
  }
}

private struct ChatView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var isSharing = false
  @State private var shareURL: URL?
  @State private var exportError: String?

  private var effectiveSystemPrompt: String {
    guard let cfg = store.status?.config else { return "" }
    if cfg.useCustomSystemPrompt && !cfg.systemPrompt.isEmpty {
      return cfg.systemPrompt
    }
    return cfg.defaultSystemPrompt
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
          Text("Chat stale: \(err)")
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }

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
              if item.kind == "system" {
                Text(effectiveSystemPrompt)
                  .font(.system(.footnote, design: .monospaced))
                  .textSelection(.enabled)
              } else {
                Text(item.raw ?? "")
                  .font(.system(.footnote, design: .monospaced))
                  .textSelection(.enabled)
              }
            } else {
              if item.kind == "system" {
                Text(effectiveSystemPrompt)
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
          }
          .padding(.vertical, 4)
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            Picker("Mode", selection: $store.chatMode) {
              ForEach(ConsoleStore.ChatMode.allCases) { m in
                Text(m.title).tag(m)
              }
            }
          }
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Export") {
              exportChat()
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

  private func exportChat() {
    exportError = nil
    do {
      let content: String
      let ext: String
      switch store.chatMode {
      case .message:
        content = exportChatMessageText()
        ext = "txt"
      case .raw:
        content = exportChatRawJSONL()
        ext = "jsonl"
      }
      let ts = Int(Date().timeIntervalSince1970)
      let url = try OnDeviceAgentWriteTempText(content, filename: "agent_chat_\(ts).\(ext)")
      shareURL = url
      isSharing = true
    } catch {
      exportError = error.localizedDescription
    }
  }

  private func exportChatMessageText() -> String {
    var out: [String] = []
    for item in store.chatItems {
      out.append(exportHeader(for: item))
      if item.kind == "system" {
        out.append(effectiveSystemPrompt)
      } else {
        if let text = item.text, !text.isEmpty { out.append(text) }
        if let content = item.content, !content.isEmpty { out.append(content) }
        if let reasoning = item.reasoning, !reasoning.isEmpty {
          out.append("\n--- reasoning ---\n")
          out.append(reasoning)
        }
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

      if item.kind == "system" {
        obj["system_prompt"] = effectiveSystemPrompt
      }
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
    parts.append("Step \(item.step ?? 0) \(item.kind.uppercased())")
    if let attempt = item.attempt {
      parts.append("(attempt \(attempt))")
    }
    return parts.joined(separator: " ")
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

private struct SystemPromptEditorSheet: View {
  let title: String
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
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              // If the user never had a custom prompt and didn't change the default template,
              // keep systemPrompt empty to avoid persisting the built-in template as "custom".
              if systemPrompt.isEmpty && draft == defaultTemplate {
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

  private func handleScannedPayload(_ s: String) {
    if let err = onScan(s), !err.isEmpty {
      errorText = err
    } else {
      isPresented = false
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        Text("Scan a QR code containing a JSON config object.")
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
            errorText = "Cannot load image"
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
      errorText = "Invalid image"
      return
    }
    let payload = await OnDeviceAgentDecodeQRCodeFromImage(img)
    guard let payload, !payload.isEmpty else {
      errorText = "No QR code found in image"
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
        errorText = "Failed to generate QR image (payload may be too large)."
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
        return "Camera unavailable"
      case .permissionDenied:
        return "Camera permission denied"
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
