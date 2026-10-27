import Foundation
import Darwin
import TemplateCore

func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), encoding: .utf8)! }
/// The bundle's version, read from the Info.plist beside the real executable (a symlink to the CLI has no bundle of its own).
let version: String = {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "development"
}()
func help() {
    print("""
    creatoros \(version) — local CreatorOS control (exit 0 success, 1 action/transport error, 2 usage)
    Global flags anywhere: --json, --show / --no-show, --data-directory PATH, --version, --help
    --show brings the app, Finder or the opened document forward; commands that show nothing ignore it. Without it nothing is activated.
    Every true/false flag also accepts --no-<flag> to send false (for example --no-enabled, --no-plain-folders).
    Arrays take a JSON array text (--stages '["A","B"]'); objects take JSON (--extra '{"Sponsor":"X"}').
    Data root: explicit flag, CREATOROS_DATA_DIRECTORY, then the stable app library.
    status never launches the app. If CreatorOS is closed, other commands start it headless (no window, no Dock icon, no focus)
    and wait up to 10 seconds; that copy quits after 10 idle minutes, and --show or opening CreatorOS brings its window up.
    Project reference: UUID, exact folder name or number; --format disambiguates. Ideas use their name.
    One writer at a time: a command that changes anything waits for a busy app or an open form (busy, form_in_use), and while it runs the app's own
    clicks and background tasks are told to retry instead of interleaving with it. Reads are checked again after they wait.
    Request ids make a retry in the same app session return the first result instead of acting twice.
    """)
    for command in ControlCommand.all {
        let flags = command.strings.map { "--\(flag($0)) VALUE" } + command.integers.map { "--\(flag($0)) N" } + command.arrays.map { "--\(flag($0)) JSON_ARRAY" }
            + command.objects.map { "--\(flag($0)) JSON_OBJECT" } + command.booleans.map { "--\(flag($0))" }
        print("\n\(command.words) \(command.positional.map { "<\($0 == "project" ? "ref" : $0)> " } ?? "")\(flags.joined(separator: " "))\n  \(command.description)\n  Example: \(command.example)")
    }
    print("\nmcp-manifest — print tools JSON from this command table\n  Example: creatoros mcp-manifest\nhelp — print this help\n  Example: creatoros help")
}
func flag(_ key: String) -> String { ControlCommand.flag(key) }
struct CLIError: Error { let code: String, message: String, exit: Int32 }
func fail(_ code: String, _ message: String, _ exit: Int32 = 2) -> CLIError { CLIError(code: code, message: message, exit: exit) }
func connectSocket(_ path: String) -> Int32? {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    var uid: uid_t = 0, gid: gid_t = 0
    guard connected, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return nil }
    return fd
}
/// Whether a copy of the app is running already, from any install: a process whose executable is
/// `…/Contents/MacOS/<name>`. Reading the process table costs well under a millisecond.
func appRunning(executable name: String) -> Bool {
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var path = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
    for pid in pids.prefix(max(0, count)) where pid > 0 && pid != getpid() {
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
        if String(cString: path).hasSuffix("/Contents/MacOS/" + name) { return true }
    }
    return false
}
let args = Array(CommandLine.arguments.dropFirst())
let wantsJSON = args.contains("--json")
do {
    if args.contains("--version") || args == ["version"] { print(wantsJSON ? json(["version": version]) : version); exit(0) }
    if args.isEmpty || args.contains("--help") || args.first == "help" { help(); exit(0) }
    var words: [String] = [], flags: [String: Any] = [:]
    var dataDirectory = ProcessInfo.processInfo.environment["CREATOROS_DATA_DIRECTORY"]
    var show = false, sawShow = false, index = 0
    let commands = ControlCommand.all
    let booleanFlags = Set(commands.flatMap(\.booleans).map(flag))
    let integerFlags = Set(commands.flatMap(\.integers).map(flag))
    let arrayFlags = Set(commands.flatMap(\.arrays).map(flag)), objectFlags = Set(commands.flatMap(\.objects).map(flag))
    let keys = Dictionary(uniqueKeysWithValues: Set(commands.flatMap { $0.strings + $0.booleans + $0.integers + $0.arrays + $0.objects }).map { (flag($0), $0) })
    while index < args.count {
        let arg = args[index]; index += 1
        if arg == "--json" { continue }
        if arg == "--show" || arg == "--no-show" { show = arg == "--show"; sawShow = true; continue }
        if arg.hasPrefix("--") {
            var name = String(arg.dropFirst(2))
            var inline: String?
            if let equals = name.firstIndex(of: "=") { inline = String(name[name.index(after: equals)...]); name = String(name[..<equals]) }
            var negated = false
            if keys[name] == nil, name.hasPrefix("no-"), booleanFlags.contains(String(name.dropFirst(3))) { negated = true; name = String(name.dropFirst(3)) }
            guard name == "data-directory" || keys[name] != nil else { throw fail("usage", "Unknown flag \(arg). See --help.") }
            if booleanFlags.contains(name) { guard inline == nil, flags[keys[name]!] == nil else { throw fail("usage", "Duplicate flag \(arg).") }; flags[keys[name]!] = !negated; continue }
            let value: String
            if let inline { value = inline }
            else { guard index < args.count, !args[index].hasPrefix("--") else { throw fail("usage", "\(arg) requires a value.") }; value = args[index]; index += 1 }
            if name == "data-directory" { dataDirectory = value; continue }
            let key = keys[name]!
            guard flags[key] == nil else { throw fail("usage", "Duplicate flag \(arg).") }
            if integerFlags.contains(name) { guard let number = Int(value) else { throw fail("usage", "\(arg) requires an integer.") }; flags[key] = number }
            else if arrayFlags.contains(name) {
                guard let list = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [Any] else { throw fail("usage", "\(arg) requires a JSON array of strings.") }
                flags[key] = list
            } else if objectFlags.contains(name) {
                guard let map = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] else { throw fail("usage", "\(arg) requires a JSON object with string values.") }
                flags[key] = map
            } else { flags[key] = value }
        } else { words.append(arg) }
    }
    if words == ["mcp-manifest"] {
        guard flags.isEmpty, !sawShow else { throw fail("usage", "mcp-manifest accepts only global output/data flags.") }
        print(json(["version": version, "tools": commands.map(\.manifest)])); exit(0)
    }
    let action = words.first == "status" ? "status" : words.prefix(2).joined(separator: ".")
    guard let command = commands.first(where: { $0.action == action }) else { throw fail("usage", "Unknown command. See --help.") }
    let consumed = action == "status" ? 1 : 2
    let rest = Array(words.dropFirst(consumed))
    if !rest.isEmpty {
        guard let positional = command.positional, rest.count == 1, flags[positional] == nil else { throw fail("usage", "Unexpected or duplicate argument. \(action) takes \(command.positional.map { "one <\($0)>" } ?? "no bare words").") }
        flags[positional] = rest[0]
    }
    // --show is global: commands that cannot show anything simply ignore it.
    if sawShow, command.booleans.contains("show") { flags["show"] = show }
    do { try command.validate(flags) } catch { throw fail("usage", error.localizedDescription) }
    let root: URL
    if let dataDirectory {
        do { root = try AppRuntime.isolated(root: URL(fileURLWithPath: dataDirectory)).root }
        catch { throw fail("usage", error.localizedDescription) }
    } else { root = AppRuntime.stableRoot }
    let path = root.appendingPathComponent("control.sock").path
    guard path.utf8.count < 104 else { throw fail("usage", "Socket path is too long; use a shorter data directory.") }
    var connection = connectSocket(path)
    // A busy app can refuse a connection for a moment (its queue of waiting callers is full). A socket file that exists
    // means an app owns it, so wait a few seconds before concluding that nothing is running and launching another copy.
    // A socket left by a copy that has quit (a headless copy's idle quit, say) needs no wait.
    if connection == nil, FileManager.default.fileExists(atPath: path), appRunning(executable: "ProjectTemplates") {
        let patience = Date().addingTimeInterval(4)
        while connection == nil && Date() < patience { Thread.sleep(forTimeInterval: 0.1); connection = connectSocket(path) }
    }
    if connection == nil && action == "status" { print(wantsJSON ? json(["running": false]) : "CreatorOS is not running."); exit(0) }
    // CLIs that find CreatorOS closed at the same moment (two MCP calls) decide one at a time. Two launches would each
    // see the other as the running copy and both give way, so the first starts it and holds the lock until this process
    // exits, after its socket answered; the next one then finds the socket.
    if connection == nil {
        let lock = open(root.appendingPathComponent("cli-launch.lock").path, O_CREAT | O_RDWR, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        connection = connectSocket(path)
    }
    if connection == nil {
        let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let launch = Process()
        launch.standardInput = FileHandle.nullDevice; launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
        var viaOpen = true
        // --headless: no window, Dock tile or update prompt. --background keeps an app older than this CLI out of the way too.
        let headlessArguments = ["--background", "--headless"] + (dataDirectory != nil ? ["--data-directory", root.path] : [])
        if bundle.pathExtension == "app" {
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-g", "-n", "-a", bundle.path, "--args"] + headlessArguments
        } else {
            // Not inside an app: this CLI came from a build folder. Start the ProjectTemplates beside it, never the installed app,
            // which may be an older release that does not know these commands.
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("ProjectTemplates")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                viaOpen = false
                launch.executableURL = sibling
                launch.arguments = headlessArguments
            } else if dataDirectory != nil {
                throw fail("no_app", "No ProjectTemplates executable sits beside this creatoros, so it cannot start a test instance. Build it (swift build) or run creatoros from inside CreatorOS.app.", 1)
            } else {
                launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                launch.arguments = ["-g", "-n", "-b", AppRuntime.releaseIdentifier, "--args"] + headlessArguments
            }
        }
        try launch.run()
        if viaOpen { launch.waitUntilExit() }
        // The socket appears a few hundred milliseconds into the launch; checking often answers as soon as it does.
        let deadline = Date().addingTimeInterval(10)
        while connection == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02); connection = connectSocket(path) }
    }
    guard let fd = connection else { throw fail("timeout", "CreatorOS did not start its control socket within 10 s.", 1) }
    defer { close(fd) }
    let seconds = command.seconds
    var timeout = timeval(tv_sec: seconds, tv_usec: 0), noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let id = UUID().uuidString
    let request = Data((json(["id": id, "action": action, "params": flags]) + "\n").utf8)
    guard request.count <= 65537 else { throw fail("usage", "Request exceeds 65,536 bytes.") }
    var sent = 0
    while sent < request.count {
        let n = request.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), request.count - sent) }
        guard n > 0 else { throw fail("timeout", "CreatorOS connection closed while sending.", 1) }; sent += n
    }
    var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while !response.contains(10) {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { throw fail("timeout", "CreatorOS did not answer within \(seconds) s; a dialog may be open in the app.", 1) }
        response.append(contentsOf: buffer.prefix(n))
        guard response.count <= 4 * 1024 * 1024 else { throw fail("internal", "App response exceeds 4 MiB.", 1) }
    }
    guard let reply = try JSONSerialization.jsonObject(with: response.prefix { $0 != 10 }) as? [String: Any], reply["id"] as? String == id, let ok = reply["ok"] as? Bool else { throw fail("internal", "Malformed app response.", 1) }
    if ok {
        guard let result = reply["result"] else { throw fail("internal", "Missing app result.", 1) }
        print(json(result)); exit(0)
    }
    let error = reply["error"] as? [String: Any] ?? [:]
    throw fail(error["code"] as? String ?? "internal", error["message"] as? String ?? "App action failed.", 1)
} catch {
    let issue = error as? CLIError ?? fail("internal", error.localizedDescription, 1)
    let output = wantsJSON ? json(["error": ["code": issue.code, "message": issue.message]]) : "\(issue.code): \(issue.message)"
    if wantsJSON { print(output) } else { FileHandle.standardError.write(Data((output + "\n").utf8)) }
    exit(issue.exit)
}
