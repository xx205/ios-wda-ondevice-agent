import SwiftUI

@main
struct OnDeviceAgentConsoleApp: App {
  @StateObject private var store = ConsoleStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .task {
          await store.boot()
        }
        .onChange(of: scenePhase) { _, next in
          guard next == .active else { return }
          Task {
            await store.refresh()
            await store.checkLocalNetworkAccess(force: true)
          }
        }
    }
  }
}
