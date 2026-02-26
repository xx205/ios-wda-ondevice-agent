import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

struct LogsView: View {
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
            format: NSLocalizedString(
              "Δ(in=%d, out=%d, cached=%d, total=%d)  cum(in=%d, out=%d, cached=%d, total=%d)",
              comment: ""
            ),
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

