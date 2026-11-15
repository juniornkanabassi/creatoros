import SwiftUI
import XCTest

final class CompanionTests: XCTestCase {
    private let now = SocialsFixture.read.addingTimeInterval(30 * 60)

    // MARK: State selection

    func testStateSelection() {
        let fresh = SocialsFixture.snapshot()
        XCTAssertEqual(SocialsDisplayState.select(hasToken: false, snapshot: fresh, now: now), .notSetUp)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: SocialsSnapshot(), now: now), .loading)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: fresh, now: now), .normal)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: fresh, now: now.addingTimeInterval(8 * 86_400)), .expired)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: SocialsFixture.snapshot(state: .needsReconnect), now: now), .needsReconnect)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: SocialsFixture.snapshot(window: false), now: now), .waiting)
        var none = fresh; none.summary?.youtube = nil
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: none, now: now), .notConnected)
    }

    // MARK: Expiry entry (widget)

    func testTimelineHasAnExpiredEntryAtSevenDays() {
        let snap = SocialsFixture.snapshot()
        let entries = SocialsEntry.entries(snapshot: snap, hasToken: true, now: now)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: snap, now: entries[0].date), .normal)
        XCTAssertEqual(SocialsDisplayState.select(hasToken: true, snapshot: snap, now: entries[1].date), .expired)
        XCTAssertEqual(entries[1].date, SocialsFixture.read.addingTimeInterval(7 * 86_400 + 1))
        // Already expired, or never contacted: nothing later to schedule.
        XCTAssertEqual(SocialsEntry.entries(snapshot: snap, hasToken: true, now: now.addingTimeInterval(8 * 86_400)).count, 1)
        XCTAssertEqual(SocialsEntry.entries(snapshot: SocialsSnapshot(), hasToken: true, now: now).count, 1)
    }

    // MARK: Wipes beat reads in flight

    private func sandbox() throws -> (SocialsCache, FileCredentialStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString)")
        let creds = FileCredentialStore(directory: dir)
        try creds.write("token")
        return (SocialsCache(directory: dir), creds, dir)
    }

    private func client(summaryConnection: String = "conn-A", historyConnection: String = "conn-A", status: Int = 200,
                        whileRequesting hook: @escaping @Sendable () -> Void) -> SocialsClient {
        StubProtocol.hook = hook
        StubProtocol.summaryConnection = summaryConnection
        StubProtocol.historyConnection = historyConnection
        StubProtocol.status = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return SocialsClient(baseURL: URL(string: "https://worker.test")!, token: "token", session: URLSession(configuration: config))
    }

    func testSyncSavesWhenNothingWasWiped() async throws {
        let (cache, creds, _) = try sandbox()
        let snap = try await SocialsSync.run(client: client {}, cache: cache, force: false, credentials: creds)
        XCTAssertNotNil(snap.summary)
        XCTAssertNotNil(cache.load().lastContact)
        XCTAssertNotNil(cache.load().history[28])
    }

    func testHistoryFromAnotherConnectionIsNotKept() async throws {
        let (cache, creds, _) = try sandbox()
        let snap = try await SocialsSync.run(client: client(summaryConnection: "conn-B", historyConnection: "conn-A") {}, cache: cache, force: false, credentials: creds)
        XCTAssertEqual(snap.summary?.youtube?.connectionId, "conn-B")
        XCTAssertTrue(snap.history.isEmpty)
        XCTAssertTrue(cache.load().history.isEmpty)
    }

    func testReconnectDropsTheOldChannelsHistory() async throws {
        let (cache, creds, _) = try sandbox()
        _ = try await SocialsSync.run(client: client {}, cache: cache, force: false, credentials: creds)
        XCTAssertNotNil(cache.load().history[28])
        let snap = try await SocialsSync.run(client: client(summaryConnection: "conn-B", historyConnection: "conn-B") {}, cache: cache, force: false, credentials: creds)
        XCTAssertEqual(snap.history[28]?.connectionId, "conn-B")
    }

    // A late result must not show figures that a wipe has since removed.

    func testFailedWidgetReadDoesNotPublishTheStaleCache() async throws {
        let (cache, creds, _) = try sandbox()
        _ = try await SocialsSync.run(client: client {}, cache: cache, force: false, credentials: creds) // old copy on disk
        // The widget loads its snapshot, the app clears data, then the widget's request fails.
        let failing = client(status: 500) { Companion.clearCache(cache) }
        let shown = await SocialsSync.timelineSnapshot(client: failing, cache: cache, credentials: creds)
        XCTAssertNil(shown.snapshot.summary)
        XCTAssertTrue(shown.hasToken)
    }

    func testFailedWidgetReadStillShowsTheCacheWhenNothingWasWiped() async throws {
        let (cache, creds, _) = try sandbox()
        _ = try await SocialsSync.run(client: client {}, cache: cache, force: false, credentials: creds)
        let shown = await SocialsSync.timelineSnapshot(client: client(status: 500) {}, cache: cache, credentials: creds)
        XCTAssertNotNil(shown.snapshot.summary)
    }

    func testResultCommittedBeforeAWipeIsNotDisplayedAfterIt() async throws {
        let (cache, creds, _) = try sandbox()
        let generation = Companion.generation(cache)
        let fresh = try await SocialsSync.run(client: client {}, cache: cache, force: false, credentials: creds) // commit succeeds
        XCTAssertNotNil(fresh.summary)
        Companion.clearCache(cache) // the wipe lands before the UI assigns the result
        let shown = Companion.visible(fresh, generation: generation, cache: cache, credentials: creds)
        XCTAssertNil(shown.snapshot.summary)
        // Unchanged generation and a token: the result is shown as it is.
        let ok = Companion.visible(fresh, generation: Companion.generation(cache), cache: cache, credentials: creds)
        XCTAssertNotNil(ok.snapshot.summary)
        // A removed token also hides it.
        creds.delete()
        XCTAssertFalse(Companion.visible(fresh, generation: Companion.generation(cache), cache: cache, credentials: creds).hasToken)
    }

    func testClearDataDuringSyncIsNotUndone() async throws {
        let (cache, creds, _) = try sandbox()
        let snap = try await SocialsSync.run(client: client { Companion.clearCache(cache) }, cache: cache, force: false, credentials: creds)
        XCTAssertNil(snap.summary)
        XCTAssertNil(cache.load().summary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path))
    }

    func testRemoveDeviceDuringSyncIsNotUndone() async throws {
        let (cache, creds, _) = try sandbox()
        _ = try await SocialsSync.run(client: client {}, cache: cache, force: false, credentials: creds) // an old copy exists
        let snap = try await SocialsSync.run(client: client { Companion.wipe(cache: cache, credentials: creds) }, cache: cache, force: true, credentials: creds)
        XCTAssertNil(snap.summary)
        XCTAssertNil(cache.load().summary)
        XCTAssertNil(creds.read())
    }

    func testMissingTokenBlocksTheSave() async throws {
        let (cache, creds, _) = try sandbox()
        let snap = try await SocialsSync.run(client: client { creds.delete() }, cache: cache, force: false, credentials: creds)
        XCTAssertNil(snap.summary)
        XCTAssertNil(cache.load().summary)
    }

    // MARK: Renders

    @MainActor
    func testRenderEveryState() throws {
        let cases: [(String, Bool, SocialsSnapshot, Date)] = [
            ("normal", true, SocialsFixture.snapshot(), now),
            ("partial", true, SocialsFixture.snapshot(partial: true), now),
            ("needs-reconnect", true, SocialsFixture.snapshot(state: .needsReconnect), now),
            ("waiting", true, SocialsFixture.snapshot(window: false), now),
            ("expired", true, SocialsFixture.snapshot(), now.addingTimeInterval(8 * 86_400)),
            ("not-set-up", false, SocialsSnapshot(), now),
        ]
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EVIDENCE_DIR"] ?? "/private/tmp/socials/evidence/iphone")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, hasToken, snapshot, at) in cases {
            let state = SocialsDisplayState.select(hasToken: hasToken, snapshot: snapshot, now: at)
            // Large widget on a 6.9-inch iPhone is 364 x 382 pt with 16 pt content margins.
            let view = SocialsCardView(state: state, snapshot: snapshot, now: at) {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34).background(Palette.tile, in: Circle())
            }
            .padding(16)
            .frame(width: 364, height: 382)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let png = try XCTUnwrap(renderer.uiImage?.pngData(), "no image for \(name)")
            try png.write(to: dir.appendingPathComponent("widget-\(name).png"))
        }
    }
}

/// Answers every Worker route from the fixture, running `hook` first (where a test wipes the device mid-request).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var hook: @Sendable () -> Void = {}
    nonisolated(unsafe) static var summaryConnection = "conn-A"
    nonisolated(unsafe) static var historyConnection = "conn-A"
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.hook()
        let snap = SocialsFixture.snapshot(connection: Self.summaryConnection)
        let path = request.url?.path ?? ""
        let body: Data? = switch path {
        case "/v1/status": try? SocialsJSON.encoder.encode(snap.status)
        case "/v1/history": try? SocialsJSON.encoder.encode(SocialsFixture.snapshot(connection: Self.historyConnection).history[28])
        default: try? SocialsJSON.encoder.encode(snap.summary)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}
