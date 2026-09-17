#!/usr/bin/env python3
"""Regression tests for kit-layout namespace guards.

Run:  python tools/kit-layout/test_kit_layout.py

Covers the FOREIGN-NS trap: links created in one namespace (or before the
consumer tree was moved) must make plan/apply fail loudly (exit 2) and verify
FAIL, instead of a silent no-op plus a green verify. Also exercises the
_link-common.sh scan/compare helpers (no status leak under `set -euo
pipefail`, symlinked consumer root is one namespace).
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent


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


def _symlink_or_skip(case, target, link):
    try:
        os.symlink(str(target), str(link), target_is_directory=os.path.isdir(target))
    except (OSError, NotImplementedError) as e:  # no privilege (Windows)
        case.skipTest(f'symlinks not available: {e}')


def _find_bash():
    r"""Bash that can read this checkout's paths.

    On Windows `shutil.which('bash')` finds the WSL stub in System32, which
    cannot read C:\ temp paths; prefer the Git Bash that runs the session.
    """
    exe = os.environ.get('EXEPATH')
    if exe:
        cand = Path(exe) / 'bash.exe'
        if cand.is_file():
            return str(cand)
    found = shutil.which('bash')
    if found and 'system32' not in found.lower():
        return found
    for cand in (r'C:\Program Files\Git\bin\bash.exe',
                 r'C:\Program Files (x86)\Git\bin\bash.exe'):
        if Path(cand).is_file():
            return cand
    return found


class SymlinkedRootTest(unittest.TestCase):
    """A consumer root reached through a symlink is one namespace.

    Agent slots expose the worktree as /work -> /srv/agent-worktrees/agent-N,
    so links store the symlink spelling while the engine resolves the root.
    A lexical comparison would misread the whole tree as FOREIGN-NS.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-layout-symlink-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def layout(self, root):
        p = root / 'layout.json'
        p.write_text(json.dumps({
            'gitignore': False,
            'resources': [{
                'id': 'rules',
                'kind': 'child-files',
                'source': 'harness/cursor/rules',
                'target': '.cursor/rules',
            }],
        }), encoding='utf-8')
        return p

    def cmd(self, command, root):
        return [command, str(root), '--layout', str(root / 'layout.json'),
                '--no-gitignore', '--no-untrack']

    def test_symlinked_root_is_not_foreign(self):
        real = self.tmp / 'real'
        build_consumer(real)
        alias = self.tmp / 'work'
        _symlink_or_skip(self, real, alias)
        (real / '.cursor' / 'rules').mkdir(parents=True)
        for name in ('a.mdc', 'b.mdc'):
            _symlink_or_skip(self,
                             alias / 'harness' / 'cursor' / 'rules' / name,
                             real / '.cursor' / 'rules' / name)
        self.layout(real)
        self.assertEqual(kl.main(self.cmd('plan', real)), 0)
        # The alias spelling resolves to the same tree -> still local.
        self.assertEqual(kl.main(self.cmd('plan', alias)), 0)


class LinkCommonShellTest(unittest.TestCase):
    """_link-common.sh helpers under `set -euo pipefail` (report regressions)."""

    def setUp(self):
        self.bash = _find_bash()
        if not self.bash:
            self.skipTest('bash not available')
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-link-common-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.common = REPO_ROOT / 'scripts' / '_link-common.sh'
        if not self.common.is_file():
            self.skipTest('_link-common.sh not found')

    def run_bash(self, script, *args):
        return subprocess.run([self.bash, '-c', script, 'bash', *map(str, args)],
                              capture_output=True, text=True)

    def test_scan_does_not_leak_non_link_status(self):
        # Regression: the scan's last glob entry is a regular consumer file.
        # `[[ -L "$p" ]] && printf` used to return 1, so the pipeline and the
        # foreign_out= assignment aborted bootstrap silently before ERROR.
        skills = self.tmp / '.cursor' / 'skills'
        source = self.tmp / 'harness' / 'skills'
        skills.mkdir(parents=True)
        source.mkdir(parents=True)
        for name in ('aaa', 'mmm'):
            (source / name).mkdir()
            _symlink_or_skip(self, source / name, skills / name)
        (skills / 'zzz-local.md').write_text('local\n', encoding='utf-8')
        script = ('set -euo pipefail; source "$1"; '
                  'out="$(kit_consumer_link_paths "$2" | kit_foreign_links "$2")"; '
                  'echo "REACHED"')
        r = self.run_bash(script, self.common, self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('REACHED', r.stdout)

    def check_foreign(self, root, link):
        script = ('source "$1"; '
                  'if kit_link_is_foreign "$2" "$3"; then echo FOREIGN; '
                  'else echo LOCAL; fi')
        return self.run_bash(script, self.common, root, link)

    def test_symlinked_root_is_not_foreign(self):
        if sys.platform == 'win32':
            # MSYS maps %TEMP% to /tmp in readlink output but keeps C:/... in
            # realpath, so the two spellings cannot be compared reliably here.
            # The engine test above and Linux CI cover the resolved compare.
            self.skipTest('Git Bash path translation is inconsistent on Windows')
        real = self.tmp / 'real'
        (real / 'harness' / 'skills' / 'foo').mkdir(parents=True)
        alias = self.tmp / 'work'
        _symlink_or_skip(self, real, alias)
        link = real / '.cursor' / 'skills' / 'foo'
        link.parent.mkdir(parents=True)
        _symlink_or_skip(self, alias / 'harness' / 'skills' / 'foo', link)
        r = self.check_foreign(real, link)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('LOCAL', r.stdout)

    def test_genuinely_foreign_target(self):
        real = self.tmp / 'real'
        (real / 'harness').mkdir(parents=True)
        outside = self.tmp / 'outside' / 'skills' / 'foo'
        outside.mkdir(parents=True)
        link = real / '.cursor' / 'skills' / 'foo'
        link.parent.mkdir(parents=True)
        _symlink_or_skip(self, outside, link)
        r = self.check_foreign(real, link)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('FOREIGN', r.stdout)


def build_consumer(root):
    src = root / 'harness' / 'cursor' / 'rules'
    src.mkdir(parents=True)
    (src / 'a.mdc').write_text('rule-a\n', encoding='utf-8')
    (src / 'b.mdc').write_text('rule-b\n', encoding='utf-8')


if __name__ == '__main__':
    unittest.main(verbosity=2)
