# Content Template

Junior chose Content Template as the current name. The enclosing project folder and documentation have been renamed. Source targets, installed 0.3.0 app, old archives and data directory still use Project Templates pending Claude's safe display-name update. Existing technical names in commands and paths below remain intentional, not instructions to discard or rename user data.

Native SwiftUI/AppKit utility. Current version is 0.3.0, a development milestone, not the complete version-one specification. This update adds an in-app file browser, consistent format artwork and filters, and a native parameter form with live naming and icon previews.

## Build and run

Requires an Apple silicon Mac and Swift 6 command-line tools with a macOS SDK. No third-party dependencies. Source deployment target is macOS 14; the current test machine runs macOS 26.6.2. Older supported OS releases still need testing.

From this folder:

```sh
swift build --scratch-path /private/tmp/project-templates-build
swift run --scratch-path /private/tmp/project-templates-build CoreChecks
zsh build.sh
```

The packaging script builds the `.app` in a fresh temporary packaging directory and writes a versioned ZIP under `../Outputs/`, using the version from Info.plist. It refuses to replace an existing archive. For a separate iteration choose a fresh `PROJECT_TEMPLATES_OUTPUT_ROOT`. Extract into a normal local Applications folder, not a file-provider-managed folder. JuniorOS's provider was observed reattaching FinderInfo to app bundles and invalidating strict signature verification, so durable delivery here is an archive. The locally installed build is in the current user's Applications folder.

The binary uses an ad-hoc local signature, not Developer ID or notarisation. Open `Package.swift` in Xcode to work on the source package; packaging remains in the script. Xcode 26.6 is installed and working.

## App icon

Original code-native artwork is in `Scripts/render-icon.swift`. Run `zsh Scripts/build-icon.sh` to regenerate the transparent 1024-pixel PNG and multi-resolution ICNS. The installer uses `Resources/AppIcon.icns` and Info.plist's `CFBundleIconFile`, so the icon travels with the app instead of relying on a local Finder override. Keep this artwork during the name update unless Junior requests a redesign.

For isolated UI testing launch the executable with `--data-directory` followed by a disposable absolute directory. Normal runs keep JSON and managed templates under the current user's Application Support/Project Templates. Never point test data at another application's data folder.

## Current implementation

- Independent whole-folder and `.pht/Files` imports, with mode, size and tree preview.
- Structure-only import excludes regular files and packages, preserving directory icons.
- Four format presets with remembered destinations/bookmarks and independently saved image/folder icons. Saved icons remain fixed until explicitly changed.
- Manual number, optional campaign and title; preview-driven output naming.
- Background scan/copy, progress, cancellation, exclusive finalisation and no overwrites.
- Searchable project and export catalogue across user-selected local, external and mounted cloud folders.
- Saved collection locations, review-before-register discovery, refresh, locate with previous-path history, and removal of records only.
- Native AppKit video preview, initially paused and muted, plus opening in the user's chosen video app.
- Multiple explicitly marked final exports per project and a combined finals-only view. Never guesses final approval from filenames or modification dates.
- Native Project Number, Content Format, Campaign and Project Name parameter grid, a separate template selector and exact filename replacement preview.
- Saved format artwork in project/export rows and visible All, Long, Short, Podcast and Live filter buttons. Export format follows its parent project, not a guess from the video's filename.
- Project and managed-template file browsing, current-folder search, parent/root navigation and a Project documents shortcut for editing files. Double-click a folder to browse, or select a document and open it in its default application.

No personal paths, templates, preferences or history are bundled in the executable.

## Catalogue behaviour

Add a collection through Projects → Add, review the detected folders, then register them. Add one existing project when its layout is not recognised. More → Add Export Subfolder supports custom export locations inside the project. The collection scanner recognises common numbered and legacy project layouts, stops at recognised project roots and does not recurse into their source media. Export indexing reads names, sizes and dates, not video contents. Playback is explicit and may hydrate a cloud placeholder.

The JSON catalogue caches relative export paths, marked finals, prior project locations and volume identity. It remains searchable while drives are disconnected. Selection refreshes that project, not every drive at launch. Locate Folder records the old path without moving anything. Collection scans deduplicate exact paths, retain unseen projects and preserve user marks; copies in different locations remain separate. No automatic historical location reconstruction or content-hash duplicate detection is claimed.

Discovery has bounded depth and entry counts. A partial export scan retains cached entries with a visible note. Missing, inaccessible and stale bookmarks do not erase records. Offline and wrong-volume states exist, but physical unplug-during-playback, permissions and cloud hydration still need release testing. H.264 playback was tested; the extensions indexed are not a promise that every codec is natively playable.

Schema 1 loads into schema 2 with optional new fields. The first upgraded save keeps `library-before-schema-2.json`. Do not run older app versions against upgraded data. Avoid simultaneous app instances and assistant edits; release-grade cross-process locking is still pending.

`LibraryAdmin` is an explicit local migration/check helper, not bundled in the app. `inspect` reads a collection; `catalogue` registers one with a library backup; `icons` captures four existing custom folder icons in Long, Short, Podcast, Livestream order. Quit the app before helper writes. The macOS icon service must be accessible; a restricted tool process can return generic folder artwork even for a custom-icon folder, so visually check captured results. Use `Scripts/inspect-folder-icons.swift` for read-only PNG inspection.

## Shared assistant handover

Read `AGENTS.md` here and the project-level instructions. `CLAUDE.md` points to the same rules. MEMORY holds current decisions/status; Validation holds executed checks and recovery details. Work in this same source folder from any assistant. Update those records after meaningful work, not just when a handoff is requested. HANDOFF is only a compatibility pointer, not another status file to maintain.

## File browser and folder artwork

Files opens the selected project's immediate directory without a Finder window. Search filters that directory; Project documents performs a bounded search for supported editing files, ignoring media/export branches and package internals. Packages remain opaque. Opening uses NSWorkspace and the registered application, with visible failure messages. Managed-template documents require a warning confirmation because saving in an editor changes the reusable copy, though not its original import source. Browsing itself is read-only. Generic executable/script launching is deliberately excluded.

The browser and template tree use actual macOS file/folder icons. Finder's `Icon\r`, AppleDouble files and `.DS_Store` are hidden in the browser. Icon copying preserves FinderInfo/resource forks and explicitly sets the hidden flag on generated `Icon\r` metadata. Do not delete those files: they carry macOS folder artwork. There is no portable, file-free custom folder icon shared by macOS, Windows and phone file browsers. Windows uses separate shell metadata such as desktop.ini and an icon resource; no Windows export feature is implemented.

Browser enumeration is cancellable and bounded, checks volume identity and containment, and rejects symlinks. It is not a general Finder replacement or an adversarial filesystem security boundary. Launching a cloud-only document may cause its provider to download it.

## Filename contract

Field tokens are case-sensitive `[Project Number]`, `[Content Format]`, `[Campaign]`, `[Project Name]`. The complete-name token `[template]` is case-insensitive, including `[Template]`. `[Conent Form]` maps to Content Format explicitly. Unrecognised tokens produce an error. Replacement is single-pass; user-entered values are not recursively expanded.

Legacy replacement is case-insensitive and applies only to the exact `Template` name or a leading `Template.` or `Template ` boundary. Thus `Template.prproj`, `Template Description.rtf` and `Template – Video Thumbnail.psd` are renamed. `My Template notes.txt` and `Templates.txt` are unchanged. Packages are copied without substitutions inside their contents. No Adobe/Rich Text internal data is rewritten.

Ordinary output components reject Windows-reserved characters/device names, control characters, path traversal, trailing dots/spaces and case/Unicode collisions. Finder `Icon\r` metadata is exempt. `.DS_Store` is deliberately omitted as disposable Finder view state, not custom icon data.

## File-copy policy

The engine streams independent file data in 1 MiB chunks and checks cancellation between chunks. Only FinderInfo and resource-fork extended attributes are copied. It does not replay arbitrary provider IDs, ACLs or ownership data. Filesystem permissions/executable bits and other specialised metadata are not preserved by this milestone, so do not use it to distribute executable software templates.

All symlinks are rejected in full imports. Structure-only reports and skips them. No attempt is made to follow links into source media. A changed file invalidates an existing plan. A uniquely named sibling staging folder is committed using macOS `renamex_np` with `RENAME_EXCL`; failure cleanup removes only that operation's stage. Destination write access and mount errors surface to the user.

The current implementation assumes the app-managed library is not concurrently rewritten by an adversarial process. It does not yet provide descriptor-relative traversal protecting every directory component against malicious symlink-swap races. Do not use this as a security boundary for untrusted, actively changing templates. No cloud/network atomicity or upload completion is claimed.

## Remaining release gates

See the project implementation plan and validation report. Still to implement or fully validate are automatic shared/per-format counters, editable presets/naming, cached template indexing, multi-item drag/drop, branch exclusions in the UI, managed editing/duplication/re-import recovery, portable sharing, optional Post Haste recents, release-grade volume/access recovery, transaction recovery and multi-instance coordination. Direct Premiere opening and native browser navigation were exercised with a generated disposable project in 0.3.0; this does not establish arbitrary Adobe media relinking.

The reader already accepts branch exclusions internally, but the interface does not expose them yet. Package matching uses native package metadata plus known extensions; unfamiliar package formats need tests. Resource forks are copied whole rather than streamed, so unusually large metadata may affect memory/cancellation responsiveness. Estimated size currently describes file data, not metadata or allocated storage.

## Release route

Local testing needs no purchased membership. Smooth external distribution requires an authorised Developer ID Application identity, hardened-runtime signing, an Apple notarisation submission and stapled ticket, followed by verification on another Mac. None is performed by `build.sh`.

When authorised and credentials exist, the release sequence is to rebuild into a fresh release folder, sign with the selected Developer ID identity and hardened runtime, create a metadata-preserving archive with `ditto`, submit via `xcrun notarytool`, inspect the accepted result, staple with `xcrun stapler`, then verify with `codesign` and `spctl`. Do not run this sequence under someone else's identity or disable Gatekeeper. See [Apple Developer ID](https://developer.apple.com/developer-id/) and [notarisation guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
