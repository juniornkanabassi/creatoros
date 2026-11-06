#!/usr/bin/env python3
"""A command against a closed CreatorOS starts it headless: no window on screen, not even for a frame, no Dock tile,
quick to answer. An unused headless copy quits by itself. --show turns a copy into the ordinary app, but a check's copy
(--agent-screen) stays invisible, in the background and out of the Dock throughout.
Usage: python3 Scripts/check-headless.py <built CreatorOS.app>. Runs only on disposable data directories; nothing
appears on any screen and nothing takes focus."""
import instances
import json, os, pathlib, re, statistics, subprocess, sys, tempfile, time
os.environ['CREATOROS_AGENT_SCREEN'] = '1'  # every CLI and app child of this check stays invisible and focus-free
app = pathlib.Path(sys.argv[1]).resolve()

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

def frontmost():
    out = subprocess.run(['/usr/bin/swift', '-e', 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)'],
                         capture_output=True, text=True, timeout=120)
    return int(out.stdout.strip())

def command_line(pid):
    """Arguments and, after them, the environment of one of this user's processes."""
    return subprocess.run(['/bin/ps', '-E', '-ww', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout

try:
    check(command('status')[0] == {'running': False}, 'status works while stopped without launching')
    seen = watch(4)  # the launch and a little after it, sampled every 5 ms
    stats, cold = command('library', 'stats')
    state, _ = command('status')
    pid = state['pid']
    print('INFO cold command, launch included: %.0f ms' % cold)
    check(cold < 10000, 'the first command answers while the app starts headless')
    check(state['headless'] is True, 'the copy the command started reports headless')
    started = command_line(pid)
    # open would drop this check's environment; a direct child keeps it.
    check(' --agent-screen ' in started and 'CREATOROS_AGENT_SCREEN=1' in started,
          'the CLI started the test copy directly, not through open, with --agent-screen and this environment')
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
    idle = subprocess.Popen([str(exe), '--agent-screen', '--data-directory', str(idle_root), '--background', '--headless', '--idle-quit', '2'],
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
    # --show promotes the copy, but under --agent-screen it never shows a window, gains a Dock tile or takes focus.
    seen = watch(8)
    shown = subprocess.Popen([str(exe), '--agent-screen', '--data-directory', str(root), '--background', '--headless'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):  # status answers {running: false} until this copy's socket is up; it never launches one
        if 'headless' in command('status')[0]: break
        time.sleep(0.1)
    command('project', 'open', idea['id'], '--show')
    state, _ = command('status')
    check(state['headless'] is False and state['pid'] == shown.pid, '--show turns the headless copy into the ordinary app')
    time.sleep(1)
    check(instances.activation_type(shown.pid) in ('UIElement', 'BackgroundOnly'), 'the revealed check copy still has no Dock tile')
    check(onscreen_windows(shown.pid) == 0, 'the revealed check copy shows no window')
    check(frontmost() != shown.pid, 'the revealed check copy stayed in the background')
    windows, dock = seen()
    check(windows == 0 and not dock, '--show never put a check copy on screen or in the Dock (saw %d, Dock %s)' % (windows, dock))
finally:
    instances.cleanup(root, idle_root)
print('RESULT %d headless checks passed' % checks)
