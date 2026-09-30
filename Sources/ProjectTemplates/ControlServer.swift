import Foundation
import AppKit
import Darwin
import TemplateCore

struct ControlFailure: LocalizedError {
    let code: String, message: String
    var errorDescription: String? { message }
}

final class ControlServer: @unchecked Sendable {
    private var listener: Int32 = -1
    private let path: String
    private let handler: @MainActor ([String: Any]) async -> [String: Any]
    init(root: URL, handler: @escaping @MainActor ([String: Any]) async -> [String: Any]) throws {
        self.path = root.appendingPathComponent("control.sock").path; self.handler = handler
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), chmod(root.path, 0o700) == 0 else { throw AppFailure("Control directory must be owned by this user and cannot be a symlink.") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AppFailure("Control socket path is too long. Use a shorter data directory.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { throw AppFailure("Refusing to remove a non-socket control path.") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(probe) }
            let answered = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
            guard !answered else { throw AppFailure("Another CreatorOS already controls this data directory.") }
            guard unlink(path) == 0 else { throw AppFailure("Cannot remove stale control socket.") }
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw AppFailure("Cannot create control socket.") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else { close(listener); listener = -1; throw AppFailure("Cannot bind private control socket.") }
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                DispatchQueue.global(qos: .utility).async { [self] in serve(client) }
            }
        }
    }
    private func serve(_ client: Int32) {
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 30, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(contentsOf: buffer.prefix(count))
            while let end = data.firstIndex(of: 10) {
                let line = data.prefix(upTo: end); data.removeSubrange(...end)
                if line.count > 65536 { return }
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                let semaphore = DispatchSemaphore(value: 0)
                var response = Data()
                Task { @MainActor in
                    let result = await handler(request)
                    response = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
                    response.append(10); semaphore.signal()
                }
                semaphore.wait()
                var sent = 0
                while sent < response.count {
                    let n = response.withUnsafeBytes { write(client, $0.baseAddress!.advanced(by: sent), response.count - sent) }
                    if n <= 0 { return }; sent += n
                }
            }
            if data.count > 65536 { return }
        }
    }
}

extension AppModel {
    func startControl() {
        guard controlServer == nil else { return }
        do { controlServer = try ControlServer(root: runtime.root) { [weak self] in await self?.control($0) ?? ["id": NSNull(), "ok": false, "error": ["code": "internal", "message": "App is closing."]] } }
        catch { storeUsable = false; self.error = error.localizedDescription }
    }
    func control(_ request: [String: Any]) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        do {
            guard let stringID = id as? String, !stringID.isEmpty, stringID.utf8.count <= 4096,
                  Set(request.keys).isSubset(of: ["id", "action", "params"]), let action = request["action"] as? String,
                  let params = request["params"] as? [String: Any] else { throw ControlFailure(code: "bad_request", message: "Send id, action and params as a JSON object.") }
            guard let command = ControlCommand.all.first(where: { $0.action == action }) else { throw ControlFailure(code: "unknown_action", message: "Unknown action: \(action)") }
            do { try command.validate(params) } catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
            let key = (params["requestId"] as? String).map { action + ":" + $0 }
            if let key, let result = controlResults[key] { return ["id": id, "ok": true, "result": result] }
            if let key, controlPending.contains(key) { throw ControlFailure(code: "busy", message: "This request is still running; retry the same requestId.") }
            if let key { guard controlResults.count < 4096 else { throw ControlFailure(code: "busy", message: "Session request cache is full; restart before creating more projects.") }; controlPending.insert(key) }
            defer { if let key { controlPending.remove(key) } }
            let mutating = action == "project.create" || action == "project.rename"
            if mutating {
                guard !controlMutating else { throw ControlFailure(code: "busy", message: "Another control mutation is preparing or running.") }
                controlMutating = true
            }
            defer { if mutating { controlMutating = false } }
            let result = try await controlAction(action, params)
            if let key { controlResults[key] = result }
            if params["show"] as? Bool == true, action != "project.reveal" { NSApp.activate(ignoringOtherApps: true) }
            return ["id": id, "ok": true, "result": result]
        } catch {
            let failure = error as? ControlFailure ?? ControlFailure(code: "internal", message: error.localizedDescription)
            return ["id": id, "ok": false, "error": ["code": failure.code, "message": failure.message]]
        }
    }
    func controlRecord(_ params: [String: Any]) throws -> ProjectRecord {
        let ref = params["project"] as? String ?? ""
        let matches = library.projects.filter { record in
            (params["format"] == nil || record.format == params["format"] as? String) &&
            (record.id.uuidString.lowercased() == ref.lowercased() || record.name == ref || (Int(ref) != nil && record.numberValue == Int(ref)))
        }
        guard !matches.isEmpty else { throw ControlFailure(code: "not_found", message: "No project matches \(ref).") }
        guard matches.count == 1 else { throw ControlFailure(code: "ambiguous_project", message: "Use a UUID or --format: " + matches.prefix(5).map { "\($0.number ?? "") \($0.format) \($0.name)" }.joined(separator: "; ")) }
        let record = matches[0]
        guard record.isPlanned || !hiddenLocations.contains(record.location.key) else { throw ControlFailure(code: "location_hidden", message: "Tick this project's location in the GUI first.") }
        return record
    }
    func controlSummary(_ record: ProjectRecord) -> [String: Any] {
        ["id": record.id.uuidString, "number": record.number as Any? ?? NSNull(), "name": record.name, "format": record.format,
         "stage": effectiveStage(record), "path": record.path, "location": record.isPlanned ? NSNull() : record.location.key as Any,
         "mounted": !record.isPlanned && mountedLocations.contains(record.location.key), "pinned": record.isPinned]
    }
    func controlAction(_ action: String, _ params: [String: Any]) async throws -> [String: Any] {
        if action == "status" { return ["app": AppInfo.name, "version": AppInfo.version, "channel": AppInfo.channel, "pid": getpid(), "dataRoot": runtime.root.path, "isolated": runtime.isIsolated, "storeUsable": storeUsable, "busy": busy || controlMutating, "statusText": status, "page": page.rawValue, "selectedProject": selectedRecord.map { ["id": $0.id.uuidString, "name": $0.name] } as Any? ?? NSNull(), "newProjectSheetOpen": newProjectPresented, "renameSheetOpen": renamePrompt != nil, "socket": runtime.root.appendingPathComponent("control.sock").path] }
        guard storeUsable else { throw ControlFailure(code: "store_unavailable", message: "Resolve the library error in the GUI first.") }
        let visible = library.projects.filter { $0.isPlanned || !hiddenLocations.contains($0.location.key) }
        if action == "library.stats" { return ["schema": Library.currentSchema, "projects": visible.filter { !$0.isPlanned }.count, "ideas": visible.filter(\.isPlanned).count, "byFormat": Dictionary(grouping: visible, by: \.format).mapValues(\.count), "byStage": Dictionary(grouping: visible, by: { effectiveStage($0) }).mapValues(\.count), "templates": library.templates.count, "sets": library.sets.count, "locations": distinctLocations.count, "hiddenLocations": hiddenLocations.sorted()] }
        if action == "project.list" {
            let records = visible.filter { record in
                (params["includeIdeas"] as? Bool == true || !record.isPlanned) &&
                (params["format"] == nil || record.format == params["format"] as? String) &&
                (params["stage"] == nil || effectiveStage(record) == params["stage"] as? String) &&
                (params["search"] == nil || record.searchableText.localizedCaseInsensitiveContains(params["search"] as? String ?? ""))
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            let offset = params["offset"] as? Int ?? 0, limit = params["limit"] as? Int ?? 50
            let batch = records.dropFirst(min(offset, records.count)).prefix(limit)
            return ["total": records.count, "offset": offset, "returned": batch.count, "projects": batch.map(controlSummary)]
        }
        if action == "project.create" {
            guard !busy else { throw ControlFailure(code: "busy", message: "Wait for the current operation.") }
            guard !newProjectPresented, renamePrompt == nil, !importPresented, startingFrom == nil else { throw ControlFailure(code: "form_in_use", message: "Close the app's project form first.") }
            let requestedFormat = params["format"] as! String
            guard Library.formats.contains(requestedFormat) else { throw ControlFailure(code: "invalid_params", message: "Use Long, Short, Podcast or Livestream.") }
            let saved = (format, selection, number, numberIsAutomatic, title, campaign, extraValues, destination, plainFolders)
            defer {
                format = saved.0; selection = saved.1; number = saved.2; numberIsAutomatic = saved.3
                title = saved.4; campaign = saved.5; extraValues = saved.6; destination = saved.7; plainFolders = saved.8
                refresh()
            }
            format = requestedFormat; changeFormat()
            if let template = params["template"] as? String {
                let sets = library.sets.filter { $0.id.uuidString.lowercased() == template.lowercased() || $0.name == template }
                let templates = library.templates.filter { $0.id.uuidString.lowercased() == template.lowercased() || $0.name == template }
                guard sets.count + templates.count == 1 else { throw ControlFailure(code: "template_not_ready", message: "Choose a unique template set or payload UUID/name.") }
                selection = sets.first.map { .set($0.id) } ?? .legacy(templates[0].id)
            }
            guard payload != nil else { throw ControlFailure(code: "template_not_ready", message: "Set up a template for this format in the GUI.") }
            title = params["title"] as! String; campaign = params["campaign"] as? String ?? ""
            numberIsAutomatic = params["number"] == nil; number = params["number"] as? String ?? suggestedNumber
            do { _ = try fields.finalName() } catch { throw ControlFailure(code: "invalid_params", message: error.localizedDescription) }
            guard !hiddenLocations.contains(ProjectLocation(path: destination).key) else { throw ControlFailure(code: "location_hidden", message: "Tick the destination's location in the GUI first.") }
            guard !destination.isEmpty else { throw ControlFailure(code: "no_destination", message: "Choose a destination for this format in the GUI.") }
            busy = true
            refresh(); await refreshTask?.value
            busy = false
            guard !newProjectPresented, renamePrompt == nil, !importPresented else { throw ControlFailure(code: "form_in_use", message: "Close the app's project form first.") }
            guard canCreate else { throw ControlFailure(code: "template_not_ready", message: validation.isEmpty ? "Template cannot create this project." : validation) }
            let templateID = payload?.id.uuidString
            let record: ProjectRecord = try await withCheckedThrowingContinuation { done in create { done.resume(with: $0) } }
            var result = controlSummary(record); result["template"] = templateID as Any? ?? NSNull(); return result
        }
        let record = try controlRecord(params)
        if action == "project.status" {
            let inspection = record.isPlanned ? nil : Catalogue.availability(record)
            var result = controlSummary(record)
            result["title"] = ProjectRename.fields(of: record)?.title ?? record.title
            result["campaign"] = record.campaign as Any? ?? NSNull(); result["available"] = inspection?.available ?? false
            result["availability"] = inspection?.status ?? "Planned idea"; result["folderCreated"] = record.folderCreated.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
            result["previousPaths"] = record.previousPaths ?? []; return result
        }
        guard !busy else { throw ControlFailure(code: "busy", message: "Wait for the current operation.") }
        if action == "project.rename" {
            guard renamePrompt == nil, !newProjectPresented, !importPresented else { throw ControlFailure(code: "form_in_use", message: "Close the app's rename or creation form first.") }
            guard let fields = ProjectRename.fields(of: record) else { throw ControlFailure(code: "invalid_params", message: "Rename needs Number — Format — [Campaign — ]Title and an existing folder.") }
            let number = params["number"] as? String ?? fields.number
            let campaign = params["campaign"] as? String ?? fields.campaign
            let title = params["title"] as? String ?? fields.title
            let headings = params["updateHeadings"] as? Bool ?? false
            let plan: ProjectRenamePlan
            do { busy = true; defer { busy = false }; plan = try await renamePlan(for: record.id, number: number, campaign: campaign, title: title, updateHeadings: headings) }
            catch let failure as ControlFailure { throw failure }
            catch { throw ControlFailure(code: "rename_failed", message: error.localizedDescription) }
            let adobe = Self.runningAdobeApps()
            if params["dryRun"] as? Bool == true {
                return ["dryRun": true, "oldName": plan.oldName, "newName": plan.newName, "changes": plan.changes.count,
                        "items": plan.changes.prefix(50).map { ["path": $0.path, "from": $0.from, "to": $0.to] }, "warnings": plan.warnings + adobe.map { "Running: " + $0 }]
            }
            guard adobe.isEmpty || params["ignoreOpenApps"] as? Bool == true else { throw ControlFailure(code: "adobe_app_running", message: "Close " + adobe.joined(separator: ", ") + " or explicitly use --ignore-open-apps.") }
            let result: ProjectRenameResult = try await withCheckedThrowingContinuation { done in
                renameProject(record.id, number: number, campaign: campaign, title: title, updateHeadings: headings, expectedChanges: plan.changes) { done.resume(with: $0) }
            }
            return ["id": record.id.uuidString, "oldName": plan.oldName, "newName": plan.newName, "oldPath": result.oldRoot.path, "newPath": result.newRoot.path,
                    "renamed": result.changes.count, "manifest": result.manifest.path, "warnings": plan.warnings]
        }
        if action == "project.open" { search = ""; formatFilter = "All formats"; excludedStages = []; selectedProject = record.id; page = .projects; selectProject(); return ["id": record.id.uuidString, "name": record.name, "selected": true] }
        if action == "project.reveal" {
            let url = try projectFolderForAction(record)
            let config = NSWorkspace.OpenConfiguration(); config.activates = params["show"] as? Bool == true
            try await NSWorkspace.shared.open(url, configuration: config)
            return ["id": record.id.uuidString, "path": url.path]
        }
        throw ControlFailure(code: "unknown_action", message: action)
    }
}
