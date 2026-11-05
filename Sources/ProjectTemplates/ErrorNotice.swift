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
                Button { m.error = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss this message")
                    .accessibilityLabel("Dismiss error message")
            }
            .padding(Space.md)
            .background(Surface.control)
            .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    func errorNotice() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { ErrorNotice() }
    }
}
