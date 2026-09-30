#!/usr/bin/env python3
"""One-off, offline Notion export audit/backup. Not an app integration.

Default is a read-only production audit. --apply adds exclusive, verifiable
snapshots to existing project/01 Documents folders. Never edits library.json.
"""
import argparse
import collections
import csv
import datetime
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import stat
import unicodedata
from urllib.parse import unquote, urlsplit, quote
import zipfile

FORMATS = [('Longs', 'Long', 'Longs'), ('Shorts', 'Short', 'Shorts'),
           ('Podcasts', 'Podcast', 'Podcast')]
PROJECT = re.compile(r'^\s*(\d+)\s*[—–-]\s*(Long|Short|Podcast|Livestream)\s*[—–-]\s*(.+)$')
PAGE_ID = re.compile(r' ([0-9a-f]{32})\.md$')

def links(text):
    """Notion emits unescaped balanced parentheses in some relative URLs."""
    result = []
    for start in re.finditer(r'\]\(', text):
        depth, end, matched = 1, start.end(), False
        while end < len(text) and text[end] != '\n':
            c = text[end]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    result.append(text[start.end():end])
                    matched = True
                    break
            end += 1
        if not matched:
            # Exported directory names can be truncated after an opening '(';
            # Notion still puts an unescaped raw URL on a single line.
            line = text[start.end():end]
            if ')' in line:
                result.append(line.rsplit(')', 1)[0])
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normal(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).casefold() if c.isalnum())


def safe_relative(name):
    p = PurePosixPath(name)
    return bool(name) and not p.is_absolute() and '..' not in p.parts and '\\' not in name and '\x00' not in name


def no_symlinks(path):
    p = Path(path).absolute()
    return not any(x.is_symlink() for x in (p, *p.parents))


def inside(path, root):
    return path == root or root in path.parents


def title_matches(name, title, campaign):
    m = PROJECT.match(name)
    if not m:
        return False
    suffix = m[3]
    if normal(suffix) == normal(title):
        return True
    parts = re.split(r'\s+[—–-]\s+', suffix, maxsplit=1)
    return bool(campaign and len(parts) == 2 and normal(parts[0]) == normal(campaign)
                and normal(parts[1]) == normal(title))


def archive_files(z):
    files = {}
    total = 0
    for item in z.infolist():
        if item.is_dir():
            continue
        if not safe_relative(item.filename) or stat.S_ISLNK(item.external_attr >> 16):
            raise ValueError('Unsafe archive entry: ' + item.filename)
        if item.filename in files:
            raise ValueError('Duplicate archive entry: ' + item.filename)
        total += item.file_size
        if item.file_size > 64 * 1024**2 or total > 256 * 1024**2:
            raise ValueError('Export exceeds conservative size bounds')
        files[item.filename] = z.read(item)
    return files


def linked_files(files, parent):
    """Preserve original relative paths and bytes; never fetch remote links."""
    found, pending, missing = set(), [parent], set()
    # Direct children are rooted in the directory linked from the parent page.
    # Notion exports strip IDs from this directory, so derive it from links.
    child_roots = set()
    for raw in links(files[parent].decode('utf-8-sig')):
        target = posixpath.normpath(posixpath.join(posixpath.dirname(parent), unquote(raw)))
        if target in files and posixpath.dirname(target) != posixpath.dirname(parent):
            child_roots.add(posixpath.dirname(target))
    while pending:
        name = pending.pop()
        if name in found:
            continue
        found.add(name)
        if not name.endswith('.md'):
            continue
        for raw in links(files[name].decode('utf-8-sig')):
            # Match literal export paths first (parentheses can occur in names).
            link = urlsplit(raw)
            if link.scheme or link.netloc or not link.path:
                continue
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), unquote(link.path)))
            if not safe_relative(target):
                missing.add(raw)
            elif target not in files:
                missing.add(raw)
            elif any(target.startswith(root + '/') for root in child_roots):
                pending.append(target)
            elif target != parent:
                missing.add(raw)  # cross-project references stay in source, not silently imported
    # Include all attachments/subpages under the owned child roots, even if a
    # Markdown link contains syntax beyond the simple parser above.
    for name in files:
        if any(name.startswith(root + '/') for root in child_roots):
            found.add(name)
    return {n: files[n] for n in sorted(found)}, sorted(missing)


def rows_from(files, label):
    names = [n for n in files if '/' not in n and n.endswith('.csv')]
    if len(names) != 2:
        raise ValueError(f'{label}: expected the view and full CSV exports')
    variants = [list(csv.DictReader(io.StringIO(files[n].decode('utf-8-sig')))) for n in names]
    canon = lambda rows: collections.Counter(json.dumps(r, sort_keys=True) for r in rows)
    if canon(variants[0]) != canon(variants[1]):
        raise ValueError(f'{label}: view/full CSV rows differ; review before migrating')
    return variants[0]


def inventory(library, roots):
    records = {p['path']: dict(p) for p in library['projects'] if p.get('path')}
    visited, warnings = 0, []
    for root in roots:
        if not no_symlinks(root) or not root.is_dir():
            warnings.append(f'Unavailable or symlink root: {root}')
            continue
        pending = [(root, 0)]
        while pending:
            directory, depth = pending.pop()
            try:
                with os.scandir(directory) as entries:
                    for entry in entries:
                        visited += 1
                        if visited > 8000:
                            return records, warnings + ['Folder inventory stopped at 8,000 entries']
                        if entry.name.startswith('.') or not entry.is_dir(follow_symlinks=False):
                            continue
                        match = PROJECT.match(entry.name)
                        if match:
                            records.setdefault(entry.path, {'name': entry.name, 'path': entry.path,
                                                           'format': match[2], 'discoveredByAudit': True})
                        elif depth < 5:
                            pending.append((Path(entry.path), depth + 1))
            except OSError as e:
                warnings.append(f'{directory}: {e}')
    return records, warnings


def exclusive(path, data):
    """No overwrite, including on rerun. Existing identical files are verified."""
    if not no_symlinks(path):
        raise ValueError('Symlink destination rejected: ' + str(path))
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError('Existing file differs; left untouched: ' + str(path))
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('xb') as f:
        f.write(data)
    if path.read_bytes() != data:
        raise IOError('Verification failed: ' + str(path))
    return True


def migrate(args):
    library_path = Path(args.library)
    original_library = library_path.read_bytes()
    roots = [Path(r).absolute() for r in args.root]
    records, warnings = inventory(json.loads(original_library), roots)
    report = {'mode': 'apply' if args.apply else 'audit', 'date': args.date,
              'librarySHA256': digest(original_library), 'roots': list(map(str, roots)),
              'warnings': warnings, 'archives': [], 'projects': [], 'catalogueOnly': []}
    covered = set()
    for label, fmt, col in FORMATS:
        path = Path(args.exports) / (label + ' — Notion Export.zip')
        raw_zip = path.read_bytes()
        with zipfile.ZipFile(io.BytesIO(raw_zip)) as z:
            files = archive_files(z)
        rows = rows_from(files, label)
        report['archives'].append({'path': str(path), 'sha256': digest(raw_zip), 'rows': len(rows),
                                   'files': len(files), 'csvAgreement': True})
        pages = []
        for name, data in files.items():
            if not name.endswith('.md') or name.count('/') != 1:
                continue
            text = data.decode('utf-8-sig')
            title = text.splitlines()[0].removeprefix('# ').strip()
            number = re.search(r'^' + re.escape(col) + r' No\.: (\d+)\s*$', text, re.M)
            page_id = PAGE_ID.search(name)
            if number and page_id:
                pages.append((int(number[1]), normal(title), name, page_id[1], text))
        row_numbers = collections.Counter(r[col + ' No.'].strip().lstrip('0') or '0' for r in rows
                                          if r[col + ' No.'].strip())
        for row in rows:
            title, number = row[col + ' Project Name'].strip(), row[col + ' No.'].strip()
            item = {'format': fmt, 'number': number, 'title': title, 'properties': row}
            report['projects'].append(item)
            if not number or row['Status'].strip().casefold() == 'idea':
                item['outcome'] = 'excluded_idea_or_unnumbered'
                continue
            if not number.isascii() or not number.isdigit() or row_numbers[str(int(number))] != 1:
                item['outcome'] = 'review_number'
                continue
            candidates = [p for p in records.values() if p.get('format') == fmt and
                          (m := PROJECT.match(p['name'])) and int(m[1]) == int(number)]
            item['candidates'] = [{'path': p['path'], 'name': p['name'], 'id': p.get('id')} for p in candidates]
            covered.update(p['path'] for p in candidates)
            exact = [p for p in candidates if title_matches(p['name'], title, row.get('Campaign', ''))]
            page = [p for p in pages if p[0] == int(number) and p[1] == normal(title)]
            if len(page) != 1:
                item['outcome'] = 'review_export_page'
                continue
            _, _, parent, page_id, parent_text = page[0]
            item.update(pageID=page_id, notionURL='https://www.notion.so/' + page_id, sourcePage=parent)
            # CSV and parent-page properties must agree before copying.
            if not re.search(r'^Status: ' + re.escape(row['Status']) + r'\s*$', parent_text, re.M):
                item['outcome'] = 'review_status'
                continue
            if len(exact) != 1:
                item['outcome'] = 'review_title_or_duplicate' if candidates else 'no_folder_match'
                continue
            project = Path(exact[0]['path'])
            item['matchedPath'] = str(project)
            if not any(inside(project, root) for root in roots):
                item['outcome'] = 'outside_approved_local_roots'
                continue
            documents = project / '01 Documents'
            if not no_symlinks(documents) or not documents.is_dir():
                item['outcome'] = 'unavailable_or_missing_documents'
                continue
            payload, missing = linked_files(files, parent)
            item['unresolvedLocalLinks'] = missing
            item['files'] = {n: digest(b) for n, b in payload.items()}
            target = documents / 'Notion Backup' / (args.date + ' ' + page_id)
            item['backupPath'] = str(target)
            manifest = {'pageID': page_id, 'notionURL': item['notionURL'], 'properties': row,
                        'archiveSHA256': digest(raw_zip), 'files': item['files'],
                        'unresolvedLocalLinks': missing, 'exportDate': args.date}
            readme = (f'# Notion backup\n\n{title}\n\n'
                      f'Export snapshot {args.date}. [Original Notion page]({item["notionURL"]}).\n\n'
                      f'[Open project notes](Sources/{quote(parent, safe="/")})\n\n'
                      'Original Markdown and exported attachments are preserved byte for byte under Sources. '
                      'Relative links retain their exported paths. Empty template sections are not missing notes. '
                      'Remote links/embeds are references, not downloaded media.\n\n'
                      'This is a snapshot, not synchronisation. Read live Notion before reconciling later changes. '
                      'Do not overwrite local edits during verification. Hashes and source properties are in manifest.json.\n')
            readme += ('\n## Exported pages\n\nThese links also work where Notion exported malformed '
                       'parentheses in its original links. Original files remain unchanged.\n\n')
            readme += ''.join(f'- [{PurePosixPath(n).name.replace("[", "").replace("]", "")}]'
                             f'(Sources/{quote(n, safe="/")})\n' for n in payload if n.endswith('.md'))
            outputs = {'README.md': readme.encode(), 'manifest.json': (json.dumps(manifest, ensure_ascii=False, indent=2)+'\n').encode()}
            outputs.update({'Sources/' + n: b for n, b in payload.items()})
            # Preflight every destination before making even one file.
            conflicts = [n for n, b in outputs.items() if not no_symlinks(target / n) or
                         ((target / n).exists() and (target / n).read_bytes() != b)]
            if conflicts:
                item.update(outcome='existing_backup_conflict', conflicts=conflicts)
                continue
            item['outcome'] = 'ready'
            if args.apply:
                try:
                    written = sum(exclusive(target / n, b) for n, b in outputs.items())
                    item.update(outcome='backed_up' if written else 'verified_existing', filesWritten=written)
                except (OSError, ValueError) as e:
                    item.update(outcome='write_error', error=str(e))
    report['catalogueOnly'] = [{'format': p.get('format'), 'name': p['name'], 'path': p['path']}
                               for p in records.values() if p.get('format') in ['Long', 'Short', 'Podcast']
                               and p['path'] not in covered]
    report['counts'] = dict(collections.Counter(p['outcome'] for p in report['projects']))
    report['libraryUnchanged'] = library_path.read_bytes() == original_library
    destination = Path(args.report)
    exclusive(destination, (json.dumps(report, ensure_ascii=False, indent=2)+'\n').encode())
    print(json.dumps({'report': str(destination), 'counts': report['counts'],
                      'catalogueOnly': len(report['catalogueOnly']), 'warnings': warnings,
                      'libraryUnchanged': report['libraryUnchanged']}, indent=2))


def supplement_attachments(args):
    """Add referenced exported images outside a page's own subtree, without
    changing the original manifest or any notes. A separate manifest records
    these additions, so both the initial snapshot and supplement are auditable.
    """
    prior = json.loads(Path(args.supplement_from).read_text())
    additions = []
    for item in prior['projects']:
        if item['outcome'] != 'backed_up' or not item.get('unresolvedLocalLinks'):
            continue
        target = Path(item['backupPath'])
        roots = [Path(r).absolute() for r in args.root]
        if not any(inside(target, r) for r in roots) or not no_symlinks(target):
            raise ValueError('Supplement outside approved roots')
        manifest = json.loads((target / 'manifest.json').read_text())
        if manifest['files'] != item['files']:
            raise ValueError('Original manifest changed; review manually')
        for name, expected in item['files'].items():
            if digest((target / 'Sources' / name).read_bytes()) != expected:
                raise ValueError('Snapshot was edited; review manually')
        label = next(label for label, fmt, _ in FORMATS if fmt == item['format'])
        raw = (Path(args.exports) / (label + ' — Notion Export.zip')).read_bytes()
        if digest(raw) != manifest['archiveSHA256']:
            raise ValueError('Export changed since backup')
        with zipfile.ZipFile(io.BytesIO(raw)) as z:
            files = archive_files(z)
        extra = {}
        for link in item['unresolvedLocalLinks']:
            for source in item['files']:
                if source.endswith('.md') and link in files[source].decode('utf-8-sig'):
                    name = posixpath.normpath(posixpath.join(posixpath.dirname(source), unquote(link)))
                    if (safe_relative(name) and name in files and
                            PurePosixPath(name).suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp', '.gif'}):
                        extra[name] = files[name]
        for name, data in extra.items():
            exclusive(target / 'Sources' / name, data)
        entry = {'pageID': item['pageID'], 'backupPath': str(target),
                 'archiveSHA256': manifest['archiveSHA256'],
                 'files': {name: digest(data) for name, data in extra.items()}}
        exclusive(target / 'attachment-supplement.json', (json.dumps(entry, ensure_ascii=False, indent=2)+'\n').encode())
        additions.append(entry)
    exclusive(Path(args.report), (json.dumps(additions, ensure_ascii=False, indent=2)+'\n').encode())
    print(json.dumps({'supplementedProjects': len(additions), 'verifiedImages': sum(len(x['files']) for x in additions)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exports', required=True)
    parser.add_argument('--library', required=True)
    parser.add_argument('--root', action='append', required=True, help='Approved local production root; repeatable')
    parser.add_argument('--date', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--supplement-from', help='Completed apply report; add only verified cross-page exported image references')
    args = parser.parse_args()
    try:
        if datetime.date.fromisoformat(args.date).isoformat() != args.date:
            raise ValueError()
    except ValueError:
        parser.error('--date must be YYYY-MM-DD')
    if args.supplement_from:
        if not args.apply:
            parser.error('--supplement-from requires explicit --apply')
        supplement_attachments(args)
    else:
        migrate(args)
