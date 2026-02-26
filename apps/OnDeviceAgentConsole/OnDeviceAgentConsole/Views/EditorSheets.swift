import SwiftUI

struct TextEditorSheet: View {
  let title: LocalizedStringKey
  @Binding var text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 8)
        .navigationTitle(title)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }
}

struct SystemPromptEditorSheet: View {
  let title: LocalizedStringKey
  @Binding var systemPrompt: String
  let defaultTemplate: String
  @Environment(\.dismiss) private var dismiss

  @State private var draft: String = ""

  var body: some View {
    NavigationStack {
      TextEditor(text: $draft)
        .font(.system(.body, design: .monospaced))
        .padding(.horizontal, 8)
        .navigationTitle(title)
        .onAppear {
          if draft.isEmpty {
            draft = systemPrompt.isEmpty ? defaultTemplate : systemPrompt
          }
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Restore Default Template") {
              draft = defaultTemplate
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              // If the user never had a custom prompt and didn't change the default template,
              // keep systemPrompt empty to avoid persisting the built-in template as "custom".
              if draft == defaultTemplate {
                systemPrompt = ""
              } else {
                systemPrompt = draft
              }
              dismiss()
            }
          }
        }
    }
  }
}

