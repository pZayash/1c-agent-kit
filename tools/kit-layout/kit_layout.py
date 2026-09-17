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
  plan    [consumer-root]   dry-run of apply, exit 0
  apply   [consumer-root]
  verify  [consumer-root]   all expected links exist and are links; exit 1 on FAIL
                            (file copy-fallback = WARN, dir copies = FAIL)
  tracked [consumer-root]   list kit link paths tracked in the consumer index;
                            exit 1 if any (junction traversal on Windows)

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
FALLBACK_MANIFEST_REL = 'tools/cc-1c-skills-sync/kit-fallback.txt'
GITIGNORE_BEGIN = '# >>> kit-managed: begin (bootstrap-kit) >>>'
GITIGNORE_END = '# <<< kit-managed: end <<<'
_FILE_SYMLINK_OK = None  # cached result of file_symlink_available()


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
    # Windows returns junction targets with a \\?\ prefix - strip it so
    # comparisons with normally-resolved paths work.
    if WIN and raw.startswith('\\\\?\\'):
        raw = raw[4:]
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
        if rel.startswith('harness/'):
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


def load_local(ctx, rel):
    names = set()
    if not rel:
        return names
    p = ctx.resolve(rel)
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


def prune_stale(ctx, source, target, local, kind):
    """Tombstones: remove links in target pointing into source whose child
    name no longer exists upstream. Only links are touched."""
    if not target.is_dir():
        return
    want_dir = kind == 'child-dirs'
    for entry in sorted(target.iterdir()):
        if entry.name in local:
            continue
        if not is_link(entry):
            continue
        raw = read_link(entry)
        if raw is None:
            continue
        try:
            resolved = Path(raw).resolve()
        except OSError:
            resolved = Path(raw)
        src_resolved = source.resolve()
        if resolved != src_resolved and src_resolved not in resolved.parents:
            continue
        if not (source / entry.name).exists():
            ctx.act(f'PRUNE: {entry.name}', lambda e=entry: remove_link_or_tree(e))


def run_child(ctx, res):
    source = ctx.resolve(res['source'])
    target = ctx.resolve(res['target'])
    if not source.is_dir():
        ctx.say('FAIL', f'FAIL missing kit source: {res["source"]}')
        return False
    local = load_local(ctx, res.get('local_manifest'))
    include = set(res.get('include') or [])
    want_dir = res['kind'] == 'child-dirs'
    for child in sorted(source.iterdir()):
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
    prune_stale(ctx, source, target, local, res['kind'])
    return True


def run_alias(ctx, res):
    source = ctx.resolve(res['source'])
    target = ctx.resolve(res['target'])
    if not source.is_dir():
        ctx.say('OK', f'SKIP {res["id"]} (no {res["source"]})')
        return True
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


def iter_expected_links(ctx, layout):
    """Yield consumer paths the layout manages (independent of existence)."""
    for res in layout['resources']:
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
            if child.is_dir() != want_dir:
                continue
            if include and child.name not in include:
                continue
            if child.name in local:
                continue
            yield target / child.name


def scan_namespace(ctx, layout):
    """Classify existing managed links as inside/foreign before any action.

    Filesystem-only and side-effect free: lets apply/plan refuse a foreign
    namespace before the first link is touched (not after 100+ silent skips).
    """
    for link in iter_expected_links(ctx, layout):
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
    """Read previous HARDLINK/COPY entries (tombstones + drift detection)."""
    p = ctx.manifest_path
    if not p.is_file():
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


def prune_stale_fallbacks(ctx):
    """Tombstones for non-reparse fallbacks: remove a pristine fallback whose
    source vanished upstream or that the layout no longer manages. A fallback
    with consumer edits is kept (never silently delete local work)."""
    if ctx.dry_run:
        return
    for rel in sorted(ctx.old_fallback):
        if rel in ctx.fallback:
            continue
        path = ctx.root / rel
        if is_link(path) or not path.is_file():
            continue
        rec = ctx.old_fallback[rel]
        if not (ctx.root / rec['source']).exists():
            if hash_file(path) == rec['sha']:
                ctx.say('ACT', f'PRUNE (fallback): {rel}')
                path.unlink()
            else:
                ctx.say('WARN', f'stale fallback has local edits, kept: {rel}')


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
    p.write_text('\n'.join(lines) + '\n', encoding='utf-8')


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
    prefix = kept + ([''] if kept else [])
    text = '\n'.join(prefix + [GITIGNORE_BEGIN] + entries + [GITIGNORE_END]) + '\n'
    p.write_text(text, encoding='utf-8')


def main(argv=None):
    p = argparse.ArgumentParser(prog='kit-layout', description=__doc__.split('\n')[0])
    p.add_argument('command', choices=['plan', 'apply', 'verify', 'tracked'])
    p.add_argument('consumer_root', nargs='?', default='.')
    p.add_argument('--harness-rel', default=os.environ.get('HARNESS_REL', 'harness'))
    p.add_argument('--layout', default=str(Path(__file__).with_name('layout.json')))
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
    gitignore = (not a.no_gitignore
                 and os.environ.get('KIT_NO_GITIGNORE') != '1'
                 and bool(layout.get('gitignore', True)))
    ctx = Ctx(a.consumer_root, a.harness_rel,
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

    # Namespace pre-scan: never start link work in a tree owned by another
    # OS/namespace (silent no-op + green verify is worse than a hard error).
    scan_namespace(ctx, layout)
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
        for res in layout['resources']:
            failed |= not verify_resource(ctx, res)
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
        for res in layout['resources']:
            runner = run_alias if res['kind'] == 'alias' else run_child
            runner(ctx, res)
        tracked = tracked_under(ctx.root, sorted(ctx.managed))
        for rel in tracked:
            print(rel)
        return 1 if tracked else 0
    else:
        load_fallback_manifest(ctx)
        warn_gitignore_overlap(ctx)
        for res in layout['resources']:
            runner = run_alias if res['kind'] == 'alias' else run_child
            failed |= not runner(ctx, res)
        prune_stale_fallbacks(ctx)
        upgrade_fallbacks(ctx)
        write_fallback_manifest(ctx)
        write_managed_gitignore(ctx)
        untrack_links(ctx)

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
