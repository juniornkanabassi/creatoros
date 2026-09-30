#!/usr/bin/env python3
import hashlib, json, pathlib, subprocess, tempfile
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-backup-', dir='/private/tmp'))
backup = root / 'backup'; (backup / 'Sources').mkdir(parents=True)
(backup / 'README.md').write_text('fixture')
(backup / 'Sources/note.md').write_text('# Fixture\nThis note has enough body words to pass.\n')
files = {'note.md':hashlib.sha256((backup / 'Sources/note.md').read_bytes()).hexdigest()}
(backup / 'manifest.json').write_text(json.dumps({'files':files}))
applied = root / 'applied.json'
applied.write_text(json.dumps({'projects':[{'outcome':'backed_up','backupPath':str(backup),'format':'Short','number':'001','title':'Fixture','files':files}]}))
library = root / 'library.json'; library.write_text('{"projects":[]}')
def verify():
    report = root / 'verification.md'
    subprocess.run(['python3','Scripts/verify-notion-backup.py',str(applied),'--library',str(library),'--report',str(report)], check=True, capture_output=True)
    return json.loads(report.with_suffix('.json').read_text())[0]
assert verify()['status'] == 'verified'
(backup / 'manifest.json').write_text('{"files":{}}')
assert verify()['status'] == 'problem'
(backup / 'Sources/note.md').unlink()
assert 'note.md' in verify()['missing']
for date in ['../escape','/private/tmp/escape','20260930','2026-09-31']:
    result = subprocess.run(['python3','Scripts/notion-backup.py','--exports',str(root),'--library',str(library),'--root',str(root),'--date',date,'--report',str(root/'unused.json')],capture_output=True,text=True)
    assert result.returncode == 2 and '--date must be YYYY-MM-DD' in result.stderr, result.stderr
print('PASS 7 backup security checks; fixture', root)
