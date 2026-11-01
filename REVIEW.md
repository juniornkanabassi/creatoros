# Review guide

How to review changes to CreatorOS. The shared rules (lanes, check results, finding format, the three-round checkpoint, approval of an exact revision) are in the owner's JuniorOS `03 Skills/Review workflow.md`. This file holds only what is specific here. Severity is Important, Nit (at most three, never blocking) or Pre-existing. Start the summary with the count. 0 findings is a valid result.

## Failure here means

- An isolated or test run writes to the stable app's real preferences or library.
- A command or launch starts processes without bound (the earlier process storm).
- A user's icons, templates or project files are changed, moved or lost.
- The GUI, CLI and MCP disagree, or a CLI change does not show in the running window.
- A headless start shows a window, a Dock tile or steals focus.

## Always High

Storage and library code, isolation (`--data-directory`), process launching, `install.sh`, `release.sh` and `build.sh`.

## Always check

- Disposable data only; no read or write of the real defaults domain.
- New commands reuse the existing business action rather than a second code path.

## Check results

Last results on 1 Nov 2026, revision `5468af1`. `.github/workflows/fast-checks.yml` runs the first four on pull requests (macOS 26, read-only, no secrets); it has not run on GitHub yet. Report every check you run as PASS, FAIL, NOT RUN or NOT APPLICABLE with the revision.

| Command | Proves | 1 Nov |
|---|---|---|
| `swift run --scratch-path /private/tmp/content-template-build CoreChecks` | the core rules on synthetic data | PASS, 519 |
| `zsh Scripts/check-durable-save.sh [build dir]` | saves survive storage failure and symlink replacement; file providers | PASS |
| `python3 -B -m unittest discover -s Scripts -p test_notion_backup.py` | the offline backup utility | PASS, 11 |
| `python3 Scripts/check-backup-security.py` | backup verification refuses unsafe input | PASS, 7 |
| `zsh Scripts/check-isolated-defaults.sh <packaged CreatorOS.app>` | an isolated launch writes nothing to the real defaults | NOT RUN (needs a packaged app) |
| `python3 Scripts/check-headless.py`, `Scripts/check-control.py`, `Scripts/check-ai-control.py` | headless start, control socket, every control command on synthetic data | NOT RUN (need a built app) |

## Skip

`Resources/` binaries, `docs/` screenshots, generated icons.

## Known gaps

Native gestures and real storage integration are not covered by the scripts.
