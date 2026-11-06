#!/usr/bin/env python3
"""Run a check under a read-only 0.2-second window/focus sampler (includes orphaned processes). Usage: check-invisible.py command [args...]."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) < 2:
    raise SystemExit(__doc__)
with tempfile.TemporaryDirectory(prefix='cos-invisible-', dir='/private/tmp') as directory:
    scratch = Path(directory)
    sampler = scratch / 'watch'
    subprocess.run(['swiftc', str(Path(__file__).with_name('watch-invisible.swift')), '-o', str(sampler)], check=True)
    stop, report = scratch / 'stop', scratch / 'report.json'
    watcher = subprocess.Popen([str(sampler), str(os.getpid()), str(stop), str(report), os.getcwd()], stdout=subprocess.PIPE, text=True)
    try:
        if watcher.stdout.readline().strip() != 'READY':
            raise RuntimeError('Window sampler failed to start; no check was run')
        result = subprocess.run(sys.argv[1:])
    finally:
        stop.touch()
        output = watcher.communicate(timeout=15)[0]
        print(output, end='', flush=True)
    evidence = json.loads(report.read_text())
    if destination := os.environ.get('CREATOROS_VISIBILITY_REPORT'):
        Path(destination).write_text(json.dumps(evidence, indent=2) + '\n')
    if watcher.returncode:
        print(json.dumps(evidence, indent=2), file=sys.stderr)
        raise SystemExit(watcher.returncode)
    raise SystemExit(result.returncode)
