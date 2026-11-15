import SwiftUI
import AppKit
import Charts
import SocialsCore

// The Socials page. YouTube only for now: every figure is one the API returned, shown as returned (no sums, no net
// subscribers, no growth). Instagram, TikTok and X would add their own tile and cards beside YouTube's, never blended.

/// YouTube's mark drawn in SwiftUI (no trademark asset files): a red rounded rectangle with a white play triangle.
struct YouTubeMark: View {
    var height: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: height * 0.28)
            .fill(Color(red: 1, green: 0, blue: 0))
            .frame(width: height * 1.4, height: height)
            .overlay {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 1, y: 0.5)); p.addLine(to: CGPoint(x: 0, y: 1)); p.closeSubpath()
                }
                .applying(CGAffineTransform(scaleX: height * 0.36, y: height * 0.4))
                .fill(.white)
                .frame(width: height * 0.36, height: height * 0.4)
                .padding(.leading, height * 0.08)
            }
            .accessibilityLabel("YouTube")
    }
}

/// A Socials card: the same filled, hairline-bordered surface as the Pipeline columns.
private struct SocialsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).font(TypeStyle.headline)
            content()
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Surface.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(.separator, lineWidth: 1))
    }
}

/// One label and its figure on a card row.
private struct FigureRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(TypeStyle.callout)
        .accessibilityElement(children: .combine)
    }
}

struct SocialsPage: View {
    @ObservedObject var s: SocialsModel
    @EnvironmentObject var m: AppModel

    var body: some View {
        Group {
            switch s.phase() {
            case .setup: SocialsSetupCard(s: s)
            case .connect: SocialsConnectCard(s: s)
            case .expired: expired
            case .needsReconnect, .connected: SocialsDashboard(s: s)
            }
        }
        .gridArea("socials")
        .background(Surface.secondary)
        // Read at once when shown and every 15 minutes while it stays shown; .task ends when the page goes away.
        .task(id: s.configured) {
            guard SocialsModel.liveFetch, s.configured else { return }
            while !Task.isCancelled {
                await s.syncQuietly()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
        .task(id: s.range) { if SocialsModel.liveFetch, s.snapshot.history[s.range] == nil { await s.syncQuietly() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the browser after connecting YouTube: read again.
            if SocialsModel.liveFetch { Task { await s.syncQuietly() } }
        }
    }

    private var expired: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "wifi.slash").font(TypeStyle.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Offline, data expired").font(TypeStyle.title2)
            Text("CreatorOS has not reached the Socials server for 7 days, so your figures are hidden until it does.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 400)
            Button("Try Again") { Task { try? await s.sync() } }
                .help("Contact the Socials server now")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Before set-up: what Socials does, the privacy note, the server address and the one-time code.
struct SocialsSetupCard: View {
    @ObservedObject var s: SocialsModel
    @State private var code = ""
    var body: some View {
        ScrollView {
            SocialsCard(title: "Socials") {
                Text("See your YouTube channel's figures here: subscribers, daily views, watch time and subscribers gained and lost, read every 15 minutes by your own Socials server. Nothing changes in CreatorOS until you set it up.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Privacy").font(TypeStyle.callout.weight(.semibold))
                    Text("Socials uses YouTube API Services. Your sign-in stays on your Socials server, never on this Mac, and only you can see the figures. Disconnecting deletes them.")
                        .font(TypeStyle.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SocialsPolicyLinks(s: s)
                }
                Divider()
                Form {
                    TextField("Server address", text: $s.workerURL)
                        .help("Your social-stats Worker, starting with https://")
                    TextField("One-time code", text: $code)
                        .help("The enrolment code set when the Worker was deployed, or a pairing code from another device")
                }
                .formStyle(.columns)
                HStack(spacing: Space.md) {
                    Button("Set Up") { Task { try? await s.setUp(url: s.workerURL, code: code) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || s.working != nil)
                        .keyboardShortcut(.defaultAction)
                        .help("Enrol this Mac with your Socials server")
                    if s.working != nil { ProgressView().controlSize(.small) }
                    if let message = s.message { Text(message).font(TypeStyle.callout).foregroundStyle(.red) }
                }
            }
            .frame(maxWidth: 560)
            .padding(Space.xl)
            .frame(maxWidth: .infinity)
        }
    }
}

struct SocialsPolicyLinks: View {
    @ObservedObject var s: SocialsModel
    var body: some View {
        HStack(spacing: Space.lg) {
            Link("YouTube Terms of Service", destination: URL(string: "https://www.youtube.com/t/terms")!)
                .help("https://www.youtube.com/t/terms")
            Link("Google Privacy Policy", destination: URL(string: "https://policies.google.com/privacy")!)
                .help("https://policies.google.com/privacy")
            if let server = SocialsModel.validatedURL(s.workerURL) {
                Link("Socials privacy policy", destination: server.appendingPathComponent("privacy"))
                    .help(server.appendingPathComponent("privacy").absoluteString)
            }
        }
        .font(TypeStyle.callout)
    }
}

/// Enrolled, YouTube not connected yet.
struct SocialsConnectCard: View {
    @ObservedObject var s: SocialsModel
    var body: some View {
        ScrollView {
            SocialsCard(title: "Connect YouTube") {
                HStack(alignment: .top, spacing: Space.md) {
                    YouTubeMark(height: 24)
                    Text("Connect opens Google's consent page in your browser. Your Socials server asks only for read-only access to your channel's statistics and analytics. Come back here when it says connected.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.md) {
                    Button("Connect") { Task { await SocialsActions.connect(s) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(s.working != nil)
                        .help("Open Google's consent page in your default browser")
                    Button("Check Again") { Task { try? await s.sync() } }
                        .help("Read the connection state from your Socials server")
                    if s.working != nil { ProgressView().controlSize(.small) }
                    if let message = s.message { Text(message).font(TypeStyle.callout).foregroundStyle(.red) }
                }
                SocialsPolicyLinks(s: s)
            }
            .frame(maxWidth: 560)
            .padding(Space.xl)
            .frame(maxWidth: .infinity)
        }
    }
}

enum SocialsActions {
    /// Asks the Worker for the consent address and opens it in the default browser. Never during invisible checks.
    @MainActor static func connect(_ s: SocialsModel) async {
        guard let url = try? await s.connectURL() else { return }
        if !AgentScreen.active { NSWorkspace.shared.open(url) }
    }
}

/// Connected (or lapsed): the tile, the chart and the three cards.
struct SocialsDashboard: View {
    @ObservedObject var s: SocialsModel
    var body: some View {
        let lapsed = s.phase() == .needsReconnect
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if lapsed { reconnectBanner.gridProbe("socials-banner", area: "socials") }
                if s.unreachable || s.message != nil { notice }
                tile.gridProbe("socials-tile", area: "socials")
                HStack(alignment: .top, spacing: Space.lg) {
                    SocialsChartCard(s: s).gridProbe("socials-chart", area: "socials")
                    VStack(spacing: Space.lg) {
                        windowCard
                        videoCard
                        coverageCard
                    }
                    .frame(width: 320)
                    .gridProbe("socials-panel", area: "socials", edge: nil)
                }
                .saturation(lapsed ? 0 : 1)
                .opacity(lapsed ? 0.6 : 1)
            }
            .padding(Space.xl)
        }
    }

    private var reconnectBanner: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("YouTube needs reconnecting").font(TypeStyle.callout.weight(.semibold))
                Text("These are the last figures read. Last good read: " + SocialsFormat.readTime(s.youtubeStatus?.lastGoodReadAt).replacingOccurrences(of: "Read ", with: ""))
                    .font(TypeStyle.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reconnect") { Task { await SocialsActions.connect(s) } }
                .buttonStyle(.borderedProminent)
                .disabled(s.working != nil)
                .help("Sign in to YouTube again in your browser")
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1))
    }

    private var notice: some View {
        Text(s.unreachable ? "Couldn't reach the Socials server. Showing the figures from its last read." : (s.message ?? ""))
            .font(TypeStyle.caption).foregroundStyle(.secondary)
            .accessibilityLabel(s.unreachable ? "Couldn't reach the Socials server" : (s.message ?? ""))
    }

    private var tile: some View {
        let yt = s.youtube
        return HStack(alignment: .center, spacing: Space.lg) {
            YouTubeMark(height: 28)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(yt?.channelTitle ?? "YouTube").font(TypeStyle.headline).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    if yt?.subscriberCountHidden == true {
                        Text("Subscriber count hidden").font(TypeStyle.title2)
                    } else {
                        Text(SocialsFormat.count(yt?.subscriberCount)).font(TypeStyle.largeTitle.weight(.semibold)).monospacedDigit()
                        Text("subscribers").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: Space.sm) {
                    if yt?.subscriberCountHidden != true { Text("Rounded by YouTube") }
                    Text(SocialsFormat.readTime(yt?.countsReadAt))
                }
                .font(TypeStyle.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.lg)
            SocialsSparkline(days: s.days())
                .frame(width: 160, height: 40)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Surface.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(.separator, lineWidth: 1))
    }

    private var windowCard: some View {
        SocialsCard(title: "Last 28 days YouTube reports") {
            if let w = s.youtube?.window {
                HStack(spacing: Space.sm) {
                    Text(SocialsFormat.dateRange(w.startDate, w.endDate)).font(TypeStyle.callout).foregroundStyle(.secondary)
                    if w.partial {
                        Text("Partial").font(TypeStyle.caption.weight(.semibold))
                            .padding(.horizontal, Space.sm).padding(.vertical, Space.xxs)
                            .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                            .help("YouTube returned fewer than 28 days in this range")
                    }
                }
                FigureRow(label: "Views", value: SocialsFormat.count(w.views))
                FigureRow(label: "Watch time", value: SocialsFormat.hours(fromMinutes: w.estimatedMinutesWatched))
                FigureRow(label: "Subscribers gained", value: SocialsFormat.count(w.subscribersGained))
                FigureRow(label: "Subscribers lost", value: SocialsFormat.count(w.subscribersLost))
                Text(SocialsFormat.readTime(w.readAt)).font(TypeStyle.caption).foregroundStyle(.secondary)
            } else {
                Text("YouTube has not reported this window yet.").font(TypeStyle.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var videoCard: some View {
        SocialsCard(title: "Newest video") {
            if let video = s.youtube?.newestVideo {
                Button {
                    if !AgentScreen.active { NSWorkspace.shared.open(video.url) }
                } label: {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(video.title).font(TypeStyle.callout.weight(.medium)).lineLimit(1)
                        HStack {
                            Text(video.publishedAt.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(SocialsFormat.count(video.viewCount) + " views").monospacedDigit()
                        }
                        .font(TypeStyle.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open “\(video.title)” on YouTube")
                .accessibilityLabel("Newest video, \(video.title), \(SocialsFormat.count(video.viewCount)) views. Opens on YouTube.")
            } else {
                Text("No public video found.").font(TypeStyle.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var coverageCard: some View {
        SocialsCard(title: "Coverage") {
            let status = s.youtubeStatus
            FigureRow(label: "Last good read", value: SocialsFormat.readTime(status?.lastGoodReadAt).replacingOccurrences(of: "Read ", with: ""))
            FigureRow(label: "Read interval", value: status.map { "Every \($0.readIntervalMinutes) min" } ?? "–")
            FigureRow(label: "Gaps in the last 7 days", value: status.map { $0.gaps.isEmpty ? "None" : "\($0.gaps.count)" } ?? "–")
            if let gaps = status?.gaps, !gaps.isEmpty {
                ForEach(Array(gaps.suffix(3).enumerated()), id: \.offset) { _, gap in
                    Text(gap.from.formatted(date: .abbreviated, time: .shortened) + " to " + gap.to.formatted(date: .omitted, time: .shortened))
                        .font(TypeStyle.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SocialsSparkline: View {
    let days: [SocialsDay]
    var body: some View {
        Chart(days.filter { $0.row != nil }) { day in
            LineMark(x: .value("Day", day.date, unit: .day), y: .value("Views", day.row?.views ?? 0))
                .foregroundStyle(Color.red)
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .accessibilityLabel("Daily views sparkline")
    }
}

/// The main chart: one bar per day YouTube reported, the unreported days tinted, the exact figure on hover.
struct SocialsChartCard: View {
    @ObservedObject var s: SocialsModel
    @State private var hovered: Date?

    var body: some View {
        let days = s.days()
        let calendar = Calendar.current
        let start = days.first?.date ?? Date()
        let end = calendar.date(byAdding: .day, value: 1, to: days.last?.date ?? Date()) ?? Date()
        let gap = s.notYetReportedStart()
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Daily").font(TypeStyle.headline)
                Spacer()
                Picker("Figure", selection: $s.metric) {
                    ForEach(SocialsMetric.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Choose which daily figure to chart")
            }
            Chart {
                if let gap {
                    RectangleMark(xStart: .value("From", gap), xEnd: .value("To", end))
                        .foregroundStyle(Color.secondary.opacity(0.14))
                        .annotation(position: .overlay, alignment: .top) {
                            Text("Not yet reported").font(TypeStyle.caption2).foregroundStyle(.secondary)
                        }
                }
                ForEach(days.filter { $0.row != nil }) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value(s.metric.title, s.metric.value(day.row!)))
                        .foregroundStyle(Color.red.opacity(hovered == nil || hovered == day.date ? 0.85 : 0.4))
                }
                if let hovered {
                    RuleMark(x: .value("Day", hovered, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            hoverLabel(hovered, days: days)
                        }
                }
            }
            .chartXScale(domain: start...end)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let origin = proxy.plotFrame.map { geometry[$0].origin } ?? .zero
                                if let date: Date = proxy.value(atX: point.x - origin.x) { hovered = calendar.startOfDay(for: date) }
                            case .ended: hovered = nil
                            }
                        }
                }
            }
            .frame(minHeight: 280)
            .accessibilityLabel("Daily \(s.metric.title.lowercased()) for the last \(s.range) days")
            Text(s.snapshot.history[s.range].map { SocialsFormat.readTime($0.readAt) } ?? "Not read yet")
                .font(TypeStyle.caption).foregroundStyle(.secondary)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Surface.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(.separator, lineWidth: 1))
    }

    private func hoverLabel(_ date: Date, days: [SocialsDay]) -> some View {
        let row = days.first { $0.date == date }?.row
        return VStack(alignment: .leading, spacing: Space.xxs) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(TypeStyle.caption.weight(.semibold))
            Text(row.map(s.metric.label) ?? "Not yet reported").font(TypeStyle.caption).monospacedDigit()
        }
        .padding(Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Surface.window))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(.separator, lineWidth: 1))
    }
}

/// Toolbar: range, Refresh and Accounts. The Accounts sheet hangs here too.
struct SocialsPageChrome: ViewModifier {
    @ObservedObject var s: SocialsModel
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if s.configured {
                        Picker("Range", selection: $s.range) {
                            ForEach(SocialsModel.ranges, id: \.self) { Text("\($0) days").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .help("How many days the chart shows")
                        Button { Task { try? await s.refreshNow() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(s.working != nil || s.phase() == .connect)
                            .help("Ask your Socials server to read YouTube now (at most once a minute)")
                        Button { s.accountsPresented = true } label: { Label("Accounts", systemImage: "person.crop.circle") }
                            .help("Connected accounts, devices and Socials data")
                    }
                }
            }
            .sheet(isPresented: $s.accountsPresented) { SocialsAccountsSheet(s: s) }
    }
}

/// Connect, reconnect and disconnect YouTube, enrolled devices, pairing, privacy and data deletion.
struct SocialsAccountsSheet: View {
    @ObservedObject var s: SocialsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @State private var confirmDeleteAll = false
    @State private var confirmClear = false
    @State private var revoking: SocialsDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Socials Accounts").font(TypeStyle.title2)
            Form {
                Section("YouTube") {
                    HStack(spacing: Space.md) {
                        YouTubeMark(height: 20)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(s.youtubeStatus?.account ?? s.youtube?.channelTitle ?? "Not connected")
                            Text(stateText).font(TypeStyle.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch s.phase() {
                        case .connect:
                            Button("Connect") { Task { await SocialsActions.connect(s) } }.help("Open Google's consent page in your browser")
                        case .needsReconnect:
                            Button("Reconnect") { Task { await SocialsActions.connect(s) } }.help("Sign in to YouTube again in your browser")
                            Button("Disconnect…", role: .destructive) { confirmDisconnect = true }.help("Disconnect YouTube and delete its data on your Socials server")
                        default:
                            Button("Disconnect…", role: .destructive) { confirmDisconnect = true }.help("Disconnect YouTube and delete its data on your Socials server")
                        }
                    }
                }
                Section("Devices") {
                    ForEach(s.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(device.name + (device.current ? " (this Mac)" : ""))
                                Text(device.kind.capitalized + " · " + (device.lastSeenAt.map { "last seen " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "not seen yet"))
                                    .font(TypeStyle.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke…") { revoking = device }.help("Stop \(device.name) reading Socials")
                        }
                    }
                    if s.devices.isEmpty { Text("No devices listed yet.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Pair Another Device") { Task { _ = try? await s.pair() } }
                            .help("Make a 10-minute code to set Socials up on your iPhone or another Mac")
                        if let pairing = s.pairing {
                            Text(pairing.code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            Text("expires " + pairing.expiresAt.formatted(date: .omitted, time: .shortened)).font(TypeStyle.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Privacy and data") {
                    SocialsPolicyLinks(s: s)
                    HStack {
                        Button("Clear Socials Data on This Mac…") { confirmClear = true }
                            .help("Forget Socials on this Mac: its cached figures and device credential")
                        Button("Delete All Socials Data…", role: .destructive) { confirmDeleteAll = true }
                            .help("Delete every account's sign-in and figures on your Socials server")
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let message = s.message { Text(message).font(TypeStyle.callout).foregroundStyle(.red) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).help("Close Accounts")
            }
        }
        .padding(Space.xl)
        .frame(width: 600, height: 560)
        .task { try? await s.loadDevices() }
        .confirmationDialog("Disconnect YouTube?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { try? await s.disconnectYouTube() } }
        } message: { Text("Your Socials server revokes its access to YouTube and deletes your YouTube figures at once.") }
        .confirmationDialog("Delete all Socials data?", isPresented: $confirmDeleteAll) {
            Button("Delete All", role: .destructive) { Task { try? await s.deleteAll() } }
        } message: { Text("Every account's sign-in and figures are deleted on your Socials server. Your devices stay set up.") }
        .confirmationDialog("Clear Socials data on this Mac?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { Task { await s.clearLocal(); dismiss() } }
        } message: { Text("This Mac forgets its cached figures and its device credential, and asks your Socials server to revoke it. You will need a new code to set it up again.") }
        .confirmationDialog(revoking?.current == true ? "Revoke this Mac?" : "Revoke \(revoking?.name ?? "device")?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { device in
            Button("Revoke", role: .destructive) { Task { if (try? await s.revoke(device.id)) == true { dismiss() } } }
        } message: { device in
            Text(device.current ? "This is the Mac you are using. It will stop showing Socials and forget its data here." : "\(device.name) will stop reading Socials. It needs a new pairing code to come back.")
        }
    }

    private var stateText: String {
        switch s.phase() {
        case .connect: "Not connected"
        case .needsReconnect: "Needs reconnecting"
        case .expired: "Offline, data expired"
        case .setup: "Not set up"
        case .connected: SocialsFormat.readTime(s.youtubeStatus?.lastGoodReadAt ?? s.youtube?.countsReadAt)
        }
    }
}
