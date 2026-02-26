import SwiftUI
import UniformTypeIdentifiers

#if canImport(PhotosUI)
import PhotosUI
#endif

#if os(iOS)
import AVFoundation
import UIKit
#endif

struct QRCodeImportSheet: View {
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

struct QRCodeExportSheet: View {
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

