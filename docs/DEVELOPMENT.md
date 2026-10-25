# Developing CreatorOS

This is the technical reference for CreatorOS: building and checking it, how the source is laid out, what each feature does in detail, and the full command line and MCP reference. The public overview is in the [README](../README.md).

Native SwiftUI/AppKit Mac app that creates correctly named project folders from reusable content templates and tracks them through the content pipeline. The source is CreatorOS 1.5.1. Since 1.5.0 there is a `creatoros` command and MCP tool for every GUI action (see AI control). Examples below use my own install folder, `/Applications/JuniorOS Apps/`. Builds do not install, tag or push.

CreatorOS keeps the established `local.projecttemplates.mac` identity and `~/Library/Application Support/Project Templates/` data root so existing preferences, templates, bookmarks and catalogue data continue without a lossy copy or merge. The internal executable remains `ProjectTemplates`; that is not a user-facing product name. Explicit `--data-directory` launches and ContentTool remain isolated from the everyday library. A build carrying the old alpha identifier or α channel also selects isolation, never production data.

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
swift run --scratch-path /private/tmp/content-template-build CoreChecks --library-copy "/path/to/a/copied/library.json"
zsh build.sh
```

`CoreChecks` prints `RESULT n checks passed` and keeps its disposable fixtures under the temporary directory it prints. The optional `--master` argument runs a read-only import and creation against a real template and verifies every byte and every folder icon afterwards. `--library-copy` copies the supplied JSON into the disposable fixture, exercises its schema upgrade, and checks the byte-exact backup and all stored JSON fields.

`build.sh` builds release, selects the orange icon only for the α channel and the pastel red slate icon otherwise, assembles `CreatorOS.app` in a fresh temporary folder, strips bundle-root FinderInfo, signs ad hoc, verifies strictly and writes `../Outputs/CreatorOS <version>.zip`, taking identity and version from `Resources/Info.plist`. It refuses archive overwrite; set `CONTENT_TEMPLATE_OUTPUT_ROOT` for a separate iteration. After the acceptance gate passes, `zsh install.sh` installs only the expected CreatorOS release identifier/version, refuses a running CreatorOS-family executable and restores a prior destination if final verification fails. Set `CONTENT_TEMPLATE_INSTALL_ROOT=/tmp/test-Applications` for a disposable dry run.

For interface testing launch with `--data-directory <dedicated disposable temporary folder>`. Keep it in the background with `open -g -n -a "/path/to/CreatorOS.app" --args --background --data-directory /private/tmp/creatoros-ui-data`. The app explicitly activates without `--background`; `open -g` alone is insufficient. Check the exact process and its data-directory argument before computer-use inspection, which can relaunch a closed app. The app rejects production references and starts empty; create synthetic fixtures inside its isolated root. Do not use the real library as a disposable UI fixture: its destinations and bookmarks reference production data. The optional test-only `--display-name 'Prompter XL'` positions the test window when a disposable data directory is supplied.

## Source layout

```
Sources/TemplateCore/     engine, no UI
  Library.swift           JSON store, schema 6, upgrade backups
  AppRuntime.swift        explicit production identity and disposable-root isolation
  Compatibility.swift     shared audit, explicit corrected-copy proposal and manifest
  IdeaWorkspace.swift     owned workspaces, verified promotion and recoverable Trash
  Pipelines.swift         Recordings and Live boards, stage colours, Finder tags
  TemplateSets.swift      content template sets and per-format variants
  Naming.swift            fields, tokens, the shared substitution rule, validation
  FileEngine.swift        template reader, copy plan, copy engine, icon service
  ProjectRename.swift     reviewed exclusive rename and rollback
  ControlCommands.swift   shared CLI/help/MCP action table (60 commands)
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
  ControlServer.swift     socket, request cache, mutation lock, dispatcher
  ControlActions.swift    project, idea and creation commands, shared read-back
  ControlActionsLibrary.swift  boards, settings, formats, templates, sets, locations, discovery, compatibility
Sources/CoreChecks/       assertion suite
Scripts/build-icon.sh    converts the checked-in stable and alpha PNG artwork to ICNS
Scripts/notion-backup.py  offline Notion export backup utility with its tests; not part of the app
Resources/                Info.plist, pastel red slate stable AppIcon and orange AppIconAlpha
```

## Git

`Source/` is a local git repository, tagged `v0.0.0` (baseline), `v0.1.0`, `v0.2.0` to `v0.11.0` at each delivery, following the PATCH/MINOR/MAJOR rule in `../../AGENTS.md`. Hooks are local config; after cloning run `git config core.hooksPath .githooks` and `git config commit.template .gitmessage`. Nothing is pushed anywhere until Junior says so.

## What the app does

- A **content template** is a brand, client or campaign set. Each of Long, Short, Podcast and Live can point at its own managed payload, or share another format's. A set plus a format resolves to one payload or to a setup state; there is no fallback.
- **Legacy templates** (managed copies not in any set) are still usable directly, and one button turns one into a set with all four formats on that payload.
- **Import** a folder or a Post Haste `.pht` as files and folders or as folder structure only, with a tree preview and size before copying. The original is never touched.
- **New Project** shows the whole prospective folder as soon as a set and format are chosen, with `[Project Number]` and `[Project Name]` placeholders, and re-renders on every keystroke from a cached structural scan. Create is enabled only when the rendering is executable and a destination is chosen. After creation, the sheet confirms the saved project and offers Next Project (⌘↩) or Browse Project. Closing clears the completed form; unfinished drafts stay. Idea-workspace promotion closes directly to its existing workspace review.
- **Naming**: Project Number, Content Format, optional Campaign, Project Name joined by ` — `. Files starting with `Template` take the full name; `[template]` and the four field tokens work; `[Conent Form]` is mapped for the old misspelling. Contents are never rewritten and package internals are never renamed.
- **Icons**: the saved format icon goes on the outer folder; every nested `Icon\r` resource fork is preserved and hidden. Restore Folder Icons also gives a project folder the template does not have, such as `06 Media Revised` beside `03 Media`, the icon of the template folder its name extends (the longest match wins; an exact tie is skipped and reported as ambiguous).
- **Numbering**: the next number per format comes from the projects already in the list and can be typed over.
- **Projects**: a searchable list across drives with a coloured location badge and connected dot per drive or cloud folder, an Unavailable chip, format, location and stage filters, pinning, grouping by folder creation date, previous locations, Open Folder, Reveal, Locate, Find Moved Folder and the file browser.
- **Relinking**: searches are bounded to saved locations and configured destinations, not arbitrary whole drives. One match can relink automatically when the original volume is connected and the original folder is missing. Offline originals or multiple candidates require a choice, because another copy is not proof of a move. Previous paths are retained.
- **Pipeline**: a board with one column per stage; cards carry stage, campaign, series, editor, notes and a Notion link; ideas without a folder live in the first column and can be started into New Project.
- **Browser**: Icon, List and Column views with Cmd-1, Cmd-2 and Cmd-3 in the View menu, routed to the frontmost browser, remembered per surface.
- **File dragging**: up to 100 regular files can be dropped into the open project/idea folder. A folder row in Icon, List or Column view is the destination under the pointer; blank space uses the displayed folder. Same-volume file drops move, cross-volume drops copy, and Option forces copy. Ordinary folders can be moved on the same volume; Option-copy of folders is refused. A normal same-folder drop is a no-op, and nothing overwrites or invents a duplicate name. Explicit Downloads/outside-root sources may move; library data and managed templates remain protected, and destinations remain isolated. Outgoing rows use native copy/move negotiation with Finder; CreatorOS never deletes on drag-end or uploads/publishes. Managed templates, previews and packages are excluded. Listing refreshes after drops, app activation and native change notifications for the currently displayed root; there is no whole-library or drive watcher. `Scripts/check-durable-save.sh` checks native providers/masks; these do not replace actual cross-app gesture acceptance.
- **Menus**: Command-= (or Command-+) and Command-- scale the interface, Command-0 resets, Control-Command-F toggles full screen, Go switches pages.
- **Premiere shortcut**: a project's inspector opens its only `.prproj` directly or asks which one to open when several are present; the same bounded, symlink-safe document scan powers the existing browser.
- **ContentTool** (`swift run ContentTool audit|probe|create …`): the engine from the command line; `create --no-icons` makes a plain copy for LucidLink, which refuses `Icon\r` files; `restore-icons` puts a template's icons back onto a project afterwards and `strip-icons` takes them off first, as do Restore Folder Icons and Remove Folder Icons in the app; New Project has a Plain folders switch.
- **Pipeline**: Recordings and Live boards with their own stages and colours (Settings → Pipeline); a stage change also writes a Finder tag of the same name and colour on the folder, switchable off there. `Scripts/verify-notion-backup.py` re-checks the Notion backups read-only.
- **Settings** window on Cmd-comma: Formats, Naming (extra fields), Pipeline (stages), Locations (badge colours), About.

## Data

Released CreatorOS and alpha `library.json` use schema 6 with optional owned idea workspace references. They load schemas 1–6 and refuse newer; upgrades retain a backup. Alpha and stable storage stay separate. Retained export records stay unused; see `../00 Project State/Deferred features.md`. The first empty Projects screen explains the three steps: choose a template, name the project and create it. Projects and both pipeline boards offer Create Project; Templates offers Import Template. Optional creation fields, folder-icon choices and compatibility checks are under Advanced. Template sets group the formats for a channel or client; standalone templates remain usable directly. Expert controls remain reachable in Advanced and the existing menus.

Interface state lives in isolated `UserDefaults`; a `--data-directory` run uses its own defaults suite, and refuses AppKit's window and split-view frame saving, which would otherwise write into the production `local.projecttemplates.mac` domain. For the same reason Open panels (Import Template, Choose Destination, Choose Icon) are off in an isolated run of the stable app; test them in the alpha build, which has its own domain.

## Personal setup and Notion backup utilities

The retired one-time personal setup script was run by Codex on 3 September 2026 with the app closed: it imported Notion stages, campaigns, series and page links from the export audit into blank fields only and set the four default destinations, with a backup. `Scripts/notion-backup.py` is the offline, standard-library-only utility that wrote the verified `01 Documents/Notion Backup/` snapshots; run `python3 -B -m unittest discover -s Scripts -p test_notion_backup.py` for its 11 tests. The results and exceptions are in `../Outputs/Notion Audit/Exports 2026-09-03/README.md`. Do not repeat those writes.

## Limits worth knowing

Ad-hoc signed, not Developer ID or notarised; do not distribute it as a finished release. Column dividers resize and double-click fits or resets the width. Folder artwork is macOS metadata and does not travel to Windows or phones. The copy engine is not a security boundary against templates being modified adversarially while copying. Whole-folder drag import, branch exclusion, managed payload editing, portable sharing and Post Haste recents remain unbuilt.

## AI control

`creatoros` controls the running GUI through the same main-actor actions the buttons use, so a change made by a command is the change the window shows. Since 1.5.0 every GUI action that carries state has a command and an MCP tool; the audit that lists them against the GUI is `../00 Project State/CLI parity audit 2026-10-21.md`. ContentTool remains an isolated test/audit utility.

Commands do not activate CreatorOS or Finder unless `--show` is given. `status` works while stopped and returns `running: false` without launching. Other commands launch the bundled app with `open -g` and wait up to 10 seconds. A response times out after 30 seconds, or 600 seconds for long actions (create, rename, relocate, find-moved, icons, add-files, import, scans, find-missing, tag-folders, compat). Exit codes are 0 success, 1 action or transport failure, 2 usage. `--json` prints one result or error JSON line; successful output is concise JSON either way. `creatoros --version` prints the version; the MCP shim reports the same one.

### Rules every command follows

- **One code path.** A command calls the AppModel action the GUI calls (a throwing core the GUI wraps in its alert). The one exception is `idea merge`, which has no GUI equivalent and is documented as control only.
- **Durable before the reply.** When a mutating command returns, `library.json` is on disk (or the command fails with `store_unavailable`). The result is the record read back from the library: stage, pin, campaign, editor, series, notes, Notion link, idea workspace (path and state), previous paths and availability, so a caller never has to read the file.
- **One mutation at a time.** Every mutating command takes one lock; a second caller gets `busy` instead of a lost update. Locking follows effects: `project open` (selecting can relink) and `project refresh` are mutating, reading commands are not. A busy GUI gives `busy`; an open sheet the action would collide with (New Project, icon restore, Bin confirmation, import, new set) gives `form_in_use`. Records are fetched again after every wait.
- **Dry runs.** `--dry-run` is on project remove, relocate, find-moved, icons-strip, icons-restore, workspace-bin, add-files, create, rename, idea remove and merge, stage set and move-all, field remove, template import and remove, set remove, library find-missing and tag-folders, location scan and remove, and compat `--copy-to`. A dry run never changes the library, the disk or the GUI, and is never cached.
- **Request ids.** `--request-id` on create, rename, register, idea add, idea create-workspace, field add, set create, template import and compat `--copy-to`: a retry with the same parameters in the same app session returns the first result and acts once; different parameters are refused; an in-flight retry returns `busy`. The presentation flag `--show` is not part of the match. The cache is per app session, so a restart forgets it. `app cancel --request-id ID` stops a running long operation only if that id started it (`not_running`, `not_owner` otherwise).
- **Booleans, arrays, objects.** Every true/false flag accepts `--no-<flag>` to send false (`--no-enabled`, `--no-plain-folders`). Arrays are JSON text (`--stages '["Idea","Plan, draft"]'`, `--only '["/path"]'`) and objects too (`--extra '{"Sponsor":"Acme"}'`); MCP sends real arrays and objects. Series stays a comma string, as in the GUI. `--flag=value` also works, for a value that starts with `--`.
- **Stages follow the boards.** A stage is accepted only if it is on the record's own board (`invalid_stage`); a live stream never gets a recording stage. A record with no stage reads as Unclassified, never Published. A stage change writes its Finder tag before the reply and reports `finderTag: applied|skipped|failed`; writes for one folder run in order and a newer change replaces an older one waiting.
- **Hidden locations.** A location unticked in the GUI is never read: its projects are refused with `location_hidden` by every project command, and paths on it are refused. `location set --hidden` is GUI state shared by every caller, so it changes what other callers can see.
- **One writer at a time.** A command that changes anything waits for a busy app or an open form (`busy`, `form_in_use`), and while it runs the app's own writes are refused with a plain "Busy, retry" message instead of interleaving: stage changes, pins, details, settings, sets, templates, fields, relocate, remove and icons. Background writes (date backfill, the quiet relink on selection, mount refresh) skip while a command runs and try again later. Reads are checked again after they wait, and answer `location_hidden` or `record_changed` if the project was hidden, moved or removed meanwhile.
- **Nothing outside the writable area.** `AppRuntime` still applies: an isolated run refuses any write outside its data folder (`not_allowed`). Paths must be absolute, without `.` or `..` parts. Deleting only ever means the Bin: workspace-bin and template remove move to Trash.

### Commands

| Command | MCP tool | What it does | Example |
| --- | --- | --- | --- |
| `status` | `status` | Read app and GUI state without launching | `creatoros status --json` |
| `library stats` | `library_stats` | Count visible library records | `creatoros library stats` |
| `project list` | `project_list` | List projects on ticked locations; --deep also matches text inside documents | `creatoros project list --format Short --limit 10` |
| `project status` | `project_status` | Inspect a project or idea: stage, pin, campaign, editor, series, notes, workspace, previous paths, availability | `creatoros project status 001 --format Short` |
| `project open` | `project_open` | Select a project in the GUI (--page pipeline shows it on the board) | `creatoros project open 001 --format Short --page pipeline` |
| `project refresh` | `project_refresh` | Re-read a project's folder state, as the Refresh Project menu does, and try to relink it if missing | `creatoros project refresh 001 --format Short` |
| `project reveal` | `project_reveal` | Open the project folder in Finder | `creatoros project reveal 001 --format Short` |
| `project create` | `project_create` | Create and register a project, or start one from an idea; --dry-run previews name, plan and compatibility | `creatoros project create --format Short --title Example --extra '{"Sponsor":"Acme"}' --request-id example-1` |
| `project rename` | `project_rename` | Preview or apply the app's reviewed project rename | `creatoros project rename 001 --format Short --title Updated --dry-run` |
| `project pin` | `project_pin` | Pin a project to the top of the list (idempotent) | `creatoros project pin 001 --format Short` |
| `project unpin` | `project_unpin` | Unpin a project (idempotent) | `creatoros project unpin 001 --format Short` |
| `project set-stage` | `project_set_stage` | Move a project or idea to a stage on its own board; the Finder tag is written before replying | `creatoros project set-stage 001 --format Short --stage Editing` |
| `project update` | `project_update` | Edit pipeline details; an empty value clears. Series is comma separated | `creatoros project update 001 --format Short --editor Jon --series "Euro 2026, Finals"` |
| `project relocate` | `project_relocate` | Point a record at a folder you name (Locate Folder); the record takes the folder's name | `creatoros project relocate 001 --format Short --path /Volumes/Drive/001 --dry-run` |
| `project find-moved` | `project_find_moved` | Search the ticked drives for a moved folder; relinks only when exactly one safe match exists | `creatoros project find-moved 001 --format Short --dry-run` |
| `project icons-strip` | `project_icons_strip` | Remove folder icons so the project can go to LucidLink (the template keeps them) | `creatoros project icons-strip 001 --format Short --dry-run` |
| `project icons-restore` | `project_icons_restore` | Put a template set's folder icons back; later folders such as 06 Media Revised inherit the icon of the folder their name extends | `creatoros project icons-restore 001 --format Short --set Main --dry-run` |
| `project remove` | `project_remove` | Remove a project from the list; its folder is never touched | `creatoros project remove 001 --format Short --dry-run` |
| `project workspace-detach` | `project_workspace_detach` | Keep a started idea's old workspace folder and stop linking it | `creatoros project workspace-detach 001 --format Short` |
| `project workspace-bin` | `project_workspace_bin` | Move a started idea's old workspace to the Bin (needs --confirm) | `creatoros project workspace-bin 001 --format Short --confirm` |
| `project register` | `project_register` | Add one existing project folder to the list (Add Existing Project) | `creatoros project register --path /Volumes/Drive/005 --format Short --request-id reg-1` |
| `project files` | `project_files` | List a project's files and folders (bounded; no symlinks or package contents) | `creatoros project files 001 --format Short --path "02 Project Files"` |
| `project open-file` | `project_open_file` | Open a project document in its default app with the browser's safety checks | `creatoros project open-file 001 --format Short --path "01 Documents/Script.md"` |
| `project add-files` | `project_add_files` | Move or copy a file or folder into a project as a browser drop does; never overwrites | `creatoros project add-files 001 --format Short --from /Users/me/clip.mov --to "03 Media" --copy` |
| `project open-premiere` | `project_open_premiere` | List a project's Premiere documents, or open one with --file | `creatoros project open-premiere 001 --format Short --file "02 Project Files/001.prproj"` |
| `idea add` | `idea_add` | Add an idea to the first column (recordings only) | `creatoros idea add --title "Ref bias" --format Short --request-id idea-1` |
| `idea remove` | `idea_remove` | Bin an idea; one with a workspace needs --trash-workspace | `creatoros idea remove "Ref bias" --format Short --dry-run` |
| `idea create-workspace` | `idea_create_workspace` | Create a draft workspace folder for an idea | `creatoros idea create-workspace "Ref bias" --format Short --template Main --request-id ws-1` |
| `idea merge` | `idea_merge` | Fold an idea's empty-field metadata and notes into a project, then remove the idea (control only) | `creatoros idea merge "Ref bias" --into 001 --into-format Short --dry-run` |
| `stage list` | `stage_list` | List both boards' stages with colours and record counts | `creatoros stage list` |
| `stage set` | `stage_set` | Replace a board's stage list (JSON array, at least two); reports records left on orphaned stages | `creatoros stage set --board recordings --stages '["Idea","Writing","Editing","Published","Abandoned"]'` |
| `stage rename` | `stage_rename` | Rename a stage: its records, colour and saved filter move with it, and Finder tags are rewritten | `creatoros stage rename --board recordings --from Editing --to Cutting --dry-run` |
| `stage set-colour` | `stage_set_colour` | Set a stage's colour (none, gray, green, purple, blue, yellow, red, orange) | `creatoros stage set-colour --stage Editing --colour purple` |
| `stage move-all` | `stage_move_all` | Move every record in one stage to another on the same board, ignoring GUI filters | `creatoros stage move-all --from Editing --to Published --board recordings --dry-run` |
| `settings finder-tags` | `settings_finder_tags` | Turn stage Finder tags on or off (--enabled / --no-enabled) | `creatoros settings finder-tags --no-enabled` |
| `library tag-folders` | `library_tag_folders` | Write stage tags onto every staged folder on a connected, ticked drive | `creatoros library tag-folders --dry-run` |
| `field list` | `field_list` | List custom naming fields | `creatoros field list` |
| `field add` | `field_add` | Add a custom naming field | `creatoros field add --name Sponsor --exclude-from-name --request-id field-1` |
| `field update` | `field_update` | Rename a field or change whether it goes in the folder name | `creatoros field update Sponsor --name Client --no-include-in-name` |
| `field remove` | `field_remove` | Remove a custom field; --dry-run reports the creation form value it would drop | `creatoros field remove Sponsor --dry-run` |
| `format list` | `format_list` | List formats with destination, icon and readiness | `creatoros format list` |
| `format set-destination` | `format_set_destination` | Set where a format's projects are created (saved) | `creatoros format set-destination --format Short --path /Volumes/Drive/Short` |
| `format set-icon` | `format_set_icon` | Set a format's folder icon from an image or from another folder's icon | `creatoros format set-icon --format Short --image /Users/me/icon.png` |
| `template list` | `template_list` | List template sets, variants and managed templates | `creatoros template list` |
| `template files` | `template_files` | List a managed template's files (read-only; opening or editing templates stays in the GUI) | `creatoros template files Main --path "01 Documents"` |
| `template import` | `template_import` | Import a template folder or .pht; --dry-run returns the scan | `creatoros template import --path /Users/me/Template --name Main --mode full --set Main --format Short` |
| `template remove` | `template_remove` | Delete a managed template (its copy goes to the Bin) and drop its assignments | `creatoros template remove Old --dry-run` |
| `set create` | `set_create` | Create a template set, optionally mapping all formats to one template | `creatoros set create --name Main --from-template Fixture --request-id set-1` |
| `set rename` | `set_rename` | Rename a template set | `creatoros set rename Main --name Channel` |
| `set assign` | `set_assign` | Use a template for one format in a set | `creatoros set assign Main --format Short --template Fixture` |
| `set unassign` | `set_unassign` | Stop using a template for one format in a set | `creatoros set unassign Main --format Short` |
| `set remove` | `set_remove` | Delete a template set (templates stay) | `creatoros set remove Main --dry-run` |
| `library find-missing` | `library_find_missing` | Find Missing Projects: relink the certain ones, report the rest | `creatoros library find-missing --dry-run` |
| `library duplicates` | `library_duplicates` | Group projects registered under the same name | `creatoros library duplicates` |
| `location list` | `location_list` | List locations (key, mounted, hidden, colour, count) and saved scan locations | `creatoros location list` |
| `location set` | `location_set` | Hide, show or recolour a location in the GUI; hidden locations disappear for every caller | `creatoros location set volume:Drive --hidden --colour orange` |
| `location scan` | `location_scan` | Scan a folder or saved location for projects; --dry-run lists them, --only registers a subset | `creatoros location scan --path /Volumes/Drive/Projects --dry-run` |
| `location remove` | `location_remove` | Forget a saved scan location (registered projects stay) | `creatoros location remove Projects --dry-run` |
| `compat check` | `compat_check` | Check names for LucidLink; --copy-to makes a corrected copy (--dry-run returns the rename proposal) | `creatoros compat check --project 001 --format Short --copy-to /Volumes/Drive/Out` |
| `app cancel` | `app_cancel` | Cancel the running long operation, only if this request id started it | `creatoros app cancel --request-id create-1` |

References: a project or idea is a UUID, its exact folder name or its number (`--format` disambiguates; ideas use their name). A set, template, field or saved location is a UUID or its exact name. Most commands take the reference as a bare word or as `--project`, `--set`, `--template`, `--field`, `--location`, `--key`.

### Notes and limits

- `project create` accepts `--from-idea REF` (the idea becomes the project and keeps its identity; format must match the idea; a workspace-backed idea goes through the same promotion as the GUI and the result says the old workspace still needs a decision), `--extra` (custom field values by field name), `--destination PATH` (a one-off destination for this project only, never saved, so it cannot race another caller's saved setting), `--plain-folders` / `--no-plain-folders` (omitted keeps the LucidLink rule) and `--dry-run`, which returns the rendered folder name, readiness, issues, renamed entries and the prospective LucidLink report without creating anything. It retains New Project's saved form settings.
- `stage move-all` moves every record of a board's stage regardless of the GUI's search, format and stage filters (the GUI's Move All moves only what is showing); records on hidden locations are left alone. `stage set` takes names in a JSON array because a name may contain a comma, and reports records left on removed stages, which keep them.
- `project icons-restore` defaults the format to the record's and the set to the only available candidate; otherwise it answers `ambiguous_set` and lists the candidates with their availability and reason. Folders that extend a template folder's name are restored too and reported under `inherited`; ties under `ambiguous`. A stopped strip or restore reports what it already did (`cancelled`), and a file that cannot be changed is listed under `failed` while the rest proceeds.
- `project relocate` mirrors Locate Folder: the record takes the folder's name and the old path joins `previousPaths`; nothing is renamed on disk. `project find-moved` relinks only when exactly one safe candidate exists; otherwise it returns the candidates and `project relocate` finishes the job. Dry runs say `wouldRelink`.
- `project files`, `open-file`, `open-premiere`, `add-files` and `template files` use the file browser's engines: no symlinks, no package contents, `Icon\r` hidden, applications, installers and scripts never opened, no overwriting, same-volume moves and cross-volume copies (`--copy` forces a copy; folders only move). Opening or editing a managed template stays GUI-only.
- `location scan --dry-run` lists what it found with `alreadyRegistered`; applying registers everything found or the paths in `--only`, and saves the location either way.
- `library tag-folders` skips hidden locations and checks each folder again before writing. `workspace-bin` and `idea remove --trash-workspace` need explicit confirmation flags; the folder goes to the Bin and the reply names where.
- `stage rename` (and the rename field in Settings, which uses the same core) moves the records on the old stage, re-keys its colour, updates the saved stage filter and rewrites the Finder tag on every staged folder on a connected, ticked drive: the old tag goes, other tags stay. It reports projects changed and tags rewritten; `--dry-run` only counts. `stage set` does not detect renames; a name that is no longer in the list leaves its records on it as an orphan.
- Remove Folder Icons (`project icons-strip`) deletes the `Icon\r` files and clears only the custom-icon bit of each folder's FinderInfo; colour labels, tags, comments and other attributes stay, and the attribute is removed only if clearing the bit leaves it all zeros.
- Export indexing is retired: nothing in the app read the export lists, so discovery and Add Existing Project no longer scan for movies. The optional `exports`, `exportFolders`, `finalExportPath(s)`, `lastIndexed` and `scanNotes` fields stay in the schema so older libraries decode and save unchanged.
- In the icon view, left and right move within a row and up and down move by the number of columns on screen (worked out from the window width); Return opens.
- Template deletion saves the library before it finishes; if the save fails the files are put back from the Bin, or the error names their exact place in the Bin.
- No token savings have been measured.

The Unix socket is `<data root>/control.sock` (directory 0700, socket 0600, same-user peers only), with newline JSON requests `{"id":"1","action":"status","params":{}}` and `{"id":"1","ok":true,"result":{...}}` or `{"id":"1","ok":false,"error":{"code":"...","message":"..."}}`. Unknown params and requests over 65,536 bytes are refused. Only stale socket files are removed at launch. This is local control, with no authentication beyond OS ownership/peer identity and no remote listener. Error codes you may see include `busy`, `form_in_use`, `not_found`, `ambiguous_*`, `invalid_params`, `invalid_stage`, `location_hidden`, `not_allowed`, `workspace_review`, `confirmation_required`, `cancelled`, `store_unavailable`, `unavailable`, `tags_disabled` and `action_failed`.

The bundled CLI is `Contents/MacOS/creatoros`, and `install.sh` links it into `~/.local/bin` only for the default install root, preserving non-symlink files. The MCP shim ships at `Contents/Resources/mcp/creatoros-mcp.mjs`, uses Node built-ins and the CLI's generated manifest (`creatoros mcp-manifest`), and implements protocol 2025-06-18 (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`). It routes each tool by the exact CLI words the manifest carries in `_meta.creatoros.words`, never by splitting the tool name, so tool names with `_` for both `.` and `-` (`project_set_stage`) are safe. Node must already be installed. Each app carries its own thin shim; accepted duplication avoids a shared runtime dependency. The shim starts one CLI process per call without waiting for the previous one, so two calls sent together can meet `busy`.

```sh
claude mcp add creatoros -- node "/Applications/JuniorOS Apps/CreatorOS.app/Contents/Resources/mcp/creatoros-mcp.mjs"
```

```toml
# ~/.codex/config.toml
[mcp_servers.creatoros]
command = "node"
args = ["/Applications/JuniorOS Apps/CreatorOS.app/Contents/Resources/mcp/creatoros-mcp.mjs"]
```

For a disposable build check: `python3 Scripts/check-ai-control.py <built ProjectTemplates executable or CreatorOS.app>` (the executable form needs `creatoros` beside it) runs every command on synthetic data, sends every MCP tool through the shim and covers dry-run byte identity, request-id retries, hidden-location refusals and concurrent callers; `python3 Scripts/check-control.py <app> <scratch>` runs the socket boundary and the AppModel harness (`Scripts/check-control-model.swift`, including GUI-sheet collisions); `zsh Scripts/check-isolated-defaults.sh "/path/to/CreatorOS.app"` launches a re-identified copy with `--data-directory` and fails if anything reaches its defaults domain (it never touches the production domain). `MCP_CLI` overrides the shim's executable for testing. MCP inherits `CREATOROS_DATA_DIRECTORY`. UI gestures, physical disconnected drives, real LucidLink and Adobe relinking need separate acceptance evidence.


## 1.4.0 UI fix-round evidence

On the disposable UI worktree, round 2 passes debug/release builds, 483 CoreChecks, 43 packaged AI checks, 26 packaged control checks (including the new completion regression), and the native-provider/durable-save harness. Window-only before/after captures cover every screen, both boards, all Settings tabs and browser modes. Dark/light navigation each passes 10 checks without changing the synthetic library.

The final packaged instance at 150% passed coordinate clicks in Settings and New Project, field typing and Tab navigation, manual/automatic numbering, pointer and keyboard creation, pointer and keyboard Next Project, Browse Project, completed-form reset and unfinished-draft preservation. Settings intentionally stays unscaled. Evidence: `/private/tmp/ship/creatoros-ui-round2-final-pointer.json` and `/private/tmp/ship/creatoros-ui-screens/round-2/`. This is bounded UI evidence, not full keyboard/VoiceOver, drag, physical-drive or Adobe acceptance. The round report records two test-run constraint breaches; it does not certify production-data integrity.
