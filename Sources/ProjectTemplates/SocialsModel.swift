import Foundation
import AppKit
import SocialsCore

/// The daily figure the Socials chart shows. Each one is a column YouTube Analytics returns; nothing is derived
/// except the minutes-to-hours unit change for watch time.
enum SocialsMetric: String, CaseIterable, Identifiable {
    case views, watchTime, gained, lost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .views: "Views"
        case .watchTime: "Watch time (hours)"
        case .gained: "Subscribers gained"
        case .lost: "Subscribers lost"
        }
    }
    func value(_ row: SocialsHistory.Row) -> Double {
        switch self {
        case .views: Double(row.views)
        case .watchTime: Double(row.estimatedMinutesWatched) / 60
        case .gained: Double(row.subscribersGained)
        case .lost: Double(row.subscribersLost)
        }
    }
    /// The exact figure for one day, as the hover shows it.
    func label(_ row: SocialsHistory.Row) -> String {
        switch self {
        case .views: SocialsFormat.count(row.views) + " views"
        case .watchTime: (Double(row.estimatedMinutesWatched) / 60).formatted(.number.precision(.fractionLength(1))) + " h (" + SocialsFormat.count(row.estimatedMinutesWatched) + " min)"
        case .gained: SocialsFormat.count(row.subscribersGained) + " gained"
        case .lost: SocialsFormat.count(row.subscribersLost) + " lost"
        }
    }
}

/// What the Socials screen shows, in order of precedence.
enum SocialsPhase: Equatable {
    case setup            // no device token on this Mac
    case expired          // no contact with the Worker for 7 days: figures hidden
    case connect          // enrolled, YouTube not connected
    case needsReconnect   // YouTube sign-in lapsed: last figures greyed
    case connected
}

/// One day on the chart: its date at local midnight and the row YouTube reported for it, if any.
struct SocialsDay: Identifiable, Equatable {
    let date: Date
    let row: SocialsHistory.Row?
    var id: Date { date }
}

/// Socials on the Mac: optional, off until set up, never touches library.json. The GUI and the control commands call
/// these same actions. Instagram, TikTok and X would slot in beside `youtube` in SocialsCore's Summary and in `phase`.
@MainActor final class SocialsModel: ObservableObject {
    static let defaultWorker = "https://social-stats.junior-nkana-bassi.workers.dev"
    static let ranges = [7, 28, 90]
    /// Snapshot mode renders fixtures and must never reach a network.
    static let liveFetch = ProcessInfo.processInfo.environment["APP_SNAPSHOT"] == nil

    @Published private(set) var snapshot: SocialsSnapshot
    @Published private(set) var configured: Bool
    @Published var workerURL: String { didSet { defaults.set(workerURL, forKey: "socials.workerURL") } }
    @Published var range: Int { didSet { defaults.set(range, forKey: "socials.range") } }
    @Published var metric: SocialsMetric { didSet { defaults.set(metric.rawValue, forKey: "socials.metric") } }
    /// The last contact failed for a transport reason: cached figures stay, with a quiet line.
    @Published private(set) var unreachable = false
    /// A plain message for the last action that failed or needs saying (rate limit, server error).
    @Published var message: String?
    /// The action in progress, if any; a second action is refused with busy rather than interleaved.
    @Published private(set) var working: String?
    @Published private(set) var devices: [SocialsDevice] = []
    @Published private(set) var pairing: (code: String, expiresAt: Date)?
    @Published var accountsPresented = false

    let cache: SocialsCache
    let credentials: any SocialsCredentialStore
    let defaults: UserDefaults
    /// Replaced by the model check with a stubbed session.
    var session: URLSession = .shared
    private var token: String?
    /// Bumped whenever local data is wiped, so a fetch that started before cannot write the old account back.
    private var epoch = 0

    init(root: URL, isolated: Bool, defaults: UserDefaults) {
        let directory = root.appendingPathComponent("Socials")
        cache = SocialsCache(directory: directory)
        // An isolated (test) run never touches the real Keychain.
        credentials = isolated ? FileCredentialStore(directory: directory) : KeychainCredentialStore()
        self.defaults = defaults
        token = credentials.read()
        configured = token != nil
        snapshot = cache.load()
        workerURL = defaults.string(forKey: "socials.workerURL") ?? Self.defaultWorker
        let saved = defaults.integer(forKey: "socials.range")
        range = Self.ranges.contains(saved) ? saved : 28
        metric = SocialsMetric(rawValue: defaults.string(forKey: "socials.metric") ?? "") ?? .views
    }

    // MARK: State

    var youtube: YouTubeSummary? { snapshot.summary?.youtube }
    var youtubeStatus: SocialsStatus.Platform? { snapshot.status?.platforms.first { $0.platform == "youtube" } }

    func phase(now: Date = Date()) -> SocialsPhase {
        guard configured else { return .setup }
        if snapshot.isExpired(now: now) { return .expired }
        let state = youtubeStatus?.state ?? youtube?.state ?? .disconnected
        switch state {
        case .needsReconnect: return .needsReconnect
        case .connected: return youtube == nil ? .connect : .connected
        case .disconnected: return .connect
        }
    }

    /// Every day of the chosen range ending today, each with the row YouTube reported for it.
    func days(today: Date = Date(), calendar: Calendar = .current) -> [SocialsDay] {
        let rows = Dictionary((snapshot.history[range]?.rows ?? []).map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        let end = calendar.startOfDay(for: today)
        return (0..<range).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: end) else { return nil }
            return SocialsDay(date: date, row: rows[Self.ymd(date, calendar: calendar)])
        }
    }

    /// The first day YouTube has not reported yet, up to today; nil when every day in range is reported.
    func notYetReportedStart(today: Date = Date(), calendar: Calendar = .current) -> Date? {
        let end = calendar.startOfDay(for: today)
        guard let history = snapshot.history[range] else { return nil }
        guard let last = history.lastReportedDate.flatMap({ Self.date($0, calendar: calendar) }) else {
            return history.rows.isEmpty ? calendar.date(byAdding: .day, value: -(range - 1), to: end) : nil
        }
        guard let next = calendar.date(byAdding: .day, value: 1, to: last), next <= end else { return nil }
        return next
    }

    static func ymd(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(_ ymd: String, calendar: Calendar = .current) -> Date? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A Worker address must be https; plain http is accepted only for this Mac itself (the checks' fake Worker).
    static func validatedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil, url.user == nil else { return nil }
        if url.scheme == "https" { return url }
        if url.scheme == "http", ["127.0.0.1", "localhost"].contains(host) { return url }
        return nil
    }

    private func client() throws -> SocialsClient {
        guard let base = Self.validatedURL(workerURL) else { throw SocialsError.server(0, "The Socials server address must start with https://.") }
        return SocialsClient(baseURL: base, token: token, session: session)
    }

    // MARK: Actions (the GUI and the control commands share these)

    /// Takes the one Socials action slot, or refuses with busy.
    private func run<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        guard working == nil else { throw ControlFailure(code: "busy", message: "Socials is busy with \(working ?? "another action"). Retry in a moment.") }
        working = name
        defer { working = nil }
        do { return try await body() }
        catch { try handle(error) }
    }

    /// 401 wipes this Mac's Socials data and credential; transport failures keep the cache. Always rethrows.
    private func handle(_ error: Error) throws -> Never {
        switch error as? SocialsError {
        case .unauthorized?:
            wipeLocal()
            message = SocialsError.unauthorized.localizedDescription
        case .transport?:
            unreachable = true
        case .rateLimited?:
            message = SocialsError.rateLimited.localizedDescription
        case .server?:
            message = error.localizedDescription
        default: break
        }
        throw error
    }

    /// Forgets the cache and the device token on this Mac.
    func wipeLocal() {
        epoch += 1
        credentials.delete()
        cache.clear()
        token = nil; configured = false
        snapshot = SocialsSnapshot(); devices = []; pairing = nil; unreachable = false
    }

    private func save() { try? cache.save(snapshot) }

    /// Reads status, summary and the chosen range's history together. Used on appear, every 15 minutes and by the reads.
    /// `days` is the history range to read: the GUI's range unless a caller (the history command) asks for its own.
    func sync(days requested: Int? = nil) async throws {
        guard configured else { throw SocialsError.notConfigured }
        let client = try client(), days = requested ?? range, started = epoch
        do {
            async let status = client.status()
            async let summary = client.summary()
            async let history = client.history(days: days)
            let (s, sum, h) = try await (status, summary, history)
            guard started == epoch else { return }
            snapshot.merge(status: s, summary: sum, history: (days, h), contact: Date())
            unreachable = false
            save()
        } catch {
            guard started == epoch else { return }
            try handle(error)
        }
    }

    /// For the read commands: answers from the cache when the server cannot be reached, but a revoked device says so.
    func syncForRead(days: Int? = nil) async throws {
        guard configured else { return }
        do { try await sync(days: days) } catch SocialsError.unauthorized { throw SocialsError.unauthorized } catch {}
    }

    /// The quiet background refresh: errors only show in the page's own lines.
    func syncQuietly() async {
        guard configured, working == nil else { return }
        try? await sync()
    }

    func setUp(url text: String, code: String) async throws {
        guard let url = Self.validatedURL(text) else { throw ControlFailure(code: "invalid_params", message: "Use the Socials server's https:// address.") }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw ControlFailure(code: "invalid_params", message: "Enter the one-time code.") }
        guard !configured else { throw ControlFailure(code: "already_set_up", message: "Socials is already set up on this Mac. Clear it first to set it up again.") }
        try await run("setting up") {
            let name = Host.current().localizedName ?? "Mac"
            let newToken = try await SocialsClient(baseURL: url, token: nil, session: session).enrol(code: code, name: name, kind: "mac")
            try credentials.write(newToken)
            workerURL = url.absoluteString
            token = newToken; configured = true; message = nil
            epoch += 1
        }
        try? await sync()
    }

    /// The Google consent address for this device. Opening it is the caller's choice.
    func connectURL() async throws -> URL {
        try await run("connecting YouTube") { try await client().connectYouTube() }
    }

    func disconnectYouTube() async throws {
        try await run("disconnecting YouTube") {
            try await client().disconnectYouTube()
            snapshot.summary?.youtube = nil; snapshot.history = [:]; snapshot.status = nil
            save()
        }
        try? await sync()
    }

    /// The Refresh button: asks the Worker to read YouTube now (at most once a minute), then reads everything back.
    func refreshNow() async throws {
        try await run("refreshing") {
            let summary = try await client().refresh()
            snapshot.merge(status: nil, summary: summary, history: nil, contact: Date())
            message = nil
            save()
        }
        try await sync()
    }

    func loadDevices() async throws {
        let list = try await run("listing devices") { try await client().devices() }
        devices = list
    }

    func pair() async throws -> (code: String, expiresAt: Date) {
        let result = try await run("making a pairing code") { try await client().pairingCode() }
        pairing = result
        return result
    }

    /// Revokes one device. Revoking this Mac also forgets its Socials data here.
    func revoke(_ id: String) async throws -> Bool {
        let current = devices.first { $0.id == id }?.current ?? false
        try await run("revoking a device") { try await client().revoke(deviceID: id) }
        if current { wipeLocal(); return true }
        devices.removeAll { $0.id == id }
        return false
    }

    /// Clears this Mac's cache and device token. It first tries to revoke this Mac on the server, so no unused
    /// credential is left behind; offline, the local data goes anyway.
    func clearLocal() async {
        if configured, working == nil, let client = try? client() {
            working = "clearing"
            if let list = try? await client.devices(), let me = list.first(where: \.current) { try? await client.revoke(deviceID: me.id) }
            working = nil
        }
        wipeLocal()
        message = nil
    }

    func deleteAll() async throws {
        try await run("deleting all Socials data") {
            try await client().deleteAll()
            snapshot.summary?.youtube = nil; snapshot.history = [:]; snapshot.status = nil
            save()
        }
        try? await sync()
    }

    /// Fixture entry point for snapshots and checks: replaces the cache as if a sync had just happened.
    func load(_ fixture: SocialsSnapshot, configured: Bool) {
        snapshot = fixture
        self.configured = configured
        unreachable = false; message = nil
    }
}

// MARK: - Control commands

extension AppModel {
    /// The `socials.*` commands. They never touch the library, so they do not take the library writer slot; Socials
    /// actions that change anything take Socials' own slot instead.
    func controlSocials(_ action: String, _ params: [String: Any]) async throws -> [String: Any] {
        let s = socials
        func confirmed(_ what: String) throws {
            guard params["confirm"] as? Bool == true else { throw ControlFailure(code: "confirmation_required", message: "\(what) Repeat with --confirm to do it.") }
        }
        do {
            switch action {
            case "socials.status":
                try await s.syncForRead()
                return s.controlState()
            case "socials.summary":
                try await s.syncForRead()
                return try s.controlFigures(["summary": s.json(s.snapshot.summary)])
            case "socials.history":
                // The caller's own range, kept local: concurrent callers never share it and the GUI's range stays put.
                let days = params["days"] as? Int ?? s.range
                guard SocialsModel.ranges.contains(days) else { throw ControlFailure(code: "invalid_params", message: "Use --days 7, 28 or 90.") }
                try await s.syncForRead(days: days)
                return try s.controlFigures(["days": days, "history": s.json(s.snapshot.history[days])])
            case "socials.refresh":
                try await s.refreshNow()
                return try s.controlFigures(["summary": s.json(s.snapshot.summary)])
            case "socials.setup":
                try await s.setUp(url: params["url"] as! String, code: params["code"] as! String)
                return s.controlState()
            case "socials.connect":
                let url = try await s.connectURL()
                var opened = false
                if params["open"] as? Bool == true {
                    guard !AgentScreen.active else { throw ControlFailure(code: "not_allowed", message: "Opening a browser is disabled during invisible checks.") }
                    opened = NSWorkspace.shared.open(url)
                }
                return ["authUrl": url.absoluteString, "opened": opened]
            case "socials.disconnect":
                try confirmed("This disconnects YouTube and deletes its data on the server.")
                try await s.disconnectYouTube()
                return s.controlState()
            case "socials.devices":
                try await s.loadDevices()
                return ["devices": s.json(s.devices)]
            case "socials.pair":
                let pairing = try await s.pair()
                return ["code": pairing.code, "expiresAt": pairing.expiresAt.formatted(.iso8601)]
            case "socials.revoke":
                try confirmed("This stops that device reading Socials.")
                if s.devices.isEmpty { try await s.loadDevices() }
                let id = params["device"] as! String
                guard s.devices.contains(where: { $0.id == id }) else { throw ControlFailure(code: "not_found", message: "No enrolled device has id \(id).") }
                let wasThisMac = try await s.revoke(id)
                return ["revoked": id, "thisMac": wasThisMac]
            case "socials.clear-local":
                try confirmed("This forgets Socials on this Mac (cache and device credential).")
                await s.clearLocal()
                return s.controlState()
            case "socials.delete-all":
                try confirmed("This deletes every platform's tokens and data on the server.")
                try await s.deleteAll()
                return s.controlState()
            default:
                throw ControlFailure(code: "unknown_action", message: "Unknown action: \(action)")
            }
        } catch let error as SocialsError {
            let code: String
            switch error {
            case .notConfigured: code = "not_configured"
            case .unauthorized: code = "unauthorized"
            case .rateLimited: code = "rate_limited"
            case .server: code = "server_error"
            case .transport: code = "unreachable"
            }
            throw ControlFailure(code: code, message: error.localizedDescription)
        }
    }
}

extension SocialsModel {
    func json<T: Encodable>(_ value: T?) -> Any {
        guard let value, let data = try? SocialsJSON.encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }

    func controlState() -> [String: Any] {
        let phase: String = switch phase() {
        case .setup: "notSetUp"
        case .expired: "expired"
        case .connect: "youtubeNotConnected"
        case .needsReconnect: "needsReconnect"
        case .connected: "connected"
        }
        return ["configured": configured, "workerUrl": workerURL, "state": phase, "reachable": !unreachable,
                "lastContact": snapshot.lastContact.map { $0.formatted(.iso8601) } as Any? ?? NSNull(),
                "status": json(snapshot.status)]
    }

    /// Figures go out only while they may be shown: not before set-up and never once they have expired.
    func controlFigures(_ figures: [String: Any]) throws -> [String: Any] {
        guard configured else { throw SocialsError.notConfigured }
        guard !snapshot.isExpired() else { throw ControlFailure(code: "data_expired", message: "Offline, data expired: CreatorOS has not reached the Socials server for 7 days.") }
        var reply = figures
        reply["reachable"] = !unreachable
        reply["lastContact"] = snapshot.lastContact.map { $0.formatted(.iso8601) } as Any? ?? NSNull()
        return reply
    }
}
