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
