#!/usr/bin/env python3
"""kit-spec - легковесный spec-workflow kit (propose -> apply -> archive).

Замена openspec CLI: конвенция каталога + scaffold/validate/archive без
host-deps. Запуск от корня потребителя:

    python harness/tools/kit-spec/kit_spec.py <cmd> [--root DIR]

Layout (канон):
    specs/.kit-spec.json          маркер {"spec_format": 1}
    specs/<cap>/spec.md           библиотека слитых спек (capability dirs)
    specs/changes/<id>/           активный change
        proposal.md design.md tasks.md
        operator-checklist.md      (опц.; не в прогрессе, блокирует archive)
        implementation-notes.md    (опц.; жёстко блокирует archive)
        specs/<cap>/spec.md        дельты (зеркалит путь библиотеки)
    specs/changes/archive/YYYY-MM-DD-<id>/

Легаси-корень openspec/ поддерживается read-only для list/status/validate
(layout openspec/specs + openspec/changes/archive) с подсказкой migrate-root.
migrate-root переносит openspec/ -> specs/ и оставляет junction-shim
openspec/{specs,changes}, чтобы старые ссылки работали (shim в .gitignore).

Commands:
  init                      scaffold specs/ (+маркер, README); --force поверх
                            чужого непустого specs/
  migrate-root [--apply]    openspec/ -> specs/ + shim junctions; без --apply
                            только план
  new <id> [--with-delta C] scaffold change из templates/
  instructions <artifact> --change <id>
                            JSON {rules, template, outputPath} для скилла
  list                      активные changes + прогресс чекбоксов (--json)
  status <id>               артефакты, прогресс, дельты, блокеры (--json)
  validate [<id>|--all|--archive]
                            структурные проверки; --archive — WARN-only
  archive <id> [--force]    гейты -> move в changes/archive/YYYY-MM-DD-<id>

Exit codes: 0 ok, 1 FAIL/отказ, 2 usage/internal error.
Stdlib only.
"""
import argparse
import datetime
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE / 'templates'
WIN = sys.platform == 'win32'

SPEC_FORMAT = 1
MARKER = '.kit-spec.json'
RESERVED = {'changes', 'readme.md'}
ARTIFACTS = ('proposal', 'design', 'tasks')
KNOWN_CHANGE_FILES = {a + '.md' for a in ARTIFACTS} | {
    'operator-checklist.md', 'implementation-notes.md',
    '.openspec.yaml'}
# kit-семейства: executor-task.md (задание), executor-prompt.md (контракт)
KNOWN_CHANGE_GLOBS = ('executor-*.md',)
KEBAB_RE = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')
CHECK_RE = re.compile(r'^\s*- \[([ xX])\]', re.M)
REQ_SECTION_RE = re.compile(r'^## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements',
                            re.M)
REQ_RE = re.compile(r'^#### Requirement:', re.M)
SCENARIO_RE = re.compile(r'^##### Scenario:', re.M)
CAS_MARKER = '<!-- code-as-spec: render -->'
COMMENT_RE = re.compile(r'<!--.*?-->', re.S)
GENERATED_README = (
    '# specs/\n'
    '\n'
    'Спек-флоу kit: `changes/<id>/` — активные, `changes/archive/` —\n'
    'завершённые, `<cap>/spec.md` — библиотека. Канон:\n'
    'harness/core/docs/ai/spec-workflow.md; инструмент:\n'
    '`python harness/tools/kit-spec/kit_spec.py`. Вход — скилл\n'
    '`spec-propose`.\n')


def is_generated_readme(text):
    """Совпадение с GENERATED_README с точностью до переносов строк
    (старые версии генерировали одну длинную строку)."""
    return ' '.join(text.split()) == ' '.join(GENERATED_README.split())


def kit_sha():
    """Short sha kit-репозитория (для error-сообщений о формате); None офлайн."""
    try:
        r = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'],
                           cwd=str(HERE.parent.parent), capture_output=True,
                           text=True, timeout=10)
        out = r.stdout.strip()
        return out if r.returncode == 0 and out else None
    except (OSError, subprocess.SubprocessError):
        return None


def strip_comments(text):
    """Убрать <!-- --> инструкционные блоки из scaffolded артефактов."""
    return COMMENT_RE.sub('', text)


def bad_name(name):
    """kebab-case + запрет reserved/traversal; -> описание проблемы | None."""
    if not KEBAB_RE.match(name):
        return f'имя не kebab-case: {name}'
    if name == 'archive':
        return 'имя зарезервировано: archive (каталог архива changes/)'
    return None


# ── spec root ───────────────────────────────────────────────────────

class Specs:
    """Layout-модель: канон 'new' (specs/) и легаси 'legacy' (openspec/)."""

    def __init__(self, root_dir, layout):
        self.dir = Path(root_dir)
        self.layout = layout

    @property
    def changes_dir(self):
        return self.dir / 'changes'

    @property
    def archive_dir(self):
        return self.changes_dir / 'archive'

    @property
    def library_dir(self):
        """Каталог capability-спек: specs/<cap> (new) / openspec/specs/<cap>."""
        return self.dir if self.layout == 'new' else self.dir / 'specs'

    def change_dir(self, name):
        return self.changes_dir / name

    def deltas_dir(self, name):
        return self.change_dir(name) / 'specs'


def read_marker(specs_dir):
    p = Path(specs_dir) / MARKER
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None


def resolve_specs(root, explicit=None):
    """-> (Specs|None, warns, err).

    explicit — путь относительно root или абсолютный (каталог сам становится
    корнем, layout 'new'). Иначе specs/ -> openspec/ (legacy) -> ошибка.
    """
    warns = []
    root = Path(root)
    if explicit:
        d = Path(explicit)
        if not d.is_absolute():
            d = root / d
        if not d.is_dir():
            return None, warns, f'--spec-root не каталог: {d}'
        return Specs(d, 'new'), warns, None

    canon = root / 'specs'
    legacy = root / 'openspec'
    if canon.is_dir():
        m = read_marker(canon)
        foreign = False
        if m is None:
            if (canon / 'changes').is_dir():
                warns.append('specs/ без маркера .kit-spec.json — принят за '
                             'kit-format; зафиксируй: kit_spec.py init')
            elif any(canon.iterdir()):
                foreign = True
                warns.append('specs/ без маркера и без changes/ — похоже '
                             'чужой каталог, пропущен; --spec-root или '
                             'kit_spec.py init --force')
        else:
            try:
                fmt = int(m.get('spec_format', 0) or 0)
            except (TypeError, ValueError):
                return None, warns, (f'{MARKER}: spec_format не int '
                                     f'({m.get("spec_format")!r})')
            if fmt > SPEC_FORMAT:
                sha = kit_sha()
                return None, warns, (f'spec_format {fmt} > supported '
                                     f'{SPEC_FORMAT} — обнови kit'
                                     + (f' (kit sha {sha})' if sha else ''))
        if not foreign:
            if legacy_has_content(legacy):
                warns.append('рядом с specs/ немигрированный openspec/ с '
                             'содержимым — он невидим для команд; '
                             'kit_spec.py migrate-root --apply')
            return Specs(canon, 'new'), warns, None
    if legacy.is_dir():
        warns.append('легаси-корень openspec/ (read-only) — миграция: '
                     'python harness/tools/kit-spec/kit_spec.py migrate-root --apply')
        return Specs(legacy, 'legacy'), warns, None
    return None, warns, ('spec-каталог не найден (ни specs/, ни openspec/). '
                         'Scaffold: kit_spec.py init')


def write_marker(specs_dir):
    (Path(specs_dir) / MARKER).write_text(
        json.dumps({'spec_format': SPEC_FORMAT}, indent=2) + '\n',
        encoding='utf-8')


# ── чекбоксы / файлы ───────────────────────────────────────────────

def checkbox_counts(path):
    """(done, total) по чекбоксам - [ ]/- [x]; (0,0) если файла нет."""
    p = Path(path)
    if not p.is_file():
        return 0, 0
    try:
        text = p.read_text(encoding='utf-8', errors='replace')
    except OSError:
        return 0, 0
    marks = CHECK_RE.findall(text)
    return sum(1 for m in marks if m.lower() == 'x'), len(marks)


def active_changes(specs):
    """Имена активных changes (дети changes/, кроме archive и не-каталогов)."""
    cdir = specs.changes_dir
    if not cdir.is_dir():
        return []
    return sorted(p.name for p in cdir.iterdir()
                  if p.is_dir() and p.name != 'archive' and not p.name.startswith('.'))


def archived_changes(specs):
    adir = specs.archive_dir
    if not adir.is_dir():
        return []
    return sorted(p.name for p in adir.iterdir()
                  if p.is_dir() and not p.name.startswith('.'))


def delta_caps(specs, name):
    ddir = specs.deltas_dir(name)
    if not ddir.is_dir():
        return []
    return sorted(p.name for p in ddir.iterdir()
                  if p.is_dir() and not p.name.startswith('.')
                  and (p / 'spec.md').is_file())


def load_rules():
    return json.loads((TEMPLATES / 'rules.json').read_text(encoding='utf-8'))


def change_report(specs, name):
    """Структурный отчёт по change для status/list/validate."""
    cdir = specs.change_dir(name)
    rep = {'name': name, 'dir': str(cdir), 'exists': cdir.is_dir(),
           'layout': specs.layout,
           'artifacts': {a: (cdir / f'{a}.md').is_file() for a in ARTIFACTS}}
    rep['tasks'] = dict(zip(('done', 'total'),
                           checkbox_counts(cdir / 'tasks.md')))
    rep['deltas'] = delta_caps(specs, name)
    oc = cdir / 'operator-checklist.md'
    rep['operator_checklist'] = {'exists': oc.is_file()}
    if oc.is_file():
        d, t = checkbox_counts(oc)
        rep['operator_checklist']['open'] = t - d
    notes = cdir / 'implementation-notes.md'
    rep['implementation_notes'] = {'exists': notes.is_file()}
    if notes.is_file():
        d, t = checkbox_counts(notes)
        rep['implementation_notes']['open'] = t - d
    rep['legacy_marker'] = (cdir / '.openspec.yaml').is_file()
    return rep


# ── validate ────────────────────────────────────────────────────────

def load_local_rules(specs):
    """specs/rules.local.json — потребительский whitelist посторонних
    файлов/каталогов в changes. -> (rules, warn)."""
    path = specs.dir / 'rules.local.json'
    if not path.is_file():
        return {}, None
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}, 'rules.local.json: битый JSON — игнорируется'
    if not isinstance(data, dict):
        return {}, 'rules.local.json: не объект — игнорируется'
    return data, None


def _globs(name, patterns):
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def validate_change(specs, name):
    """(fails, warns) по правилам design §4."""
    fails, warns = [], []
    cdir = specs.change_dir(name)
    if not KEBAB_RE.match(name):
        fails.append(f'имя change не kebab-case: {name}')
    if not cdir.is_dir():
        fails.append(f'change не найден: {cdir}')
        return fails, warns
    for a in ARTIFACTS:
        if not (cdir / f'{a}.md').is_file():
            fails.append(f'нет {a}.md')
    td, tt = checkbox_counts(cdir / 'tasks.md')
    if (cdir / 'tasks.md').is_file() and tt == 0:
        fails.append('tasks.md без чекбоксов - [ ]')
    if (cdir / '.openspec.yaml').is_file():
        warns.append('легаси-маркер .openspec.yaml — удали: '
                     'kit_spec.py clean-legacy --apply')
    local, w = load_local_rules(specs)
    if w:
        warns.append(w)
    tol_files = local.get('tolerated_files') or []
    tol_dirs = local.get('tolerated_dirs') or []
    for p in sorted(cdir.iterdir()):
        if p.name.startswith('.') and p.name != '.openspec.yaml':
            continue
        if p.is_dir() and p.name == 'specs':
            continue
        if p.is_file():
            if p.name in KNOWN_CHANGE_FILES or \
                    _globs(p.name, KNOWN_CHANGE_GLOBS) or \
                    _globs(p.name, tol_files):
                continue
            warns.append(f'посторонний файл в change: {p.name}')
        elif p.is_dir():
            if _globs(p.name, tol_dirs):
                continue
            warns.append(f'посторонний каталог в change: {p.name}/')
    prop = cdir / 'proposal.md'
    if prop.is_file():
        try:
            if 'Артефакт' not in prop.read_text(encoding='utf-8', errors='replace'):
                warns.append('proposal.md: нет секции «Артефакты»')
        except OSError:
            pass
    for cap in delta_caps(specs, name):
        fails_cap, warns_cap = validate_delta(cdir / 'specs' / cap / 'spec.md', cap)
        fails += fails_cap
        warns += warns_cap
    return fails, warns


def validate_delta(path, cap):
    fails, warns = [], []
    try:
        text = Path(path).read_text(encoding='utf-8', errors='replace')
    except OSError:
        return [f'delta {cap}: не читается {path}'], warns
    sections = list(REQ_SECTION_RE.finditer(text))
    if not sections:
        fails.append(f'delta {cap}: нет секций '
                     '## ADDED/MODIFIED/REMOVED/RENAMED Requirements')
        return fails, warns
    # требования внутри ADDED/MODIFIED: SHALL + Scenario
    pos = [(m.start(), m.group(1)) for m in sections] + [(len(text), '')]
    for i, (start, kind) in enumerate(pos[:-1]):
        body = text[start:pos[i + 1][0]]
        reqs = list(REQ_RE.finditer(body))
        req_pos = [m.start() for m in reqs] + [len(body)]
        for j, m in enumerate(reqs):
            rb = body[m.start():req_pos[j + 1]]
            rname = rb.splitlines()[0].strip()
            if kind in ('ADDED', 'MODIFIED'):
                if 'SHALL' not in rb:
                    fails.append(f'delta {cap}: {rname} — нет SHALL-тела')
                if not SCENARIO_RE.search(rb):
                    fails.append(f'delta {cap}: {rname} — нет ##### Scenario:')
    return fails, warns


def validate_library(specs):
    """WARN по детям library_dir: каждый каталог — capability со spec.md."""
    warns = []
    lib = specs.library_dir
    if not lib.is_dir():
        return warns
    for p in sorted(lib.iterdir()):
        if p.name.startswith('.'):
            continue
        if p.is_file():
            if p.name not in ('README.md', 'project.md', 'rules.local.json'):
                warns.append(f'specs/{p.name}: файл не в capability-каталоге '
                             '(non-capability child)')
            continue
        if not p.is_dir():
            continue
        if p.name.lower() in RESERVED or p.name == 'specs':
            if specs.layout == 'new' and p.name != 'changes':
                warns.append(f'specs/{p.name}: зарезервированное имя')
            continue
        if not (p / 'spec.md').is_file():
            warns.append(f'specs/{p.name}: каталог без spec.md '
                         '(capability или лишнее?)')
    return warns


def print_findings(name, fails, warns):
    for f in fails:
        print(f'FAIL {name}: {f}')
    for w in warns:
        print(f'WARN {name}: {w}')


# ── команды ─────────────────────────────────────────────────────────

def is_reparse(p):
    """Junction/symlink? st_file_attributes reparse-point bit (Win) или
    is_symlink (POSIX)."""
    if p.is_symlink():
        return True
    try:
        return bool(p.lstat().st_file_attributes & 0x400)
    except (AttributeError, OSError):
        return False


def is_shim_child(p):
    """Элемент openspec/, являющийся частью shim: junction (changes) или
    real dir 'specs', чьи дети — только junction на specs/<cap>."""
    if is_reparse(p):
        return True
    if p.name == 'specs' and p.is_dir():
        return all(is_reparse(c) for c in p.iterdir())
    return False


def legacy_has_content(old):
    """openspec/ содержит реальное содержимое (не только shim)."""
    if not old.is_dir():
        return False
    for p in old.iterdir():
        if p.name in ('specs', 'changes') and is_shim_child(p):
            continue
        return True
    return False


def cmd_init(a):
    root = Path(a.root).resolve()
    specs = root / 'specs'
    legacy = root / 'openspec'
    marker = read_marker(specs)
    if marker is not None:
        try:
            if int(marker.get('spec_format', 0) or 0) > SPEC_FORMAT:
                print(f'FAIL: spec_format {marker.get("spec_format")} > '
                      f'supported {SPEC_FORMAT} — обнови kit')
                return 1
        except (TypeError, ValueError):
            print(f'FAIL: {MARKER}: spec_format не int')
            return 1
    if specs.is_dir() and marker is None and any(specs.iterdir()):
        kids = sorted(p for p in specs.iterdir() if not p.name.startswith('.'))
        ours = all(p.name in ('changes', 'README.md') or
                   (p.is_dir() and (p / 'spec.md').is_file()) for p in kids)
        if not ours:
            if not a.force:
                children = ', '.join(p.name for p in kids) or '(только dotfiles)'
                print(f'FAIL: specs/ непустой без маркера ({children}) — '
                      'чужой каталог? --force чтобы создать структуру поверх')
                return 1
            for p in kids:
                print(f'WARN: чужой ребёнок specs/{p.name} — validate будет '
                      'считать каталоги capability')
        else:
            print('specs/ без маркера, но структура kit — ставлю маркер')
    if legacy_has_content(legacy):
        if not a.force:
            print('FAIL: легаси openspec/ с содержимым — init осиротил бы '
                  'его. Сначала: kit_spec.py migrate-root --apply '
                  '(или --force для сознательного параллельного specs/)')
            return 1
        print('WARN: openspec/ с содержимым рядом с specs/ — '
              'дальнейшее поведение легаси-корня: resolve_specs отдаст '
              'приоритет specs/')
    created = []
    for rel in ('changes', 'changes/archive'):
        d = specs / rel
        if not d.is_dir():
            d.mkdir(parents=True)
            created.append(rel + '/')
    readme = specs / 'README.md'
    if not readme.exists():
        readme.write_text(
            '# specs/\n\nСпек-флоу kit: `changes/<id>/` — активные, '
            '`changes/archive/` — завершённые, `<cap>/spec.md` — библиотека. '
            'Канон: harness/core/docs/ai/spec-workflow.md; инструмент: '
            '`python harness/tools/kit-spec/kit_spec.py`. Вход — скилл '
            '`spec-propose`.\n', encoding='utf-8')
        created.append('README.md')
    if marker is None:
        write_marker(specs)
        created.append(MARKER)
    print('OK specs/' + (f' — создано: {", ".join(created)}' if created
                         else ' — уже инициализирован'))
    return 0


def cmd_new(a):
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}')
    if err:
        print(f'FAIL: {err}')
        return 1
    name = a.name
    bad = bad_name(name)
    if bad:
        print(f'FAIL: {bad}')
        return 1
    if specs.layout == 'legacy':
        print('FAIL: легаси-корень openspec/ read-only — сначала migrate-root')
        return 1
    for cap in (a.with_delta or []):
        bad = bad_name(cap)
        if bad:
            print(f'FAIL: --with-delta: {bad}')
            return 1
    cdir = specs.change_dir(name)
    if cdir.exists():
        print(f'FAIL: change уже существует: {cdir}')
        return 1
    rules = load_rules()['artifacts']
    cdir.mkdir(parents=True)
    for art in ARTIFACTS:
        tpl = (TEMPLATES / rules[art]['template']).read_text(encoding='utf-8')
        (cdir / rules[art]['file']).write_text(strip_comments(tpl),
                                             encoding='utf-8')
        print(f'created {art}.md')
    for cap in (a.with_delta or []):
        ddir = cdir / 'specs' / cap
        ddir.mkdir(parents=True)
        tpl = (TEMPLATES / rules['delta']['template']).read_text(encoding='utf-8')
        (ddir / 'spec.md').write_text(strip_comments(tpl), encoding='utf-8')
        print(f'created specs/{cap}/spec.md')
    print(f'OK change {name}: {cdir}')
    print('далее: заполни артефакты — правила через '
          f'kit_spec.py instructions <artifact> --change {name}')
    return 0


def cmd_instructions(a):
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}', file=sys.stderr)
    if err:
        print(f'FAIL: {err}')
        return 1
    bad = bad_name(a.change)
    if bad:
        print(f'FAIL: --change: {bad}')
        return 1
    if a.cap:
        bad = bad_name(a.cap)
        if bad:
            print(f'FAIL: --cap: {bad}')
            return 1
    if specs.layout == 'legacy':
        print('FAIL: легаси-корень openspec/ read-only — сначала migrate-root')
        return 1
    rules = load_rules()['artifacts']
    art = rules.get(a.artifact)
    if not art:
        print(f'FAIL: неизвестный артефакт {a.artifact} '
              f'(есть: {", ".join(sorted(rules))})')
        return 1
    rel = art['file']
    if '<cap>' in rel:
        if not a.cap:
            print('FAIL: delta требует --cap <capability>')
            return 1
        rel = rel.replace('<cap>', a.cap)
    out = {
        'change': a.change,
        'rules': art['rules'],
        'instruction': art['instruction'],
        'template': (TEMPLATES / art['template']).read_text(encoding='utf-8'),
        'outputPath': str(specs.change_dir(a.change) / rel),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


def cmd_list(a):
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}', file=sys.stderr)
    if err:
        print(f'FAIL: {err}')
        return 1
    reps = [change_report(specs, n) for n in active_changes(specs)]
    if a.json:
        print(json.dumps({'layout': specs.layout, 'changes': reps},
                         ensure_ascii=False, indent=2))
        return 0
    if not reps:
        print('нет активных changes')
        return 0
    for r in reps:
        t = r['tasks']
        print(f'{r["name"]}  tasks {t["done"]}/{t["total"]}'
              + ('  [deltas: ' + ', '.join(r['deltas']) + ']' if r['deltas'] else ''))
    return 0


def cmd_status(a):
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}', file=sys.stderr)
    if err:
        print(f'FAIL: {err}')
        return 1
    bad = bad_name(a.name)
    if bad:
        print(f'FAIL: {bad}')
        return 1
    rep = change_report(specs, a.name)
    if a.json:
        print(json.dumps(rep, ensure_ascii=False, indent=2))
        return 0
    if not rep['exists']:
        print(f'FAIL: change не найден: {rep["dir"]}')
        return 1
    t = rep['tasks']
    arts = ', '.join(f'{x}={"+" if rep["artifacts"][x] else "-"}'
                     for x in ARTIFACTS)
    print(f'{rep["name"]}  [{rep["layout"]}]  tasks {t["done"]}/{t["total"]}')
    print(f'  artifacts: {arts}')
    if rep['deltas']:
        print(f'  deltas: {", ".join(rep["deltas"])}')
    oc = rep['operator_checklist']
    if oc['exists']:
        print(f'  operator-checklist: {oc["open"]} открытых')
    if rep['implementation_notes']['exists']:
        open_cb = rep['implementation_notes'].get('open', 0)
        print('  implementation-notes.md: есть (перед archive — review+delete)'
              + (f', открытых чекбоксов: {open_cb}' if open_cb else ''))
    return 0


def cmd_validate(a):
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}')
    if err:
        print(f'FAIL: {err}')
        return 1
    rc = 0
    if a.archive:
        if a.name:
            print('WARN: имя change игнорируется в режиме --archive')
        for n in archived_changes(specs):
            w = []
            cdir = specs.archive_dir / n
            td, tt = checkbox_counts(cdir / 'tasks.md')
            if tt - td:
                w.append(f'открытые задачи в архиве: {tt - td}/{tt}')
            od, ot = checkbox_counts(cdir / 'operator-checklist.md')
            if ot - od:
                w.append(f'открытый operator-checklist в архиве: {ot - od}/{ot}')
            print_findings(f'archive/{n}', [], w)
        return 0
    if a.all:
        names = active_changes(specs)
        lib_warns = validate_library(specs)  # библиотека — даже без changes
        if not names:
            print_findings('library', [], lib_warns)
            print('validate: нет активных changes — OK')
            return 0
    elif a.name:
        names = [a.name]
    else:
        print('FAIL: укажи change, --all или --archive')
        return 1
    for n in names:
        fails, wrns = validate_change(specs, n)
        print_findings(n, fails, wrns)
        if fails:
            rc = 1
    if a.all:
        print_findings('library', [], lib_warns)
    if rc == 0:
        print('validate: OK')
    return rc


def cmd_archive(a):
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}')
    if err:
        print(f'FAIL: {err}')
        return 1
    if specs.layout == 'legacy':
        print('FAIL: легаси-корень openspec/ read-only — сначала migrate-root')
        return 1
    name = a.name
    bad = bad_name(name)
    if bad:
        print(f'FAIL: {bad} (traversal-защита: --force не обходит)')
        return 1
    rep = change_report(specs, name)
    if not rep['exists']:
        print(f'FAIL: change не найден: {rep["dir"]}')
        return 1
    force = a.force
    refusals, overridden = [], []

    fails, wrns = validate_change(specs, name)
    if rep['implementation_notes']['exists']:
        refusals.append('implementation-notes.md существует — review и delete '
                        '(не архивируется; --force не обходит)')
    t = rep['tasks']
    if t['total'] - t['done']:
        (overridden if force else refusals).append(
            f'незакрытые задачи: {t["total"] - t["done"]}/{t["total"]}')
    oc = rep['operator_checklist']
    if oc.get('open'):
        (overridden if force else refusals).append(
            f'незакрытый operator-checklist: {oc["open"]} пунктов')
    if fails:
        (overridden if force else refusals).append(
            f'validate FAIL: {len(fails)} ({"; ".join(fails[:3])})')
    today = datetime.date.today().isoformat()
    target = specs.archive_dir / f'{today}-{name}'
    if target.exists():
        refusals.append(f'цель архива существует: {target}')
    if refusals:
        for r in refusals:
            print(f'FAIL: {r}')
        print('archive отклонён' + (' (--force для гейтов)' if not force else ''))
        return 1
    for r in overridden:
        print(f'WARN override: {r}')
    for w in wrns:
        print(f'WARN: {w}')
    # напоминание про sync дельт
    for cap in rep['deltas']:
        if not (specs.library_dir / cap / 'spec.md').is_file():
            print(f'WARN: дельта {cap} — в библиотеке specs/{cap}/spec.md нет; '
                  'sync (spec-sync) до archive?')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(specs.change_dir(name)), str(target))
    for f in target.rglob('.openspec.yaml'):
        f.unlink()
        print(f'drop {f.relative_to(target)} (легаси-артефакт openspec CLI)')
    print('## Archive Complete')
    print(f'**Change:** {name}')
    print(f'**Archived to:** {target}')
    print(f'**Specs:** дельт {len(rep["deltas"])} (merge — скилл spec-sync, '
          'если не выполнен)')
    if overridden:
        print(f'**Warnings:** {len(overridden)} override(s)')
    return 0


# ── migrate-root ───────────────────────────────────────────────────

def make_dir_junction(target, link):
    target, link = Path(target), Path(link)
    if WIN:
        r = subprocess.run(['cmd', '/c', 'mklink', '/J',
                            str(link), str(target)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise OSError(f'mklink /J failed: {r.stdout.strip()} '
                          f'{r.stderr.strip()}')
    else:
        os.symlink(str(target), str(link))
    try:
        if link.resolve() != target.resolve():
            raise OSError(f'junction {link} -> {link.resolve()} '
                          f'(ожидали {target}) — удалён')
    except OSError as e:
        try:
            link.rmdir()
        except OSError:
            pass
        raise e


def plan_migrate(root):
    """-> (moves, loose, errs): moves=[(src,dst)], loose=[(src,dst)].

    Все коллизии/ошибки собираются ДО любого move: --apply отказывает
    целиком, а не после частичной миграции."""
    moves, loose, errs = [], [], []
    old = root / 'openspec'
    new = root / 'specs'
    if not old.is_dir():
        errs.append('openspec/ не найден')
        return moves, loose, errs
    if not legacy_has_content(old):
        return moves, loose, errs  # пустой или только shim — нечего мигрировать
    if new.exists():
        m = read_marker(new)
        if m is None and any(new.iterdir()):
            errs.append('specs/ непустой без маркера — коллизия, разбор вручную')
            return moves, loose, errs
    o_specs = old / 'specs'
    o_changes = old / 'changes'
    if o_specs.is_dir() and not is_reparse(o_specs):
        for p in sorted(o_specs.iterdir()):
            if p.is_dir() and not p.name.startswith('.'):
                moves.append((p, new / p.name))
            elif p.is_file():
                loose.append((p, new / p.name))
    if o_changes.is_dir() and not is_reparse(o_changes):
        for p in sorted(o_changes.iterdir()):
            if p.name == 'archive':
                if not p.is_dir():
                    errs.append('openspec/changes/archive не каталог — '
                                'типовая коллизия, разбор вручную')
                    continue
                for q in sorted(p.iterdir()):
                    if q.is_dir():
                        moves.append((q, new / 'changes' / 'archive' / q.name))
                    elif q.is_file():
                        loose.append((q, new / 'changes' / 'archive' / q.name))
            elif p.is_dir() and not p.name.startswith('.'):
                moves.append((p, new / 'changes' / p.name))
            elif p.is_file():
                loose.append((p, new / 'changes' / p.name))
    for p in sorted(old.iterdir()):
        if p in (o_specs, o_changes) or p.name.startswith('.'):
            continue
        if is_reparse(p):
            continue  # остатки shim-junction
        if p.is_file():
            loose.append((p, new / p.name))
        elif p.is_dir():
            errs.append(f'нестандартный каталог в openspec/: {p.name} — '
                        'ручной разбор')
    seen = {}
    for s, d in moves + loose:
        if str(d) in seen:
            errs.append(f'коллизия имён: {s.relative_to(root)} и '
                        f'{seen[str(d)].relative_to(root)} -> '
                        f'{d.relative_to(root)}')
            continue
        seen[str(d)] = s
        same = False
        try:
            same = d.exists() and d.samefile(s)
        except OSError:
            pass
        if d.exists() and not same:
            # перенесённый README имеет приоритет над сгенерированным
            if d.name == 'README.md' and d.is_file():
                try:
                    if is_generated_readme(d.read_text(
                            encoding='utf-8', errors='replace')):
                        continue  # перезапишем сгенерированный перенесённым
                except OSError:
                    pass
            errs.append(f'цель существует: {d.relative_to(root)} '
                        f'(из {s.relative_to(root)}) — не перезаписываю')
    return moves, loose, errs


def cmd_migrate_root(a):
    root = Path(a.root).resolve()
    old, new = root / 'openspec', root / 'specs'
    if old.is_dir() and not legacy_has_content(old):
        print('migrate-root: openspec/ уже shim или пуст — нечего мигрировать')
        return 0
    moves, loose, errs = plan_migrate(root)
    if errs:
        for e in errs:
            print(f'FAIL: {e}')
        return 1
    if not moves and not loose:
        print('migrate-root: openspec/ без мигрируемого содержимого '
              '(только служебное)')
        return 0
    legacy_files = sorted((old / 'changes').rglob('.openspec.yaml')) \
        if (old / 'changes').is_dir() else []
    print('план migrate-root:')
    for s, d in moves:
        print(f'  move {s.relative_to(root)} -> {d.relative_to(root)}')
    for s, d in loose:
        print(f'  move (loose) {s.relative_to(root)} -> {d.relative_to(root)}')
        if s.name == 'project.md':
            print('    NOTE: project.md не канон spec-флоу — перенесён в '
                  'specs/ для сохранности; при желании перемести в docs/')
        elif s.name == 'config.yaml':
            print('    NOTE: config.yaml — конфиг openspec CLI; если там '
                  'проектные правила — перенеси в docs/ai/, сам файл не канон')
    if legacy_files:
        print(f'  rm легаси .openspec.yaml ×{len(legacy_files)} в changes/ '
              '(clean-legacy)')
    print('  shim openspec/changes -> specs/changes; '
          'openspec/specs/<cap> -> specs/<cap> (мигрированные)')
    print('  .gitignore += openspec/; маркер specs/.kit-spec.json')
    if not a.apply:
        print('dry-run: --apply для выполнения')
        return 0
    caps = [s.name for s, d in moves
            if s.parent == old / 'specs' and s.is_dir()]
    for d in (new, new / 'changes', new / 'changes' / 'archive'):
        d.mkdir(parents=True, exist_ok=True)
    write_marker(new)  # маркер до moves: specs/ наш даже при сбое дальше
    for s, d in moves + loose:
        try:
            if d.is_file() and d.name == 'README.md':
                d.unlink()  # приоритет перенесённому (preflight одобрил)
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(s), str(d))
        except OSError as e:
            print(f'FAIL: move {s.relative_to(root)} -> '
                  f'{d.relative_to(root)}: {e}')
            print('частичная миграция: перенесённое уже в specs/, остаток в '
                  'openspec/ — разбор вручную, затем повтори migrate-root')
            return 1
        print(f'moved {s.relative_to(root)} -> {d.relative_to(root)}')
    for f in (new / 'changes').rglob('.openspec.yaml'):
        f.unlink()
    if legacy_files:
        print(f'clean-legacy: удалено .openspec.yaml ×{len(legacy_files)}')
    # опустевшие openspec/{changes/archive,changes,specs} убрать до shim
    for rel in ('changes/archive', 'changes', 'specs'):
        d = old / rel
        if d.is_dir() and not is_reparse(d) and not any(d.iterdir()):
            d.rmdir()
    # openspec/ должен опустеть до shim (junction-остатки — уже готовый shim)
    leftover = [p for p in old.iterdir() if not is_reparse(p)]
    if leftover:
        print('FAIL: openspec/ не пуст после moves: '
              + ', '.join(p.name for p in leftover))
        print('частичная миграция: вручную перенеси остаток в specs/ '
              'и удали openspec/, затем создай shim сам или повтори '
              'migrate-root после разбора')
        return 1
    if not any(old.iterdir()):
        old.rmdir()
        old.mkdir()
        try:
            # openspec/specs — real dir + per-cap junctions: старые ссылки
            # openspec/specs/<cap> работают, specs/changes не торчит наружу
            if caps:
                (old / 'specs').mkdir()
                for cap in caps:
                    make_dir_junction(new / cap, old / 'specs' / cap)
            make_dir_junction(new / 'changes', old / 'changes')
        except OSError as e:
            print(f'FAIL: shim не создан ({e}). Содержимое уже в specs/ — '
                  'вручную: mklink /J openspec\\changes specs\\changes и '
                  'junction на каждый specs\\<cap> (или symlink на POSIX)')
            return 1
        if caps:
            print('shim: openspec/changes -> specs/changes; '
                  'openspec/specs/<cap> -> specs/<cap> для мигрированных '
                  'caps')
            print('  (capability, созданные позже, в openspec/specs/ не '
                  'появятся — shim точечный, только для мигрированных)')
        else:
            print('shim: openspec/changes -> specs/changes '
                  '(capability не было — openspec/specs не создан)')
    else:
        print('shim openspec/{specs,changes} уже существует — оставлен')
    readme = new / 'README.md'
    if not readme.exists():
        readme.write_text(GENERATED_README, encoding='utf-8')
    gi = root / '.gitignore'
    entry = 'openspec/'
    text = gi.read_text(encoding='utf-8') if gi.is_file() else ''
    if entry not in [l.strip() for l in text.splitlines()]:
        with gi.open('a', encoding='utf-8') as f:
            if text and not text.endswith('\n'):
                f.write('\n')
            f.write('\n# kit-spec: junction shim (не трекать)\nopenspec/\n')
        print('.gitignore += openspec/')
    tracked = ''
    try:
        r = subprocess.run(['git', 'ls-files', 'openspec'], cwd=str(root),
                           capture_output=True, text=True, timeout=15)
        if r.returncode == 0:
            tracked = r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    if tracked:
        print('WARN: openspec/ есть в git-индексе — перед коммитом: '
              'git rm -r --cached openspec  (иначе junction-содержимое '
              'может попасть в индекс как blobs)')
    print('OK migrate-root. Коммит: moves видны как delete+add '
          '(rename detection по схожести); openspec/ — gitignored shim.')
    return 0


# ── clean-legacy ───────────────────────────────────────────────────

def cmd_clean_legacy(a):
    """Удаляет мёртвые артефакты openspec CLI (.openspec.yaml) из changes/
    (active + archive). Dry-run по умолчанию, --apply для удаления."""
    root = Path(a.root).resolve()
    specs, warns, err = resolve_specs(root, a.spec_root)
    for w in warns:
        print(f'WARN: {w}')
    if err:
        print(f'FAIL: {err}')
        return 1
    found = sorted(specs.changes_dir.rglob('.openspec.yaml')) \
        if specs.changes_dir.is_dir() else []
    if not found:
        print('clean-legacy: легаси-артефактов (.openspec.yaml) нет')
        return 0
    for f in found:
        print(f'  rm {f.relative_to(specs.changes_dir)}')
    if not a.apply:
        print(f'dry-run: {len(found)} файл(ов); --apply для удаления')
        return 0
    for f in found:
        f.unlink()
    print(f'clean-legacy: удалено .openspec.yaml ×{len(found)}')
    return 0


# ── main ────────────────────────────────────────────────────────────

def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8')
        except (AttributeError, OSError):
            pass
    p = argparse.ArgumentParser(prog='kit-spec',
                                description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    def common(ps):
        ps.add_argument('--root', default='.')
        ps.add_argument('--spec-root', default=None)

    ps = sub.add_parser('init', help='scaffold specs/')
    common(ps)
    ps.add_argument('--force', action='store_true')
    ps.set_defaults(fn=cmd_init)

    ps = sub.add_parser('migrate-root', help='openspec/ -> specs/ + shim')
    common(ps)
    ps.add_argument('--apply', action='store_true')
    ps.set_defaults(fn=cmd_migrate_root)

    ps = sub.add_parser('new', help='scaffold change')
    common(ps)
    ps.add_argument('name')
    ps.add_argument('--with-delta', action='append')
    ps.set_defaults(fn=cmd_new)

    ps = sub.add_parser('instructions', help='rules+template артефакта (JSON)')
    common(ps)
    ps.add_argument('artifact', choices=['proposal', 'design', 'tasks', 'delta'])
    ps.add_argument('--change', required=True)
    ps.add_argument('--cap', default=None)
    ps.add_argument('--json', action='store_true',
                    help='no-op: вывод всегда JSON (совместимость)')
    ps.set_defaults(fn=cmd_instructions)

    ps = sub.add_parser('list', help='активные changes + прогресс')
    common(ps)
    ps.add_argument('--json', action='store_true')
    ps.set_defaults(fn=cmd_list)

    ps = sub.add_parser('status', help='статус change')
    common(ps)
    ps.add_argument('name')
    ps.add_argument('--json', action='store_true')
    ps.set_defaults(fn=cmd_status)

    ps = sub.add_parser('validate', help='структурные проверки')
    common(ps)
    ps.add_argument('name', nargs='?')
    ps.add_argument('--all', action='store_true')
    ps.add_argument('--archive', action='store_true')
    ps.set_defaults(fn=cmd_validate)

    ps = sub.add_parser('clean-legacy',
                        help='удалить .openspec.yaml из changes/ (dry-run)')
    common(ps)
    ps.add_argument('--apply', action='store_true')
    ps.set_defaults(fn=cmd_clean_legacy)

    ps = sub.add_parser('archive', help='гейты + move в archive/')
    common(ps)
    ps.add_argument('name')
    ps.add_argument('--force', action='store_true')
    ps.set_defaults(fn=cmd_archive)

    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except Exception as e:
        print(f'kit-spec: internal error: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
