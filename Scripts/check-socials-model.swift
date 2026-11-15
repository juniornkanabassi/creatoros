import Foundation
import SwiftUI
import TemplateCore
import SocialsCore

/// Answers every Socials request in-process, so this check never reaches a network.
final class StubWorker: URLProtocol {
    nonisolated(unsafe) static var handler: (URLRequest) -> (Int, String) = { _ in (500, "{}") }
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var requests: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append((request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")); Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            if Self.offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            let (code, body) = Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main struct SocialsModelCheck {
    @MainActor static func main() async throws {
        let model = AppModel()
        defer { model.runtime.removeDisposablePreferences() }
        precondition(model.runtime.isIsolated && model.storeUsable, "Socials checks need a disposable data root")
        var checks = 0
        func pass(_ condition: Bool, _ name: String) { precondition(condition, "FAILED: " + name); checks += 1; print("PASS", name) }
        func code(_ action: String, _ params: [String: Any] = [:]) async -> String? {
            do { _ = try await model.controlAction(action, params); return nil } catch { return (error as? ControlFailure)?.code ?? "other" }
        }
        let s = model.socials
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubWorker.self]
        s.session = URLSession(configuration: config)
        let libraryBefore = try? Data(contentsOf: model.store.file)
        let socialsDir = model.runtime.root.appendingPathComponent("Socials")

        // Not set up: CreatorOS behaves as before, nothing is requested.
        pass(s.phase() == .setup && !s.configured, "Socials starts not set up")
        let state = try await model.controlAction("socials.status", [:])
        pass(state["configured"] as? Bool == false && state["state"] as? String == "notSetUp" && StubWorker.requests.isEmpty, "status before set-up answers locally without a request")
        pass(await code("socials.summary") == "not_configured", "summary before set-up is not_configured")
        pass(await code("socials.setup", ["url": "http://example.com", "code": "1"]) == "invalid_params", "set-up refuses a plain http address")
        pass(await code("socials.setup", ["url": "x", "code": "1"]) == "invalid_params" && StubWorker.requests.isEmpty, "set-up refuses a malformed address without a request")

        // A fake Worker following docs/SOCIALS-API.md.
        let today = Calendar.current.startOfDay(for: Date())
        func ymd(_ back: Int) -> String { SocialsModel.ymd(Calendar.current.date(byAdding: .day, value: -back, to: today)!) }
        var ytState = "connected"
        var deletionAt = "2000-01-01T00:00:00Z"
        let now = Date().formatted(.iso8601)
        StubWorker.handler = { request in
            let path = request.url!.path
            switch path {
            case "/v1/devices/enrol": return (200, #"{"deviceId":"mac-1","token":"token-abc"}"#)
            case "/v1/status": return (200, #"{"serverTime":"\#(now)","platforms":[{"platform":"youtube","state":"\#(ytState)","account":"Fixture Channel","lastGoodReadAt":"\#(now)","lastAttemptAt":"\#(now)","lastError":null,"readIntervalMinutes":15,"gaps":[]}],"deletions":[{"platform":"youtube","at":"\#(deletionAt)"}]}"#)
            case "/v1/summary", "/v1/refresh": return (200, #"{"serverTime":"\#(now)","youtube":{"state":"\#(ytState)","channelTitle":"Fixture Channel","subscriberCount":4810,"subscriberCountHidden":false,"countsReadAt":"\#(now)","window":{"startDate":"\#(ymd(30))","endDate":"\#(ymd(3))","partial":false,"views":1234,"estimatedMinutesWatched":5678,"subscribersGained":90,"subscribersLost":4,"readAt":"\#(now)"},"newestVideo":null,"connectionId":"conn-1"}}"#)
            case "/v1/history":
                let rows = (3..<28).map { #"{"date":"\#(ymd($0))","views":\#($0 * 10),"estimatedMinutesWatched":\#($0 * 60),"subscribersGained":\#($0),"subscribersLost":1}"# }
                return (200, #"{"platform":"youtube","readAt":"\#(now)","rows":[\#(rows.joined(separator: ","))],"lastReportedDate":"\#(ymd(3))","connectionId":"conn-1"}"#)
            case "/v1/devices": return (200, #"{"devices":[{"id":"mac-1","name":"This Mac","kind":"mac","createdAt":"\#(now)","lastSeenAt":null,"current":true},{"id":"phone-1","name":"iPhone","kind":"iphone","createdAt":"\#(now)","lastSeenAt":null,"current":false}]}"#)
            case "/v1/devices/pair": return (200, #"{"code":"PAIR-1234","expiresAt":"\#(now)"}"#)
            case "/v1/youtube/connect": return (200, #"{"authUrl":"https://accounts.google.com/o/oauth2/v2/auth?state=x"}"#)
            default: return (200, #"{"ok":true}"#)
            }
        }
        let setUp = try await model.controlAction("socials.setup", ["url": "https://worker.example.test/", "code": "one-time"])
        pass(setUp["configured"] as? Bool == true && setUp["state"] as? String == "connected", "set-up enrols and reads YouTube")
        pass(FileCredentialStore(directory: socialsDir).read() == "token-abc", "the device token is in the scratch root's file store, not the Keychain")
        pass(FileManager.default.fileExists(atPath: socialsDir.appendingPathComponent("socials-cache.json").path), "the cache is its own file under the data root")
        pass((try? Data(contentsOf: model.store.file)) == libraryBefore, "Socials never touches library.json")
        pass(model.defaults.string(forKey: "socials.workerURL") == "https://worker.example.test", "the server address is kept in the isolated defaults suite")
        pass(await code("socials.setup", ["url": "https://worker.example.test", "code": "again"]) == "already_set_up", "set-up twice is refused")

        // The chart: every day of the range, unreported days after the last reported date.
        let days = s.days()
        pass(days.count == 28 && days.last?.date == today && days.filter { $0.row != nil }.count == 25, "chart has one slot per day of the range, ending today")
        pass(s.notYetReportedStart() == Calendar.current.date(byAdding: .day, value: -2, to: today), "days after the last reported date are 'not yet reported'")
        pass(SocialsMetric.watchTime.value(days.last { $0.row != nil }!.row!) == 3 && SocialsMetric.lost.value(days.last { $0.row != nil }!.row!) == 1, "chart values are the returned columns (watch time in hours)")
        let history = try await model.controlAction("socials.history", ["days": 7])
        pass(s.range == 28 && history["days"] as? Int == 7 && s.snapshot.history[7] != nil, "history --days 7 reads that range and leaves the GUI's range alone")
        pass(await code("socials.history", ["days": 30]) == "invalid_params", "history refuses a range other than 7, 28 or 90")
        let summary = try await model.controlAction("socials.summary", [:])
        let yt = ((summary["summary"] as? [String: Any])?["youtube"] as? [String: Any])
        pass(yt?["subscriberCount"] as? Int == 4810 && summary["reachable"] as? Bool == true, "summary returns the figures as the API returned them")

        // Confirmation before anything destructive, with no request sent.
        StubWorker.requests = []
        for action in ["socials.disconnect", "socials.clear-local", "socials.delete-all"] {
            pass(await code(action) == "confirmation_required", action + " needs --confirm")
        }
        pass(await code("socials.revoke", ["device": "phone-1"]) == "confirmation_required" && StubWorker.requests.isEmpty, "revoke needs --confirm and sends nothing without it")
        let connect = try await model.controlAction("socials.connect", [:])
        pass((connect["authUrl"] as? String)?.hasPrefix("https://accounts.google.com") == true && connect["opened"] as? Bool == false, "connect returns the consent address without opening it")
        pass(await code("socials.connect", ["open": true]) == "not_allowed", "connect --open never opens a browser during invisible checks")
        let pair = try await model.controlAction("socials.pair", [:])
        pass(pair["code"] as? String == "PAIR-1234" && s.pairing?.code == "PAIR-1234", "pair shows the code in the GUI too")
        let revoked = try await model.controlAction("socials.revoke", ["device": "phone-1", "confirm": true])
        pass(revoked["thisMac"] as? Bool == false && s.configured && !s.devices.contains { $0.id == "phone-1" }, "revoking another device keeps this Mac set up")

        // Two history callers at once each get their own range back.
        let plain = StubWorker.handler
        StubWorker.handler = { request in
            guard request.url!.path == "/v1/history" else { return plain(request) }
            let days = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "days" }!.value!)!
            let rows = (0..<(days / 7)).map { #"{"date":"\#(ymd($0 + 3))","views":\#(days),"estimatedMinutesWatched":1,"subscribersGained":1,"subscribersLost":0}"# }
            return (200, #"{"platform":"youtube","readAt":"\#(now)","rows":[\#(rows.joined(separator: ","))],"lastReportedDate":"\#(ymd(3))","connectionId":"conn-1"}"#)
        }
        StubWorker.delay = 0.2
        async let week = model.controlAction("socials.history", ["days": 7])
        async let quarter = model.controlAction("socials.history", ["days": 90])
        let (w, q) = try await (week, quarter)
        StubWorker.delay = 0
        func rowsOf(_ reply: [String: Any]) -> Int { ((reply["history"] as? [String: Any])?["rows"] as? [Any])?.count ?? -1 }
        pass(w["days"] as? Int == 7 && rowsOf(w) == 1 && q["days"] as? Int == 90 && rowsOf(q) == 12 && s.range == 28,
             "concurrent history --days 7 and --days 90 each return their own range and leave the GUI's range alone")
        StubWorker.handler = plain

        // Disconnected elsewhere: the deletion is newer than the old copy, the new summary has no YouTube.
        try await s.sync()
        precondition(!s.snapshot.history.isEmpty)
        ytState = "disconnected"
        deletionAt = Date().addingTimeInterval(1).formatted(.iso8601)
        let connectedHandler = StubWorker.handler
        StubWorker.handler = { $0.url!.path == "/v1/summary" ? (200, #"{"serverTime":"\#(Date().addingTimeInterval(60).formatted(.iso8601))","youtube":null}"#) : connectedHandler($0) }
        try await s.sync()
        pass(s.youtube == nil && s.snapshot.history.isEmpty && s.phase() == .connect, "a disconnect seen in sync leaves no cached history behind")
        StubWorker.handler = connectedHandler
        ytState = "connected"; deletionAt = "2000-01-01T00:00:00Z"
        try await s.sync()

        // A reconnect lands between the history and summary reads: A's rows arrive with B's summary.
        let beforeRace = StubWorker.handler
        StubWorker.handler = { request in
            let (status, body) = beforeRace(request)
            return request.url!.path == "/v1/summary" ? (status, body.replacingOccurrences(of: "conn-1", with: "conn-2")) : (status, body)
        }
        try await s.sync()
        pass(s.youtube?.connectionId == "conn-2" && s.snapshot.history.isEmpty, "a history from the previous connection is not attached to the new one")
        StubWorker.handler = beforeRace
        try await s.sync()
        pass(s.snapshot.history[s.range]?.connectionId == "conn-1", "history from the summary's own connection is kept")

        // Problem states.
        ytState = "needsReconnect"
        try await s.sync()
        pass(s.phase() == .needsReconnect && s.youtube?.subscriberCount == 4810, "needsReconnect keeps the last figures")
        ytState = "connected"
        try await s.sync()
        StubWorker.offline = true
        _ = try await model.controlAction("socials.status", [:])
        pass(s.unreachable && s.youtube?.subscriberCount == 4810 && s.phase() == .connected, "an unreachable server keeps cached figures and says so")
        let offlineSummary = try await model.controlAction("socials.summary", [:])
        pass(offlineSummary["reachable"] as? Bool == false, "summary falls back to the cache when offline")
        var stale = s.snapshot
        stale.lastContact = Date().addingTimeInterval(-8 * 86_400)
        s.load(stale, configured: true)
        let expiredCode = await code("socials.summary")
        pass(s.phase() == .expired && expiredCode == "data_expired", "after 7 days without contact the figures are hidden")
        StubWorker.offline = false
        try await s.sync()
        pass(s.phase() == .connected, "contact again shows the figures")
        deletionAt = Date().addingTimeInterval(3600).formatted(.iso8601)
        try await s.sync()
        pass(s.youtube == nil && s.snapshot.history.isEmpty, "a newer deletion drops YouTube from the cache")
        deletionAt = "2000-01-01T00:00:00Z"
        try await s.sync()

        // Rate limit and two callers at once.
        let saved = StubWorker.handler
        StubWorker.handler = { $0.url!.path == "/v1/refresh" ? (429, #"{"error":"rate_limited","message":"wait"}"#) : saved($0) }
        pass(await code("socials.refresh") == "rate_limited" && s.message == SocialsError.rateLimited.localizedDescription, "refresh within a minute is rate_limited with a friendly message")
        StubWorker.handler = saved
        StubWorker.delay = 0.3
        async let first = code("socials.refresh")
        async let second = code("socials.refresh")
        let outcomes = await [first, second]
        StubWorker.delay = 0
        pass(outcomes.contains { $0 == nil } && outcomes.contains("busy"), "two refreshes at once: one runs, the other is told busy")

        // 401 wipes this Mac's Socials data and credential.
        StubWorker.handler = { _ in (401, #"{"error":"unauthorized"}"#) }
        pass(await code("socials.summary") == "unauthorized", "a revoked device is told unauthorized")
        pass(!s.configured && s.phase() == .setup && FileCredentialStore(directory: socialsDir).read() == nil &&
             !FileManager.default.fileExists(atPath: socialsDir.appendingPathComponent("socials-cache.json").path), "401 wipes the cache and the credential and returns to set-up")

        // Clear on this Mac works offline too.
        StubWorker.handler = saved
        _ = try await model.controlAction("socials.setup", ["url": "https://worker.example.test", "code": "again"])
        StubWorker.offline = true
        let cleared = try await model.controlAction("socials.clear-local", ["confirm": true])
        StubWorker.offline = false
        pass(cleared["configured"] as? Bool == false && FileCredentialStore(directory: socialsDir).read() == nil, "clear-local forgets Socials on this Mac even offline")
        pass((try? Data(contentsOf: model.store.file)) == libraryBefore, "library.json is still untouched after every Socials action")
        print("RESULT \(checks) Socials model checks passed")
    }
}
