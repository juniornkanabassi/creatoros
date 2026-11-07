import SwiftUI

/// Keep the engine's precise cause and recovery wording intact, including paths and partial results.
struct ErrorNotice: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        if let message = m.error, m.storeUsable {
            HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message).font(TypeStyle.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let action = m.errorAction {
                    Button(action.title) { action.run() }.disabled(m.busy)
                }
                if m.canRetryUndo {
                    Button("Retry Undo") { m.retryUndo() }
                        .disabled(m.busy || m.writeLocked)
                        .help("Retry the undo after the current change finishes")
                }
                Button { m.error = nil } label: { Image(systemName: "xmark").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Dismiss this message")
                    .accessibilityLabel("Dismiss error message")
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.control)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    /// The notice takes its own row above the view. A top safe-area inset let split views and scroll views draw under it.
    func errorNotice() -> some View {
        VStack(spacing: 0) { ErrorNotice(); self }
    }
}
