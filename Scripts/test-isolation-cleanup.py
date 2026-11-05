#!/usr/bin/env python3
"""The isolation harness must reap its exact child before removing preferences or fixtures."""
import base64, os, pathlib, signal, subprocess, sys, tempfile, uuid

source = pathlib.Path(__file__).with_name('check-isolated-defaults.sh').read_text()
cleanup = source[source.index('cleanup() {'):source.index('\ntrap cleanup EXIT')]
with tempfile.TemporaryDirectory(prefix='cos-cleanup-', dir='/private/tmp') as work:
    work = pathlib.Path(work)
    root, stage, marker = work / 'Data', work / 'Stage', work / 'pid'
    root.mkdir(); stage.mkdir()
    domain = 'local.creatoros.check.' + str(uuid.uuid4())
    suite = 'local.creatoros.alpha.' + base64.b64encode(str(root).encode()).decode()
    child = 'import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)'
    shell = cleanup + '''
root=$1; stage=$2; id=$3; suite=$4; pid=""
trap cleanup EXIT
"$5" -c "$6" "$7" --headless --background --data-directory "$root" &
pid=$!
for _ in {1..100}; do [[ -f "$7" ]] && break; sleep 0.05; done
[[ -f "$7" ]] || exit 8
exit 7
'''
    try:
        for name in (domain, suite):
            subprocess.run(['/usr/bin/defaults', 'write', name, 'fixture', '-string', 'owned'], check=True)
        result = subprocess.run(['zsh', '-c', shell, 'cleanup-check', str(root), str(stage), domain, suite, sys.executable, child, str(marker)], timeout=20)
        assert result.returncode == 7, result.returncode
        pid = int(marker.read_text())
        try: os.kill(pid, 0)
        except ProcessLookupError: pass
        else: raise AssertionError('cleanup left its SIGTERM-resistant child alive')
        assert not root.exists() and not stage.exists()
        for name in (domain, suite):
            assert subprocess.run(['/usr/bin/defaults', 'read', name], capture_output=True).returncode != 0
            assert not (pathlib.Path.home() / 'Library/Preferences' / (name + '.plist')).exists()
        print('PASS failed isolation harness reaps a SIGTERM-resistant child before removing both owned domains and fixtures')
    finally:
        if marker.exists():
            pid = int(marker.read_text())
            args = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'args='], capture_output=True, text=True).stdout
            if str(marker) in args:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
        for name in (domain, suite):
            subprocess.run(['/usr/bin/defaults', 'delete', name], capture_output=True)
            (pathlib.Path.home() / 'Library/Preferences' / (name + '.plist')).unlink(missing_ok=True)
