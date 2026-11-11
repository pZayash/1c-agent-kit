#!/usr/bin/env python3
"""Regression tests for kit-layout namespace guards and stack filtering.

Run:  python tools/kit-layout/test_kit_layout.py

Covers the FOREIGN-NS trap: links created in one namespace (or before the
consumer tree was moved) must make plan/apply fail loudly (exit 2) and verify
FAIL, instead of a silent no-op plus a green verify. Also exercises the
_link-common.sh scan/compare helpers (no status leak under `set -euo
pipefail`, symlinked consumer root is one namespace), .kit.json validation,
stack filtering and the stateless orphan-sweep.
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


# ── .kit.json / stacks / orphan-sweep ─────────────────────────────

STACKED_LAYOUT = {
    'gitignore': False,
    'fallback_manifest': '.kit/fallback.txt',
    'resources': [
        {'id': 'core-skills', 'kind': 'child-dirs',
         'source': 'harness/core/cursor/skills', 'target': '.cursor/skills',
         'local_manifest': '.kit/local-skills.txt'},
        {'id': 'skills-1c', 'kind': 'child-dirs',
         'source': 'harness/stacks/1c/cursor/skills',
         'target': '.cursor/skills',
         'local_manifest': '.kit/local-skills.txt', 'stacks': ['1c']},
    ],
}


def build_stacked_consumer(root):
    """Fake kit: two core skills, two 1c skills, stack registry."""
    for name in ('explore', 'handoff'):
        d = root / 'harness' / 'core' / 'cursor' / 'skills' / name
        d.mkdir(parents=True)
        (d / 'SKILL.md').write_text(f'core {name}\n', encoding='utf-8')
    for name in ('bsl-check', 'query-rule'):
        d = root / 'harness' / 'stacks' / '1c' / 'cursor' / 'skills' / name
        d.mkdir(parents=True)
        (d / 'SKILL.md').write_text(f'1c {name}\n', encoding='utf-8')
    (root / 'harness' / 'stacks' / '1c' / 'stack.json').write_text(
        '{"id": "1c"}', encoding='utf-8')


def write_kit_json(root, obj):
    (root / '.kit.json').write_text(
        json.dumps(obj) if not isinstance(obj, str) else obj,
        encoding='utf-8')


def dir_link(case, target, link):
    """Junction/symlink via the engine's own primitive (dangling targets
    are allowed - a link may outlive its source)."""
    link.parent.mkdir(parents=True, exist_ok=True)
    try:
        kl.make_dir_link(Path(target), Path(link))
    except OSError as e:
        case.skipTest(f'dir links not available: {e}')


class StackConfigTest(unittest.TestCase):
    """kit-stacks-layout 2.x: .kit.json load/validate + resource filter."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-stacks-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        build_stacked_consumer(self.tmp)
        (self.tmp / 'layout.json').write_text(
            json.dumps(STACKED_LAYOUT), encoding='utf-8')
        self._env = mock.patch.dict(os.environ)
        self._env.__enter__()
        self.addCleanup(self._env.__exit__, None, None, None)
        os.environ.pop('KIT_LEGACY', None)

    def args(self, command, *extra):
        return [command, str(self.tmp), '--layout',
                str(self.tmp / 'layout.json'), '--no-gitignore',
                '--no-untrack', *extra]

    def call(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = kl.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def linked(self, name):
        return kl.is_link(self.tmp / '.cursor' / 'skills' / name)

    def test_stacks_1c_links_everything(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['1c']})
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        for name in ('explore', 'handoff', 'bsl-check', 'query-rule'):
            self.assertTrue(self.linked(name), name)

    def test_stacks_empty_filters_1c(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.linked('explore'))
        self.assertFalse(self.linked('bsl-check'))
        self.assertFalse(self.linked('query-rule'))

    def test_missing_kit_json_is_core_only(self):
        rc, out, err = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('.kit.json', err)
        self.assertTrue(self.linked('explore'))
        self.assertFalse(self.linked('bsl-check'))

    def test_kit_legacy_overrides_file(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        os.environ['KIT_LEGACY'] = '1'
        rc, out, err = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('KIT_LEGACY', err)
        self.assertTrue(self.linked('bsl-check'))

    def test_star_in_file_is_rejected(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['*']})
        rc, _, err = self.call(*self.args('apply'))
        self.assertEqual(rc, 2)
        self.assertIn('"*"', err)

    def test_unknown_stack_fails_without_mutations(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['9x']})
        rc, _, err = self.call(*self.args('apply'))
        self.assertEqual(rc, 2)
        self.assertIn('unknown stack', err)
        self.assertFalse((self.tmp / '.cursor' / 'skills').exists())

    def test_broken_json_fails_without_mutations(self):
        write_kit_json(self.tmp, '{broken')
        rc, _, err = self.call(*self.args('apply'))
        self.assertEqual(rc, 2)
        self.assertIn('JSON', err)
        self.assertFalse((self.tmp / '.cursor' / 'skills').exists())

    def test_bad_types_fail_without_mutations(self):
        for cfg in ({'version': '1', 'stacks': []},
                    {'version': 1, 'stacks': 'all'},
                    {'version': 1},
                    {'version': 1, 'stacks': ['1c', '1c']},
                    {'version': 1, 'stacks': [''], 'sparse': 'yes'},
                    {'version': 2, 'stacks': []}):
            write_kit_json(self.tmp, cfg)
            rc, _, err = self.call(*self.args('apply'))
            self.assertEqual(rc, 2, cfg)
            self.assertIn('ERROR', err)
            self.assertFalse((self.tmp / '.cursor' / 'skills').exists(), cfg)

    def test_all_stacks_bypasses_filter(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        rc, out, _ = self.call(*self.args('plan', '--all-stacks'))
        self.assertEqual(rc, 0, out)
        self.assertIn('bsl-check', out)


class OrphanSweepTest(unittest.TestCase):
    """Stateless orphan-sweep: dropped stacks/paths are cleaned up."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-sweep-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        build_stacked_consumer(self.tmp)
        (self.tmp / 'layout.json').write_text(
            json.dumps(STACKED_LAYOUT), encoding='utf-8')
        self._env = mock.patch.dict(os.environ)
        self._env.__enter__()
        self.addCleanup(self._env.__exit__, None, None, None)
        os.environ.pop('KIT_LEGACY', None)

    def args(self, command, *extra):
        return [command, str(self.tmp), '--layout',
                str(self.tmp / 'layout.json'), '--no-gitignore',
                '--no-untrack', *extra]

    def call(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = kl.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def linked(self, name):
        return kl.is_link(self.tmp / '.cursor' / 'skills' / name)

    def test_stack_removed_sweeps_links_keeps_core(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['1c']})
        rc, _, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0)
        self.assertTrue(self.linked('bsl-check'))
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        rc, out, _ = self.call(*self.args('plan'))
        self.assertIn('WOULD REMOVE', out)
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('removed 2 link(s)', out)
        self.assertFalse(self.linked('bsl-check'))
        self.assertFalse(self.linked('query-rule'))
        self.assertTrue(self.linked('explore'))
        self.assertTrue(self.linked('handoff'))
        rc, out, _ = self.call(*self.args('verify'))
        self.assertEqual(rc, 0, out)

    def test_first_apply_removes_legacy_links(self):
        # Old layout linked into harness/cursor/skills/<x>; the path is
        # gone after git mv but the raw readlink string still points into
        # the kit -> orphan even without any .kit/ state.
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['1c']})
        dead = self.tmp / '.cursor' / 'skills' / 'gone-skill'
        dir_link(self, self.tmp / 'harness' / 'cursor' / 'skills' / 'gone-skill',
                 dead)
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertFalse(kl.is_link(dead))
        self.assertIn('removed 1 link(s)', out)

    def test_local_manifest_name_survives_sweep(self):
        (self.tmp / '.kit').mkdir()
        (self.tmp / '.kit' / 'local-skills.txt').write_text(
            'my-skill\n', encoding='utf-8')
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        mine = self.tmp / '.cursor' / 'skills' / 'my-skill'
        dir_link(self, self.tmp / 'harness' / 'legacy' / 'my-skill', mine)
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertTrue(self.linked('my-skill'))

    def test_legacy_local_manifest_is_read(self):
        # Old location still protects consumer overrides on first apply.
        legacy = self.tmp / 'tools' / 'cc-1c-skills-sync'
        legacy.mkdir(parents=True)
        (legacy / 'local-skills.txt').write_text('explore\n',
                                                encoding='utf-8')
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['1c']})
        own = self.tmp / '.cursor' / 'skills' / 'explore'
        own.mkdir(parents=True)
        (own / 'SKILL.md').write_text('consumer override\n',
                                     encoding='utf-8')
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('SKIP LOCAL: explore', out)
        self.assertTrue(own.is_dir() and not kl.is_link(own))

    def test_foreign_ns_orphan_warned_not_removed(self):
        # Target outside the consumer root = foreign namespace (another
        # checkout's layout seen from here): WARN, never deleted.
        outside = Path(tempfile.mkdtemp(prefix='kit-outside-')) / 'target'
        self.addCleanup(shutil.rmtree, outside.parent, ignore_errors=True)
        outside.mkdir()
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        link = self.tmp / '.cursor' / 'skills' / 'ext-skill'
        dir_link(self, outside, link)
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('unmanaged orphan', out)
        self.assertTrue(kl.is_link(link))

    def test_pristine_orphan_fallback_removed(self):
        fb = self.tmp / 'tools' / 'copy.txt'
        fb.parent.mkdir(parents=True)
        fb.write_text('kit copy\n', encoding='utf-8')
        sha = kl.hash_file(fb)
        (self.tmp / '.kit').mkdir()
        (self.tmp / '.kit' / 'fallback.txt').write_text(
            f'tools/copy.txt\tharness/tools/copy.txt\t{sha}\n',
            encoding='utf-8')
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('REMOVE orphan fallback', out)
        self.assertFalse(fb.exists())
        manifest = (self.tmp / '.kit' / 'fallback.txt').read_text(
            encoding='utf-8')
        self.assertNotIn('copy.txt', manifest)

    def test_edited_orphan_fallback_warned_and_kept(self):
        fb = self.tmp / 'tools' / 'copy.txt'
        fb.parent.mkdir(parents=True)
        fb.write_text('original\n', encoding='utf-8')
        sha = kl.hash_file(fb)
        fb.write_text('consumer edited\n', encoding='utf-8')
        (self.tmp / '.kit').mkdir()
        (self.tmp / '.kit' / 'fallback.txt').write_text(
            f'tools/copy.txt\tharness/tools/copy.txt\t{sha}\n',
            encoding='utf-8')
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertIn('local edits, kept', out)
        self.assertEqual(fb.read_text(encoding='utf-8'), 'consumer edited\n')
        manifest = (self.tmp / '.kit' / 'fallback.txt').read_text(
            encoding='utf-8')
        self.assertIn('tools/copy.txt', manifest)

    def test_legacy_fallback_manifest_is_read(self):
        fb = self.tmp / 'tools' / 'copy.txt'
        fb.parent.mkdir(parents=True)
        fb.write_text('kit copy\n', encoding='utf-8')
        sha = kl.hash_file(fb)
        legacy = self.tmp / 'tools' / 'cc-1c-skills-sync'
        legacy.mkdir(parents=True)
        (legacy / 'kit-fallback.txt').write_text(
            f'tools/copy.txt\tharness/tools/copy.txt\t{sha}\n',
            encoding='utf-8')
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        self.assertFalse(fb.exists())
        self.assertTrue((self.tmp / '.kit' / 'fallback.txt').is_file())

    def test_verify_warns_about_orphans(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        link = self.tmp / '.cursor' / 'skills' / 'stale'
        dir_link(self, self.tmp / 'harness' / 'stacks' / '1c' / 'cursor'
                 / 'skills' / 'bsl-check', link)
        rc, out, _ = self.call(*self.args('apply'))
        self.assertEqual(rc, 0, out)
        dir_link(self, self.tmp / 'harness' / 'stacks' / '1c' / 'cursor'
                 / 'skills' / 'bsl-check', link)
        rc, out, _ = self.call(*self.args('verify'))
        self.assertIn('orphan kit link', out)


class PrintConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-pconf-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        build_stacked_consumer(self.tmp)
        (self.tmp / 'layout.json').write_text(
            json.dumps(STACKED_LAYOUT), encoding='utf-8')
        self._env = mock.patch.dict(os.environ)
        self._env.__enter__()
        self.addCleanup(self._env.__exit__, None, None, None)
        os.environ.pop('KIT_LEGACY', None)

    def call(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = kl.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def args(self, *extra):
        return ['print-config', str(self.tmp), '--layout',
                str(self.tmp / 'layout.json'), *extra]

    def test_print_config_json(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['1c'],
                                  'source_root': 'src/', 'sparse': True})
        rc, out, _ = self.call(*self.args('--json'))
        self.assertEqual(rc, 0)
        cfg = json.loads(out)
        self.assertEqual(cfg['stacks'], ['1c'])
        self.assertEqual(cfg['stacks_source'], 'file')
        self.assertEqual(cfg['source_root'], 'src/')
        self.assertEqual(cfg['source_root_source'], 'file')
        self.assertTrue(cfg['sparse'])

    def test_source_root_env_fallback(self):
        write_kit_json(self.tmp, {'version': 1, 'stacks': []})
        (self.tmp / '.env').write_text('CONFIG_PATH=cfg-src\n',
                                       encoding='utf-8')
        rc, out, _ = self.call(*self.args('--json'))
        cfg = json.loads(out)
        self.assertEqual(cfg['source_root'], 'cfg-src')
        self.assertEqual(cfg['source_root_source'], 'env')

    def test_source_root_default(self):
        rc, out, _ = self.call(*self.args('--json'))
        cfg = json.loads(out)
        self.assertEqual(cfg['source_root'], 'conf/')
        self.assertEqual(cfg['source_root_source'], 'default')


class ResolveSourceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-resolve-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        build_stacked_consumer(self.tmp)
        (self.tmp / 'layout.json').write_text(
            json.dumps(STACKED_LAYOUT), encoding='utf-8')
        write_kit_json(self.tmp, {'version': 1, 'stacks': ['1c']})
        self._env = mock.patch.dict(os.environ)
        self._env.__enter__()
        self.addCleanup(self._env.__exit__, None, None, None)
        os.environ.pop('KIT_LEGACY', None)

    def call(self, rel):
        out, err = io.StringIO(), io.StringIO()
        argv = ['resolve-source', rel, '--root', str(self.tmp),
                '--layout', str(self.tmp / 'layout.json')]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = kl.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def test_core_skill(self):
        rc, out, _ = self.call('.cursor/skills/explore/SKILL.md')
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(),
                         'harness/core/cursor/skills/explore/SKILL.md')

    def test_stack_skill(self):
        rc, out, _ = self.call('.cursor/skills/bsl-check')
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(),
                         'harness/stacks/1c/cursor/skills/bsl-check')

    def test_unmanaged_path_fails(self):
        rc, _, err = self.call('docs/readme.md')
        self.assertEqual(rc, 2)
        self.assertIn('no kit source', err)


if __name__ == '__main__':
    unittest.main(verbosity=2)
