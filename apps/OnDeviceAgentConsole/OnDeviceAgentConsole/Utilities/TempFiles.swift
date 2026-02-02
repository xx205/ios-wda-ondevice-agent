import Foundation
import UIKit

func OnDeviceAgentWriteTempText(_ text: String, filename: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  guard let data = text.data(using: .utf8) else {
    throw NSError(domain: "OnDeviceAgentConsole", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot encode text as UTF-8"])
  }
  try data.write(to: url, options: .atomic)
  return url
}

func OnDeviceAgentWriteTempPNG(_ image: UIImage, filename: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
  guard let data = image.pngData() else {
    throw NSError(domain: "OnDeviceAgentConsole", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
  }
  try data.write(to: url, options: .atomic)
  return url
}

