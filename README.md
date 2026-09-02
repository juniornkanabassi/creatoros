# Content Template

Native SwiftUI/AppKit Mac app that creates correctly named, correctly iconed project folders from reusable templates. Version 0.1.0 is the first build under this name. Builds 0.1.0 to 0.3.0 of the earlier series were installed as Project Templates; the bundle identifier `local.projecttemplates.mac`, the executable name and the data folder `~/Library/Application Support/Project Templates/` are kept on purpose so nothing the user saved is stranded.

Read `../00 Project State/ARCHITECTURE-ESSENTIALS.md` before changing code. The full design is `../00 Project State/ARCHITECTURE.md` and the product statement is `../00 Project State/PRD.md`.

## Build and run

Apple silicon Mac, Xcode 26.6 or Swift 6 command-line tools with a macOS SDK. No third-party dependencies. Deployment target macOS 14; tested on macOS 26.6.

```sh
swift build --scratch-path /private/tmp/content-template-build
swift run --scratch-path /private/tmp/content-template-build CoreChecks
swift run --scratch-path /private/tmp/content-template-build CoreChecks --master "/path/to/a/real/template"
zsh build.sh
```

`CoreChecks` prints `RESULT n checks passed` and keeps its disposable fixtures under the temporary directory it prints. The optional `--master` argument runs a read-only import and creation against a real template and verifies every byte and every folder icon afterwards.

`build.sh` builds release, assembles `Content Template.app` in a fresh temporary folder, strips FinderInfo the file provider may have attached, signs ad hoc, verifies strictly and writes `../Outputs/Content Template <version>.zip` with `ditto`. It refuses to overwrite an existing archive; set `CONTENT_TEMPLATE_OUTPUT_ROOT` for a separate iteration. Extract into a normal local Applications folder, never inside JuniorOS, whose provider re-attaches metadata that breaks the signature.

For interface testing launch with `--data-directory <disposable folder>`; copy the real `library.json` and `Templates/` there first if a realistic library is wanted. Never point a test at a production destination or at the original templates.

## Source layout

```
Sources/TemplateCore/     engine, no UI
  Library.swift           JSON store, schema 3, upgrade backups
  TemplateSets.swift      content template sets and per-format variants
  Naming.swift            fields, tokens, the shared substitution rule, validation
  FileEngine.swift        template reader, copy plan, copy engine, icon service
  Preview.swift           placeholder rendering that can never become a copy plan
  Catalogue.swift         project discovery, availability, retained export indexing
  ProjectBrowser.swift    safe read-only folder listing and opening rules
Sources/ProjectTemplates/ the app
  AppModel.swift          state, selection, structure cache, background runner
  CreationView.swift      New Project form and live preview
  CatalogueViews.swift    Projects list, inspector, discovery sheet
  TemplateSetsView.swift  Templates page, set detail, legacy templates, new-set sheet
  FileBrowserView.swift   shared Icon, List and Column browser
  ProjectFileBrowser.swift host for browsing a real folder with open rules
  SettingsView.swift      Settings window
  ProjectTemplatesApp.swift scene, menus, main split view, import sheet
Sources/CoreChecks/       assertion suite
Scripts/render-icon.swift original app icon drawing; build-icon.sh regenerates the ICNS
Resources/                Info.plist, AppIcon
```

## Git

`Source/` is a local git repository. The current code was tagged `v0.0.0` as the baseline before the 0.1.0 work and `v0.1.0` at delivery. Hooks are local config; after cloning run `git config core.hooksPath .githooks` and `git config commit.template .gitmessage`. Nothing is pushed anywhere until Junior says so.

## What the app does

- A **content template** is a brand, client or campaign set. Each of Long, Short, Podcast and Live can point at its own managed payload, or share another format's. A set plus a format resolves to one payload or to a setup state; there is no fallback.
- **Legacy templates** (managed copies not in any set) are still usable directly, and one button turns one into a set with all four formats on that payload.
- **Import** a folder or a Post Haste `.pht` as files and folders or as folder structure only, with a tree preview and size before copying. The original is never touched.
- **New Project** shows the whole prospective folder as soon as a set and format are chosen, with `[Project Number]` and `[Project Name]` placeholders, and re-renders on every keystroke from a cached structural scan. Create is enabled only when the rendering is executable and a destination is chosen.
- **Naming**: Project Number, Content Format, optional Campaign, Project Name joined by ` — `. Files starting with `Template` take the full name; `[template]` and the four field tokens work; `[Conent Form]` is mapped for the old misspelling. Contents are never rewritten and package internals are never renamed.
- **Icons**: the saved format icon goes on the outer folder; every nested `Icon\r` resource fork is preserved and hidden.
- **Projects**: a searchable list across drives with availability checks, previous locations, Open Folder, Reveal, Locate and the file browser. Selecting a project no longer indexes or saves anything.
- **Browser**: Icon, List and Column views with Cmd-1, Cmd-2 and Cmd-3 in the View menu, routed to the frontmost browser, remembered per surface.
- **Settings** window on Cmd-comma: per-format icon and destination, naming summary, data location.

## Data

`library.json` schema 3. Loads schema 1 to 3, refuses newer. The first save over an older file keeps `library-before-schema-3.json` next to it. Export records from 0.2.0 and 0.3.0 are kept but unused; see `../00 Project State/Deferred features.md`. Interface state (selected set, format, page, view modes) lives in `UserDefaults`.

## Limits worth knowing

Ad-hoc signed, not Developer ID or notarised; do not distribute it as a finished release. Column view widths are fixed. Folder artwork is macOS metadata and does not travel to Windows or phones. The copy engine is not a security boundary against templates being modified adversarially while copying. Automatic counters, drag-and-drop import, branch exclusion, managed payload editing, portable sharing and Post Haste recents remain unbuilt.
