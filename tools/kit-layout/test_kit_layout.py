#!/usr/bin/env python3
"""Regression tests for kit-layout namespace guards.

Run:  python tools/kit-layout/test_kit_layout.py

Covers the FOREIGN-NS trap: links created in one namespace (or before the
consumer tree was moved) must make plan/apply fail loudly (exit 2) and verify
FAIL, instead of a silent no-op plus a green verify.
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_engine():
    spec = importlib.util.spec_from_file_location('kit_layout', HERE / 'kit_layout.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


kl = load_engine()


class NamespaceGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-layout-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        build_consumer(self.tmp)
        self.layout = self.tmp / 'layout.json'
        self.layout.write_text(json.dumps({
            'gitignore': False,
            'resources': [{
                'id': 'rules',
                'kind': 'child-files',
                'source': 'harness/cursor/rules',
                'target': '.cursor/rules',
            }],
        }), encoding='utf-8')

    def args(self, command, root, *extra):
        # The layout travels with the consumer root (it is renamed in tests).
        return [command, str(root), '--layout', str(Path(root) / 'layout.json'),
                '--no-gitignore', '--no-untrack', *extra]

    def test_host_namespace_is_clean(self):
        self.assertEqual(kl.main(self.args('apply', self.tmp)), 0)
        self.assertEqual(kl.main(self.args('plan', self.tmp)), 0)
        self.assertEqual(kl.main(self.args('plan', self.tmp, '--strict')), 0)
        self.assertEqual(kl.main(self.args('verify', self.tmp)), 0)

    def test_foreign_namespace_is_loud(self):
        self.assertEqual(kl.main(self.args('apply', self.tmp)), 0)
        moved = self.tmp.with_name(self.tmp.name + '-moved')
        os.rename(self.tmp, moved)
        try:
            # plan/apply must refuse before touching anything; strict too.
            self.assertEqual(kl.main(self.args('plan', moved)), 2)
            self.assertEqual(kl.main(self.args('plan', moved, '--strict')), 2)
            self.assertEqual(kl.main(self.args('apply', moved)), 2)
            # verify cannot validate a foreign namespace.
            self.assertEqual(kl.main(self.args('verify', moved)), 1)
        finally:
            if moved.exists():
                os.rename(moved, self.tmp)

    def test_gitignore_overlap_detection(self):
        gi = self.tmp / '.gitignore'
        gi.write_text(
            '*.log\n'
            '/.cursor/rules/a.mdc\n'
            '/.pi/skills/\n'
            'build/\n'
            '# >>> kit-managed: begin (bootstrap-kit) >>>\n'
            '/.cursor/rules/a.mdc\n'
            '/.pi/skills\n'
            '/tools/cc-1c-skills-sync/kit-fallback.txt\n'
            '# <<< kit-managed: end <<<\n',
            encoding='utf-8')
        overlap = kl.check_gitignore_overlap(kl.Ctx(self.tmp, 'harness'))
        self.assertEqual(overlap, ['.cursor/rules/a.mdc', '.pi/skills'])


class IsWithinTest(unittest.TestCase):
    def test_prefix_is_not_enough(self):
        self.assertTrue(kl.is_within('/a/b/c', '/a/b'))
        self.assertTrue(kl.is_within('/a/b', '/a/b'))
        self.assertFalse(kl.is_within('/a/bc', '/a/b'))
        self.assertFalse(kl.is_within('/a', '/a/b'))


def build_consumer(root):
    src = root / 'harness' / 'cursor' / 'rules'
    src.mkdir(parents=True)
    (src / 'a.mdc').write_text('rule-a\n', encoding='utf-8')
    (src / 'b.mdc').write_text('rule-b\n', encoding='utf-8')


if __name__ == '__main__':
    unittest.main(verbosity=2)
