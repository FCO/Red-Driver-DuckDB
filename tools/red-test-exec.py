#!/usr/bin/env python3
"""Preload DuckDB, isolate TAP diagnostics, and enforce a per-file process-tree timeout."""
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

BAILOUT = re.compile(rb'(?m)^([ \t]*)Bail out!')


def stop_tree(process):
    """Kill descendants as well as the direct Raku process before draining pipes."""
    if os.name == 'nt':
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        if process.poll() is None:
            process.kill()
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if not arguments:
        print('Usage: red-test-exec.py [Raku options] TEST', file=sys.stderr)
        return 2
    try:
        timeout = float(os.environ.get('RED_TEST_TIMEOUT', '180'))
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError
    except ValueError:
        print('RED_TEST_TIMEOUT must be a finite positive number of seconds', file=sys.stderr)
        return 2
    project = Path(__file__).resolve().parent.parent
    red = Path(os.environ.get('RED_CHECKOUT', str(project.parent / 'Red'))).resolve()
    results = Path(os.environ.get('RED_TEST_RESULTS', str(project / 'test-results' / 'latest')))
    results.mkdir(parents=True, exist_ok=True)
    test = Path(arguments[-1]).resolve()
    command = [shutil.which('raku') or 'raku', f'-I{red / "lib"}', f'-I{project / "lib"}',
               '-MRed::Driver::DuckDB', *arguments[:-1], str(test)]
    started = time.monotonic()
    cwd = red if test.is_relative_to(red / 't') else project
    stdout = stderr = b''
    child_code = None
    timed_out = False
    try:
        options = ({'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == 'nt'
                   else {'start_new_session': True})
        process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, **options)
        try:
            stdout, stderr = process.communicate(timeout=timeout)
            code = child_code = process.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_tree(process)
            stdout, stderr = process.communicate()
            child_code = process.returncode
            stdout += b'\nBail out! Per-file timeout\n'
            code = 124
    except OSError as error:
        stderr = (str(error) + '\n').encode()
        code = 127
    bailout = bool(BAILOUT.search(stdout))
    # A bailout is failure even when an END phaser overwrites the child's exit code.
    if bailout and code == 0:
        code = 1
    prefix = results / test.name
    Path(str(prefix) + '.tap').write_bytes(stdout)
    Path(str(prefix) + '.stderr.log').write_bytes(stderr)
    Path(str(prefix) + '.log').write_bytes(stdout + (b'\n[stderr]\n' + stderr if stderr else b''))
    Path(str(prefix) + '.json').write_text(json.dumps({
        'file': str(test), 'driver': os.environ.get('RED_DATABASE'), 'exit_code': code,
        'child_exit_code': child_code, 'timeout_seconds': timeout, 'timed_out': timed_out,
        'bailout': bailout, 'seconds': round(time.monotonic() - started, 2), 'command': command,
    }, indent=2) + '\n')
    # Keep the remaining files running; preserve the original bailout in raw TAP.
    sys.stdout.buffer.write(BAILOUT.sub(rb'\1# Original Bail out!', stdout))
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(stderr)
    sys.stderr.buffer.flush()
    return code


if __name__ == '__main__':
    sys.exit(main())
