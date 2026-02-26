import SwiftUI

struct LimitField: View {
  let title: LocalizedStringKey
  let help: LocalizedStringKey
  let placeholder: LocalizedStringKey
  @Binding var text: String
  let keyboard: OnDeviceAgentKeyboard

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      #if os(macOS)
      TextField("", text: $text, prompt: Text(placeholder))
        .onDeviceAgentKeyboard(keyboard)
        .multilineTextAlignment(.trailing)
        .font(.system(.body, design: .monospaced))
      #else
      TextField(placeholder, text: $text)
        .onDeviceAgentKeyboard(keyboard)
        #if canImport(UIKit)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .multilineTextAlignment(.trailing)
        .font(.system(.body, design: .monospaced))
      #endif

      Text(help)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .lineSpacing(2)
    }
    .padding(.vertical, 2)
  }
}

struct ToggleField: View {
  let title: LocalizedStringKey
  let help: LocalizedStringKey?
  @Binding var isOn: Bool

  init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
    self.title = title
    help = nil
    _isOn = isOn
  }

  init(_ title: LocalizedStringKey, help: LocalizedStringKey, isOn: Binding<Bool>) {
    self.title = title
    self.help = help
    _isOn = isOn
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isOn: $isOn) {
        Text(title)
          .font(.headline)
      }

      if let help {
        Text(help)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(2)
      }
    }
    .padding(.vertical, 2)
  }
}

struct ActionButtonField: View {
  let title: LocalizedStringKey
  let help: LocalizedStringKey?
  let role: ButtonRole?
  let disabled: Bool
  let action: () -> Void

  init(
    _ title: LocalizedStringKey,
    help: LocalizedStringKey? = nil,
    disabled: Bool = false,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.help = help
    self.disabled = disabled
    self.role = role
    self.action = action
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 0) {
        Button(role: role, action: action) {
          Text(title)
            .font(.headline)
            #if os(macOS)
            .foregroundStyle(role == .destructive ? .red : Color.accentColor)
            #endif
        }
        #if canImport(UIKit)
        .buttonStyle(.borderless)
        #endif
        #if os(macOS)
        .buttonStyle(.link)
        .controlSize(.regular)
        .font(.headline)
        #endif
        .disabled(disabled)

        Spacer(minLength: 0)
      }

      if let help {
        Text(help)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(2)
      }
    }
    .padding(.vertical, 2)
  }
}

struct InlineEditHeader: View {
  let title: LocalizedStringKey
  let onEdit: () -> Void

  init(_ title: LocalizedStringKey, onEdit: @escaping () -> Void) {
    self.title = title
    self.onEdit = onEdit
  }

  var body: some View {
    HStack {
      Text(title)
        .font(.headline)
      Spacer()
      Button("Edit", action: onEdit)
        .font(.footnote)
      #if canImport(UIKit)
        .buttonStyle(.borderless)
      #endif
      #if os(macOS)
        .buttonStyle(.link)
      #endif
    }
  }
}

struct ConfigField: View {
  let title: LocalizedStringKey
  let help: String
  let placeholder: String
  @Binding var text: String
  let keyboard: OnDeviceAgentKeyboard
  let collapsibleHelp: Bool
  let helpTitle: LocalizedStringKey = "Help"

  init(
    title: LocalizedStringKey,
    help: String,
    placeholder: String,
    text: Binding<String>,
    keyboard: OnDeviceAgentKeyboard,
    collapsibleHelp: Bool = false
  ) {
    self.title = title
    self.help = help
    self.placeholder = placeholder
    _text = text
    self.keyboard = keyboard
    self.collapsibleHelp = collapsibleHelp
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      #if os(macOS)
      TextField("", text: $text, prompt: Text(placeholder))
        .onDeviceAgentKeyboard(keyboard)
        .font(.system(.body, design: .monospaced))
      #else
      TextField(placeholder, text: $text)
        .onDeviceAgentKeyboard(keyboard)
        #if canImport(UIKit)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .font(.system(.body, design: .monospaced))
      #endif

      let helpText = NSLocalizedString(help, comment: "")
      if !helpText.isEmpty {
        if collapsibleHelp {
          DisclosureGroup(helpTitle) {
            Text(verbatim: helpText)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .lineSpacing(2)
              .padding(.top, 4)
          }
        } else {
          Text(verbatim: helpText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct ConfigPicker: View {
  typealias Option = (title: LocalizedStringKey, value: String)

  let title: LocalizedStringKey
  let help: String?
  @Binding var selection: String
  let options: [Option]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)

      Picker("", selection: $selection) {
        ForEach(options, id: \.value) { opt in
          Text(opt.title).tag(opt.value)
        }
      }
      .pickerStyle(.segmented)

      if let help {
        Text(verbatim: NSLocalizedString(help, comment: ""))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .lineSpacing(2)
      }
    }
    .padding(.vertical, 2)
  }
}

