#!/usr/bin/env python3
"""Disposable built-app socket checks; no foreground UI or production data."""
import json, os, pathlib, socket, subprocess, sys, tempfile, time
rename_source = pathlib.Path('Sources/TemplateCore/ProjectRename.swift').read_text()
volume_guard = 'try requireExclusiveRenaming(root.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey]).volumeSupportsExclusiveRenaming)'
assert volume_guard in rename_source and rename_source.index(volume_guard) < rename_source.index('try walk(root)')
print('PASS 1 rename plan checks volume support before walking', flush=True)
# Guard the concurrency boundary that a local connected fixture cannot time reliably.
control_source = pathlib.Path('Sources/ProjectTemplates/ControlServer.swift').read_text()
assert 'await Task.detached { Catalogue.availability(record) }.value' in control_source
print('PASS 1 status filesystem check stays off the main actor', flush=True)
# Reuse the existing isolated AppModel harness, without launching or interacting with UI.
scratch = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else '/private/tmp/creatoros-fix2-build')
objects = scratch if (scratch / 'out').exists() else scratch / (os.uname().machine + '-apple-macosx/debug')
subprocess.run(['zsh', 'Scripts/check-durable-save.sh', str(objects)],
               env=dict(os.environ, CONTENT_TEMPLATE_CHECK_SOURCE='Scripts/check-control-model.swift'), check=True)
app = pathlib.Path(sys.argv[1]).resolve()
exe = app / 'Contents/MacOS/ProjectTemplates' if app.suffix == '.app' else app
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-control-', dir='/private/tmp'))
# A stale socket owned by this fixture must be replaced, never a regular file.
stale = socket.socket(socket.AF_UNIX)
stale.bind(str(root / 'control.sock')); stale.close()
proc = subprocess.Popen([str(exe), '--background', '--data-directory', str(root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            with socket.socket(socket.AF_UNIX) as probe: probe.connect(str(root / 'control.sock'))
            break
        except OSError: pass
        assert proc.poll() is None, 'test app exited before socket startup'
        time.sleep(.1)
    def call(action, params=None):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(10); sock.connect(str(root / 'control.sock'))
            sock.sendall((json.dumps({'id':'check', 'action':action, 'params':params or {}})+'\n').encode())
            return json.loads(sock.makefile().readline())
    status = call('status')
    assert status['ok'] and status['result']['isolated'] and status['result']['pid'] == proc.pid, status
    assert status['result']['dataRoot'] == str(root) and not status['result']['newProjectSheetOpen'], status
    assert (root.stat().st_mode & 0o777) == 0o700
    assert ((root / 'control.sock').stat().st_mode & 0o777) == 0o600
    assert call('library.stats')['result']['projects'] == 0
    assert call('project.list')['result']['total'] == 0
    assert call('bad')['error']['code'] == 'unknown_action'
    assert call('status', {'extra':1})['error']['code'] == 'invalid_params'
    assert call('project.list', {'limit':True})['error']['code'] == 'invalid_params'
    assert call('project.create', {'format':'Short','title':'Test'})['error']['code'] == 'template_not_ready'
    assert call('project.status', {'project':'missing'})['error']['code'] == 'not_found'
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10); sock.connect(str(root / 'control.sock'))
        sock.sendall(b'x' * 65537 + b'\n')
        try: rejected = sock.recv(1) == b''
        except ConnectionResetError: rejected = True
        assert rejected, 'oversized request must close'
    assert call('status')['ok'], 'oversized client must not stop server'
    print('PASS 13 built-app socket checks (including stale socket and oversize); fixture', root)
finally:
    # Only the exact disposable child spawned above, never a pre-existing app.
    proc.terminate(); proc.wait(timeout=10)

blocked_root = pathlib.Path(tempfile.mkdtemp(prefix='cos-socket-file-', dir='/private/tmp'))
(blocked_root / 'control.sock').write_bytes(b'keep this regular file')
blocked = subprocess.Popen([str(exe), '--background', '--data-directory', str(blocked_root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    time.sleep(.5)
    assert (blocked_root / 'control.sock').read_bytes() == b'keep this regular file'
    print('PASS non-socket control path is preserved; fixture', blocked_root)
finally:
    blocked.terminate(); blocked.wait(timeout=10)
