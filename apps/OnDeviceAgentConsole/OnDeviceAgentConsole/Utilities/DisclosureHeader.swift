import SwiftUI

struct DisclosureHeader<Trailing: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let trailing: () -> Trailing

  init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
    self.title = title
    self.trailing = trailing
  }

  var body: some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.headline)
      Spacer()
      trailing()
    }
  }
}

extension DisclosureHeader where Trailing == EmptyView {
  init(_ title: LocalizedStringKey) {
    self.title = title
    self.trailing = { EmptyView() }
  }
}

