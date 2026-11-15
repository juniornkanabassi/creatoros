import SwiftUI

@main
struct CreatorOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.hasToken { TodayView(model: model) } else { SetupView(model: model) }
            }
            .preferredColorScheme(.dark)
            .task { await model.sync(force: false) }
        }
    }
}

struct SetupView: View {
    @Bindable var model: AppModel
    @State private var worker = Companion.defaultWorker
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("CreatorOS shows your YouTube channel figures using YouTube API Services. It stores only what YouTube returns, and you can delete it at any time.")
                    Link("YouTube Terms of Service", destination: URL(string: "https://www.youtube.com/t/terms")!)
                    Link("Google Privacy Policy", destination: URL(string: "https://policies.google.com/privacy")!)
                    if let privacy = URL(string: worker)?.appendingPathComponent("privacy") {
                        Link("CreatorOS privacy policy", destination: privacy)
                    }
                } header: { Text("Privacy") }
                Section("Your Worker") {
                    TextField("Worker address", text: $worker)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Pairing code from your Mac", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let message = model.message { Section { Text(message).foregroundStyle(.red) } }
                Section {
                    Button("Set up") { Task { await model.setUp(worker: worker, code: code) } }
                        .disabled(model.busy || code.isEmpty)
                } footer: { Text("On your Mac, open CreatorOS, then Socials, then Accounts, and choose Pair iPhone.") }
            }
            .navigationTitle("CreatorOS")
        }
    }
}

struct TodayView: View {
    @Bindable var model: AppModel
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            List {
                SocialsCardView(state: model.state, snapshot: model.snapshot) {
                    Button { Task { await model.sync(force: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34).background(Palette.tile, in: Circle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Refresh").disabled(model.busy)
                }
                .padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)

                Section("YouTube") {
                    Text(model.statusText)
                    if let message = model.message { Text(message).foregroundStyle(.orange) }
                }
                Section {
                    Button("Clear data on this iPhone") { model.clearData() }
                    Button("Remove this iPhone", role: .destructive) { confirmRemove = true }
                } footer: { Text("Pull down to read YouTube now. It can be done once a minute.") }
            }
            .refreshable { await model.sync(force: true) }
            .navigationTitle("Today")
            .confirmationDialog("Remove this iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await model.removeDevice() } }
            } message: { Text("This deletes the token and every figure kept on this iPhone.") }
        }
    }
}
