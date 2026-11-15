import Foundation

/// A snapshot shaped like docs/SOCIALS-API.md, for the widget gallery placeholder and the render tests.
enum SocialsFixture {
    static let read = Date(timeIntervalSince1970: 1_794_751_500) // 2026-11-15 14:05 UTC

    static func snapshot(state: PlatformState = .connected, window: Bool = true, partial: Bool = false, connection: String = "conn-A") -> SocialsSnapshot {
        let rows: [SocialsHistory.Row] = (0..<28).map { i in
            let day = Date(timeIntervalSince1970: 1_792_108_800 + Double(i) * 86_400) // from 2026-10-16
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            let views = 1_200 + Int(500 * sin(Double(i) / 3)) + i * 15
            return .init(date: f.string(from: day), views: views, estimatedMinutesWatched: views * 2, subscribersGained: 3, subscribersLost: 0)
        }
        let w = AnalyticsWindow(startDate: "2026-10-16", endDate: "2026-11-12", partial: partial,
                                views: rows.reduce(0) { $0 + $1.views }, estimatedMinutesWatched: 215_040,
                                subscribersGained: 90, subscribersLost: 4, readAt: read)
        let video = Video(id: "abc", title: "Why Yamal is better than Doué in the Champions League", publishedAt: read,
                          viewCount: 12_408, url: URL(string: "https://youtu.be/abc")!)
        let yt = YouTubeSummary(state: state, channelTitle: "Junior Nkana Bassi", subscriberCount: 4_810, countsReadAt: read,
                                window: window ? w : nil, newestVideo: video, connectionId: connection)
        let status = SocialsStatus(serverTime: read, platforms: [.init(platform: "youtube", state: state, account: "Junior Nkana Bassi",
                                   lastGoodReadAt: read, lastAttemptAt: read, lastError: nil, readIntervalMinutes: 15, gaps: [])], deletions: [])
        let history = SocialsHistory(platform: "youtube", readAt: read, rows: rows, lastReportedDate: "2026-11-12", connectionId: connection)
        return SocialsSnapshot(summary: .init(serverTime: read, youtube: yt), status: status, history: [28: history], lastContact: read)
    }
}
