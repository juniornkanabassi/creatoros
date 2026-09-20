# CreatorOS

Native SwiftUI/AppKit Mac app that creates correctly named project folders from reusable content templates and tracks them through the content pipeline. Current source targets **CreatorOS 0.15.2 α**, under validation, not a final release. The usable baseline remains **Content Template 0.11.0**, tagged `v0.11.0`, installed separately at `/Applications/Content Template.app`.

Alpha uses `local.creatoros.alpha`, `CreatorOS Alpha.app` and `~/Library/Application Support/CreatorOS Alpha/`. Stable retains `local.projecttemplates.mac` and `~/Library/Application Support/Project Templates/`. Both keep the internal executable name `ProjectTemplates`; that is not a user-facing product name. Alpha must never upgrade or write the stable library. See the cumulative acceptance checklist before installation.

Read `../00 Project State/ARCHITECTURE-ESSENTIALS.md` before changing code. The full design is `../00 Project State/ARCHITECTURE.md` and the product statement is `../00 Project State/PRD.md`.

## Build and run

Apple silicon Mac, Xcode 26.6 or Swift 6 command-line tools with a macOS SDK. No third-party dependencies. Deployment target macOS 14; tested on macOS 26.6. The durable-save wrapper was also tested with Xcode 27 / Swift 6.4.

```sh
swift build --scratch-path /private/tmp/content-template-build
swift run --scratch-path /private/tmp/content-template-build CoreChecks
# Legacy SwiftPM debug directory:
zsh Scripts/check-durable-save.sh /private/tmp/content-template-build/arm64-apple-macosx/debug
# Xcode 27 scratch root:
zsh Scripts/check-durable-save.sh /private/tmp/content-template-build
swift run --scratch-path /private/tmp/content-template-build CoreChecks --master "/path/to/a/real/template"
zsh build.sh
```

`CoreChecks` prints `RESULT n checks passed` and keeps its disposable fixtures under the temporary directory it prints. The optional `--master` argument runs a read-only import and creation against a real template and verifies every byte and every folder icon afterwards.

`build.sh` builds release, assembles `CreatorOS Alpha.app` in a fresh temporary folder, strips bundle-root FinderInfo, signs ad hoc, verifies strictly and writes `../Outputs/CreatorOS Alpha <version> α.zip`, taking the version from `Resources/Info.plist`. It refuses archive overwrite; set `CONTENT_TEMPLATE_OUTPUT_ROOT` for a separate iteration. After the acceptance gate passes, `zsh install.sh` installs only the expected alpha identifier/version, refuses a running target and restores the prior alpha if final verification fails. Set `CONTENT_TEMPLATE_INSTALL_ROOT=/tmp/test-Applications` for a disposable dry run. Stable app and library are not installation targets.

For interface testing launch with `--data-directory <dedicated disposable temporary folder>`. Alpha rejects production references and starts empty; create synthetic fixtures inside its isolated root. Do not copy the real library: its destinations and bookmarks still reference production data. The optional test-only `--display-name 'Prompter XL'` positions the test window when a disposable data directory is supplied.

## Source layout

```
Sources/TemplateCore/     engine, no UI
  Library.swift           JSON store, schema 6, upgrade backups
  AppRuntime.swift        alpha writable-root and stored-reference isolation
  Compatibility.swift     shared audit, explicit corrected-copy proposal and manifest
  IdeaWorkspace.swift     owned workspaces, verified promotion and recoverable Trash
  Pipelines.swift         Recordings and Live boards, stage colours, Finder tags
  TemplateSets.swift      content template sets and per-format variants
  Naming.swift            fields, tokens, the shared substitution rule, validation
  FileEngine.swift        template reader, copy plan, copy engine, icon service
  Preview.swift           placeholder rendering that can never become a copy plan
  Catalogue.swift         project discovery, availability, retained export indexing
  Locations.swift         drive and cloud classification, per-format numbering
  Relink.swift            finding moved project folders
  Configuration.swift     validation of custom field names and stage lists
  ProjectBrowser.swift    safe read-only folder listing and opening rules
Sources/ProjectTemplates/ the app
  AppModel.swift          state, selection, structure cache, numbering, mounts, relinking, pipeline
  CreationView.swift      New Project form and live preview
  PipelineView.swift      board, cards, status editor, filters, location badge, new idea sheet
  CatalogueViews.swift    Projects list with pinned and date groups, inspector, discovery sheet
  TemplateSetsView.swift  Templates page, set detail, legacy templates, new-set sheet
  FileBrowserView.swift   shared Icon, List and Column browser
  ProjectFileBrowser.swift host for browsing a real folder with open rules
  SettingsView.swift      Settings window
  ProjectTemplatesApp.swift scene, menus, main split view, import sheet
Sources/CoreChecks/       assertion suite
Scripts/render-icon.swift historical app icon drawing; build-icon.sh converts Resources/AppIcon.png to ICNS
Scripts/configure-library.swift one-time personal setup (Notion stages and default destinations), run with the app closed
Scripts/notion-backup.py  offline Notion export backup utility with its tests; not part of the app
Resources/                Info.plist, AppIcon
```

## Git

`Source/` is a local git repository, tagged `v0.0.0` (baseline), `v0.1.0`, `v0.2.0` to `v0.11.0` at each delivery, following the PATCH/MINOR/MAJOR rule in `../../AGENTS.md`. Hooks are local config; after cloning run `git config core.hooksPath .githooks` and `git config commit.template .gitmessage`. Nothing is pushed anywhere until Junior says so.

## What the app does

- A **content template** is a brand, client or campaign set. Each of Long, Short, Podcast and Live can point at its own managed payload, or share another format's. A set plus a format resolves to one payload or to a setup state; there is no fallback.
- **Legacy templates** (managed copies not in any set) are still usable directly, and one button turns one into a set with all four formats on that payload.
- **Import** a folder or a Post Haste `.pht` as files and folders or as folder structure only, with a tree preview and size before copying. The original is never touched.
- **New Project** shows the whole prospective folder as soon as a set and format are chosen, with `[Project Number]` and `[Project Name]` placeholders, and re-renders on every keystroke from a cached structural scan. Create is enabled only when the rendering is executable and a destination is chosen.
- **Naming**: Project Number, Content Format, optional Campaign, Project Name joined by ` — `. Files starting with `Template` take the full name; `[template]` and the four field tokens work; `[Conent Form]` is mapped for the old misspelling. Contents are never rewritten and package internals are never renamed.
- **Icons**: the saved format icon goes on the outer folder; every nested `Icon\r` resource fork is preserved and hidden.
- **Numbering**: the next number per format comes from the projects already in the list and can be typed over.
- **Projects**: a searchable list across drives with a coloured location badge and connected dot per drive or cloud folder, an Unavailable chip, format, location and stage filters, pinning, grouping by folder creation date, previous locations, Open Folder, Reveal, Locate, Find Moved Folder and the file browser.
- **Relinking**: searches are bounded to saved locations and configured destinations, not arbitrary whole drives. One match can relink automatically when the original volume is connected and the original folder is missing. Offline originals or multiple candidates require a choice, because another copy is not proof of a move. Previous paths are retained.
- **Pipeline**: a board with one column per stage; cards carry stage, campaign, series, editor, notes and a Notion link; ideas without a folder live in the first column and can be started into New Project.
- **Browser**: Icon, List and Column views with Cmd-1, Cmd-2 and Cmd-3 in the View menu, routed to the frontmost browser, remembered per surface.
- **File dragging**: the whole file area accepts up to 100 regular files into the currently open project/idea folder. A folder row in Icon, List or Column view is the destination under the pointer; blank space uses the displayed folder. Same-volume drops move, cross-volume drops copy, and Option forces copy; a normal same-folder drag is a no-op, while Option-copy still cannot overwrite or invent a duplicate name. Explicit Downloads/outside-root sources may move; library data and managed templates remain protected, and destinations remain isolated. Outgoing rows use native copy/move negotiation with Finder; CreatorOS never deletes on drag-end or uploads/publishes. Managed templates, previews, folders and packages are excluded. Listing refreshes after drops, app activation and native change notifications for the currently displayed root; there is no whole-library or drive watcher. `Scripts/check-durable-save.sh` checks native providers/masks; these do not replace actual cross-app gesture acceptance.
- **Menus**: Command-= (or Command-+) and Command-- scale the interface, Command-0 resets, Control-Command-F toggles full screen, Go switches pages.
- **Premiere shortcut**: a project's inspector opens its only `.prproj` directly or asks which one to open when several are present; the same bounded, symlink-safe document scan powers the existing browser.
- **ContentTool** (`swift run ContentTool audit|probe|create …`): the engine from the command line; `create --no-icons` makes a plain copy for LucidLink, which refuses `Icon\r` files; `restore-icons` puts a template's icons back onto a project afterwards and `strip-icons` takes them off first, as do Restore Folder Icons and Remove Folder Icons in the app; New Project has a Plain folders switch.
- **Pipeline**: Recordings and Live boards with their own stages and colours (Settings → Pipeline); a stage change also writes a Finder tag of the same name and colour on the folder, switchable off there. `Scripts/verify-notion-backup.py` re-checks the Notion backups read-only.
- **Settings** window on Cmd-comma: Formats, Naming (extra fields), Pipeline (stages), Locations (badge colours), About.

## Data

Alpha `library.json` uses schema 6 with optional owned idea workspace references. It loads schemas 1–6 and refuses newer; upgrades retain a backup. Stable 0.11.0 understands only up to schema 5, so alpha and stable storage must stay separate. Retained export records stay unused; see `../00 Project State/Deferred features.md`. Interface state lives in isolated `UserDefaults`; a `--data-directory` run uses its own defaults suite.

## Personal setup and Notion backup utilities

`Scripts/configure-library.swift` is the one-time personal setup Codex ran on 3 September 2026 with the app closed: it imported Notion stages, campaigns, series and page links from the export audit into blank fields only and set the four default destinations, with a backup. `Scripts/notion-backup.py` is the offline, standard-library-only utility that wrote the verified `01 Documents/Notion Backup/` snapshots; run `python3 -B -m unittest discover -s Scripts -p test_notion_backup.py` for its 11 tests. The results and exceptions are in `../Outputs/Notion Audit/Exports 2026-09-03/README.md`. Do not repeat those writes.

## Limits worth knowing

Ad-hoc signed, not Developer ID or notarised; do not distribute it as a finished release. Column view widths are fixed. Folder artwork is macOS metadata and does not travel to Windows or phones. The copy engine is not a security boundary against templates being modified adversarially while copying. Whole-folder drag import, branch exclusion, managed payload editing, portable sharing and Post Haste recents remain unbuilt.
