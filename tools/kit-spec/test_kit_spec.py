#!/usr/bin/env python3
"""Regression tests for kit-spec.

Run:  python tools/kit-spec/test_kit_spec.py
"""
import argparse
import contextlib
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_spec():
    spec = importlib.util.spec_from_file_location('kit_spec', HERE / 'kit_spec.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ks = load_spec()


def run(fn, **kw):
    """Call a cmd_* with a Namespace; returns (rc, stdout)."""
    a = argparse.Namespace(**kw)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn(a)
    return rc, buf.getvalue()


def run_main(argv, cwd):
    """Full main() against a consumer root (cwd switched)."""
    old = Path.cwd()
    import os
    os.chdir(cwd)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = ks.main(argv)
    finally:
        os.chdir(old)
    return rc, buf.getvalue()


class TempConsumer(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='kit-spec-test-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def init_specs(self):
        rc, _ = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=False)
        assert rc == 0

    def new_change(self, name='my-change', **kw):
        return run(ks.cmd_new, root=str(self.tmp), spec_root=None,
                   name=name, with_delta=kw.get('with_delta'))

    def write_tasks(self, name, lines):
        p = self.tmp / 'specs' / 'changes' / name / 'tasks.md'
        p.write_text('# Tasks\n\n' + '\n'.join(lines) + '\n', encoding='utf-8')


class InitTest(TempConsumer):
    def test_init_creates_structure(self):
        rc, out = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=False)
        self.assertEqual(rc, 0)
        self.assertTrue((self.tmp / 'specs' / 'changes' / 'archive').is_dir())
        self.assertTrue((self.tmp / 'specs' / '.kit-spec.json').is_file())
        self.assertTrue((self.tmp / 'specs' / 'README.md').is_file())

    def test_init_idempotent(self):
        self.init_specs()
        rc, out = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=False)
        self.assertEqual(rc, 0)
        self.assertIn('уже инициализирован', out)

    def test_init_foreign_refuses(self):
        (self.tmp / 'specs').mkdir()
        (self.tmp / 'specs' / 'other.txt').write_text('x')
        rc, out = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=False)
        self.assertEqual(rc, 1)
        self.assertIn('FAIL', out)

    def test_init_foreign_force(self):
        (self.tmp / 'specs').mkdir()
        (self.tmp / 'specs' / 'other.txt').write_text('x')
        rc, out = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=True)
        self.assertEqual(rc, 0)
        self.assertTrue((self.tmp / 'specs' / 'changes').is_dir())


class NewTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()

    def test_new_scaffolds(self):
        rc, out = self.new_change()
        self.assertEqual(rc, 0)
        cdir = self.tmp / 'specs' / 'changes' / 'my-change'
        for f in ('proposal.md', 'design.md', 'tasks.md'):
            self.assertTrue((cdir / f).is_file(), f)

    def test_new_kebab(self):
        rc, out = self.new_change('Bad_Name')
        self.assertEqual(rc, 1)
        self.assertIn('kebab', out)

    def test_new_existing_refuses(self):
        self.new_change()
        rc, out = self.new_change()
        self.assertEqual(rc, 1)

    def test_new_with_delta(self):
        rc, out = self.new_change(with_delta=['orders'])
        self.assertEqual(rc, 0)
        self.assertTrue((self.tmp / 'specs' / 'changes' / 'my-change' /
                         'specs' / 'orders' / 'spec.md').is_file())


class StatusListTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()
        self.new_change()
        self.write_tasks('my-change', ['- [ ] one', '- [x] two', '- [ ] three'])

    def test_status_counts(self):
        rc, out = run(ks.cmd_status, root=str(self.tmp), spec_root=None,
                      name='my-change', json=False)
        self.assertEqual(rc, 0)
        self.assertIn('1/3', out)

    def test_status_json(self):
        rc, out = run(ks.cmd_status, root=str(self.tmp), spec_root=None,
                      name='my-change', json=True)
        rep = json.loads(out)
        self.assertEqual(rep['tasks'], {'done': 1, 'total': 3})

    def test_list(self):
        rc, out = run(ks.cmd_list, root=str(self.tmp), spec_root=None, json=False)
        self.assertEqual(rc, 0)
        self.assertIn('my-change', out)
        self.assertIn('1/3', out)

    def test_operator_checklist_counted(self):
        p = self.tmp / 'specs' / 'changes' / 'my-change' / 'operator-checklist.md'
        p.write_text('# Оператор\n\n- [ ] check\n- [x] done\n')
        rc, out = run(ks.cmd_status, root=str(self.tmp), spec_root=None,
                      name='my-change', json=True)
        rep = json.loads(out)
        self.assertEqual(rep['operator_checklist']['open'], 1)


class ValidateTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()
        self.new_change()

    def test_validate_clean_scaffold(self):
        # пустой tasks.md из шаблона: есть чекбокс-пример -> ок по структуре,
        # но нет «Артефакты»? в шаблоне секция есть -> только возможные WARN
        rc, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                      name='my-change', all=False, archive=False)
        self.assertEqual(rc, 0)

    def test_validate_missing_file(self):
        (self.tmp / 'specs' / 'changes' / 'my-change' / 'design.md').unlink()
        rc, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                      name='my-change', all=False, archive=False)
        self.assertEqual(rc, 1)
        self.assertIn('нет design.md', out)

    def test_validate_delta_bad(self):
        d = self.tmp / 'specs' / 'changes' / 'my-change' / 'specs' / 'cap'
        d.mkdir(parents=True)
        (d / 'spec.md').write_text('# cap\n\njust prose\n')
        rc, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                      name='my-change', all=False, archive=False)
        self.assertEqual(rc, 1)
        self.assertIn('Requirements', out)

    def test_validate_delta_ok(self):
        d = self.tmp / 'specs' / 'changes' / 'my-change' / 'specs' / 'cap'
        d.mkdir(parents=True)
        (d / 'spec.md').write_text(
            '# cap\n\n## ADDED Requirements\n\n'
            '#### Requirement: R1\n\nSys SHALL x.\n\n'
            '##### Scenario: S1\n\n- GIVEN a\n- WHEN b\n- THEN c\n')
        rc, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                      name='my-change', all=False, archive=False)
        self.assertEqual(rc, 0, out)

    def test_validate_archive_warn_only(self):
        adir = self.tmp / 'specs' / 'changes' / 'archive' / '2026-01-01-old'
        adir.mkdir(parents=True)
        (adir / 'tasks.md').write_text('- [ ] unfinished\n')
        rc, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                      name=None, all=False, archive=True)
        self.assertEqual(rc, 0)
        self.assertIn('WARN', out)


class ArchiveTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()
        self.new_change()

    def _close_tasks(self):
        self.write_tasks('my-change', ['- [x] one', '- [x] two'])

    def test_archive_open_tasks_refuses(self):
        self.write_tasks('my-change', ['- [ ] open'])
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='my-change', force=False)
        self.assertEqual(rc, 1)
        self.assertIn('незакрытые задачи', out)

    def test_archive_force_moves(self):
        self.write_tasks('my-change', ['- [ ] open'])
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='my-change', force=True)
        self.assertEqual(rc, 0, out)
        adir = self.tmp / 'specs' / 'changes' / 'archive'
        self.assertEqual(len(list(adir.iterdir())), 1)
        self.assertFalse((self.tmp / 'specs' / 'changes' / 'my-change').exists())

    def test_archive_notes_hard_refuse(self):
        self._close_tasks()
        (self.tmp / 'specs' / 'changes' / 'my-change' /
         'implementation-notes.md').write_text('x')
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='my-change', force=True)
        self.assertEqual(rc, 1)
        self.assertIn('implementation-notes', out)

    def test_archive_ok(self):
        self._close_tasks()
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='my-change', force=False)
        self.assertEqual(rc, 0, out)
        self.assertIn('Archive Complete', out)

    def test_archive_operator_checklist_refuses(self):
        self._close_tasks()
        p = self.tmp / 'specs' / 'changes' / 'my-change' / 'operator-checklist.md'
        p.write_text('# Оператор\n\n- [ ] smoke\n')
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='my-change', force=False)
        self.assertEqual(rc, 1)
        self.assertIn('operator-checklist', out)

    def test_archive_drops_openspec_yaml(self):
        self._close_tasks()
        (self.tmp / 'specs' / 'changes' / 'my-change' /
         '.openspec.yaml').write_text('legacy: true\n')
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='my-change', force=False)
        self.assertEqual(rc, 0, out)
        self.assertIn('drop .openspec.yaml', out)
        adir = self.tmp / 'specs' / 'changes' / 'archive'
        target = next(adir.iterdir())
        self.assertFalse((target / '.openspec.yaml').exists())


class CleanLegacyTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()
        c1 = self.tmp / 'specs' / 'changes' / 'c1'
        c1.mkdir(parents=True)
        (c1 / '.openspec.yaml').write_text('x\n')
        old = self.tmp / 'specs' / 'changes' / 'archive' / '2025-01-01-old'
        old.mkdir(parents=True)
        (old / '.openspec.yaml').write_text('x\n')

    def test_clean_legacy_dry_run(self):
        rc, out = run(ks.cmd_clean_legacy, root=str(self.tmp), spec_root=None,
                      apply=False)
        self.assertEqual(rc, 0)
        self.assertIn('dry-run', out)
        self.assertIn('2', out)
        self.assertTrue((self.tmp / 'specs' / 'changes' / 'c1' /
                         '.openspec.yaml').is_file())

    def test_clean_legacy_apply(self):
        rc, out = run(ks.cmd_clean_legacy, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0, out)
        self.assertIn('удалено .openspec.yaml ×2', out)
        self.assertEqual(
            list((self.tmp / 'specs' / 'changes').rglob('.openspec.yaml')), [])

    def test_clean_legacy_noop(self):
        run(ks.cmd_clean_legacy, root=str(self.tmp), spec_root=None, apply=True)
        rc, out = run(ks.cmd_clean_legacy, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0)
        self.assertIn('нет', out)

    def test_clean_legacy_via_main_parser(self):
        # регрессия: у clean-legacy не было common(ps) — a.root отсутствовал
        rc, out = run_main(['clean-legacy', '--root', str(self.tmp)],
                           str(self.tmp))
        self.assertEqual(rc, 0, out)
        self.assertIn('dry-run', out)
        rc, out = run_main(['clean-legacy', '--root', str(self.tmp), '--apply'],
                           str(self.tmp))
        self.assertEqual(rc, 0, out)
        self.assertIn('удалено .openspec.yaml ×2', out)


class MigrateTest(TempConsumer):
    def setUp(self):
        super().setUp()
        o = self.tmp / 'openspec'
        (o / 'specs' / 'orders').mkdir(parents=True)
        (o / 'specs' / 'orders' / 'spec.md').write_text('# orders\n')
        (o / 'changes' / 'c1').mkdir(parents=True)
        (o / 'changes' / 'c1' / 'tasks.md').write_text('- [x] done\n')
        (o / 'changes' / 'archive' / '2025-01-01-old').mkdir(parents=True)
        (o / 'README.md').write_text('legacy readme\n')

    def test_migrate_plan_no_apply(self):
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=False)
        self.assertEqual(rc, 0)
        self.assertIn('dry-run', out)
        self.assertTrue((self.tmp / 'openspec' / 'specs' / 'orders').is_dir())

    def test_migrate_apply(self):
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0, out)
        s = self.tmp / 'specs'
        self.assertTrue((s / 'orders' / 'spec.md').is_file())
        self.assertTrue((s / 'changes' / 'c1' / 'tasks.md').is_file())
        self.assertTrue((s / 'changes' / 'archive' / '2025-01-01-old').is_dir())
        self.assertTrue((s / 'README.md').is_file())
        self.assertTrue((s / '.kit-spec.json').is_file())
        shim = self.tmp / 'openspec'
        self.assertTrue((shim / 'specs').exists())
        self.assertTrue((shim / 'specs' / 'orders' / 'spec.md').is_file())
        self.assertTrue((shim / 'changes' / 'c1' / 'tasks.md').is_file())
        self.assertIn('openspec/', (self.tmp / '.gitignore').read_text())

    def test_migrate_removes_openspec_yaml(self):
        (self.tmp / 'openspec' / 'changes' / 'c1' /
         '.openspec.yaml').write_text('x\n')
        (self.tmp / 'openspec' / 'changes' / 'archive' / '2025-01-01-old' /
         '.openspec.yaml').write_text('x\n')
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=False)
        self.assertEqual(rc, 0)
        self.assertIn('rm легаси .openspec.yaml ×2', out)
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0, out)
        self.assertIn('clean-legacy: удалено .openspec.yaml ×2', out)
        self.assertEqual(
            list((self.tmp / 'specs' / 'changes').rglob('.openspec.yaml')), [])

    def test_migrate_collision(self):
        (self.tmp / 'specs').mkdir()
        (self.tmp / 'specs' / 'x.txt').write_text('x')
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 1)
        self.assertIn('коллизия', out)

    def test_migrate_project_md_tolerated(self):
        (self.tmp / 'openspec' / 'project.md').write_text('# ctx\n')
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0, out)
        self.assertIn('project.md не канон', out)
        self.assertTrue((self.tmp / 'specs' / 'project.md').is_file())
        specs = ks.Specs(str(self.tmp / 'specs'), 'new')
        warns = ks.validate_library(specs)
        self.assertFalse([w for w in warns if 'project.md' in w], warns)

    def test_generated_readme_line_length(self):
        for line in ks.GENERATED_README.splitlines():
            self.assertLessEqual(len(line), 80, line)

    def test_migrate_zero_caps_no_empty_specs_shim(self):
        o = self.tmp / 'openspec'
        shutil.rmtree(o / 'specs')
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0, out)
        self.assertFalse((o / 'specs').exists())
        self.assertTrue((o / 'changes' / 'c1' / 'tasks.md').is_file())

    def test_migrate_replaces_old_format_generated_readme(self):
        (self.tmp / 'specs').mkdir()
        (self.tmp / 'specs' / '.kit-spec.json').write_text(
            '{"spec_format": 1}')
        legacy_gen = ('# specs/\n\nСпек-флоу kit: `changes/<id>/` — активные, '
                      '`changes/archive/` — завершённые, `<cap>/spec.md` — '
                      'библиотека. Канон: harness/core/docs/ai/'
                      'spec-workflow.md; инструмент: `python harness/tools/'
                      'kit-spec/kit_spec.py`. Вход — скилл `spec-propose`.\n')
        (self.tmp / 'specs' / 'README.md').write_text(
            legacy_gen, encoding='utf-8')
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0, out)
        self.assertEqual((self.tmp / 'specs' / 'README.md').read_text(),
                         'legacy readme\n')


class NameGuardTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()

    def test_new_archive_reserved(self):
        rc, out = self.new_change('archive')
        self.assertEqual(rc, 1)
        self.assertIn('зарезервировано', out)

    def test_new_traversal(self):
        rc, out = self.new_change('../evil')
        self.assertEqual(rc, 1)

    def test_archive_traversal_force(self):
        (self.tmp / 'specs' / 'other').mkdir()
        rc, out = run(ks.cmd_archive, root=str(self.tmp), spec_root=None,
                      name='../other', force=True)
        self.assertEqual(rc, 1)
        self.assertTrue((self.tmp / 'specs' / 'other').is_dir())
        self.assertFalse((self.tmp / 'specs' / 'changes' / 'archive').exists()
                         and any((self.tmp / 'specs' / 'changes' / 'archive')
                                 .iterdir()))

    def test_new_delta_bad_cap(self):
        rc, out = self.new_change(with_delta=['../x'])
        self.assertEqual(rc, 1)


class MarkerTest(TempConsumer):
    def test_marker_bad_format_value(self):
        (self.tmp / 'specs').mkdir()
        (self.tmp / 'specs' / '.kit-spec.json').write_text('{"spec_format": "abc"}')
        rc, out = run(ks.cmd_list, root=str(self.tmp), spec_root=None, json=False)
        self.assertEqual(rc, 1)
        self.assertIn('spec_format', out)

    def test_marker_newer_format(self):
        (self.tmp / 'specs').mkdir()
        (self.tmp / 'specs' / '.kit-spec.json').write_text('{"spec_format": 99}')
        rc, out = run(ks.cmd_list, root=str(self.tmp), spec_root=None, json=False)
        self.assertEqual(rc, 1)
        self.assertIn('spec_format', out)

    def test_init_selfheal_stamps(self):
        (self.tmp / 'specs' / 'changes' / 'c1').mkdir(parents=True)
        rc, out = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=False)
        self.assertEqual(rc, 0, out)
        self.assertTrue((self.tmp / 'specs' / '.kit-spec.json').is_file())

    def test_init_refuses_with_legacy_content(self):
        (self.tmp / 'openspec' / 'changes' / 'c1').mkdir(parents=True)
        rc, out = run(ks.cmd_init, root=str(self.tmp), spec_root=None, force=False)
        self.assertEqual(rc, 1)
        self.assertIn('migrate-root', out)


class InstructionsTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()
        self.new_change()

    def test_instructions_json_flag(self):
        rc, out = run_main(
            ['instructions', 'proposal', '--change', 'my-change', '--json'],
            self.tmp)
        self.assertEqual(rc, 0, out)
        data = json.loads(out)
        self.assertIn('rules', data)
        self.assertTrue(data['outputPath'].endswith('proposal.md'))

    def test_instructions_bad_change(self):
        rc, out = run(ks.cmd_instructions, root=str(self.tmp), spec_root=None,
                      artifact='proposal', change='../x', cap=None, json=False)
        self.assertEqual(rc, 1)

    def test_scaffold_no_comments(self):
        text = (self.tmp / 'specs' / 'changes' / 'my-change' / 'tasks.md') \
            .read_text(encoding='utf-8')
        self.assertNotIn('<!--', text)


class ValidateStrayTest(TempConsumer):
    def setUp(self):
        super().setUp()
        self.init_specs()
        self.new_change()

    def test_stray_file_warns(self):
        (self.tmp / 'specs' / 'changes' / 'my-change' / 'notes.txt') \
            .write_text('x')
        rc, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                      name='my-change', all=False, archive=False)
        self.assertEqual(rc, 0)
        self.assertIn('посторонний файл', out)

    def test_executor_glob_kit_tolerated(self):
        (self.tmp / 'specs' / 'changes' / 'my-change' /
         'executor-prompt.md').write_text('x')
        _, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                     name='my-change', all=False, archive=False)
        self.assertNotIn('executor-prompt.md', out)

    def test_rules_local_tolerates(self):
        (self.tmp / 'specs' / 'rules.local.json').write_text(json.dumps({
            'tolerated_files': ['review-*.md', 'notes-*.md'],
            'tolerated_dirs': ['probe*']}))
        c = self.tmp / 'specs' / 'changes' / 'my-change'
        (c / 'review-r1.md').write_text('x')
        (c / 'notes-context.md').write_text('x')
        (c / 'probe-x').mkdir()
        _, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                     name='my-change', all=False, archive=False)
        self.assertNotIn('посторонний', out)

    def test_rules_local_bad_json_warns(self):
        (self.tmp / 'specs' / 'rules.local.json').write_text('{bad')
        _, out = run(ks.cmd_validate, root=str(self.tmp), spec_root=None,
                     name='my-change', all=False, archive=False)
        self.assertIn('rules.local.json: битый JSON', out)

    def test_rules_local_self_not_stray_in_library(self):
        (self.tmp / 'specs' / 'rules.local.json').write_text('{}')
        specs = ks.Specs(str(self.tmp / 'specs'), 'new')
        warns = ks.validate_library(specs)
        self.assertFalse([w for w in warns if 'rules.local.json' in w], warns)


class MigratePreFlightTest(MigrateTest):
    def test_no_partial_moves_on_collision(self):
        # цель занята в marker'd specs/ -> отказ ДО первого move
        (self.tmp / 'specs' / 'changes' / 'c1').mkdir(parents=True)
        (self.tmp / 'specs' / '.kit-spec.json').write_text('{"spec_format": 1}')
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 1, out)
        self.assertTrue((self.tmp / 'openspec' / 'changes' / 'c1').is_dir())
        self.assertTrue((self.tmp / 'openspec' / 'specs' / 'orders').is_dir())
        self.assertIn('цель существует', out)

    def test_migrate_idempotent(self):
        rc, _ = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                    apply=True)
        self.assertEqual(rc, 0)
        rc, out = run(ks.cmd_migrate_root, root=str(self.tmp), spec_root=None,
                      apply=True)
        self.assertEqual(rc, 0)
        self.assertIn('нечего', out)


class LegacyReadOnlyTest(TempConsumer):
    def setUp(self):
        super().setUp()
        o = self.tmp / 'openspec'
        (o / 'changes' / 'c1').mkdir(parents=True)
        (o / 'changes' / 'c1' / 'tasks.md').write_text('- [x] a\n- [ ] b\n')
        (o / 'changes' / 'c1' / 'proposal.md').write_text('x\n## Артефакты\n')
        (o / 'changes' / 'c1' / 'design.md').write_text('x\n')
        (o / 'specs').mkdir(parents=True)

    def test_list_legacy(self):
        rc, out = run(ks.cmd_list, root=str(self.tmp), spec_root=None, json=False)
        self.assertEqual(rc, 0)
        self.assertIn('c1', out)
        self.assertIn('1/2', out)

    def test_new_legacy_refuses(self):
        rc, out = self.new_change()
        self.assertEqual(rc, 1)
        self.assertIn('легаси', out)


if __name__ == '__main__':
    unittest.main()
