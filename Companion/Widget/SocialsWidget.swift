import AppIntents
import SwiftUI
import WidgetKit

struct SocialsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SocialsEntry {
        SocialsEntry(date: Date(), snapshot: SocialsFixture.snapshot(), hasToken: true)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SocialsEntry) -> Void) {
        let entry = context.isPreview ? placeholder(in: context)
            : SocialsEntry(date: Date(), snapshot: Companion.cache.load(), hasToken: Companion.credentials.read() != nil)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SocialsEntry>) -> Void) {
        Task {
            let cache = Companion.cache
            var snapshot = cache.load()
            var hasToken = Companion.credentials.read() != nil
            if let client = Companion.client() {
                do {
                    snapshot = try await SocialsSync.withTimeout(12) { try await SocialsSync.run(client: client, cache: cache, force: false) }
                } catch SocialsError.unauthorized {
                    Companion.wipe(); snapshot = SocialsSnapshot(); hasToken = false
                } catch {} // keep the cache; the view shows expiry on its own
            }
            let now = Date()
            // No maximum delay is promised: iOS decides when the reload really happens.
            completion(Timeline(entries: SocialsEntry.entries(snapshot: snapshot, hasToken: hasToken, now: now),
                                policy: .after(now.addingTimeInterval(30 * 60))))
        }
    }
}

struct RefreshSocialsIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh Socials" }

    func perform() async throws -> some IntentResult {
        if let client = Companion.client() {
            let cache = Companion.cache
            do {
                try await SocialsSync.run(client: client, cache: cache, force: true)
            } catch SocialsError.unauthorized {
                Companion.wipe()
            } catch SocialsError.rateLimited {
                _ = try? await SocialsSync.run(client: client, cache: cache, force: false)
            } catch {}
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct SocialsWidgetEntryView: View {
    let entry: SocialsEntry

    var body: some View {
        SocialsCardView(state: .select(hasToken: entry.hasToken, snapshot: entry.snapshot, now: entry.date),
                        snapshot: entry.snapshot, now: entry.date) {
            Button(intent: RefreshSocialsIntent()) {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34).background(Palette.tile, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
    }
}

@main
struct SocialsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SocialsWidget", provider: SocialsProvider()) { entry in
            SocialsWidgetEntryView(entry: entry)
                .containerBackground(Palette.card, for: .widget)
        }
        .configurationDisplayName("Socials")
        .description("Your YouTube figures, exactly as YouTube reports them.")
        .supportedFamilies([.systemLarge])
    }
}
