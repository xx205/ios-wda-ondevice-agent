import SwiftUI

struct LiveProgressPanel: View {
  let progress: ConsoleStore.LiveProgress
  let onJumpToStep: (() -> Void)?

  init(progress: ConsoleStore.LiveProgress, onJumpToStep: (() -> Void)? = nil) {
    self.progress = progress
    self.onJumpToStep = onJumpToStep
  }

  private func phaseText(_ phase: ConsoleStore.LiveProgress.Phase) -> String {
    switch phase {
    case .idle:
      return NSLocalizedString("Idle", comment: "")
    case .stopping:
      return NSLocalizedString("Stopping…", comment: "")
    case .callingModel:
      return NSLocalizedString("Calling model…", comment: "")
    case .parsingOutput:
      return NSLocalizedString("Parsing output…", comment: "")
    case .executingAction:
      return NSLocalizedString("Executing action…", comment: "")
    }
  }

  var body: some View {
    if progress.running {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text("Live")
            .font(.headline)

          Spacer()

          if let onJumpToStep, progress.step != nil {
            Button("Jump") {
              onJumpToStep()
            }
            #if os(macOS)
            .buttonStyle(.link)
            #endif
            .font(.footnote)
          }
        }

        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let step = progress.step {
            Text(String(format: NSLocalizedString("Step %d", comment: ""), step))
              .font(.system(.footnote, design: .monospaced))
          }

          Text(phaseText(progress.phase))
            .font(.footnote)
            .foregroundStyle(.secondary)

          if let action = progress.action, !action.isEmpty {
            Text(action)
              .font(.system(.footnote, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }

        if let next = progress.nextPlanItem, !next.isEmpty {
          Text(String(format: NSLocalizedString("Next: %@", comment: ""), next))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }

        if let t = progress.tokens {
          Text(
            String(
              format: NSLocalizedString(
                "Δ(in=%d, out=%d, cached=%d, total=%d)  cum(in=%d, out=%d, cached=%d, total=%d)",
                comment: ""
              ),
              t.delta.input,
              t.delta.output,
              t.delta.cached,
              t.delta.total,
              t.cumulative.input,
              t.cumulative.output,
              t.cumulative.cached,
              t.cumulative.total
            )
          )
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
        }
      }
      .padding(12)
      .background(Color.secondary.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .padding(.vertical, 4)
    }
  }
}

