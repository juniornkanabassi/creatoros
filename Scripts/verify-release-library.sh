#!/bin/zsh
set -euo pipefail

root=${1:-"$HOME/Library/Application Support/Project Templates"}
expected_before=${2:-}
live="$root/library.json"
backup="$root/library-before-schema-6.json"

[[ -f "$live" && -f "$backup" ]] || { print -u2 "Expected both library.json and library-before-schema-6.json in: $root"; exit 1; }
before_hash=$(shasum -a 256 "$backup" | awk '{print $1}')
if [[ -n "$expected_before" && "$before_hash" != "$expected_before" ]]; then
  print -u2 "Schema backup hash mismatch: $before_hash"
  exit 1
fi
[[ "$(/usr/bin/jq -r '.schema' "$live")" == 6 ]] || { print -u2 "Live library is not schema 6."; exit 1; }

before_normalised=$(/usr/bin/jq -cS '.schema = 6 | if has("templateSets") then . else . + {templateSets: []} end' "$backup" | shasum -a 256 | awk '{print $1}')
after_normalised=$(/usr/bin/jq -cS '.' "$live" | shasum -a 256 | awk '{print $1}')
[[ "$before_normalised" == "$after_normalised" ]] || { print -u2 "The migrated library changed data beyond schema/templateSets normalisation."; exit 1; }

print "PASS schema backup $before_hash"
print "PASS migrated JSON $after_normalised"
/usr/bin/jq -r '"COUNTS projects=\(.projects|length) templates=\(.templates|length) sets=\(.templateSets|length) presets=\(.presets|length) locations=\(.locations|length)"' "$live"
