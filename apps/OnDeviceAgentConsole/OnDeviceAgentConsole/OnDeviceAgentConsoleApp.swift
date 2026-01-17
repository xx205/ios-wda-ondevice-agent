import SwiftUI

@main
struct OnDeviceAgentConsoleApp: App {
  @StateObject private var store = ConsoleStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .task {
          await store.boot()
        }
    }
  }
}

