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

    /// "Clear data on this iPhone": drop every cached figure and invalidate any read still in flight.
    static func clearCache(_ cache: SocialsCache = Companion.cache) {
        coordinated(cache) {
            bumpGeneration(cache)
            cache.clear()
        }
    }

    /// 401 or "Remove this iPhone": forget the token and every cached figure.
    static func wipe(cache: SocialsCache = Companion.cache, credentials: SocialsCredentialStore = Companion.credentials) {
        credentials.delete()
        clearCache(cache)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Wipe generation

    // A counter next to the cache file in the App Group container. A sync notes it before its requests and saves only
    // if it is unchanged, so a wipe in either process cannot be undone by a read that was already under way.
    private static func generationURL(_ cache: SocialsCache) -> URL {
        cache.fileURL.deletingLastPathComponent().appendingPathComponent("socials-wipe-generation")
    }

    static func generation(_ cache: SocialsCache) -> Int {
        (try? String(contentsOf: generationURL(cache), encoding: .utf8)).flatMap { Int($0) } ?? 0
    }

    private static func bumpGeneration(_ cache: SocialsCache) {
        let url = generationURL(cache)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(generation(cache) + 1).utf8).write(to: url, options: .atomic)
    }

    /// Runs `body` while holding the cache file for writing, so the app and the widget cannot interleave.
    private static func coordinated(_ cache: SocialsCache, _ body: () -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: cache.fileURL, options: .forMerging, error: &error) { _ in body() }
        if error != nil { body() } // coordination failed: do the work anyway rather than leave a wipe undone
    }

    /// What to put on screen. A result is shown only if no wipe has happened since `generation` was read and the token
    /// still exists; otherwise (or with no result) the cache is read from disk again, which a wipe will have emptied.
    static func visible(_ snapshot: SocialsSnapshot?, generation: Int, cache: SocialsCache,
                        credentials: SocialsCredentialStore) -> (snapshot: SocialsSnapshot, hasToken: Bool) {
        let hasToken = credentials.read() != nil
        if let snapshot, hasToken, Companion.generation(cache) == generation { return (snapshot, true) }
        return (cache.load(), hasToken)
    }

    /// Loads the cache, lets `change` edit it, and saves, but only if no wipe has happened since `generation` was read
    /// and the device still has its token. Returns the cache as it now stands.
    static func commit(cache: SocialsCache, generation: Int, credentials: SocialsCredentialStore,
                       _ change: (inout SocialsSnapshot) -> Void) throws -> SocialsSnapshot {
        var result = SocialsSnapshot()
        var failure: Error?
        coordinated(cache) {
            guard Companion.generation(cache) == generation, credentials.read() != nil else { result = cache.load(); return }
            var snap = cache.load()
            change(&snap)
            do { try cache.save(snap); result = snap } catch { failure = error }
        }
        if let failure { throw failure }
        return result
    }
}

struct SocialsEntry: TimelineEntry {
    let date: Date
    let snapshot: SocialsSnapshot
    let hasToken: Bool

    /// The current entry, plus one just after the 7-day expiry so figures disappear even if iOS delays the next reload.
    static func entries(snapshot: SocialsSnapshot, hasToken: Bool, now: Date) -> [SocialsEntry] {
        var entries = [SocialsEntry(date: now, snapshot: snapshot, hasToken: hasToken)]
        if let last = snapshot.lastContact {
            let expiry = last.addingTimeInterval(SocialsSnapshot.expiredAfter + 1)
            if expiry > now { entries.append(SocialsEntry(date: expiry, snapshot: snapshot, hasToken: hasToken)) }
        }
        return entries
    }
}

enum SocialsSync {
    /// Fetches summary (or forces a read), status and 28 days of history, then saves them unless this device was wiped meanwhile.
    @discardableResult
    static func run(client: SocialsClient, cache: SocialsCache, force: Bool,
                    credentials: SocialsCredentialStore = Companion.credentials) async throws -> SocialsSnapshot {
        let generation = Companion.generation(cache)
        async let summary = force ? client.refresh() : client.summary()
        async let status = client.status()
        async let history = client.history(days: 28)
        let (s, st, h) = try await (summary, status, history)
        return try Companion.commit(cache: cache, generation: generation, credentials: credentials) { snap in
            snap.merge(status: st, summary: s, history: (28, h), contact: Date())
        }
    }

    /// What the widget publishes: a fresh read when there is one, otherwise whatever the cache holds on disk now.
    static func timelineSnapshot(client: SocialsClient?, cache: SocialsCache, credentials: SocialsCredentialStore,
                                 timeout: Double = 12) async -> (snapshot: SocialsSnapshot, hasToken: Bool) {
        let generation = Companion.generation(cache)
        var fresh: SocialsSnapshot?
        if let client {
            do {
                fresh = try await withTimeout(timeout) { try await run(client: client, cache: cache, force: false, credentials: credentials) }
            } catch SocialsError.unauthorized {
                Companion.wipe(cache: cache, credentials: credentials)
            } catch {} // keep what is on disk; the view shows expiry on its own
        }
        return Companion.visible(fresh, generation: generation, cache: cache, credentials: credentials)
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
