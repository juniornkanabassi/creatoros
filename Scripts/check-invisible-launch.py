#!/usr/bin/env python3
"""Fail-closed invisible launch and idle-lifetime checks on disposable state only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

location = Path(sys.argv[1]).resolve()
binaries = location / 'Contents/MacOS' if location.suffix == '.app' else location
app, cli = binaries / 'ProjectTemplates', binaries / 'creatoros'
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1
    print('PASS', message, flush=True)


with tempfile.TemporaryDirectory(prefix='cos-invisible-launch-', dir='/private/tmp') as folder:
    root = Path(folder)
    home, data = root / 'Home', root / 'Data'
    (home / 'Library/Preferences').mkdir(parents=True)
    env = dict(os.environ, CREATOROS_TEST_HOME=str(home), CFFIXED_USER_HOME=str(home))
    env.pop('CREATOROS_DATA_DIRECTORY', None)
    env.pop('CREATOROS_AGENT_SCREEN', None)
    # Foundation's home lookup uses CFFIXED_USER_HOME for this disposable process.
    query = subprocess.run(['/usr/bin/swift', '-e', 'import Foundation; print(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)'],
                           env=env, capture_output=True, text=True, check=True, timeout=90)
    support = Path(query.stdout.strip())
    check(support.resolve().is_relative_to(home.resolve()), 'Foundation uses the disposable home')
    stable, alpha = support / 'Project Templates', support / 'CreatorOS Alpha'
    linked = root / 'Linked'
    linked.symlink_to(data, target_is_directory=True)

    rejected = [
        ['--agent-screen'],
        ['--agent-screen', '--data-directory'],
        ['--agent-screen', '--data-directory', str(stable)],
        ['--agent-screen', '--data-directory', str(alpha)],
        ['--agent-screen', '--data-directory', str(alpha / 'Child')],
        ['--agent-screen', '--data-directory', str(linked)],
        ['--agent-screen', '--data-directory', '/private/tmp'],
    ]
    for args in rejected:
        result = subprocess.run([str(app), *args], env=env, capture_output=True, text=True, timeout=15)
        check(result.returncode == 64 and result.stderr.strip(), 'app refuses invalid invisible launch: ' + ' '.join(args))
    check(not data.exists(), 'rejected launches did not create their candidate data folder')
    check(not stable.exists() and not alpha.exists(), 'rejected launches did not create either persistent library')
    for command in [('status',), ('library', 'stats')]:
        result = subprocess.run([str(cli), *command, '--json'], env=dict(env, CREATOROS_AGENT_SCREEN='1'), capture_output=True, text=True, timeout=15)
        check(result.returncode == 2 and json.loads(result.stdout)['error']['code'] == 'usage',
              'CLI refuses check environment without a disposable root: ' + ' '.join(command))
    result = subprocess.run([str(app)], env=dict(env, CREATOROS_AGENT_SCREEN='1'), capture_output=True, text=True, timeout=15)
    check(result.returncode == 64, 'app refuses check environment without a disposable root')

    process = subprocess.Popen([str(app), '--agent-screen', '--data-directory', str(data), '--headless', '--background', '--idle-quit', '2'],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while not (data / 'control.sock').exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        check((data / 'control.sock').exists(), 'valid invisible copy starts its isolated control socket')
        def command(*args):
            result = subprocess.run([str(cli), *args, '--data-directory', str(data), '--json'], env=env,
                                    capture_output=True, text=True, timeout=15)
            check(result.returncode == 0, 'isolated command succeeds: ' + ' '.join(args))
            return json.loads(result.stdout)
        idea = command('idea', 'add', '--title', 'Idle check', '--format', 'Short')
        command('project', 'open', idea['id'], '--show')
        state = command('status')
        check(state['pid'] == process.pid and state['headless'] is False, 'promotion retains the same invisible process')
        process.wait(timeout=15)
        check(process.returncode == 0, 'promoted invisible copy still quits when idle')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    direct_data = root / 'Direct'
    direct = subprocess.Popen([str(app), '--agent-screen', '--data-directory', str(direct_data), '--background', '--show', '--idle-quit', '2'],
                              env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        while not (direct_data / 'control.sock').exists() and direct.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        check((direct_data / 'control.sock').exists(), 'direct invisible copy starts with --show')
        direct.wait(timeout=15)
        check(direct.returncode == 0, 'direct invisible copy also quits when idle')
    finally:
        if direct.poll() is None:
            direct.terminate()
            try:
                direct.wait(timeout=10)
            except subprocess.TimeoutExpired:
                direct.kill()
                direct.wait(timeout=5)
print('RESULT %d invisible-launch checks passed' % checks)
