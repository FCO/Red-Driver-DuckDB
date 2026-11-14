import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

LAUNCHER = Path(__file__).resolve().parents[1] / 'red-test-exec.py'
STUB = '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
mode = os.environ['STUB_MODE']
if mode == 'bailout':
    print('1..1\\nBail out! deliberate')
elif mode == 'message':
    print('1..1\\nok 1 - message mentions Bail out!')
elif mode == 'timeout':
    child = subprocess.Popen([sys.executable, '-c', 'import time, pathlib, sys; time.sleep(2); pathlib.Path(sys.argv[1]).touch()', os.environ['MARKER']])
    pathlib.Path(os.environ['STARTED']).write_text(str(child.pid))
    time.sleep(30)
else:
    print('1..1\\nok 1 - stub')
    print('diagnostic', file=sys.stderr)
    sys.exit(int(os.environ.get('STUB_EXIT', '0')))
'''


@unittest.skipIf(os.name == 'nt', 'POSIX executable shim; Windows process-tree path is reviewed separately')
class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'bin').mkdir()
        fake = self.root / 'bin' / 'raku'
        fake.write_text(STUB)
        fake.chmod(0o755)
        self.test = self.root / 'case.rakutest'
        self.test.touch()
        self.results = self.root / 'results'
        self.env = dict(os.environ, PATH=str(fake.parent) + os.pathsep + os.environ['PATH'],
                        RED_TEST_RESULTS=str(self.results), STUB_MODE='normal')

    def tearDown(self):
        self.temp.cleanup()

    def run_launcher(self, **environment):
        return subprocess.run([sys.executable, str(LAUNCHER), str(self.test)],
                              env=dict(self.env, **environment), capture_output=True, timeout=10)

    def metadata(self):
        return json.loads((self.results / (self.test.name + '.json')).read_text())

    def test_success_separates_stderr(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(b'diagnostic', result.stdout)
        self.assertEqual(result.stderr, b'diagnostic\n')
        self.assertFalse(self.metadata()['bailout'])

    def test_nonzero_exit_is_preserved(self):
        result = self.run_launcher(STUB_EXIT='7')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.metadata()['child_exit_code'], 7)

    def test_zero_exit_bailout_still_fails_and_preserves_raw_tap(self):
        result = self.run_launcher(STUB_MODE='bailout')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b'\nBail out!', result.stdout)
        self.assertIn(b'\nBail out!', (self.results / (self.test.name + '.tap')).read_bytes())
        self.assertEqual(self.metadata()['child_exit_code'], 0)
        self.assertTrue(self.metadata()['bailout'])

    def test_bailout_words_inside_assertion_are_not_a_bailout(self):
        result = self.run_launcher(STUB_MODE='message')
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.metadata()['bailout'])

    def test_timeout_kills_grandchild(self):
        marker = self.root / 'surviving-child'
        result = self.run_launcher(STUB_MODE='timeout', RED_TEST_TIMEOUT='1', MARKER=str(marker), STARTED=str(self.root / 'child-started'))
        self.assertEqual(result.returncode, 124)
        self.assertTrue(self.metadata()['timed_out'])
        self.assertTrue((self.root / 'child-started').exists(), 'test must actually spawn a grandchild')
        time.sleep(1.5)
        self.assertFalse(marker.exists(), 'grandchild survived the timeout')

    def test_invalid_timeouts_fail_before_launch(self):
        for value in ['0', '-1', 'nan', 'inf', 'bad']:
            with self.subTest(value=value):
                result = self.run_launcher(RED_TEST_TIMEOUT=value)
                self.assertEqual(result.returncode, 2)
                self.assertIn(b'finite positive', result.stderr)
        self.assertFalse(self.results.exists())


if __name__ == '__main__':
    unittest.main()
