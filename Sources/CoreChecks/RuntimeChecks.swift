import Foundation
import TemplateCore

func runtimeChecks(base: URL) throws {
    let stable = base.appendingPathComponent("Stable")
    let alpha = base.appendingPathComponent("Alpha")
    let runtime = try AppRuntime.isolated(root: alpha, stableRoot: stable)
    let production = try AppRuntime.production(stableRoot: stable)
    let systemTemporaryChild = FileManager.default.temporaryDirectory.appendingPathComponent("CreatorOS-runtime-" + UUID().uuidString)
    let temporaryRuntime = try AppRuntime(root: systemTemporaryChild)
    try temporaryRuntime.requireWritable(systemTemporaryChild.appendingPathComponent("Projects"))
    try check(AppRuntime.contains(temporaryRuntime.root, systemTemporaryChild), "real system temporary URL and its canonical alias share the alpha boundary")
    try check(AppRuntime.contains(runtime.root, alpha.resolvingSymlinksInPath()) && AppRuntime.contains(alpha.resolvingSymlinksInPath(), runtime.root), "alpha uses its independent data root")
    try runtime.requireWritable(alpha.appendingPathComponent("Projects/Short"))
    let external = base.appendingPathComponent("External projects/Short")
    try production.requireWritable(external)
    var productionLibrary = Library(); productionLibrary.presets[0].destination = external.path
    try production.validate(productionLibrary)
    try check(!production.isIsolated && AppRuntime.contains(production.root, stable) && AppRuntime.contains(stable, production.root), "production uses the preserved stable library and accepts saved external destinations")
    try rejects("production refuses home as a write destination") { try production.requireWritable(FileManager.default.homeDirectoryForCurrentUser) }
    try rejects("production rejects relative stored paths before URL normalisation") { var bad = Library(); bad.presets[0].destination = "relative/project"; try production.validate(bad) }
    try check(try AppRuntime.forLaunch(bundleIdentifier: AppRuntime.alphaIdentifier, channel: "α", dataRoot: alpha).isIsolated, "alpha identity remains isolated")
    try check(try !AppRuntime.forLaunch(bundleIdentifier: AppRuntime.releaseIdentifier, channel: "").isIsolated, "release identity selects production")
    try rejects("the pre-release identity no longer opens production") { _ = try AppRuntime.forLaunch(bundleIdentifier: AppRuntime.legacyIdentifier, channel: "") }
    try rejects("unknown identity cannot open production") { _ = try AppRuntime.forLaunch(bundleIdentifier: "example.unreviewed", channel: "") }
    try rejects("alpha refuses stable data root") { _ = try AppRuntime(root: stable, stableRoot: stable) }
    try rejects("alpha refuses ancestor of stable root") { _ = try AppRuntime(root: base, stableRoot: stable) }
    try rejects("alpha refuses child of stable root") { _ = try AppRuntime(root: stable.appendingPathComponent("Child"), stableRoot: stable) }
    try rejects("alpha refuses sibling-prefix escape") { try runtime.requireWritable(base.appendingPathComponent("Alpha-old")) }
    try rejects("alpha refuses parent traversal") { try runtime.requireWritable(alpha.appendingPathComponent("../Stable")) }
    try rejects("alpha refuses broad temporary root") { _ = try AppRuntime(root: URL(fileURLWithPath: "/private/tmp")) }
    try rejects("alpha refuses arbitrary production directory override") { _ = try AppRuntime(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Content Creation")) }
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stable, withIntermediateDirectories: true)
    let alias = alpha.appendingPathComponent("Outside")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: stable)
    try rejects("alpha refuses symlink write escape") { try runtime.requireWritable(alias.appendingPathComponent("new")) }
    try rejects("alpha refuses symlink data root") { _ = try AppRuntime(root: alias, stableRoot: base.appendingPathComponent("OtherStable")) }
    var imported = Library(); imported.presets[0].destination = stable.path
    try rejects("alpha refuses imported external destination before background work") { try runtime.validate(imported) }
    try check(runtime.sharesProductionPreferences(bundleIdentifier: AppRuntime.releaseIdentifier) && !runtime.sharesProductionPreferences(bundleIdentifier: AppRuntime.alphaIdentifier) && !production.sharesProductionPreferences(bundleIdentifier: AppRuntime.releaseIdentifier), "only an isolated stable-bundle launch shares the production preferences domain")
    try check(runtime.defaultsSuite != (try AppRuntime(root: base.appendingPathComponent("Alpha2"), stableRoot: stable)).defaultsSuite, "disposable alpha roots use separate preferences")
    // A fixed root whose base64 has no "/", so the suite is a plain domain name. The literal pins the formula Scripts/instances.py and the zsh harnesses repeat.
    let suitePin = try AppRuntime(root: URL(fileURLWithPath: "/private/tmp/cos-suite-pin"))
    try check(suitePin.defaultsSuite == "local.creatoros.alpha.L3ByaXZhdGUvdG1wL2Nvcy1zdWl0ZS1waW4=", "harness scripts can derive the disposable defaults suite from the data directory")
    let disposable = try AppRuntime(root: base.appendingPathComponent("Preferences"))
    let alphaInstall = try AppRuntime.isolated(), alphaChild = try AppRuntime.isolated(root: AppRuntime.alphaRoot.appendingPathComponent("Child"))
    try check(disposable.ownsDisposablePreferences && temporaryRuntime.ownsDisposablePreferences && !production.ownsDisposablePreferences
              && !alphaInstall.ownsDisposablePreferences && !alphaChild.ownsDisposablePreferences,
              "only temporary roots own their preferences; production and the alpha install keep theirs")
    try rejects("invisible launch requires an explicit data root") { _ = try AppRuntime.forInvisibleLaunch(dataRoot: nil) }
    try rejects("invisible launch refuses the production library") { _ = try AppRuntime.forInvisibleLaunch(dataRoot: AppRuntime.stableRoot) }
    try rejects("invisible launch refuses the persistent alpha library") { _ = try AppRuntime.forInvisibleLaunch(dataRoot: AppRuntime.alphaRoot) }
    try rejects("invisible launch refuses a persistent alpha descendant") { _ = try AppRuntime.forInvisibleLaunch(dataRoot: AppRuntime.alphaRoot.appendingPathComponent("Child")) }
    try rejects("invisible launch refuses a symbolic-link root") { _ = try AppRuntime.forInvisibleLaunch(dataRoot: alias) }
    try check(try AppRuntime.forInvisibleLaunch(dataRoot: disposable.root).root == disposable.root,
              "invisible launch accepts an explicit disposable data root")
    let tempAlias = URL(fileURLWithPath: disposable.root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
    try check(try AppRuntime.forInvisibleLaunch(dataRoot: tempAlias).root == disposable.root,
              "invisible launch accepts the macOS temporary directory alias")
}
