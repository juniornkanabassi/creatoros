import Observation
import SwiftUI
import UIKit
import WidgetKit

@MainActor @Observable
final class AppModel {
    var snapshot = SocialsSnapshot()
    var hasToken = false
    var busy = false
    var message: String?

    init() { reload() }

    var state: SocialsDisplayState { .select(hasToken: hasToken, snapshot: snapshot) }

    var statusText: String {
        switch state {
        case .needsReconnect: "Needs reconnecting on your Mac"
        case .expired: "Offline, data expired"
        case .notConnected: "Not connected. Connect YouTube from CreatorOS on your Mac."
        case .normal, .waiting: "Connected as \(snapshot.summary?.youtube?.channelTitle ?? "YouTube")"
        case .loading, .notSetUp: "Not read yet"
        }
    }

    func reload() {
        hasToken = Companion.credentials.read() != nil
        snapshot = Companion.cache.load()
    }

    func setUp(worker: String, code: String) async {
        guard let url = URL(string: worker.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host != nil else {
            message = "Enter the Worker address, starting with https://"; return
        }
        busy = true; defer { busy = false }
        do {
            let client = SocialsClient(baseURL: url, token: nil)
            let token = try await client.enrol(code: code.trimmingCharacters(in: .whitespaces), name: UIDevice.current.name, kind: "iphone")
            try Companion.credentials.write(token)
            Companion.defaults.set(url.absoluteString, forKey: "workerURL")
            message = nil
            reload()
            await sync(force: false)
        } catch { message = error.localizedDescription }
    }

    func sync(force: Bool) async {
        guard let client = Companion.client() else { return }
        busy = true; defer { busy = false }
        do {
            snapshot = try await SocialsSync.run(client: client, cache: Companion.cache, force: force)
            message = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch SocialsError.unauthorized {
            Companion.wipe(); reload()
            message = SocialsError.unauthorized.localizedDescription
        } catch { message = error.localizedDescription }
    }

    func clearData() {
        Companion.clearCache(); snapshot = SocialsSnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Revokes this phone's token on the Worker when it can, then forgets the token and cache here either way.
    func removeDevice() async {
        if let client = Companion.client(), let me = try? await client.devices().first(where: \.current) {
            try? await client.revoke(deviceID: me.id)
        }
        Companion.wipe(); reload(); message = nil
    }
}
