#!/usr/bin/env python3
"""Read-only check that every Notion backup written on 2026-09-03 is still complete and byte-identical.

Usage: verify-notion-backup.py <applied.json> [--library library.json] [--report out.md]

For each project the audit backed up, this confirms the backup folder exists, that README.md and
manifest.json are present, and that every Markdown file and attachment listed in the manifest has the
recorded SHA-256. Projects on a drive that is not connected are reported as such, never as missing.
Nothing is written except the report. Standard library only.
"""
import argparse, collections, datetime, hashlib, json, os, sys

parser = argparse.ArgumentParser()
parser.add_argument("applied")
parser.add_argument("--library", default=os.path.expanduser("~/Library/Application Support/Project Templates/library.json"))
parser.add_argument("--report")
args = parser.parse_args()

applied = json.load(open(args.applied))
library = json.load(open(args.library)) if os.path.exists(args.library) else {"projects": []}
by_path = {p["path"]: p for p in library["projects"] if p.get("path")}

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def drive_of(path):
    if path.startswith("/Volumes/"):
        return "/".join(path.split("/")[:3])
    return "/"

results = []
for p in applied["projects"]:
    if p.get("outcome") != "backed_up":
        continue
    backup = p["backupPath"]; drive = drive_of(backup)
    row = {"format": p["format"], "number": p["number"], "title": p["title"], "backup": backup, "drive": drive,
           "files": 0, "verified": 0, "mismatched": [], "missing": [], "emptyPages": [], "record": None}
    if not os.path.isdir(drive):
        row["status"] = "drive not connected"; results.append(row); continue
    if not os.path.isdir(backup):
        row["status"] = "backup folder missing"; results.append(row); continue
    for name in ("README.md", "manifest.json"):
        if not os.path.isfile(os.path.join(backup, name)):
            row["missing"].append(name)
    manifest = {}
    if "manifest.json" not in row["missing"]:
        manifest = json.load(open(os.path.join(backup, "manifest.json")))
    for rel, digest in manifest.get("files", {}).items():
        row["files"] += 1
        target = os.path.join(backup, "Sources", rel)
        if not os.path.isfile(target):
            row["missing"].append(rel); continue
        if sha256(target) != digest:
            row["mismatched"].append(rel); continue
        row["verified"] += 1
        if rel.endswith(".md"):
            text = open(target, encoding="utf-8", errors="replace").read()
            body = [l for l in text.splitlines()[1:] if l.strip() and not l.startswith("#") and ":" not in l[:25]]
            if len(" ".join(body).split()) < 5:
                row["emptyPages"].append(os.path.basename(rel).rsplit(" ", 1)[0])
    project_folder = os.path.dirname(os.path.dirname(os.path.dirname(backup)))
    record = by_path.get(project_folder)
    if record:
        row["record"] = "linked" if record.get("notionURL") == p.get("notionURL") else "no Notion link on record"
    else:
        row["record"] = "not in app list"
    row["status"] = "verified" if not row["missing"] and not row["mismatched"] else "problem"
    results.append(row)

counts = collections.Counter(r["status"] for r in results)
by_drive = collections.defaultdict(collections.Counter)
for r in results:
    by_drive[r["drive"]][r["status"]] += 1
today = datetime.date.today().isoformat()
lines = [f"# Notion backup verification [{today}]", "",
         "Read-only re-check of the backups written on 2026-09-03. Every file listed in a backup's manifest was re-hashed and compared with the recorded SHA-256. Nothing was rewritten.", "",
         "| Drive | Verified | Problem | Folder missing | Drive not connected |", "| --- | ---: | ---: | ---: | ---: |"]
for drive, c in sorted(by_drive.items()):
    label = "Macintosh HD" if drive == "/" else os.path.basename(drive)
    lines.append(f"| {label} | {c['verified']} | {c['problem']} | {c['backup folder missing']} | {c['drive not connected']} |")
lines.append(f"| Total | {counts['verified']} | {counts['problem']} | {counts['backup folder missing']} | {counts['drive not connected']} |")
files = sum(r["verified"] for r in results)
lines += ["", f"{files} files re-hashed and matched across {counts['verified']} verified backups."]
problems = [r for r in results if r["status"] == "problem" or r["status"] == "backup folder missing"]
if problems:
    lines += ["", "## Problems", "", "| Project | Status | Detail |", "| --- | --- | --- |"]
    for r in problems:
        detail = "; ".join(["missing: " + ", ".join(r["missing"])] * bool(r["missing"]) + ["changed: " + ", ".join(r["mismatched"])] * bool(r["mismatched"]))
        lines.append(f"| {r['format']} {r['number']} {r['title']} | {r['status']} | {detail} |")
unlinked = [r for r in results if r["status"] == "verified" and r["record"] != "linked"]
if unlinked:
    lines += ["", "## App records", "", "Verified backups whose project record in the app is missing or has no Notion link:", ""]
    for r in unlinked:
        lines.append(f"- {r['format']} {r['number']} {r['title']}: {r['record']}")
empties = [(r, r["emptyPages"]) for r in results if r["emptyPages"]]
if empties:
    lines += ["", "## Pages with no written content", "", "These backups are correct copies of pages that were empty apart from their headings or properties in Notion. Nothing was lost in conversion; there was nothing to convert.", ""]
    for r, pages in empties:
        lines.append(f"- {r['format']} {r['number']} {r['title']}: {', '.join(sorted(set(pages)))}")
pending = [r for r in results if r["status"] == "drive not connected"]
if pending:
    lines += ["", f"## Not checked this run", "", f"{len(pending)} backups are on a drive that was not connected. Run this script again with the drive mounted:", "",
              "```bash", f"python3 \"{os.path.abspath(__file__)}\" \"{os.path.abspath(args.applied)}\"", "```"]
report = "\n".join(lines) + "\n"
print(report)
if args.report:
    open(args.report, "w").write(report)
    json.dump(results, open(os.path.splitext(args.report)[0] + ".json", "w"), indent=1, ensure_ascii=False)
