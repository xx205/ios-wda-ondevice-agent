import SwiftUI

enum OnDeviceAgentKeyboard {
  case `default`
  case numberPad
  case decimalPad
  case URL
}

extension View {
  @ViewBuilder
  func onDeviceAgentKeyboard(_ keyboard: OnDeviceAgentKeyboard) -> some View {
    #if canImport(UIKit)
    switch keyboard {
    case .default:
      self.keyboardType(.default)
    case .numberPad:
      self.keyboardType(.numberPad)
    case .decimalPad:
      self.keyboardType(.decimalPad)
    case .URL:
      self.keyboardType(.URL)
    }
    #else
    self
    #endif
  }
}

func OnDeviceAgentDismissKeyboard() {
  #if canImport(UIKit)
  UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  #endif
}

