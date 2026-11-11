#!/usr/bin/env python3
"""kit-layout - declarative layout engine (idea: teamai ResourceHandler/tool-paths table).

One engine replaces the link-*.sh/.ps1 script pairs. The table is
layout.json (next to this file); paths are consumer-relative, "harness/"
prefix resolves via --harness-rel.

Resource kinds:
  child-dirs   link each child dir  of source into target/ (skills, tools)
  child-files  link each child file of source into target/ (rules, commands)
  alias        link target -> source dir itself (.agents/skills, .pi/*)

Resource fields:
  include         allow-list of child names (absent = all children)
  local_manifest  consumer file with names to skip (consumer-owned)
  stacks          list of stack ids; resource is effective only when the
                  consumer selected one of them in .kit.json (absent = core)

Convention synthesis (kit-stacks-hardening): every stacks/<s>/stack.json
yields auto:<res> resources for canonical dirs —
  cursor/skills -> .cursor/skills (child-dirs), cursor/rules ->
  .cursor/rules (child-files), cursor/commands -> .cursor/commands
  (child-files), tools -> tools (child-dirs); each carries stacks:[<s>]
  and the same local_manifest contract (.kit/local-overlay.txt for
  overlay-*, .kit/local-tools.txt for kit-tools-<s>). Synthesis key:
  dir on disk (untracked counts) or in git HEAD (a missing checkout dir
  keeps the resource -> missing_source FAIL, sparse protection); absent
  in both -> skipped silently, a stack need not ship all four dirs.
  Synthesized resources sit between stack-explicit and alias resources
  (canonical order core -> stacks -> aliases); an explicit resource with
  identical kind+source+target is a hard duplicate ERROR.
Service names (.* and __pycache__) are never published, explicit or
synthesized.
layout_version (optional, default 1, int >= 1) in .kit.json, core.json,
stack.json — engine<->kit mechanism compatibility; a value above
SUPPORTED_LAYOUT_VERSION is an ERROR naming the kit sha. Three version
axes: .kit.json "version" = consumer file schema, layout_version =
engine mechanism, layout.json "version" = resource manifest schema.

Consumer config .kit.json (repo root):
  {"version": 1, "stacks": ["1c"], "source_root": "conf/",
   "paths": {...}, "sparse": false}
  Missing file  -> stacks [] (core-only) + WARN.
  KIT_LEGACY=1  -> stacks ["*"] (all stacks) + WARN; env beats file.
  print-config --json is the ONLY parser scripts may use; besides the
  resolved config it emits `deps` ({'core': [...], 'stacks': {<s>: [...]}}
  from core.json + stack.json — the dep-id registry init-kit-deps
  dispatches) and `resources` (resource ids, synthesized ones auto:-prefixed).

State files live in .kit/ (tracked dir): fallback.txt + lock are
engine-owned (gitignored via the managed block); local-*.txt exclusion
lists are consumer-owned (tracked). Legacy locations
tools/cc-1c-skills-sync/{kit-fallback,local-*}.txt are still read when
the new files are absent.

Orphan-sweep (stateless, no applied.txt): apply order is
  read old fallback manifest -> lay out effective resources -> link ->
  sweep -> atomic manifest write (tmp + os.replace) -> managed .gitignore.
A reparse point in a managed target whose readlink string points inside
ctx.resolve('harness') but whose name is neither expected by the
effective resources nor listed in local-*.txt is an orphan and is
removed; foreign-ns targets get WARN unmanaged and are kept. Old-manifest
fallbacks the run did not re-record: byte-identical (sha match) ->
removed, locally edited -> WARN + record kept in the new manifest.

Behavior (same vocabulary as the legacy scripts):
  LINK / JUNCTION / FILELINK (symlink) / HARDLINK / COPY fallback when no
  symlink privilege (file symlink needs Developer Mode / SeCreateSymbolicLink;
  a hardlink needs neither, only the same volume), SKIP LOCAL, REPLACE COPY,
  REFRESH/KEEP stale fallback, PRUNE (tombstones: link into source whose child
  vanished upstream), WOULD * in --dry-run.
  Idempotent: a link already pointing at the right target prints OK, no churn.

Fallback lifecycle (consumer consequences of "no symlink privilege"):
  * every HARDLINK/COPY is recorded in tools/cc-1c-skills-sync/kit-fallback.txt
    (consumer-rel path, source path, sha256) so tombstones can prune it even
    though it is not a reparse point;
  * a fallback whose content was edited by the consumer is NOT overwritten
    (KEEP LOCAL EDITS) - bootstrap no longer silently discards local changes;
  * a managed `.gitignore` block is regenerated so fallbacks do not show up as
    untracked kit paths in `git status`;
  * on Windows git follows directory junctions (core.symlinks=false), so kit
    content gets tracked as consumer blobs; apply untracks those paths from the
    index (`git rm --cached`, worktree untouched), verify warns about them.

Commands:
  plan    [consumer-root]   dry-run of apply, exit 0 (--all-stacks: no filter)
  apply   [consumer-root]   takes .kit/lock for the mutation window
  verify  [consumer-root]   all expected links exist and are links; exit 1 on FAIL
                            (file copy-fallback = WARN, dir copies = FAIL)
  tracked [consumer-root]   list kit link paths tracked in the consumer index;
                            exit 1 if any (junction traversal on Windows)
  print-config [consumer-root]  resolved .kit.json view (--json for scripts)
  resolve-source <consumer-rel-path> [--root .]
                            reverse layout lookup for promote (kit source path)

Namespace safety:
  A link whose target is outside the consumer root belongs to another
  OS/namespace (typically a Windows checkout seen from a Linux sandbox/WSL).
  plan/apply refuse to touch such a tree (exit 2) instead of silently
  skipping every action and reporting "nothing to do"; verify reports
  FOREIGN-NS and FAILs when nothing local can be checked. plan --strict
  also exits 1 on foreign-ns.

Stdlib only. Windows: dirs -> mklink /J junctions (no admin needed),
files -> symlink with copy fallback. Junction removal via os.rmdir
(never recurses into the target).
"""
import argparse
import filecmp
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

WIN = sys.platform == 'win32'
REPARSE_ATTR = 0x400  # FILE_ATTRIBUTE_REPARSE_POINT
KIT_CONFIG_NAME = '.kit.json'
KIT_STATE_DIR = '.kit'
FALLBACK_MANIFEST_REL = KIT_STATE_DIR + '/fallback.txt'
LOCK_REL = KIT_STATE_DIR + '/lock'
LEGACY_STATE_DIR = 'tools/cc-1c-skills-sync'
LEGACY_MANIFEST_REL = LEGACY_STATE_DIR + '/kit-fallback.txt'
DEFAULT_SOURCE_ROOT = 'conf/'
GITIGNORE_BEGIN = '# >>> kit-managed: begin (bootstrap-kit) >>>'
GITIGNORE_END = '# <<< kit-managed: end <<<'
_FILE_SYMLINK_OK = None  # cached result of file_symlink_available()
SUPPORTED_LAYOUT_VERSION = 1
# Canonical stack dirs -> convention-synthesized resources:
# (id_prefix, source_rel, kind, target, local_manifest).
CANON_STACK_RESOURCES = (
    ('overlay-skills', 'cursor/skills', 'child-dirs',
     '.cursor/skills', KIT_STATE_DIR + '/local-overlay.txt'),
    ('overlay-rules', 'cursor/rules', 'child-files',
     '.cursor/rules', KIT_STATE_DIR + '/local-overlay.txt'),
    ('overlay-commands', 'cursor/commands', 'child-files',
     '.cursor/commands', KIT_STATE_DIR + '/local-overlay.txt'),
    ('kit-tools', 'tools', 'child-dirs',
     'tools', KIT_STATE_DIR + '/local-tools.txt'),
)


def is_wsl():
    """Linux userland under Windows (WSL)."""
    if not sys.platform.startswith('linux'):
        return False
    if os.environ.get('WSL_DISTRO_NAME'):
        return True
    try:
        with open('/proc/version', encoding='utf-8', errors='replace') as f:
            return 'microsoft' in f.read().lower()
    except OSError:
        return False


def wsl_windows_path(root):
    """WSL path on a Windows drive: /mnt/c/... (links would be visible only
    inside WSL and broken for Windows-side tools)."""
    s = str(root)
    return bool(re.match(r'^/mnt/[A-Za-z](/|$)', s))


def is_sandbox_namespace(root):
    """Docker/sandbox marker: /.dockerenv with the consumer mounted at
    /workspace (tools/sandbox/run.sh). Only sharpens the message; the actual
    signal is a link whose target is outside the consumer root."""
    try:
        return os.path.exists('/.dockerenv') and str(root) in ('/workspace', '/')
    except OSError:
        return False


FOREIGN_NS_HINT = (
    'Foreign namespace: these links were created by another OS/namespace\n'
    '(e.g. a Windows checkout seen from a Linux sandbox/WSL container).\n'
    'Run kit-layout in the namespace that created the layout: host Git Bash\n'
    '(bash harness/scripts/bootstrap-kit.sh .) or PowerShell\n'
    '(harness/scripts/bootstrap-kit.ps1), not through tools/sandbox/run.sh.'
)


# ── platform primitives ─────────────────────────────────────────────

def is_link(path):
    """Symlink or (on Windows) any reparse point (junction included)."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if WIN:
        return bool(getattr(st, 'st_file_attributes', 0) & REPARSE_ATTR)
    return os.path.islink(path)


def read_link(path):
    try:
        raw = os.readlink(path)
    except OSError:
        return None
    # Junction targets come back with a namespace prefix - \\?\ for
    # mklink-created ones, Global\ (NT object manager) or \??\ for those
    # written by MSYS/cygwin tooling. Strip all spellings so comparisons
    # with normally-resolved paths work.
    if WIN:
        for prefix in ('\\\\?\\Global\\', '\\\\?\\', '\\??\\', 'Global\\'):
            if raw.startswith(prefix):
                raw = raw[len(prefix):]
                break
    return raw


def make_dir_link(target, link):
    if WIN:
        r = subprocess.run(['cmd', '/c', 'mklink', '/J', str(link), str(target)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise OSError(f'mklink /J failed: {r.stdout.strip()} {r.stderr.strip()}')
    else:
        os.symlink(str(target), str(link))


def file_symlink_available():
    """Whether a file symlink can be created here (Windows Developer Mode /
    SeCreateSymbolicLinkPrivilege). Probes the system temp dir, never the
    consumer tree; the result is cached for the process. Privilege can appear
    mid-life (Developer Mode turned on), so apply uses it to upgrade existing
    hardlink/copy fallbacks to symlinks.
    """
    global _FILE_SYMLINK_OK
    if _FILE_SYMLINK_OK is None:
        import tempfile
        d = tempfile.mkdtemp(prefix='kit-symprobe-')
        target = os.path.join(d, 'target')
        linkname = os.path.join(d, 'link')
        try:
            with open(target, 'w', encoding='utf-8') as f:
                f.write('probe')
            try:
                os.symlink(target, linkname)
                _FILE_SYMLINK_OK = True
            except OSError:
                _FILE_SYMLINK_OK = False
        finally:
            shutil.rmtree(d, ignore_errors=True)
    return _FILE_SYMLINK_OK


def make_file_link(target, link):
    """Symlink, then hardlink (no privilege, same volume), then copy.

    Returns 'FILELINK' | 'HARDLINK' | 'COPY'. A hardlink keeps consumer and
    kit file on the same inode, so it never silently goes stale (a copy does);
    the last-resort copy is kept for cross-volume layouts.
    """
    try:
        os.symlink(str(target), str(link))
        return 'FILELINK'
    except OSError:
        pass
    try:
        os.link(str(target), str(link))
        return 'HARDLINK'
    except OSError:
        if not WIN:
            raise
        shutil.copy2(str(target), str(link))
        return 'COPY'


def hash_file(path):
    """sha256 of a file (used to detect drift / safely prune fallbacks)."""
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def file_equal(a, b):
    try:
        return filecmp.cmp(str(a), str(b), shallow=False)
    except OSError:
        return False


def rel_posix(path, root):
    try:
        return os.path.relpath(str(path), str(root)).replace(os.sep, '/')
    except ValueError:
        return str(path).replace(os.sep, '/')


def service_name(name):
    """.* and __pycache__ children are never published (all resources)."""
    return name.startswith('.') or name == '__pycache__'


def is_within(path, root):
    """True if path is inside root (lexical, case-insensitive on Windows)."""
    try:
        common = os.path.commonpath([str(path), str(root)])
        return os.path.normcase(common) == os.path.normcase(str(root))
    except (ValueError, OSError):
        return False


def is_within_resolved(path, root):
    """True if the realpath of path lies inside the realpath of root.

    A consumer root reached through a symlink (agent slot: /work ->
    /srv/agent-worktrees/agent-N) makes a lexical comparison flag every link
    as foreign, because the links store the symlink spelling while the engine
    resolves the root. Compare both sides after resolving symlinks; the target
    need not exist (Path.resolve is non-strict).
    """
    try:
        path = Path(path).resolve()
        root = Path(root).resolve()
    except (OSError, RuntimeError):
        pass
    return is_within(path, root)


def git_run(root, *args):
    """Run git in the consumer root; never raises (no git -> rc 127)."""
    try:
        r = subprocess.run(['git', '-C', str(root), *args],
                           capture_output=True, text=True)
        return r.returncode, r.stdout, r.stderr
    except OSError:
        return 127, '', 'git not found'


def tracked_under(root, rels):
    """Subset of rels that the consumer's git index tracks.

    Only meaningful for a repo root that is exactly the consumer root. On
    Windows kit dirs are junctions; git (core.symlinks=false) follows the
    reparse point and records kit content as ordinary blobs. Such paths must
    be untracked, otherwise a fresh clone gets stale kit copies, not links.
    """
    rels = [r.replace('\\', '/').rstrip('/') for r in rels if r]
    if not rels:
        return []
    rc, out, _ = git_run(root, 'rev-parse', '--is-inside-work-tree')
    if rc != 0 or out.strip() != 'true':
        return []
    rc, top, _ = git_run(root, 'rev-parse', '--show-toplevel')
    if rc != 0:
        return []
    if os.path.normcase(str(Path(top.strip()).resolve())) != os.path.normcase(str(root)):
        return []
    tracked = set()
    for i in range(0, len(rels), 100):
        rc, out, _ = git_run(root, 'ls-files', '-z', '--', *rels[i:i + 100])
        if rc != 0:
            return []
        tracked.update(p for p in out.split('\0') if p)
    return [rel for rel in rels
            if any(t == rel or t.startswith(rel + '/') for t in tracked)]


def remove_link_or_tree(path):
    """Reparse points are removed as links (os.rmdir/os.remove never recurse
    into the junction target); plain copies are removed as trees."""
    if is_link(path):
        if os.path.isdir(path):
            os.rmdir(path)
        else:
            os.remove(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    else:
        os.remove(path)


# ── layout ──────────────────────────────────────────────────────────

class Ctx:
    def __init__(self, root, harness_rel, dry_run=False, gitignore=True,
                 manifest_rel=FALLBACK_MANIFEST_REL, quiet=False, untrack=True,
                 upgrade_fallbacks=False):
        self.root = Path(root).resolve()
        self.harness_rel = harness_rel
        self.dry_run = dry_run
        self.gitignore = gitignore
        self.quiet = quiet
        self.untrack = untrack
        self.upgrade_fallbacks = upgrade_fallbacks
        self.actions = []   # (level, message); level: ACT/WARN/FAIL/OK
        self.pending = 0    # would-be mutations in plan mode
        self.managed = set()      # consumer-rel paths owned by the kit
        self.fallback = {}        # rel -> {'source', 'sha'}
        self.old_fallback = {}    # rel -> {'source', 'sha'} (previous run)
        self.foreign = []         # [(rel, raw_target)] links outside root
        self.inside = 0           # links pointing inside root
        self._foreign_seen = set()
        self._inside_seen = set()
        self.manifest_rel = manifest_rel
        self.manifest_path = self.root / manifest_rel
        self.missing_source = False  # effective resource with absent source

    def classify_link(self, link):
        """('inside'|'foreign'|None, raw_target) for a reparse point."""
        raw = read_link(link)
        if raw is None:
            return None, None
        target = Path(raw)
        if not target.is_absolute():
            target = link.parent / target
        return ('inside' if is_within_resolved(target, self.root) else 'foreign'), raw

    def note_ns(self, rel, link):
        """Record link namespace (deduped) for the final report."""
        kind, raw = self.classify_link(link)
        key = rel.replace('\\', '/')
        if kind == 'inside':
            if key not in self._inside_seen:
                self._inside_seen.add(key)
                self.inside += 1
        elif kind == 'foreign':
            if key not in self._foreign_seen:
                self._foreign_seen.add(key)
                self.foreign.append((key, raw))
        return kind, raw

    def say(self, level, msg):
        self.actions.append((level, msg))
        if not self.quiet:
            print(msg)

    def resolve(self, rel):
        if rel == 'harness':
            rel = self.harness_rel
        elif rel.startswith('harness/'):
            rel = self.harness_rel + '/' + rel[len('harness/'):]
        return self.root / rel

    def note_managed(self, rel):
        if rel:
            self.managed.add(rel.replace('\\', '/'))

    def note_fallback(self, rel, source_rel, sha):
        self.fallback[rel.replace('\\', '/')] = {
            'source': source_rel.replace('\\', '/'),
            'sha': sha,
        }

    def act(self, verb, fn):
        """Run fn or print WOULD verb in dry-run."""
        if self.dry_run:
            self.pending += 1
            self.say('ACT', f'WOULD {verb}')
            return None
        result = fn()
        self.say('ACT', verb)
        return result


# ── consumer config (.kit.json) ───────────────────────────────────

KNOWN_KIT_KEYS = {'version', 'stacks', 'source_root', 'paths', 'sparse',
                  'options', 'layout_version'}


def load_kit_config(root):
    """Read <root>/.kit.json. Never raises; returns a dict:
    {version, stacks, source_root, paths, sparse, file, warn, raw}.
    raw is the parsed JSON (None when the file is absent/broken) -
    validate_kit_config() decides whether raw is usable.
    """
    cfg = {'version': 1, 'stacks': [], 'source_root': None, 'paths': {},
           'sparse': False, 'file': None, 'warn': [], 'raw': None,
           'broken': False}
    p = Path(root) / KIT_CONFIG_NAME
    if p.is_file():
        cfg['file'] = str(p)
        try:
            cfg['raw'] = json.loads(p.read_text(encoding='utf-8'))
        except (OSError, ValueError) as e:
            cfg['warn'].append(f'.kit.json is not valid JSON: {e}')
            cfg['broken'] = True
    else:
        cfg['warn'].append(f'no {KIT_CONFIG_NAME}: running core-only '
                           f'(create it to select stacks)')
    if os.environ.get('KIT_LEGACY') == '1':
        cfg['stacks'] = ['*']
        cfg['stacks_source'] = 'KIT_LEGACY'
        cfg['warn'].append('KIT_LEGACY=1: all stacks forced (env overrides '
                           '.kit.json); remove the env var to use the file')
    return cfg


def _kit_cfg_types_ok(raw, errors):
    """Strict types, no coercion. Returns False on first structural error."""
    if not isinstance(raw, dict):
        errors.append('.kit.json root must be an object')
        return False
    if 'version' in raw and type(raw['version']) is not int:
        errors.append('.kit.json "version" must be int')
        return False
    if raw.get('version', 1) != 1:
        errors.append(f'.kit.json "version" must be 1, got {raw.get("version")!r}')
        return False
    if 'stacks' not in raw:
        errors.append('.kit.json: missing required key "stacks"')
        return False
    stacks = raw['stacks']
    if (not isinstance(stacks, list)
            or any(type(s) is not str for s in stacks)):
        errors.append('.kit.json "stacks" must be a list of strings')
        return False
    if any(not s.strip() for s in stacks):
        errors.append('.kit.json "stacks" contains an empty name')
        return False
    if len(set(stacks)) != len(stacks):
        errors.append('.kit.json "stacks" contains duplicates')
        return False
    if '*' in stacks:
        errors.append('.kit.json: "*" is not allowed in "stacks" '
                      '(use KIT_LEGACY=1 to force all stacks)')
        return False
    if any('/' in s or '\\' in s or s in ('.', '..') for s in stacks):
        errors.append('.kit.json "stacks" contains a path-like name')
        return False
    if 'sparse' in raw and type(raw['sparse']) is not bool:
        errors.append('.kit.json "sparse" must be bool')
        return False
    if 'paths' in raw:
        if (not isinstance(raw['paths'], dict)
                or any(type(k) is not str or type(v) is not str
                       for k, v in raw['paths'].items())):
            errors.append('.kit.json "paths" must be an object of strings')
            return False
    if 'source_root' in raw and type(raw['source_root']) is not str:
        errors.append('.kit.json "source_root" must be a string')
        return False
    if 'layout_version' in raw and (
            type(raw['layout_version']) is not int
            or raw['layout_version'] < 1):
        errors.append('.kit.json "layout_version" must be int >= 1 '
                      '(bool is not int)')
        return False
    return True


def known_stack_ids(ctx):
    """Stack registry: harness/stacks/*/stack.json on disk, plus git
    ls-tree fallback so sparse checkouts (stack dirs hidden, stack.json
    files always in the checkout) still validate."""
    ids = set()
    stacks_dir = ctx.resolve('harness') / 'stacks'
    if stacks_dir.is_dir():
        for f in stacks_dir.glob('*/stack.json'):
            ids.add(f.parent.name)
    rc, out, _ = git_run(ctx.resolve('harness'), 'ls-tree', '--name-only',
                         'HEAD', 'stacks/')
    if rc == 0:
        for s in out.splitlines():
            s = s.strip().strip('/')
            if s.startswith('stacks/'):
                s = s[len('stacks/'):]
            if s and '/' not in s:
                ids.add(s)
    return ids


def stack_known(ctx, name, registry):
    if name in registry:
        return True
    # Sparse fallback: stack.json is always in the checkout, but when the
    # whole stacks/ dir was ls-tree'd the name may still be resolvable in HEAD.
    rc, _, _ = git_run(ctx.resolve('harness'), 'cat-file', '-e',
                       f'HEAD:stacks/{name}/stack.json')
    return rc == 0


# ── convention synthesis (stack resources) ────────────────────────

def discover_stacks(harness_abs):
    """Stack ids with stacks/<s>/stack.json on disk or in HEAD (sparse
    checkouts may hide a whole stack dir; its stack.json lives in HEAD)."""
    harness_abs = Path(harness_abs)
    ids = {p.parent.name for p in harness_abs.glob('stacks/*/stack.json')}
    if (harness_abs / '.git').exists():
        rc, out, _ = git_run(harness_abs, 'ls-tree', '-d', '--name-only',
                             'HEAD', 'stacks/')
        if rc == 0:
            for line in out.splitlines():
                name = line.strip().rstrip('/')
                if not name.startswith('stacks/'):
                    continue
                name = name[len('stacks/'):]
                if '/' in name or name in ids:
                    continue
                rc2, _, _ = git_run(harness_abs, 'cat-file', '-e',
                                    f'HEAD:stacks/{name}/stack.json')
                if rc2 == 0:
                    ids.add(name)
    return sorted(ids)


def head_stack_dirs(harness_abs):
    """Every dir under stacks/ present in HEAD, one ls-tree batch
    (git ls-tree -r -d HEAD stacks/). Returns (dirs, warn, error):
    dirs None + warn when the kit is not a git checkout (disk-only
    synthesis); error when .git exists but ls-tree failed - silently
    falling back to disk-only would orphan-sweep stack links."""
    harness_abs = Path(harness_abs)
    if not (harness_abs / '.git').exists():
        return None, ('kit has no .git; stack dirs checked on disk '
                      'only (no sparse protection)'), None
    rc, out, _ = git_run(harness_abs, 'ls-tree', '-r', '-d',
                         '--name-only', 'HEAD', 'stacks/')
    if rc != 0:
        return None, None, ('git ls-tree HEAD failed though .git '
                            'exists; refusing disk-only synthesis '
                            '(would sweep stack links)')
    return {x.strip() for x in out.splitlines() if x.strip()}, None, None


def head_stack_paths(harness_abs):
    """Files under stacks/ present in HEAD (git ls-tree -r --name-only
    HEAD stacks/). None when the kit is not a git checkout or the
    listing fails - callers then fall back to disk-only checks (used
    for WARN heuristics only, unlike head_stack_dirs which guards
    sweeps)."""
    harness_abs = Path(harness_abs)
    if not (harness_abs / '.git').exists():
        return None
    rc, out, _ = git_run(harness_abs, 'ls-tree', '-r', '--name-only',
                         'HEAD', 'stacks/')
    if rc != 0:
        return None
    return {x.strip() for x in out.splitlines() if x.strip()}


# Dirs/files under stacks/<s>/ that mean the stack ships content even
# when they synthesize no publishable resource: docs/ai is a canonical
# layer (published as consumer stubs, not kit links), skills/ and
# deps-check.* are declared/validated elsewhere. A stack with only
# stack.json still warns.
STACK_CONTENT_MARKERS = (
    'cursor', 'skills', 'tools', 'docs',
    'deps-check.sh', 'deps-check.ps1',
)


def stack_has_content(harness_abs, sid, head_paths=None):
    """stacks/<sid>/ holds at least one canonical content dir/file.

    Checks disk and HEAD (sparse checkouts can hide committed dirs);
    head_paths=None fetches the HEAD listing lazily."""
    base = f'stacks/{sid}'
    for m in STACK_CONTENT_MARKERS:
        if (Path(harness_abs) / base / m).exists():
            return True
    if head_paths is None:
        head_paths = head_stack_paths(harness_abs)
    if not head_paths:
        return False
    prefixes = tuple(f'{base}/{m}/' for m in STACK_CONTENT_MARKERS)
    exact = {f'{base}/{m}' for m in STACK_CONTENT_MARKERS}
    return any(p in exact or p.startswith(prefixes) for p in head_paths)


def synthesized_stack_resources(harness_abs):
    """Convention resources for every stack with stacks/<s>/stack.json
    (all stacks, not only effective - scan_namespace/find_orphans and
    --all-stacks depend on the full list).

    A canonical dir synthesizes when it is on disk (untracked counts) or
    present in HEAD - a dir that is in HEAD but hidden by sparse-checkout
    keeps its resource, so the usual missing_source FAIL + abort-sweep
    protection still applies. Absent in both -> skipped silently: a stack
    need not ship all four canonical dirs."""
    harness_abs = Path(harness_abs)
    head_dirs, git_warn, git_err = head_stack_dirs(harness_abs)
    out, errors, warns = [], [], []
    if git_err:
        return out, [git_err], warns
    if git_warn:
        warns.append(git_warn)
    for s in discover_stacks(harness_abs):
        for prefix, rel, kind, target, manifest in CANON_STACK_RESOURCES:
            p = f'stacks/{s}/{rel}'
            if not (harness_abs / p).is_dir() and not (
                    head_dirs is not None and p in head_dirs):
                continue
            out.append({
                'id': f'{prefix}-{s}',
                'kind': kind,
                'source': f'harness/{p}',
                'target': target,
                'local_manifest': manifest,
                'stacks': [s],
                'synthesized': True,
            })
    return out, errors, warns


def resource_name(res):
    """Display id; synthesized resources carry the auto: prefix."""
    return ('auto:' if res.get('synthesized') else '') + res.get('id', '?')


def all_layout_resources(layout, harness_abs):
    """Explicit layout resources + synthesized stack resources inserted
    before the first alias (canonical order core -> stacks -> aliases).
    Returns (resources, errors): an explicit resource with the same
    kind+source+target as a synthesized one is a hard duplicate ERROR.
    Returns (resources, errors, warnings)."""
    resources = list(layout['resources'])
    sig = {(r['kind'], r['source'], r['target']): r.get('id')
           for r in resources}
    synth, errors, warns = synthesized_stack_resources(harness_abs)
    for r in synth:
        key = (r['kind'], r['source'], r['target'])
        if key in sig:
            errors.append(f'duplicate (explicit vs synthesized): '
                          f'"{sig[key]}" vs auto:{r["id"]}')
    idx = next((i for i, r in enumerate(resources)
                if r['kind'] == 'alias'), len(resources))
    resources[idx:idx] = synth
    return resources, errors, warns


def load_deps_registry(harness_abs):
    """{'core': [...], 'stacks': {s: [...]}} read from core/core.json
    and stacks/*/stack.json on disk."""
    harness_abs = Path(harness_abs)
    deps = {'core': [], 'stacks': {}}
    for name in ('core/core.json',):
        p = harness_abs / name
        if p.is_file():
            try:
                raw = json.loads(p.read_text(encoding='utf-8'))
                deps['core'] = list(raw.get('deps') or [])
            except (OSError, ValueError):
                pass
            break
    for sj in sorted(harness_abs.glob('stacks/*/stack.json')):
        try:
            raw = json.loads(sj.read_text(encoding='utf-8'))
            deps['stacks'][sj.parent.name] = list(raw.get('deps') or [])
        except (OSError, ValueError):
            deps['stacks'][sj.parent.name] = []
    return deps


def kit_sha(ctx):
    rc, out, _ = git_run(ctx.resolve('harness'), 'rev-parse',
                         '--short', 'HEAD')
    return out.strip() if rc == 0 and out.strip() else 'unknown'


def _layout_version_check(raw, where, ctx, errors):
    if not isinstance(raw, dict) or 'layout_version' not in raw:
        return
    v = raw['layout_version']
    if type(v) is not int or v < 1:
        errors.append(f'{where}: "layout_version" must be int >= 1, '
                      f'got {v!r}')
        return
    if v > SUPPORTED_LAYOUT_VERSION:
        errors.append(f'{where}: layout_version {v} > поддерживаемого '
                      f'{SUPPORTED_LAYOUT_VERSION} (kit {kit_sha(ctx)})')


def validate_layout_versions(ctx, cfg, stack_ids):
    """layout_version in .kit.json (raw), core/core.json and
    stack.json of effective stacks; kit-lint re-checks stack.json
    for ALL stacks."""
    errors = []
    if cfg['raw'] is not None:
        _layout_version_check(cfg['raw'], '.kit.json', ctx, errors)
    harness = ctx.resolve('harness')
    for name in ('core/core.json',):
        p = harness / name
        if p.is_file():
            try:
                _layout_version_check(
                    json.loads(p.read_text(encoding='utf-8')),
                    name, ctx, errors)
            except (OSError, ValueError):
                pass
            break
    ids = known_stack_ids(ctx) if '*' in stack_ids else stack_ids
    for s in sorted(ids):
        p = harness / 'stacks' / s / 'stack.json'
        if p.is_file():
            try:
                _layout_version_check(
                    json.loads(p.read_text(encoding='utf-8')),
                    f'stacks/{s}/stack.json', ctx, errors)
            except (OSError, ValueError):
                pass
    return errors


def validate_kit_config(ctx, cfg):
    """Validate .kit.json BEFORE any mutation. Returns error strings
    (empty = ok). Unknown keys are WARN, not ERROR."""
    errors = []
    if cfg['broken']:
        return ['.kit.json is not valid JSON']
    raw = cfg['raw']
    if raw is None:
        cfg['stacks_source'] = ('KIT_LEGACY'
                                if os.environ.get('KIT_LEGACY') == '1'
                                else 'default')
        return errors
    if not _kit_cfg_types_ok(raw, errors):
        return errors
    for key in sorted(set(raw) - KNOWN_KIT_KEYS):
        cfg['warn'].append(f'.kit.json: unknown key "{key}" (ignored)')
    cfg['version'] = raw['version']
    cfg['source_root'] = raw.get('source_root')
    cfg['paths'] = raw.get('paths', {})
    cfg['sparse'] = raw.get('sparse', False)
    if os.environ.get('KIT_LEGACY') != '1':
        cfg['stacks'] = list(raw['stacks'])
        cfg['stacks_source'] = 'file'
    registry = known_stack_ids(ctx)
    for name in cfg['stacks']:
        if name == '*':
            continue
        if not stack_known(ctx, name, registry):
            errors.append(f'.kit.json: unknown stack "{name}" '
                          f'(no stacks/{name}/stack.json in kit)')
    return errors


def validate_layout_stacks(ctx, resources):
    """Kit-side: resource "stacks" values must exist in the stack registry
    (an unknown id = dead resource that never lays out)."""
    registry = known_stack_ids(ctx)
    return [f'layout.json resource "{res.get("id")}": unknown stack "{s}"'
            for res in resources
            for s in res.get('stacks') or [] if s != '*'
            and not stack_known(ctx, s, registry)]


def effective_resources(resources, stacks):
    """Resources active for this consumer: no "stacks" field = core (always);
    otherwise the intersection with the selected stacks (or "*" on either
    side) decides."""
    if '*' in stacks:
        return list(resources)
    sel = set(stacks)
    return [r for r in resources
            if not r.get('stacks') or '*' in r['stacks']
            or sel & set(r['stacks'])]


def env_source_root(root):
    """CONFIG_PATH from the consumer's .env (fallback for source_root)."""
    p = Path(root) / '.env'
    if not p.is_file():
        return None
    try:
        for line in p.read_text(encoding='utf-8').splitlines():
            m = re.match(r'\s*CONFIG_PATH\s*=\s*(.*)$', line)
            if m:
                return m.group(1).strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def print_config(ctx, cfg, as_json, resources=None, all_stacks=False):
    """Resolved view of the consumer config - the ONLY .kit.json parser
    scripts (bootstrap/doctor/init-deps/link-*) are allowed to call."""
    if cfg['source_root'] is not None:
        src_root, src_origin = cfg['source_root'], 'file'
    else:
        env = env_source_root(ctx.root)
        if env:
            src_root, src_origin = env, 'env'
        else:
            src_root, src_origin = DEFAULT_SOURCE_ROOT, 'default'
    info = {
        'config': cfg['file'],
        'version': cfg['version'],
        'stacks': cfg['stacks'],
        'stacks_source': cfg.get('stacks_source', 'default'),
        'source_root': src_root,
        'source_root_source': src_origin,
        'sparse': cfg['sparse'],
        'paths': cfg['paths'],
        'harness_rel': ctx.harness_rel,
        'manifests': {'fallback': ctx.manifest_rel, 'lock': LOCK_REL},
        'resources': [resource_name(r) for r in
                      (resources or [] if all_stacks else
                       effective_resources(resources or [], cfg['stacks']))],
        'deps': load_deps_registry(ctx.resolve('harness')),
        'warnings': cfg['warn'],
    }
    if as_json:
        print(json.dumps(info, ensure_ascii=False, indent=2))
    else:
        for k, v in info.items():
            print(f'{k}: {v}')


def load_local(ctx, rel):
    names = set()
    if not rel:
        return names
    p = ctx.resolve(rel)
    if not p.is_file() and rel.startswith(KIT_STATE_DIR + '/'):
        legacy = ctx.resolve(LEGACY_STATE_DIR + '/' + rel.rsplit('/', 1)[-1])
        if legacy.is_file():
            p = legacy
    if p.is_file():
        for line in p.read_text(encoding='utf-8').splitlines():
            line = line.split('#', 1)[0].strip()
            if line:
                names.add(line)
    return names


def link_one(ctx, target, link, is_dir, rel, source_rel):
    """Create/refresh a single link. Returns True on success."""
    label = link.name
    if link.exists() or is_link(link):
        if is_link(link):
            cur = read_link(link)
            if cur:
                cur_path = Path(cur)
                if not cur_path.is_absolute():
                    cur_path = link.parent / cur_path
                # Foreign namespace: the link target is outside the consumer
                # root as this process sees it (e.g. engine runs in a Linux
                # sandbox over a layout created by Windows scripts). Relinking
                # it would rewrite all links to this namespace's paths and
                # break the original tools - skip instead.
                if not is_within_resolved(cur_path, ctx.root):
                    ctx.note_ns(rel, link)
                    ctx.say('WARN', f'SKIP FOREIGN-NS: {label} -> {cur} (layout from another namespace)')
                    return True
                if cur_path.resolve() == target.resolve():
                    ctx.say('OK', f'OK: {label}')
                    return True
            ctx.act(f'RELINK: {label} -> {target}',
                    lambda: remove_link_or_tree(link))
        elif is_dir:
            ctx.say('WARN', f'REPLACE COPY: {label}')
            ctx.act(f'remove copy {label}', lambda: remove_link_or_tree(link))
        else:
            src_sha = hash_file(target)
            if file_equal(link, target):
                # In-sync fallback (hardlink/copy). If symlink privilege has
                # appeared (Developer Mode), upgrade to a real symlink; this is
                # the only path that clears the degraded fallback state.
                if ctx.dry_run:
                    if file_symlink_available():
                        ctx.pending += 1
                        ctx.say('ACT', f'WOULD UPGRADE (symlink): {label}')
                    else:
                        ctx.say('OK', f'OK (fallback, in sync): {label}')
                        ctx.note_fallback(rel, source_rel, src_sha)
                    return True
                if file_symlink_available():
                    remove_link_or_tree(link)
                    how = make_file_link(target, link)
                    if how == 'FILELINK':
                        ctx.say('ACT', f'UPGRADE (symlink): {label}')
                        return True
                    ctx.say('WARN', f'upgrade to symlink failed, kept {how}: {label}')
                    ctx.note_fallback(rel, source_rel, hash_file(target))
                    return True
                ctx.say('OK', f'OK (fallback, in sync): {label}')
                ctx.note_fallback(rel, source_rel, src_sha)
                return True
            rec = ctx.old_fallback.get(rel)
            link_sha = hash_file(link)
            if rec and link_sha != rec['sha'] and link_sha != src_sha:
                ctx.say('WARN', f'KEEP LOCAL EDITS in fallback: {label} '
                               f'(not overwritten; move it to local manifest to own it)')
                return True
            ctx.say('WARN', f'REFRESH stale fallback: {label}')
            ctx.act(f'remove stale fallback {label}',
                    lambda: remove_link_or_tree(link))
            if ctx.dry_run:
                ctx.say('ACT', f'WOULD LINK: {label} -> {target}')
                return True
    if ctx.dry_run:
        if not (link.exists() or is_link(link)):
            ctx.pending += 1
            ctx.say('ACT', f'WOULD LINK: {label} -> {target}')
        return True
    link.parent.mkdir(parents=True, exist_ok=True)
    if is_dir:
        make_dir_link(target, link)
        ctx.say('ACT', f'LINK: {label}')
    else:
        how = make_file_link(target, link)
        if how == 'FILELINK':
            ctx.say('ACT', f'{how}: {label}')
        else:
            ctx.say('WARN', f'{how} (no symlink privilege): {label}')
            ctx.note_fallback(rel, source_rel, hash_file(target))
    return True


def run_child(ctx, res):
    source = ctx.resolve(res['source'])
    target = ctx.resolve(res['target'])
    if not source.is_dir():
        ctx.missing_source = True
        ctx.say('FAIL', f'FAIL missing kit source: {res["source"]} '
                       f'(selected stack hidden by sparse-checkout? '
                       f're-run bootstrap-kit to re-fetch)')
        return False
    local = load_local(ctx, res.get('local_manifest'))
    include = set(res.get('include') or [])
    want_dir = res['kind'] == 'child-dirs'
    for child in sorted(source.iterdir()):
        if service_name(child.name):
            continue
        if child.is_dir() != want_dir:
            continue
        if include and child.name not in include:
            continue
        if child.name in local:
            ctx.say('OK', f'SKIP LOCAL: {child.name}')
            continue
        link = target / child.name
        rel = rel_posix(link, ctx.root)
        ctx.note_managed(rel)
        link_one(ctx, child, link, want_dir, rel, rel_posix(child, ctx.root))
    return True


def run_alias(ctx, res):
    source = ctx.resolve(res['source'])
    target = ctx.resolve(res['target'])
    if not source.is_dir():
        # A missing consumer-side source dir (e.g. no .cursor/skills yet)
        # is a plain skip; a missing kit source is a real FAIL.
        if not res['source'].startswith('harness/'):
            ctx.say('OK', f'SKIP {res["id"]} (no {res["source"]})')
            return True
        ctx.missing_source = True
        ctx.say('FAIL', f'FAIL missing kit source: {res["source"]} '
                       f'(selected stack hidden by sparse-checkout? '
                       f're-run bootstrap-kit to re-fetch)')
        return False
    rel = rel_posix(target, ctx.root)
    ctx.note_managed(rel)
    link_one(ctx, source, target, True, rel, rel_posix(source, ctx.root))
    return True


def verify_resource(ctx, res):
    ok = True
    if res['kind'] == 'alias':
        # Verify aliases before the source check: in a foreign namespace the
        # source may itself be an unresolvable link, but the alias still needs
        # a FOREIGN-NS report instead of a misleading "no source" SKIP.
        source = ctx.resolve(res['source'])
        target = ctx.resolve(res['target'])
        rel = rel_posix(target, ctx.root)
        ctx.note_managed(rel)
        if is_link(target):
            kind, raw = ctx.note_ns(rel, target)
            if kind == 'foreign':
                ctx.say('WARN', f'WARN FOREIGN-NS: {rel} -> {raw}')
            else:
                ctx.say('OK', f'OK {res["target"]}')
        elif target.exists():
            ctx.say('FAIL', f'FAIL not link (copy?): {res["target"]}')
            ok = False
        elif not source.is_dir():
            ctx.say('OK', f'SKIP verify {res["id"]} (no source)')
        else:
            ctx.say('FAIL', f'FAIL missing: {res["target"]}')
            ok = False
        return ok
    source = ctx.resolve(res['source'])
    if not source.is_dir():
        ctx.say('OK', f'SKIP verify {res["id"]} (no source)')
        return True
    local = load_local(ctx, res.get('local_manifest'))
    include = set(res.get('include') or [])
    want_dir = res['kind'] == 'child-dirs'
    target = ctx.resolve(res['target'])
    for child in sorted(source.iterdir()):
        if service_name(child.name):
            continue
        if child.is_dir() != want_dir:
            continue
        if include and child.name not in include:
            continue
        if child.name in local:
            continue
        link = target / child.name
        rel = f'{res["target"]}/{child.name}'
        ctx.note_managed(rel)
        if is_link(link):
            kind, raw = ctx.note_ns(rel, link)
            if kind == 'foreign':
                ctx.say('WARN', f'WARN FOREIGN-NS: {rel} -> {raw}')
            else:
                ctx.say('OK', f'OK {rel}')
        elif link.exists():
            if want_dir:
                ctx.say('FAIL', f'FAIL not link (copy?): {rel}')
                ok = False
            elif file_equal(link, child):
                ctx.say('WARN', f'WARN copy-fallback, in sync: {rel}')
            else:
                ctx.say('WARN', f'WARN stale copy-fallback, content differs: {rel}')
        else:
            ctx.say('FAIL', f'FAIL missing: {rel}')
            ok = False
    return ok


# ── orphan-sweep (stateless) ──────────────────────────────────────

def expected_names(ctx, resources):
    """target-rel -> set of child names the effective resources will link;
    alias resource target rels are collected under the resource id itself."""
    by_target = {}
    for res in resources:
        if res['kind'] == 'alias':
            by_target.setdefault('\0alias', set()).add(res['target'])
            continue
        names = by_target.setdefault(res['target'], set())
        source = ctx.resolve(res['source'])
        if not source.is_dir():
            continue
        local = load_local(ctx, res.get('local_manifest'))
        include = set(res.get('include') or [])
        want_dir = res['kind'] == 'child-dirs'
        for child in source.iterdir():
            if service_name(child.name):
                continue
            if child.is_dir() != want_dir:
                continue
            if include and child.name not in include:
                continue
            if child.name in local:
                continue
            names.add(child.name)
    return by_target


def local_names_map(ctx, resources):
    """target-rel -> set of names declared consumer-owned by local-*.txt
    (union over ALL layout resources sharing the target, effective or not:
    the lists are consumer state, independent of the stack filter)."""
    by_target = {}
    for res in resources:
        if res['kind'] == 'alias':
            continue
        names = load_local(ctx, res.get('local_manifest'))
        if names:
            by_target.setdefault(res['target'], set()).update(names)
    return by_target


def _link_points_into(ctx, entry):
    """('harness'|'inside'|'foreign', raw) - where a reparse point leads.
    The raw readlink STRING is compared (no resolve): the target may be
    gone after a git mv or hidden by sparse-checkout."""
    raw = read_link(entry)
    if raw is None:
        return None, None
    tpath = Path(raw)
    if not tpath.is_absolute():
        tpath = entry.parent / tpath
    tpath = os.path.normpath(str(tpath))
    harness_abs = os.path.normpath(str(ctx.resolve('harness')))
    if is_within(tpath, harness_abs):
        return 'harness', raw
    if is_within_resolved(tpath, ctx.root):
        return 'inside', raw
    return 'foreign', raw


def find_orphans(ctx, all_resources, eff_resources):
    """Read-only orphan scan over the managed targets of ALL layout
    resources. Returns (orphans, foreign) where orphans are (path, rel)
    kit links safe to remove and foreign are (rel, raw) kept unmanaged."""
    expected = expected_names(ctx, eff_resources)
    locals_ = local_names_map(ctx, all_resources)
    keep_alias = expected.get('\0alias', set())
    orphans, foreign = [], []
    targets = sorted({res['target'] for res in all_resources
                      if res['kind'] != 'alias'})
    for t in targets:
        tdir = ctx.resolve(t)
        if not tdir.is_dir() or is_link(tdir):
            continue
        keep = expected.get(t, set()) | locals_.get(t, set())
        for entry in sorted(tdir.iterdir()):
            if entry.name in keep or not is_link(entry):
                continue
            kind, raw = _link_points_into(ctx, entry)
            rel = rel_posix(entry, ctx.root)
            if kind == 'harness':
                orphans.append((entry, rel))
            elif kind == 'foreign':
                foreign.append((rel, raw))
    for res in all_resources:
        if res['kind'] != 'alias' or res['target'] in keep_alias:
            continue
        target = ctx.resolve(res['target'])
        if not is_link(target):
            continue
        kind, raw = _link_points_into(ctx, target)
        rel = rel_posix(target, ctx.root)
        if kind == 'harness':
            orphans.append((target, rel))
        elif kind == 'foreign':
            foreign.append((rel, raw))
    return orphans, foreign


def sweep_orphans(ctx, all_resources, eff_resources):
    """Remove kit-owned links dropped from the effective set. Returns the
    number removed (would-be removed in dry-run)."""
    orphans, foreign = find_orphans(ctx, all_resources, eff_resources)
    for path, rel in orphans:
        ctx.act(f'REMOVE orphan link: {rel}',
                lambda p=path: remove_link_or_tree(p))
    for rel, raw in foreign:
        ctx.say('WARN', f'WARN unmanaged orphan (foreign-ns), kept: {rel} -> {raw}')
    if not ctx.dry_run:
        ctx.say('ACT', f'removed {len(orphans)} link(s)')
    return len(orphans)


def find_fallback_orphans(ctx):
    """Old-manifest entries the effective run did not re-record.
    Returns (pristine, edited): rel lists."""
    pristine, edited = [], []
    for rel in sorted(ctx.old_fallback):
        if rel in ctx.fallback:
            continue
        path = ctx.root / rel
        if is_link(path) or not path.is_file():
            continue  # no longer a fallback file - drop the record
        rec = ctx.old_fallback[rel]
        try:
            same = hash_file(path) == rec['sha']
        except OSError:
            same = False
        (pristine if same else edited).append(rel)
    return pristine, edited


def sweep_fallback_orphans(ctx):
    """Fallback orphan-sweep: pristine copy -> remove; locally edited ->
    WARN and KEEP the record in the new manifest + managed .gitignore
    (a forgotten record would be pruned blind on the next apply)."""
    pristine, edited = find_fallback_orphans(ctx)
    removed = 0
    for rel in pristine:
        ctx.act(f'REMOVE orphan fallback: {rel}',
                lambda r=rel: (ctx.root / r).unlink())
        removed += 1
    for rel in edited:
        rec = ctx.old_fallback[rel]
        ctx.say('WARN', f'WARN orphan fallback has local edits, kept: {rel} '
                       f'(add to a local manifest to own it)')
        ctx.note_fallback(rel, rec['source'], rec['sha'])
        ctx.note_managed(rel)
    if removed and not ctx.dry_run:
        ctx.say('ACT', f'removed {removed} fallback(s)')
    return removed


def acquire_lock(ctx):
    """.kit/lock around the mutation window of apply. Returns the Path or
    None on failure (message printed)."""
    if ctx.dry_run:
        return None
    p = ctx.root / LOCK_REL
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(p), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, f'pid {os.getpid()}\n'.encode('ascii'))
        os.close(fd)
        return p
    except FileExistsError:
        print(f'ERROR: {LOCK_REL} exists - another apply running? '
              f'(remove a stale lock to continue)', file=sys.stderr)
        return None
    except OSError as e:
        print(f'WARN: cannot create {LOCK_REL}: {e}', file=sys.stderr)
        return 'no-lock'


def iter_expected_links(ctx, resources):
    """Yield consumer paths the layout manages (independent of existence)."""
    for res in resources:
        source = ctx.resolve(res['source'])
        if not source.is_dir():
            continue
        target = ctx.resolve(res['target'])
        if res['kind'] == 'alias':
            yield target
            continue
        local = load_local(ctx, res.get('local_manifest'))
        include = set(res.get('include') or [])
        want_dir = res['kind'] == 'child-dirs'
        for child in sorted(source.iterdir()):
            if service_name(child.name):
                continue
            if child.is_dir() != want_dir:
                continue
            if include and child.name not in include:
                continue
            if child.name in local:
                continue
            yield target / child.name


def check_target_collisions(ctx, eff):
    """Pure pre-pass (before acquire_lock and any mutation in plan, apply,
    verify, tracked): two different kit sources must not claim the same
    consumer path. The map covers linkable children (after the
    include-filter, minus service names; local_manifest does NOT exempt -
    a consumer override cannot reconcile two kit sources) and alias
    targets, prefix-aware (is_within). Two resources sharing a target dir
    with disjoint child names is fine. Returns deterministic error
    strings sorted by rel_posix."""
    claims = []  # (rel_posix, display id)
    for res in eff:
        rid = resource_name(res)
        if res['kind'] == 'alias':
            claims.append((res['target'].rstrip('/'), rid))
            continue
        source = ctx.resolve(res['source'])
        if not source.is_dir():
            continue  # missing_source reports itself downstream
        include = set(res.get('include') or [])
        want_dir = res['kind'] == 'child-dirs'
        base = res['target'].rstrip('/')
        for child in source.iterdir():
            if service_name(child.name):
                continue
            if child.is_dir() != want_dir:
                continue
            if include and child.name not in include:
                continue
            claims.append((os.path.normcase(
                f'{base}/{child.name}').replace('\\', '/'), rid))
    hits = set()
    for i, (a, ra) in enumerate(claims):
        for b, rb in claims[i + 1:]:
            if ra == rb:
                continue
            if a == b or a.startswith(b + '/') or b.startswith(a + '/'):
                hits.add((*sorted((a, b)), *sorted((ra, rb))))
    return [f'target collision: {a} vs {b} (resources "{ra}" and "{rb}")'
            for a, b, ra, rb in sorted(hits)]


def scan_namespace(ctx, resources):
    """Classify existing managed links as inside/foreign before any action.

    Filesystem-only and side-effect free: lets apply/plan refuse a foreign
    namespace before the first link is touched (not after 100+ silent skips).
    """
    for link in iter_expected_links(ctx, resources):
        if is_link(link):
            ctx.note_ns(rel_posix(link, ctx.root), link)


def upgrade_fallbacks(ctx):
    """--upgrade-fallbacks: re-create recorded in-sync copies as links.

    The layout pass already upgrades managed in-sync fallbacks when symlink
    privilege appears; this also covers manifest entries that the current
    table no longer produces (paths recorded before the upgrade logic).
    """
    if ctx.dry_run or not ctx.upgrade_fallbacks:
        return
    for rel in sorted(ctx.old_fallback):
        path = ctx.root / rel
        if is_link(path) or not path.is_file():
            continue
        rec = ctx.old_fallback[rel]
        src = ctx.root / rec['source']
        if not src.is_file() or not file_equal(path, src):
            continue
        remove_link_or_tree(path)
        how = make_file_link(src, path)
        if how == 'FILELINK':
            ctx.say('ACT', f'UPGRADE (symlink) fallback: {rel}')
        else:
            ctx.say('WARN', f'fallback still {how} (symlink unavailable): {rel}')
            ctx.note_fallback(rel, rec['source'], hash_file(src))


def parse_gitignore_entries(text):
    """Split .gitignore into (managed, hand) normalized path sets."""
    managed, hand = set(), set()
    in_managed = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == GITIGNORE_BEGIN:
            in_managed = True
            continue
        if stripped == GITIGNORE_END:
            in_managed = False
            continue
        entry = line.split('#', 1)[0].strip()
        if not entry:
            continue
        key = entry.lstrip('/').rstrip('/')
        (managed if in_managed else hand).add(key)
    return managed, hand


def check_gitignore_overlap(ctx):
    """Hand-written paths already covered by the kit-managed block."""
    p = ctx.root / '.gitignore'
    if not p.is_file():
        return []
    managed, hand = parse_gitignore_entries(p.read_text(encoding='utf-8'))
    return sorted(hand & managed)


def warn_gitignore_overlap(ctx):
    overlap = check_gitignore_overlap(ctx)
    if not overlap:
        return
    show = ', '.join(overlap[:5]) + (' ...' if len(overlap) > 5 else '')
    ctx.say('WARN', f'WARN {len(overlap)} hand-written .gitignore line(s) duplicate '
                   f'the kit-managed block (remove them; the block is regenerated): {show}')


def load_fallback_manifest(ctx):
    """Read previous HARDLINK/COPY entries (tombstones + drift detection).
    Legacy location tools/cc-1c-skills-sync/kit-fallback.txt is read when
    .kit/fallback.txt does not exist yet (first apply after the move)."""
    p = ctx.manifest_path
    if not p.is_file():
        legacy = ctx.root / LEGACY_MANIFEST_REL
        if legacy.is_file():
            p = legacy
        else:
            return
    for line in p.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        rel, src, sha = parts[0], parts[1], parts[2]
        ctx.old_fallback[rel.replace('\\', '/')] = {
            'source': src.replace('\\', '/'),
            'sha': sha,
        }


def resolve_source(ctx, eff_resources, consumer_rel):
    """Reverse layout lookup for promote: which kit source produced this
    consumer path? Candidate generation walks core resources first, then
    the selected stacks; a candidate counts only if the child name exists
    in that source tree. Exactly one hit prints the kit path."""
    rel = re.sub(r'^\./+', '', consumer_rel.replace('\\', '/')).rstrip('/')
    harness_abs = os.path.normpath(str(ctx.resolve('harness')))
    hits = []
    for res in eff_resources:
        target = res['target'].rstrip('/')
        if rel != target and not rel.startswith(target + '/'):
            continue
        rest = rel[len(target):].lstrip('/')
        source = ctx.resolve(res['source'])
        if res['kind'] == 'alias':
            cand = source / rest if rest else source
            if not cand.exists() and not is_link(cand):
                continue
        else:
            if not rest:
                continue  # the target dir itself is consumer-owned
            child, _, tail = rest.partition('/')
            cand = source / child
            if not cand.exists():
                continue
            if tail:
                cand = cand / tail
        # Alias hits land on consumer paths that are themselves kit links
        # (.agents/skills/x -> .cursor/skills/x -> harness/...): follow them
        # so the reported path is the real kit source.
        if is_link(cand):
            raw = read_link(cand)
            if raw is not None:
                t = Path(raw)
                if not t.is_absolute():
                    t = cand.parent / t
                t = os.path.normpath(str(t))
                if is_within(t, harness_abs):
                    cand = Path(t)
                else:
                    continue  # consumer-owned alias, not a kit path
        hits.append(rel_posix(cand, ctx.root))
    hits = sorted(set(hits))
    if len(hits) == 1:
        print(hits[0])
        return 0
    if not hits:
        print(f'ERROR: no kit source maps {consumer_rel} '
              f'(not under a managed target, or child absent in kit)',
              file=sys.stderr)
    else:
        print(f'ERROR: ambiguous {consumer_rel}: {", ".join(hits)}',
              file=sys.stderr)
    return 2


def untrack_links(ctx):
    """Remove kit link paths from the consumer index (index only).

    Windows junction traversal makes git track kit content as consumer blobs;
    without this the submodule is duplicated in the index and a fresh clone
    materialises stale copies instead of links. --cached never touches the
    working tree (junctions stay in place).
    """
    if ctx.dry_run or not ctx.untrack:
        return
    rels = tracked_under(ctx.root, sorted(ctx.managed))
    if not rels:
        return
    for i in range(0, len(rels), 100):
        chunk = rels[i:i + 100]
        rc, out, err = git_run(ctx.root, 'rm', '-r', '-q', '-f', '--cached',
                               '--ignore-unmatch', '--', *chunk)
        if rc != 0:
            ctx.say('WARN', f'untrack failed: {(err or out).strip()}')
            continue
        for rel in chunk:
            ctx.say('ACT', f'UNTRACK: {rel}')


def verify_tracked(ctx):
    """WARN about kit link paths still tracked in the consumer index."""
    for rel in tracked_under(ctx.root, sorted(ctx.managed)):
        ctx.say('WARN', f'WARN kit link tracked in consumer index '
                       f'(git follows junction): {rel}')
    return True


def write_fallback_manifest(ctx):
    """Atomic write (tmp + os.replace): a half-written manifest would make
    the next apply forget which fallbacks are kit-owned."""
    if ctx.dry_run:
        return
    p = ctx.manifest_path
    p.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        '# kit fallback manifest (generated). Format:',
        '# consumer-rel<TAB>kit-source-consumer-rel<TAB>sha256',
    ]
    for rel in sorted(ctx.fallback):
        e = ctx.fallback[rel]
        lines.append(f"{rel}\t{e['source']}\t{e['sha']}")
    tmp = p.with_name(p.name + '.tmp')
    tmp.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    os.replace(tmp, p)


def write_managed_gitignore(ctx):
    """Regenerate the kit-managed .gitignore block so symlinks/hardlinks/copies
    created by kit do not pollute `git status` (consumer hand-lists drifted)."""
    if ctx.dry_run or not ctx.gitignore:
        return
    p = ctx.root / '.gitignore'
    old = p.read_text(encoding='utf-8') if p.is_file() else ''
    kept = []
    skip = False
    for line in old.splitlines():
        s = line.strip()
        if s == GITIGNORE_BEGIN:
            skip = True
            continue
        if s == GITIGNORE_END:
            skip = False
            continue
        if not skip:
            kept.append(line)
    while kept and not kept[-1].strip():
        kept.pop()
    entries = sorted('/' + r for r in ctx.managed)
    entries.append('/' + ctx.manifest_rel)
    entries.append('/' + LOCK_REL)
    prefix = kept + ([''] if kept else [])
    text = '\n'.join(prefix + [GITIGNORE_BEGIN] + entries + [GITIGNORE_END]) + '\n'
    p.write_text(text, encoding='utf-8')


def main(argv=None):
    p = argparse.ArgumentParser(prog='kit-layout', description=__doc__.split('\n')[0])
    p.add_argument('command', choices=['plan', 'apply', 'verify', 'tracked',
                                       'print-config', 'resolve-source'])
    p.add_argument('consumer_root', nargs='?', default='.',
                   help='consumer repo root (resolve-source: consumer-rel path)')
    p.add_argument('--root', default='.',
                   help='resolve-source: consumer repo root')
    p.add_argument('--harness-rel', default=os.environ.get('HARNESS_REL', 'harness'))
    p.add_argument('--layout', default=str(Path(__file__).with_name('layout.json')))
    p.add_argument('--all-stacks', action='store_true',
                   help='plan: ignore the stack filter (full layout)')
    p.add_argument('--json', action='store_true',
                   help='print-config: machine-readable output')
    p.add_argument('--strict', action='store_true',
                   help='plan: exit 1 if any pending action or foreign-ns link')
    p.add_argument('--no-gitignore', action='store_true',
                   help='do not (re)generate the kit-managed .gitignore block')
    p.add_argument('--no-untrack', action='store_true',
                   help='do not untrack kit link paths from the consumer index')
    p.add_argument('--upgrade-fallbacks', action='store_true',
                   help='apply: re-create recorded in-sync hardlink/copy as links')
    a = p.parse_intermixed_args(argv)

    layout = json.loads(Path(a.layout).read_text(encoding='utf-8'))
    consumer_root = a.root if a.command == 'resolve-source' else a.consumer_root
    gitignore = (not a.no_gitignore
                 and os.environ.get('KIT_NO_GITIGNORE') != '1'
                 and bool(layout.get('gitignore', True)))
    ctx = Ctx(consumer_root, a.harness_rel,
              dry_run=(a.command in ('plan', 'tracked')),
              gitignore=gitignore, quiet=(a.command == 'tracked'),
              untrack=(not a.no_untrack),
              upgrade_fallbacks=(a.upgrade_fallbacks
                                 or os.environ.get('KIT_UPGRADE_FALLBACKS') == '1'),
              manifest_rel=layout.get('fallback_manifest', FALLBACK_MANIFEST_REL))
    if is_wsl() and wsl_windows_path(ctx.root) and os.environ.get('WSL_ALLOW') != '1':
        print(
            'ERROR: WSL + Windows project path (/mnt/<drive>/...). Links created here\n'
            'would point into WSL paths and break Windows-side tools.\n'
            'Run from Windows Git Bash or PowerShell instead; set WSL_ALLOW=1 to force.',
            file=sys.stderr)
        return 2
    if not ctx.resolve('harness').is_dir():
        print(f'missing harness: {ctx.resolve("harness")} (git submodule update --init?)',
              file=sys.stderr)
        return 2

    # Consumer config: validate BEFORE any mutation. A broken .kit.json
    # exits non-zero with nothing touched; print-config is the only
    # parser scripts may use for it.
    cfg = load_kit_config(ctx.root)
    errors = validate_kit_config(ctx, cfg)
    resources, res_errors, res_warns = all_layout_resources(
        layout, ctx.resolve('harness'))
    errors += res_errors
    errors += validate_layout_stacks(ctx, resources)
    errors += validate_layout_versions(
        ctx, cfg, cfg['stacks'] if not errors else [])
    for w in res_warns + cfg['warn']:
        print(f'WARN {w}', file=sys.stderr)
    if errors:
        for e in errors:
            print(f'ERROR {e}', file=sys.stderr)
        return 2
    if a.command == 'print-config':
        print_config(ctx, cfg, a.json, resources, a.all_stacks)
        return 0
    eff = (resources if a.all_stacks or '*' in cfg['stacks']
           else effective_resources(resources, cfg['stacks']))
    if a.command == 'resolve-source':
        return resolve_source(ctx, eff, a.consumer_root)

    # Target-collision pre-pass: pure, before acquire_lock/mutations.
    if a.command in ('plan', 'apply', 'verify', 'tracked'):
        col = check_target_collisions(ctx, eff)
        if col:
            for e in col:
                print(f'ERROR {e}', file=sys.stderr)
            return 2
        # A stack in this command's scope without a single publishable
        # resource is suspicious (forgot the canonical dirs?). WARN only.
        # Stacks shipping canonical content that synthesizes nothing
        # (e.g. docs/ai) are legitimate and stay quiet.
        if a.command in ('plan', 'apply'):
            scope = (known_stack_ids(ctx)
                     if a.all_stacks or '*' in cfg['stacks']
                     else cfg['stacks'])
            claimed = {s for r in resources for s in (r.get('stacks') or [])}
            quiet = [s for s in sorted(scope)
                     if s != '*' and s not in claimed and '*' not in claimed]
            if quiet:
                harness_abs = ctx.resolve('harness')
                head_paths = head_stack_paths(harness_abs)
                quiet = [s for s in quiet
                         if not stack_has_content(harness_abs, s, head_paths)]
            for s in quiet:
                ctx.say('WARN', f'WARN stack "{s}": no publishable '
                                f'resources')

    # Namespace pre-scan: never start link work in a tree owned by another
    # OS/namespace (silent no-op + green verify is worse than a hard error).
    scan_namespace(ctx, resources)
    where = 'sandbox' if is_sandbox_namespace(ctx.root) else 'foreign'
    if ctx.foreign and a.command in ('plan', 'apply'):
        print(f'ERROR: kit-layout {where} namespace: {len(ctx.foreign)} kit link(s) '
              f'point outside {ctx.root}; refusing to relink.', file=sys.stderr)
        for rel, raw in ctx.foreign[:3]:
            print(f'  {rel} -> {raw}', file=sys.stderr)
        if len(ctx.foreign) > 3:
            print(f'  ... and {len(ctx.foreign) - 3} more', file=sys.stderr)
        print(FOREIGN_NS_HINT, file=sys.stderr)
        return 2

    failed = False
    if a.command == 'verify':
        for res in eff:
            failed |= not verify_resource(ctx, res)
        orphans, for_orph = find_orphans(ctx, resources, eff)
        for _, rel in orphans:
            ctx.say('WARN', f'WARN orphan kit link (not in effective set): {rel}')
        for rel, raw in for_orph:
            ctx.say('WARN', f'WARN unmanaged orphan (foreign-ns): {rel} -> {raw}')
        load_fallback_manifest(ctx)
        fb_pristine, fb_edited = find_fallback_orphans(ctx)
        for rel in fb_pristine + fb_edited:
            ctx.say('WARN', f'WARN orphan fallback entry: {rel}')
        verify_tracked(ctx)
        warn_gitignore_overlap(ctx)
        # verify never reports OK on a tree it cannot inspect.
        if ctx.foreign and ctx.inside == 0:
            ctx.say('FAIL', f'FAIL all {len(ctx.foreign)} kit link(s) are FOREIGN-NS '
                            f'({where} namespace); verification is meaningless here')
            failed = True
            print(FOREIGN_NS_HINT, file=sys.stderr)
        elif ctx.foreign:
            ctx.say('WARN', f'WARN {len(ctx.foreign)} FOREIGN-NS link(s) ignored, '
                            f'{ctx.inside} local link(s) checked')
    elif a.command == 'tracked':
        for res in eff:
            runner = run_alias if res['kind'] == 'alias' else run_child
            runner(ctx, res)
        tracked = tracked_under(ctx.root, sorted(ctx.managed))
        for rel in tracked:
            print(rel)
        return 1 if tracked else 0
    else:
        lock = acquire_lock(ctx) if a.command == 'apply' else None
        if a.command == 'apply' and lock is None:
            return 2
        try:
            load_fallback_manifest(ctx)
            warn_gitignore_overlap(ctx)
            for res in eff:
                if res.get('synthesized'):
                    ctx.say('INFO', f'== auto:{res["id"]} ==')
                runner = run_alias if res['kind'] == 'alias' else run_child
                failed |= not runner(ctx, res)
            if ctx.missing_source:
                # A selected stack hidden by sparse-checkout: sweeping now
                # would mass-delete its links. Refuse to clean up; linking
                # done so far stays.
                ctx.say('FAIL', 'FAIL aborting sweep: missing kit source(s) '
                               '(re-run bootstrap-kit to fix sparse-checkout)')
                failed = True
            else:
                sweep_orphans(ctx, resources, eff)
                sweep_fallback_orphans(ctx)
            upgrade_fallbacks(ctx)
            write_fallback_manifest(ctx)
            write_managed_gitignore(ctx)
            untrack_links(ctx)
        finally:
            if isinstance(lock, Path):
                lock.unlink(missing_ok=True)

    fails = sum(1 for lvl, _ in ctx.actions if lvl == 'FAIL')
    if a.command == 'plan':
        print(f'kit-layout plan: {ctx.pending} pending action(s), '
              f'{len(ctx.foreign)} foreign-ns skip(s)')
        if a.strict and (ctx.pending or ctx.foreign):
            return 1
    if a.command == 'verify':
        print(f'kit-layout verify: {"FAIL" if fails else "OK"}')
    return 1 if (failed or fails) else 0


if __name__ == '__main__':
    sys.exit(main())
