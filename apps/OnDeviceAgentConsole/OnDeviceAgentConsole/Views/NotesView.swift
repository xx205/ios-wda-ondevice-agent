import SwiftUI

struct NotesView: View {
  @EnvironmentObject private var store: ConsoleStore

  var body: some View {
    NavigationStack {
      let notes = store.status?.notes ?? ""
      Group {
        if notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView(
            NSLocalizedString("No notes yet", comment: ""),
            systemImage: "note.text",
            description: Text(NSLocalizedString("The agent writes here via the Note action.", comment: ""))
          )
          .padding(.horizontal, 20)
        } else {
          ScrollView {
            Text(notes)
              .font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
          }
        }
      }
      .navigationTitle("Notes")
    }
  }
}

