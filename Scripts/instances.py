"""Test helpers that keep CreatorOS test instances few, quiet and gone.

Only a process whose arguments carry one of the caller's own disposable data directories (under /private/tmp) is ever
looked at, so the everyday app (no --data-directory) can never be matched or stopped by these helpers."""
import os, signal, subprocess, time

def _roots(roots):
    clean = [str(r) for r in roots]
    assert clean and all(r.startswith('/private/tmp/') and len(r) > len('/private/tmp/cos-') for r in clean), clean
    return clean

def pids(*roots):
    """Process ids of ProjectTemplates instances started with exactly one of these data directories."""
    wanted = _roots(roots)
    found = []
    for line in subprocess.run(['/bin/ps', '-axo', 'pid=,args='], capture_output=True, text=True).stdout.splitlines():
        pid, _, args = line.strip().partition(' ')
        if 'ProjectTemplates' not in args.split(' --')[0]:
            continue
        marker = ' --data-directory '
        rest = args[args.find(marker) + len(marker):] if marker in args else None
        if rest is not None and any(rest == r or rest.startswith(r + ' ') for r in wanted):
            found.append(int(pid))
    return found

def quit_all(*roots, grace=10):
    """Ask each such instance to quit, wait for it to exit, and only then force the stragglers."""
    live = pids(*roots)
    for pid in live:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    deadline = time.time() + grace
    while time.time() < deadline and pids(*roots): time.sleep(0.1)
    for pid in pids(*roots):
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
    deadline = time.time() + 5
    while time.time() < deadline and pids(*roots): time.sleep(0.1)
    return len(live)

def assert_none_alive(*roots):
    left = pids(*roots)
    assert not left, 'test instances still running: %s' % left

def activation_type(pid):
    """Foreground (Dock tile), UIElement (accessory) or BackgroundOnly, as LaunchServices reports it."""
    import re
    out = subprocess.run(['/usr/bin/lsappinfo', 'info', '-app', str(pid)], capture_output=True, text=True).stdout
    found = re.search(r'type="(\w+)"', out)
    return found.group(1) if found else None
