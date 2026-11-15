import SwiftUI

enum Palette {
    static let card = Color(red: 0.106, green: 0.106, blue: 0.110)
    static let tile = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let dim = Color(white: 0.62)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let red = Color(red: 1.0, green: 0.30, blue: 0.27)
    static let youtube = Color(red: 1.0, green: 0.0, blue: 0.0)
}

private func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

private func clock(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = "HH:mm"
    return f.string(from: date)
}

/// The widget's content, also used by the app's Today view. `refresh` is the refresh button (an App Intent in the widget).
struct SocialsCardView<Refresh: View>: View {
    let state: SocialsDisplayState
    let snapshot: SocialsSnapshot
    var now: Date = Date()
    @ViewBuilder var refresh: Refresh

    private var yt: YouTubeSummary? { snapshot.summary?.youtube }
    private var window: AnalyticsWindow? { yt?.window }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch state {
            case .notSetUp: message("Open CreatorOS to set up", "iphone")
            case .loading: message("Open CreatorOS to load your numbers", "arrow.down.circle")
            case .expired: message("Offline, data expired", "wifi.slash", "Open CreatorOS when you are online.")
            case .notConnected: message("YouTube is not connected", "link", "Connect it from CreatorOS on your Mac.")
            case .needsReconnect, .waiting, .normal: content
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack {
            Text("Socials").font(rounded(24, .bold))
            Spacer()
            if state != .notSetUp, let last = snapshot.lastContact {
                Text("Updated \(clock(last))").font(rounded(14, .regular)).foregroundStyle(Palette.dim)
            }
        }
    }

    private func message(_ title: String, _ symbol: String, _ detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Palette.dim)
            Text(title).font(rounded(18)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(rounded(14, .regular)).foregroundStyle(Palette.dim).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Figures

    private var content: some View {
        let grey = state == .needsReconnect
        return VStack(alignment: .leading, spacing: 10) {
            if grey {
                Label("Reconnect on your Mac", systemImage: "exclamationmark.triangle.fill")
                    .font(rounded(14)).foregroundStyle(.orange)
            }
            Group {
                hero
                rows
                footer
            }
            .opacity(grey ? 0.4 : 1)
        }
    }

    private var views: [Double] {
        guard let h = snapshot.history[28] else { return [] }
        return h.rows.filter { h.lastReportedDate == nil || $0.date <= h.lastReportedDate! }.map { Double($0.views) }
    }

    private var hero: some View {
        let label = window.map { "YouTube views, \(SocialsFormat.dateRange($0.startDate, $0.endDate))" } ?? "YouTube views"
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).font(rounded(13, .regular)).foregroundStyle(Palette.dim).lineLimit(1).minimumScaleFactor(0.8)
                    if window?.partial == true {
                        Text("partial").font(rounded(11)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.tile, in: Capsule()).foregroundStyle(.orange)
                    }
                }
                if let window {
                    Text(SocialsFormat.count(window.views)).font(rounded(44, .bold)).minimumScaleFactor(0.6).lineLimit(1)
                } else {
                    Text("Waiting for YouTube's first report").font(rounded(16)).foregroundStyle(Palette.dim)
                }
            }
            Spacer(minLength: 8)
            Sparkline(values: views).frame(width: 130, height: 56).accessibilityHidden(true)
        }
        .padding(12)
        .background(Palette.tile.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.map { "\(label): \(SocialsFormat.count($0.views))" } ?? "Waiting for YouTube's first report")
    }

    private var rows: some View {
        let dates = window.map { SocialsFormat.dateRange($0.startDate, $0.endDate) }
        return VStack(spacing: 0) {
            row(mark: true, title: "Subscribers", caption: SocialsFormat.readTime(yt?.countsReadAt)) {
                figure(yt?.subscriberCountHidden == true ? "Hidden" : SocialsFormat.count(yt?.subscriberCount), size: 26)
            }
            Divider().overlay(Palette.tile)
            row(mark: false, title: "Watch time", caption: dates) {
                figure(SocialsFormat.hours(fromMinutes: window?.estimatedMinutesWatched), size: 22)
            }
            Divider().overlay(Palette.tile)
            row(mark: false, title: "Subscribers", caption: dates) {
                HStack(spacing: 18) {
                    labelled("Gained", window?.subscribersGained, Palette.green)
                    labelled("Lost", window?.subscribersLost, Palette.red)
                }
            }
        }
    }

    private func row<T: View>(mark: Bool, title: String, caption: String?, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            if mark { YouTubeMark() } else { Color.clear.frame(width: 32, height: 32) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(rounded(16))
                if let caption { Text(caption).font(rounded(11, .regular)).foregroundStyle(Palette.dim) }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func figure(_ text: String, size: CGFloat) -> some View {
        Text(text).font(rounded(size, .bold)).minimumScaleFactor(0.6).lineLimit(1)
    }

    private func labelled(_ name: String, _ n: Int?, _ colour: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(name).font(rounded(11, .regular)).foregroundStyle(Palette.dim)
            figure(SocialsFormat.count(n), size: 22).foregroundStyle(colour)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let video = yt?.newestVideo {
                VStack(alignment: .leading, spacing: 1) {
                    Text(video.title).font(rounded(14)).lineLimit(1)
                    Text("\(SocialsFormat.count(video.viewCount)) views").font(rounded(11, .regular)).foregroundStyle(Palette.dim)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 4)
            refresh
        }
    }
}

struct YouTubeMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.07))
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.youtube).frame(width: 22, height: 16)
            Triangle().fill(.white).frame(width: 7, height: 8).offset(x: 1)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The daily views rows exactly as returned, scaled to fit.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            if values.count >= 2 {
                let lo = values.min()!, hi = values.max()!
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: g.size.height * (hi == lo ? 0.5 : 1 - CGFloat((v - lo) / (hi - lo))))
                }
                let line = Path { p in p.addLines(pts) }
                let area = Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height)); p.addLine(to: CGPoint(x: 0, y: g.size.height)); p.closeSubpath()
                }
                area.fill(LinearGradient(colors: [Palette.green.opacity(0.35), Palette.green.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                line.stroke(Palette.green, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                Circle().fill(Palette.green).frame(width: 7, height: 7).position(pts.last!)
            }
        }
    }
}
