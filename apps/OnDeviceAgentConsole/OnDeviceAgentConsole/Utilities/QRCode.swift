import CoreImage
import ImageIO
import UIKit
import Vision

func OnDeviceAgentMakeQRCodeImage(from text: String) -> UIImage? {
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

func OnDeviceAgentDecodeQRCodeFromImage(_ image: UIImage) async -> String? {
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
    let results = req.results ?? []
    return results.first(where: { $0.symbology == .qr })?.payloadStringValue
  }.value
}

