#!/usr/bin/env python3
"""Regression tests for kit-agent session-start.

Run:  python tools/kit-agent/test_kit_agent.py

The namespace check must run outside the git branch: the sandbox image has no
git, but that is exactly where a foreign-ns layout must produce a hint instead
of a silent "everything is fine" (empty output).
"""
import argparse
import contextlib
import importlib.util
import io
import shutil
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent


def load_agent():
    spec = importlib.util.spec_from_file_location('kit_agent', HERE / 'kit_agent.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ka = load_agent()

FOREIGN_ERROR = (
    'ERROR: kit-layout foreign namespace: 2 kit link(s) point outside /x; '
    'refusing to relink.'
)


class SessionStartNoGitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-agent-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        layout = self.tmp / 'harness' / 'tools' / 'kit-layout'
        layout.mkdir(parents=True)
        (self.tmp / 'harness' / 'tools' / 'kit-agent').mkdir(parents=True)
        # Stand-in engine: exit 2 with a FOREIGN-NS ERROR line, like the real
        # kit_layout.py in a foreign namespace.
        (layout / 'kit_layout.py').write_text(
            'import sys\n'
            f'print({FOREIGN_ERROR!r}, file=sys.stderr)\n'
            'sys.exit(2)\n',
            encoding='utf-8')

    def run_session_start(self, git):
        old = ka.GIT
        ka.GIT = git
        try:
            args = argparse.Namespace(root=str(self.tmp), harness_rel='harness')
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = ka.cmd_session_start(args)
            return rc, buf.getvalue()
        finally:
            ka.GIT = old

    def test_namespace_hint_without_git(self):
        rc, out = self.run_session_start(git=None)
        self.assertEqual(rc, 0)
        self.assertIn('namespace', out)
        self.assertIn('foreign namespace', out)

    def test_namespace_hint_with_git(self):
        # Same check must survive when git is present too.
        rc, out = self.run_session_start(git='/usr/bin/git')
        self.assertEqual(rc, 0)
        self.assertIn('namespace', out)


if __name__ == '__main__':
    unittest.main(verbosity=2)
