import CoreImage
import ImageIO
import Vision

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

func OnDeviceAgentMakeQRCodeImage(from text: String) -> PlatformImage? {
  guard let data = text.data(using: .utf8) else { return nil }
  guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
  filter.setValue(data, forKey: "inputMessage")
  filter.setValue("M", forKey: "inputCorrectionLevel")
  guard let output = filter.outputImage else { return nil }

  let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
  let ctx = CIContext(options: nil)
  guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
  #if canImport(UIKit)
  return UIImage(cgImage: cg)
  #elseif canImport(AppKit)
  return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  #else
  return nil
  #endif
}

#if canImport(UIKit)
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
#endif

private func OnDeviceAgentCGImageFromPlatformImage(_ image: PlatformImage) -> CGImage? {
  #if canImport(UIKit)
  return image.cgImage
  #elseif canImport(AppKit)
  var rect = CGRect(origin: .zero, size: image.size)
  return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  #else
  return nil
  #endif
}

func OnDeviceAgentDecodeQRCodeFromImage(_ image: PlatformImage) async -> String? {
  await Task.detached(priority: .userInitiated) {
    guard let cg = OnDeviceAgentCGImageFromPlatformImage(image) else { return nil }
    let req = VNDetectBarcodesRequest()
    req.symbologies = [.qr]
    #if canImport(UIKit)
    let orientation = OnDeviceAgentCGImageOrientation(image.imageOrientation)
    #else
    let orientation: CGImagePropertyOrientation = .up
    #endif
    let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
    do {
      try handler.perform([req])
    } catch {
      return nil
    }
    let results = req.results ?? []
    return results.first(where: { $0.symbology == .qr })?.payloadStringValue
  }.value
}
