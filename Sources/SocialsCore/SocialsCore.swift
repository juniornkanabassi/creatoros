import Foundation
import Security

// Shared by the Mac app, the CLI path through the app, the iPhone companion and its widget.
// Contract: docs/SOCIALS-API.md. Foundation and Security only, so it compiles for macOS and iOS.

// MARK: - Wire types

public struct SocialsSummary: Codable, Equatable, Sendable {
    public var serverTime: Date
    public var youtube: YouTubeSummary?

    public init(serverTime: Date, youtube: YouTubeSummary?) {
        self.serverTime = serverTime
        self.youtube = youtube
    }
}

public struct YouTubeSummary: Codable, Equatable, Sendable {
    public var state: PlatformState
    public var channelTitle: String
    public var subscriberCount: Int?
    public var subscriberCountHidden: Bool
    public var countsReadAt: Date?
    public var window: AnalyticsWindow?
    public var newestVideo: Video?
    /// Changes on every (re)connect. Optional so payloads from before it existed still decode.
    public var connectionId: String?

    public init(state: PlatformState, channelTitle: String, subscriberCount: Int?, subscriberCountHidden: Bool = false,
                countsReadAt: Date?, window: AnalyticsWindow?, newestVideo: Video?, connectionId: String? = nil) {
        self.state = state; self.channelTitle = channelTitle; self.subscriberCount = subscriberCount
        self.subscriberCountHidden = subscriberCountHidden; self.countsReadAt = countsReadAt
        self.window = window; self.newestVideo = newestVideo; self.connectionId = connectionId
    }
}

public struct AnalyticsWindow: Codable, Equatable, Sendable {
    public var startDate: String
    public var endDate: String
    public var partial: Bool
    public var views: Int
    public var estimatedMinutesWatched: Int
    public var subscribersGained: Int
    public var subscribersLost: Int
    public var readAt: Date

    public init(startDate: String, endDate: String, partial: Bool, views: Int, estimatedMinutesWatched: Int,
                subscribersGained: Int, subscribersLost: Int, readAt: Date) {
        self.startDate = startDate; self.endDate = endDate; self.partial = partial; self.views = views
        self.estimatedMinutesWatched = estimatedMinutesWatched; self.subscribersGained = subscribersGained
        self.subscribersLost = subscribersLost; self.readAt = readAt
    }
}

public struct Video: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var publishedAt: Date
    public var viewCount: Int?
    public var url: URL

    public init(id: String, title: String, publishedAt: Date, viewCount: Int?, url: URL) {
        self.id = id; self.title = title; self.publishedAt = publishedAt; self.viewCount = viewCount; self.url = url
    }
}

public enum PlatformState: String, Codable, Sendable {
    case connected, disconnected, needsReconnect
}

public struct SocialsStatus: Codable, Equatable, Sendable {
    public struct Platform: Codable, Equatable, Sendable {
        public struct Gap: Codable, Equatable, Sendable { public var from: Date; public var to: Date }
        public var platform: String
        public var state: PlatformState
        public var account: String?
        public var lastGoodReadAt: Date?
        public var lastAttemptAt: Date?
        public var lastError: String?
        public var readIntervalMinutes: Int
        public var gaps: [Gap]
    }
    public struct Deletion: Codable, Equatable, Sendable { public var platform: String; public var at: Date }
    public var serverTime: Date
    public var platforms: [Platform]
    public var deletions: [Deletion]
}

public struct SocialsHistory: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var date: String
        public var views: Int
        public var estimatedMinutesWatched: Int
        public var subscribersGained: Int
        public var subscribersLost: Int
    }
    public var platform: String
    public var readAt: Date?
    public var rows: [Row]
    public var lastReportedDate: String?
    /// The connection these rows belong to; nil when nothing is connected or the Worker predates it.
    public var connectionId: String?
}

public struct SocialsDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var current: Bool
}

// MARK: - JSON

public enum SocialsJSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

// MARK: - Client

public enum SocialsError: Error, Equatable, LocalizedError {
    case notConfigured
    case unauthorized              // device revoked: caller must wipe cache and credential
    case rateLimited
    case server(Int, String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Socials is not set up on this device."
        case .unauthorized: return "This device is no longer allowed. Set Socials up again."
        case .rateLimited: return "Refreshed less than a minute ago. Try again shortly."
        case .server(let code, let message): return "The Socials server said \(code): \(message)"
        case .transport(let message): return "Could not reach the Socials server: \(message)"
        }
    }
}

public struct SocialsClient: Sendable {
    public var baseURL: URL
    public var token: String?
    public var session: URLSession

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    public func summary() async throws -> SocialsSummary { try await get("v1/summary") }
    public func status() async throws -> SocialsStatus { try await get("v1/status") }
    public func history(days: Int) async throws -> SocialsHistory {
        try await get("v1/history", query: [URLQueryItem(name: "platform", value: "youtube"), URLQueryItem(name: "days", value: String(days))])
    }
    public func refresh() async throws -> SocialsSummary { try await send("POST", "v1/refresh") }
    public func devices() async throws -> [SocialsDevice] {
        struct R: Decodable { var devices: [SocialsDevice] }
        return (try await get("v1/devices") as R).devices
    }
    public func pairingCode() async throws -> (code: String, expiresAt: Date) {
        struct R: Decodable { var code: String; var expiresAt: Date }
        let r: R = try await send("POST", "v1/devices/pair")
        return (r.code, r.expiresAt)
    }
    public func revoke(deviceID: String) async throws { let _: OK = try await send("POST", "v1/devices/\(deviceID)/revoke") }
    public func connectYouTube() async throws -> URL {
        struct R: Decodable { var authUrl: URL }
        return (try await send("POST", "v1/youtube/connect") as R).authUrl
    }
    public func disconnectYouTube() async throws { let _: OK = try await send("POST", "v1/youtube/disconnect") }
    public func deleteAll() async throws { let _: OK = try await send("POST", "v1/delete-all") }

    /// Enrols this device with a one-time code; returns the device token to keep in the credential store.
    public func enrol(code: String, name: String, kind: String) async throws -> String {
        struct Body: Encodable { var code: String; var name: String; var kind: String }
        struct R: Decodable { var deviceId: String; var token: String }
        let r: R = try await send("POST", "v1/devices/enrol", body: Body(code: code, name: name, kind: kind), authorised: false)
        return r.token
    }

    public var privacyURL: URL { baseURL.appendingPathComponent("privacy") }


    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                    body: (any Encodable)? = nil, authorised: Bool = true) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if authorised {
            guard let token, !token.isEmpty else { throw SocialsError.notConfigured }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try SocialsJSON.encoder.encode(body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SocialsError.transport(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return try SocialsJSON.decoder.decode(T.self, from: data)
        case 401: throw SocialsError.unauthorized
        case 429: throw SocialsError.rateLimited
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw SocialsError.server(code, message ?? "no details")
        }
    }
}

private struct OK: Decodable {}

// MARK: - Cache with offline expiry

public struct SocialsSnapshot: Codable, Equatable, Sendable {
    public var summary: SocialsSummary?
    public var status: SocialsStatus?
    public var history: [Int: SocialsHistory]
    public var lastContact: Date?

    public init(summary: SocialsSummary? = nil, status: SocialsStatus? = nil, history: [Int: SocialsHistory] = [:], lastContact: Date? = nil) {
        self.summary = summary; self.status = status; self.history = history; self.lastContact = lastContact
    }

    public static let expiredAfter: TimeInterval = 7 * 86_400
    public static let deletedAfter: TimeInterval = 30 * 86_400

    /// Figures are hidden ("Offline, data expired") after 7 days without a successful contact.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let lastContact else { return summary != nil }
        return now.timeIntervalSince(lastContact) > Self.expiredAfter
    }

    /// Drops any platform the Worker has deleted since this copy was read.
    /// With no YouTube in the summary, no cached history may outlive it either.
    public mutating func apply(deletions: [SocialsStatus.Deletion]) {
        for d in deletions where d.platform == "youtube" {
            if let read = summary?.youtube?.countsReadAt ?? summary?.serverTime, read <= d.at {
                summary?.youtube = nil
                history = [:]
            }
        }
        if summary != nil, summary?.youtube == nil { history = [:] }
    }

    /// Brings one read from the Worker into this copy. Public: the Mac app and the iPhone companion both call it.
    ///
    /// - Deletions are judged against the copy held before the read (a fresh summary always looks newer than them) and
    ///   again against the new figures' own read times.
    /// - A change of connection drops every cached history range: YouTube disconnected, or a different `connectionId`
    ///   (falling back to the channel title only when either side has no id, for payloads from before ids existed).
    /// - A history is kept only when its `connectionId` equals the current summary's. A history read in parallel with a
    ///   reconnect can belong to the old connection; it is dropped without failing the read.
    /// Pass nil for anything not read.
    public mutating func merge(status: SocialsStatus?, summary: SocialsSummary?, history new: (days: Int, history: SocialsHistory)?, contact: Date) {
        if let status { apply(deletions: status.deletions) }
        let old = self.summary?.youtube
        let oldTitle = old?.channelTitle ?? self.status?.platforms.first { $0.platform == "youtube" }?.account
        let state = status?.platforms.first { $0.platform == "youtube" }?.state
        if state == .disconnected { history = [:] }
        if let summary {
            if let fresh = summary.youtube {
                let changed = if let a = old?.connectionId, let b = fresh.connectionId { a != b } else { oldTitle != fresh.channelTitle }
                if changed { history = [:] }
            } else {
                history = [:]
            }
            self.summary = summary
        }
        if let status { self.status = status }
        if let new, new.history.connectionId == self.summary?.youtube?.connectionId { history[new.days] = new.history }
        // Figures in the new read that were themselves read before a deletion go too.
        if let status { apply(deletions: status.deletions) }
        // No YouTube, no history: rows read alongside a disconnected summary are not kept either.
        if self.summary != nil, self.summary?.youtube == nil { history = [:] }
        lastContact = contact
    }
}

/// One JSON file, never `library.json`. The Mac keeps it under its data root; the iPhone app and widget share it through the App Group.
public struct SocialsCache: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("socials-cache.json")
    }

    /// Loads the snapshot, deleting it outright once it is 30 days past its last contact.
    public func load(now: Date = Date()) -> SocialsSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? SocialsJSON.decoder.decode(SocialsSnapshot.self, from: data) else { return SocialsSnapshot() }
        if let last = snap.lastContact, now.timeIntervalSince(last) > SocialsSnapshot.deletedAfter {
            clear()
            return SocialsSnapshot()
        }
        return snap
    }

    public func save(_ snapshot: SocialsSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SocialsJSON.encoder.encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

// MARK: - Credentials

/// Device token storage. Production uses the Keychain; isolated test runs pass a file store inside their scratch root.
public protocol SocialsCredentialStore: Sendable {
    func read() -> String?
    func write(_ token: String) throws
    func delete()
}

public struct KeychainCredentialStore: SocialsCredentialStore {
    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(service: String = "com.juniornkanabassi.CreatorOS.socials", account: String = "device-token", accessGroup: String? = nil) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ token: String) throws {
        delete()
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SocialsError.transport("Keychain error \(status)") }
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}

public struct FileCredentialStore: SocialsCredentialStore {
    public let fileURL: URL
    public init(directory: URL) { fileURL = directory.appendingPathComponent("socials-device-token") }
    public func read() -> String? {
        (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func write(_ token: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    public func delete() { try? FileManager.default.removeItem(at: fileURL) }
}

// MARK: - Formatting

public enum SocialsFormat {
    /// Full figure with grouping, e.g. 4,810. YouTube's subscriber count is already rounded; we show it as returned.
    public static func count(_ n: Int?) -> String {
        guard let n else { return "–" }
        return n.formatted(.number.grouping(.automatic))
    }

    /// Compact figure for tight spaces, e.g. 38.2K, 1.28M.
    public static func compact(_ n: Int?) -> String {
        guard let n else { return "–" }
        return n.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// Watch time from minutes, as hours, e.g. "1,234 h".
    public static func hours(fromMinutes m: Int?) -> String {
        guard let m else { return "–" }
        return "\((m / 60).formatted(.number.grouping(.automatic))) h"
    }

    /// "16 Oct – 12 Nov" from the API's YYYY-MM-DD dates.
    public static func dateRange(_ start: String, _ end: String) -> String {
        "\(shortDate(start)) – \(shortDate(end))"
    }

    public static func shortDate(_ ymd: String) -> String {
        let p = DateFormatter()
        p.calendar = Calendar(identifier: .gregorian)
        p.locale = Locale(identifier: "en_GB_POSIX")
        p.timeZone = TimeZone(identifier: "UTC")
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: ymd) else { return ymd }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    /// "Read 14:05" today, "Read 12 Nov, 14:05" otherwise, in the device's time zone.
    public static func readTime(_ date: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date else { return "Not read yet" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
        return "Read \(f.string(from: date))"
    }
}
