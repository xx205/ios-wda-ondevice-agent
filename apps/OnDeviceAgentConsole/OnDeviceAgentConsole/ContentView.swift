import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: ConsoleStore
  @State private var selectedTab: Tab = .run

  enum Tab: String {
    case run
    case logs
    case chat
    case notes
  }

  var body: some View {
    #if os(macOS)
    let sidebarSelection = Binding<Tab?>(
      get: { selectedTab },
      set: { newValue in
        if let newValue { selectedTab = newValue }
      }
    )
    NavigationSplitView {
      List(selection: sidebarSelection) {
        Label("Run", systemImage: "slider.horizontal.3").tag(Tab.run)
        Label("Logs", systemImage: "doc.plaintext").tag(Tab.logs)
        Label("Chat", systemImage: "text.bubble").tag(Tab.chat)
        Label("Notes", systemImage: "note.text").tag(Tab.notes)
      }
      .listStyle(.sidebar)
      .frame(minWidth: 190)
    } detail: {
      VStack(spacing: 0) {
        Group {
          switch selectedTab {
          case .run:
            RunView()
          case .logs:
            LogsView()
          case .chat:
            ChatView()
          case .notes:
            NotesView()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    #else
    TabView(selection: $selectedTab) {
      VStack(spacing: 0) {
        RunView()
      }
      .tabItem { Label("Run", systemImage: "slider.horizontal.3") }
      .tag(Tab.run)

      VStack(spacing: 0) {
        LogsView()
      }
      .tabItem { Label("Logs", systemImage: "doc.plaintext") }
      .tag(Tab.logs)

      VStack(spacing: 0) {
        ChatView()
      }
      .tabItem { Label("Chat", systemImage: "text.bubble") }
      .tag(Tab.chat)

      VStack(spacing: 0) {
        NotesView()
      }
      .tabItem { Label("Notes", systemImage: "note.text") }
      .tag(Tab.notes)
    }
    #endif
  }
}

