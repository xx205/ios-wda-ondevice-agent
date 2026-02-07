import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

func OnDeviceAgentWriteTempText(_ text: String, filename: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  guard let data = text.data(using: .utf8) else {
    throw NSError(domain: "OnDeviceAgentConsole", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot encode text as UTF-8"])
  }
  try data.write(to: url, options: .atomic)
  return url
}

func OnDeviceAgentPNGData(from image: PlatformImage) -> Data? {
  #if canImport(UIKit)
  return image.pngData()
  #elseif canImport(AppKit)
  guard let tiff = image.tiffRepresentation else { return nil }
  guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
  return rep.representation(using: .png, properties: [:])
  #else
  return nil
  #endif
}

func OnDeviceAgentWriteTempPNG(_ image: PlatformImage, filename: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  guard let data = OnDeviceAgentPNGData(from: image) else {
    throw NSError(domain: "OnDeviceAgentConsole", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
  }
  try data.write(to: url, options: .atomic)
  return url
}
