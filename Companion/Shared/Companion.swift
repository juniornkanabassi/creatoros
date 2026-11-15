import Foundation
import WidgetKit

/// Where the app and the widget share state: one App Group container and one Keychain access group.
enum Companion {
    static let group = "group.com.juniornkanabassi.creatoros"
    static let keychainGroup = "M6L2VW4W5Z.com.juniornkanabassi.creatoros.shared"
    static let defaultWorker = "https://social-stats.junior-nkana-bassi.workers.dev"

    static let credentials = KeychainCredentialStore(accessGroup: keychainGroup)
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    static var cache: SocialsCache {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SocialsCache(directory: dir)
    }

    static var workerURL: URL? { defaults.string(forKey: "workerURL").flatMap { URL(string: $0) } }

    /// Nil until this device is set up.
    static func client() -> SocialsClient? {
        guard let url = workerURL, let token = credentials.read() else { return nil }
        return SocialsClient(baseURL: url, token: token)
    }

    /// 401 or "Remove this iPhone": forget the token and every cached figure.
    static func wipe() {
        credentials.delete()
        cache.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum SocialsSync {
    /// Fetches summary (or forces a read), status and 28 days of history, applies deletions, saves the snapshot.
    @discardableResult
    static func run(client: SocialsClient, cache: SocialsCache, force: Bool) async throws -> SocialsSnapshot {
        async let summary = force ? client.refresh() : client.summary()
        async let status = client.status()
        async let history = client.history(days: 28)
        var snap = cache.load()
        snap.summary = try await summary
        snap.status = try await status
        snap.history[28] = try await history
        snap.lastContact = Date()
        snap.apply(deletions: snap.status?.deletions ?? [])
        try cache.save(snap)
        return snap
    }

    static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: op)
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw SocialsError.transport("timed out") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// What the widget and the Today view show. Chosen from the cache alone so it is the same everywhere.
enum SocialsDisplayState: Equatable {
    case notSetUp, loading, expired, notConnected, needsReconnect, waiting, normal

    static func select(hasToken: Bool, snapshot: SocialsSnapshot, now: Date = Date()) -> Self {
        guard hasToken else { return .notSetUp }
        guard let summary = snapshot.summary else { return .loading }
        if snapshot.isExpired(now: now) { return .expired }
        guard let yt = summary.youtube else { return .notConnected }
        let statusState = snapshot.status?.platforms.first { $0.platform == "youtube" }?.state
        if yt.state == .needsReconnect || statusState == .needsReconnect { return .needsReconnect }
        return yt.window == nil ? .waiting : .normal
    }
}
