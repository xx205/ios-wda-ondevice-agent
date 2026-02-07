import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
extension Image {
  init(platformImage: PlatformImage) {
    self.init(uiImage: platformImage)
  }
}
#elseif canImport(AppKit)
extension Image {
  init(platformImage: PlatformImage) {
    self.init(nsImage: platformImage)
  }
}
#endif

struct ActionAnnotation: Equatable {
  enum Kind: Equatable {
    case tap(CGPoint)  // normalized 0..1000
    case swipe(start: CGPoint, end: CGPoint)  // normalized 0..1000
    case label
  }

  let name: String
  let kind: Kind

  static func buildMap(from chatItems: [AgentChatItem]) -> [Int: ActionAnnotation] {
    // Prefer the last parseable response per step (e.g. repair attempts).
    // Chat items preserve chronological order.
    var byStep: [Int: [AgentChatItem]] = [:]
    for it in chatItems {
      guard it.kind == "response", let step = it.step else { continue }
      byStep[step, default: []].append(it)
    }

    var out: [Int: ActionAnnotation] = [:]
    for (step, items) in byStep {
      // Scan backwards, pick first parseable action.
      for it in items.reversed() {
        guard let content = it.content, !content.isEmpty else { continue }
        if let ann = parse(from: content) {
          out[step] = ann
          break
        }
      }
    }
    return out
  }

  private static func parse(from jsonText: String) -> ActionAnnotation? {
    guard let data = jsonText.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any]
    else { return nil }
    guard let action = dict["action"] as? [String: Any] else { return nil }
    guard let name = action["name"] as? String else { return nil }
    let params = action["params"] as? [String: Any] ?? [:]

    let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower == "tap" || lower == "doubletap" || lower == "double tap" || lower == "longpress" || lower == "long press" {
      if let p = point(from: params["element"]) {
        return ActionAnnotation(name: name, kind: .tap(p))
      }
      return ActionAnnotation(name: name, kind: .label)
    }

    if lower == "swipe" {
      if let s = point(from: params["start"]), let e = point(from: params["end"]) {
        return ActionAnnotation(name: name, kind: .swipe(start: s, end: e))
      }
      return ActionAnnotation(name: name, kind: .label)
    }

    return ActionAnnotation(name: name, kind: .label)
  }

  private static func point(from obj: Any?) -> CGPoint? {
    guard let arr = obj as? [Any], arr.count >= 2 else { return nil }
    guard let x = dbl(arr[0]), let y = dbl(arr[1]) else { return nil }
    return CGPoint(x: x, y: y)
  }

  private static func dbl(_ obj: Any?) -> Double? {
    if let d = obj as? Double { return d }
    if let i = obj as? Int { return Double(i) }
    if let n = obj as? NSNumber { return n.doubleValue }
    if let s = obj as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
  }

  fileprivate static func toViewPoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
    let x = max(0, min(1000, normalized.x))
    let y = max(0, min(1000, normalized.y))
    let px = (x / 1000.0) * size.width
    let py = (y / 1000.0) * size.height
    return CGPoint(x: px, y: py)
  }
}

struct AnnotatedScreenshotCard: View {
  let image: PlatformImage
  let annotation: ActionAnnotation?

  var body: some View {
    ZStack {
      Image(platformImage: image)
        .resizable()
        .scaledToFit()

      if let annotation {
        ActionOverlay(annotation: annotation)
          .allowsHitTesting(false)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(.secondary.opacity(0.25), lineWidth: 1)
    )
  }
}

private struct ActionOverlay: View {
  let annotation: ActionAnnotation

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        labelBadge

        switch annotation.kind {
        case .tap(let p):
          let pt = ActionAnnotation.toViewPoint(p, in: geo.size)
          tapMarker(at: pt)

        case .swipe(let s, let e):
          let start = ActionAnnotation.toViewPoint(s, in: geo.size)
          let end = ActionAnnotation.toViewPoint(e, in: geo.size)
          swipeMarker(from: start, to: end)

        case .label:
          EmptyView()
        }
      }
    }
  }

  private var labelBadge: some View {
    Text(annotation.name)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.black.opacity(0.55))
      .foregroundStyle(.white)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .padding(8)
  }

  private func tapMarker(at pt: CGPoint) -> some View {
    let color = Color.red
    return ZStack {
      Circle()
        .fill(color.opacity(0.22))
        .frame(width: 44, height: 44)
        .position(pt)

      Circle()
        .stroke(color, lineWidth: 2)
        .frame(width: 44, height: 44)
        .position(pt)

      Circle()
        .fill(color)
        .frame(width: 10, height: 10)
        .position(pt)
    }
  }

  private func swipeMarker(from start: CGPoint, to end: CGPoint) -> some View {
    let color = Color.red
    return ZStack {
      Path { p in
        p.move(to: start)
        p.addLine(to: end)
      }
      .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

      Circle()
        .fill(color)
        .frame(width: 10, height: 10)
        .position(start)

      arrowHead(from: start, to: end)
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
  }

  private func arrowHead(from start: CGPoint, to end: CGPoint) -> Path {
    var path = Path()
    let dx = end.x - start.x
    let dy = end.y - start.y
    let angle = atan2(dy, dx)
    let length: CGFloat = 14
    let spread: CGFloat = 0.55

    let p1 = CGPoint(
      x: end.x - length * cos(angle - spread),
      y: end.y - length * sin(angle - spread)
    )
    let p2 = CGPoint(
      x: end.x - length * cos(angle + spread),
      y: end.y - length * sin(angle + spread)
    )
    path.move(to: end)
    path.addLine(to: p1)
    path.move(to: end)
    path.addLine(to: p2)
    return path
  }
}
