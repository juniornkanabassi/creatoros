import Foundation
import SocialsCore

/// SocialsCore against the shapes in docs/SOCIALS-API.md: decoding, the offline cache rules and the formatting.
func socialsChecks(base: URL) throws {
    // Shapes exactly as the contract writes them; times with and without fractional seconds.
    let status = Data("""
    {"serverTime":"2026-11-15T16:00:00Z","platforms":[{"platform":"youtube","state":"connected","account":"Junior Nkana Bassi",
     "lastGoodReadAt":"2026-11-15T15:45:00.123Z","lastAttemptAt":"2026-11-15T15:45:00Z","lastError":null,"readIntervalMinutes":15,
     "gaps":[{"from":"2026-11-12T10:00:00Z","to":"2026-11-12T10:45:00.5Z"}]}],
     "deletions":[{"platform":"youtube","at":"2026-11-01T09:00:00Z"}]}
    """.utf8)
    let summary = Data("""
    {"serverTime":"2026-11-15T16:00:00.000Z","youtube":{"state":"connected","channelTitle":"Junior Nkana Bassi","subscriberCount":4810,
     "subscriberCountHidden":false,"countsReadAt":"2026-11-15T15:45:00Z",
     "window":{"startDate":"2026-10-16","endDate":"2026-11-12","partial":false,"views":1234,"estimatedMinutesWatched":5678,
               "subscribersGained":90,"subscribersLost":4,"readAt":"2026-11-15T06:15:00.250Z"},
     "newestVideo":{"id":"abc","title":"A video","publishedAt":"2026-11-10T18:00:00Z","viewCount":321,"url":"https://www.youtube.com/watch?v=abc"}}}
    """.utf8)
    let history = Data("""
    {"platform":"youtube","readAt":null,"rows":[{"date":"2026-11-01","views":1,"estimatedMinutesWatched":2,"subscribersGained":3,"subscribersLost":0}],
     "lastReportedDate":"2026-11-12"}
    """.utf8)
    let s = try SocialsJSON.decoder.decode(SocialsStatus.self, from: status)
    let yt = s.platforms[0]
    try check(yt.state == .connected && yt.account == "Junior Nkana Bassi" && yt.readIntervalMinutes == 15 && yt.lastError == nil,
              "Socials status decodes as the contract writes it")
    try check(abs(yt.lastGoodReadAt!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) - 0.123) < 0.001 && yt.gaps.count == 1 && s.deletions.count == 1,
              "Socials times decode with and without fractional seconds")
    let sum = try SocialsJSON.decoder.decode(SocialsSummary.self, from: summary)
    try check(sum.youtube?.subscriberCount == 4810 && sum.youtube?.window?.subscribersLost == 4 && sum.youtube?.newestVideo?.viewCount == 321,
              "Socials summary decodes figures as returned")
    try check(try SocialsJSON.decoder.decode(SocialsSummary.self, from: Data(#"{"serverTime":"2026-11-15T16:00:00Z","youtube":null}"#.utf8)).youtube == nil,
              "Socials summary with YouTube not connected decodes")
    let h = try SocialsJSON.decoder.decode(SocialsHistory.self, from: history)
    try check(h.readAt == nil && h.rows.first?.subscribersGained == 3 && h.lastReportedDate == "2026-11-12", "Socials history decodes with a null read time")
    try rejects("Socials refuses a date that is not ISO 8601") {
        _ = try SocialsJSON.decoder.decode(SocialsHistory.self, from: Data(#"{"platform":"youtube","readAt":"15/11/2026","rows":[],"lastReportedDate":null}"#.utf8))
    }

    // The cache: its own file, hidden after 7 days without contact, deleted after 30.
    let directory = base.appendingPathComponent("Socials cache")
    let cache = SocialsCache(directory: directory)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try check(cache.load(now: now) == SocialsSnapshot(), "Socials cache with no file loads empty")
    var snap = SocialsSnapshot(summary: sum, status: s, history: [28: h], lastContact: now.addingTimeInterval(-2 * 86_400))
    try cache.save(snap)
    // SocialsJSON.encoder writes whole seconds, so cached times lose their fractions; figures must come back exactly.
    let reloaded = cache.load(now: now)
    try check(cache.fileURL.lastPathComponent == "socials-cache.json" && reloaded.summary?.youtube?.window == sum.youtube?.window.map { w in
                  var w = w; w.readAt = reloaded.summary!.youtube!.window!.readAt; return w } &&
              reloaded.summary?.youtube?.subscriberCount == 4810 && reloaded.history[28]?.rows == h.rows &&
              abs(reloaded.status!.platforms[0].lastGoodReadAt!.timeIntervalSince(yt.lastGoodReadAt!)) < 1,
              "Socials cache round-trips in its own file (times to the second)")
    try check(!snap.isExpired(now: now), "Socials figures show within 7 days of contact")
    try check(snap.isExpired(now: now.addingTimeInterval(6 * 86_400)), "Socials figures expire after 7 days without contact")
    try check(SocialsSnapshot(summary: sum).isExpired(now: now), "Socials figures with no contact time count as expired")
    try check(cache.load(now: now.addingTimeInterval(20 * 86_400)).summary != nil && FileManager.default.fileExists(atPath: cache.fileURL.path),
              "Socials cache is kept, hidden, between 7 and 30 days")
    try check(cache.load(now: now.addingTimeInterval(29 * 86_400)) == SocialsSnapshot() && !FileManager.default.fileExists(atPath: cache.fileURL.path),
              "Socials cache file is deleted 30 days after the last contact")

    // Deletions drop YouTube only when the cached copy is older than the deletion.
    let readAt = sum.youtube!.countsReadAt!
    var kept = snap
    kept.apply(deletions: try deletions("youtube", readAt.addingTimeInterval(-60)))
    try check(kept.summary?.youtube != nil && kept.history.count == 1, "Socials keeps YouTube when the deletion is older than the copy")
    snap.apply(deletions: try deletions("youtube", readAt.addingTimeInterval(60)))
    try check(snap.summary?.youtube == nil && snap.history.isEmpty && snap.status != nil, "Socials drops YouTube for a newer deletion")
    var other = kept
    other.apply(deletions: try deletions("instagram", readAt.addingTimeInterval(60)))
    try check(other == kept, "Socials ignores another platform's deletion")

    // The file credential store used by isolated runs: private permissions, delete forgets.
    let store = FileCredentialStore(directory: directory)
    try store.write("token-1\n")
    let mode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
    try check(store.read() == "token-1" && mode == 0o600, "Socials file credential is private to the user")
    store.delete()
    try check(store.read() == nil, "Socials file credential deletes")

    // Formatting.
    try check(SocialsFormat.count(4810) == 4810.formatted(.number.grouping(.automatic)) && SocialsFormat.count(nil) == "–", "Socials counts are grouped and missing ones show a dash")
    let compact = SocialsFormat.compact(38_200)
    try check(compact.contains("38") && compact.uppercased().contains("K") && SocialsFormat.compact(nil) == "–", "Socials compact count \(compact)")
    try check(SocialsFormat.hours(fromMinutes: 5678) == "94 h" && SocialsFormat.hours(fromMinutes: nil) == "–", "Socials watch time shows whole hours from minutes")
    try check(SocialsFormat.dateRange("2026-10-16", "2026-11-12") == "16 Oct – 12 Nov", "Socials date range uses the API's dates")
    try check(SocialsFormat.shortDate("not a date") == "not a date", "Socials leaves an unparseable date as written")
    let utc = TimeZone(identifier: "UTC")!
    let read = SocialsJSON.decoder.dateDecodingStrategyCheck("2026-11-15T14:05:00Z")
    try check(SocialsFormat.readTime(read, now: read.addingTimeInterval(3600), timeZone: utc) == "Read 14:05", "Socials read time today shows the time")
    try check(SocialsFormat.readTime(read, now: read.addingTimeInterval(3 * 86_400), timeZone: utc) == "Read 15 Nov, 14:05", "Socials read time on another day shows the date")
    try check(SocialsFormat.readTime(nil) == "Not read yet", "Socials read time before any read")
}

/// Deletions arrive only from the Worker, so they are built the way the app receives them.
private func deletions(_ platform: String, _ at: Date) throws -> [SocialsStatus.Deletion] {
    try SocialsJSON.decoder.decode([SocialsStatus.Deletion].self, from: Data("[{\"platform\":\"\(platform)\",\"at\":\"\(at.formatted(.iso8601))\"}]".utf8))
}

private extension JSONDecoder {
    /// Decodes one date string through the contract's decoder, so the checks use the same parsing as the app.
    func dateDecodingStrategyCheck(_ text: String) -> Date {
        struct Box: Decodable { var d: Date }
        return try! decode(Box.self, from: Data("{\"d\":\"\(text)\"}".utf8)).d
    }
}
