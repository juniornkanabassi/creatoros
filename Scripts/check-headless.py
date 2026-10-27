#!/usr/bin/env python3
"""A command against a closed CreatorOS starts it headless: no window on screen, not even for a frame, no Dock tile,
quick to answer. An unused headless copy quits by itself. With --visible, --show also turns a copy into the ordinary app
with its window in front, on the Prompter XL (or --display-name NAME) so nothing appears on the main monitor.
Usage: python3 Scripts/check-headless.py <built CreatorOS.app> [--visible [--display-name NAME]].
Runs only on disposable data directories. Without --visible nothing appears on screen."""
import instances
import json, os, pathlib, re, statistics, subprocess, sys, tempfile, time
app = pathlib.Path(sys.argv[1]).resolve()
visible = '--visible' in sys.argv[2:]
display = sys.argv[sys.argv.index('--display-name') + 1] if '--display-name' in sys.argv else 'Prompter XL'

assert app.suffix == '.app', 'give the built CreatorOS.app'
cli, exe = app / 'Contents/MacOS/creatoros', app / 'Contents/MacOS/ProjectTemplates'
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-headless-', dir='/private/tmp'))
idle_root = pathlib.Path(tempfile.mkdtemp(prefix='cos-headless-idle-', dir='/private/tmp'))
checks = 0

def check(condition, label):
    global checks
    assert condition, label
    checks += 1; print('PASS', label, flush=True)

def command(*args, data=root):
    started = time.monotonic()
    result = subprocess.run([str(cli), *args, '--json', '--data-directory', str(data)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout), (time.monotonic() - started) * 1000

def watch(seconds):
    """Starts watch-headless.swift on the app's executable; call the result to get (most windows at once, Dock tile)."""
    watcher = subprocess.Popen(['/usr/bin/swift', str(pathlib.Path(__file__).with_name('watch-headless.swift')), str(exe), str(seconds)],
                               stdout=subprocess.PIPE, text=True)
    assert watcher.stdout.readline().strip() == 'READY', 'the screen watcher did not start'
    def result():
        found = re.search(r'WINDOWS (\d+) DOCK (\w+)', watcher.communicate(timeout=seconds + 60)[0])
        return int(found.group(1)), found.group(2) == 'yes'
    return result

def onscreen_windows(pid):
    """Layer-0 windows of this process that are on screen and not fully transparent."""
    out = subprocess.run(['/usr/bin/swift', '-e', '''
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
print(windows.filter { $0[kCGWindowOwnerPID as String] as? Int == pid && $0[kCGWindowLayer as String] as? Int == 0
    && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }.count)''', str(pid)], capture_output=True, text=True, timeout=120)
    return int(out.stdout.strip())

try:
    check(command('status')[0] == {'running': False}, 'status works while stopped without launching')
    seen = watch(4)  # the launch and a little after it, sampled every 5 ms
    stats, cold = command('library', 'stats')
    state, _ = command('status')
    pid = state['pid']
    print('INFO cold command, launch included: %.0f ms' % cold)
    check(cold < 10000, 'the first command answers while the app starts headless')
    check(state['headless'] is True, 'the copy the command started reports headless')
    check(instances.activation_type(pid) in ('UIElement', 'BackgroundOnly'), 'the headless copy has no Dock tile')
    windows, dock = seen()
    check(windows == 0, 'the headless launch never put a window on screen, not even for a frame (saw %d)' % windows)
    check(not dock, 'the headless launch never showed a Dock tile')
    check(onscreen_windows(pid) == 0, 'the headless copy shows no window')
    warm = [command('library', 'stats')[1] for _ in range(7)]
    print('INFO warm command: median %.0f ms, slowest %.0f ms' % (statistics.median(warm), max(warm)))
    check(statistics.median(warm) < 500, 'a command to the running headless copy is quick')
    idea, _ = command('idea', 'add', '--title', 'Headless check', '--format', 'Short')
    command('project', 'open', idea['id'])
    check(command('status')[0]['headless'] is True, 'opening a project without --show keeps the copy headless')
    instances.quit_all(root)
    # An unused headless copy quits by itself; --idle-quit shortens the ten minutes for this check. Launched directly,
    # not through LaunchServices, which is the other way a headless copy starts.
    seen = watch(4)
    idle = subprocess.Popen([str(exe), '--data-directory', str(idle_root), '--background', '--headless', '--idle-quit', '2'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if (idle_root / 'control.sock').exists(): break
        time.sleep(0.1)
    check(command('status', data=idle_root)[0]['headless'] is True, 'a directly launched --headless copy is headless')
    windows, dock = seen()
    check(windows == 0 and not dock, 'a directly launched --headless copy never showed a window or Dock tile (saw %d, Dock %s)' % (windows, dock))
    try: idle.wait(timeout=15)
    except subprocess.TimeoutExpired: pass
    check(idle.poll() is not None, 'an unused headless copy quits by itself')
    if visible:
        # --display-name puts the window on that screen as it opens, so the revealed window never lands on the main monitor.
        shown = subprocess.Popen([str(exe), '--data-directory', str(root), '--background', '--headless', '--display-name', display],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):  # status answers {running: false} until this copy's socket is up; it never launches one
            if 'headless' in command('status')[0]: break
            time.sleep(0.1)
        command('project', 'open', idea['id'], '--show')
        state, _ = command('status')
        check(state['headless'] is False and state['pid'] == shown.pid, '--show turns the headless copy into the visible app')
        check(instances.activation_type(shown.pid) == 'Foreground', 'the revealed app has its Dock tile')
        time.sleep(1)
        check(onscreen_windows(shown.pid) == 1, 'the revealed app shows its window')
    else:
        print('INFO --show skipped; pass --visible to check it on the Prompter XL')
finally:
    instances.quit_all(root, idle_root)
    instances.assert_none_alive(root, idle_root)
print('RESULT %d headless checks passed' % checks)
