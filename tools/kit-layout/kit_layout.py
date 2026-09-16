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
    untracked kit paths in `git status`.

Commands:
  plan    [consumer-root]   dry-run of apply, exit 0
  apply   [consumer-root]
  verify  [consumer-root]   all expected links exist and are links; exit 1 on FAIL
                            (file copy-fallback = WARN, dir copies = FAIL)

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
        os.path.normcase(str(path)).startswith(os.path.normcase(str(root)) + os.sep)
        common = os.path.commonpath([str(path), str(root)])
        return os.path.normcase(common) == os.path.normcase(str(root))
    except (ValueError, OSError):
        return False


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
                 manifest_rel=FALLBACK_MANIFEST_REL):
        self.root = Path(root).resolve()
        self.harness_rel = harness_rel
        self.dry_run = dry_run
        self.gitignore = gitignore
        self.actions = []   # (level, message); level: ACT/WARN/FAIL/OK
        self.pending = 0    # would-be mutations in plan mode
        self.managed = set()      # consumer-rel paths owned by the kit
        self.fallback = {}        # rel -> {'source', 'sha'}
        self.old_fallback = {}    # rel -> {'source', 'sha'} (previous run)
        self.manifest_rel = manifest_rel
        self.manifest_path = self.root / manifest_rel

    def say(self, level, msg):
        self.actions.append((level, msg))
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
                if not is_within(cur_path, ctx.root):
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
    source = ctx.resolve(res['source'])
    if not source.is_dir():
        ctx.say('OK', f'SKIP verify {res["id"]} (no source)')
        return True
    if res['kind'] == 'alias':
        target = ctx.resolve(res['target'])
        if is_link(target):
            ctx.say('OK', f'OK {res["target"]}')
        elif target.exists():
            ctx.say('FAIL', f'FAIL not link (copy?): {res["target"]}')
            ok = False
        else:
            ctx.say('FAIL', f'FAIL missing: {res["target"]}')
            ok = False
        return ok
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
        if is_link(link):
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
    p.add_argument('command', choices=['plan', 'apply', 'verify'])
    p.add_argument('consumer_root', nargs='?', default='.')
    p.add_argument('--harness-rel', default=os.environ.get('HARNESS_REL', 'harness'))
    p.add_argument('--layout', default=str(Path(__file__).with_name('layout.json')))
    p.add_argument('--strict', action='store_true',
                   help='plan: exit 1 if any pending action (parity gate)')
    p.add_argument('--no-gitignore', action='store_true',
                   help='do not (re)generate the kit-managed .gitignore block')
    a = p.parse_intermixed_args(argv)

    layout = json.loads(Path(a.layout).read_text(encoding='utf-8'))
    gitignore = (not a.no_gitignore
                 and os.environ.get('KIT_NO_GITIGNORE') != '1'
                 and bool(layout.get('gitignore', True)))
    ctx = Ctx(a.consumer_root, a.harness_rel, dry_run=(a.command == 'plan'),
              gitignore=gitignore,
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

    failed = False
    if a.command != 'verify':
        load_fallback_manifest(ctx)
    for res in layout['resources']:
        if a.command == 'verify':
            failed |= not verify_resource(ctx, res)
        else:
            runner = run_alias if res['kind'] == 'alias' else run_child
            failed |= not runner(ctx, res)

    if a.command != 'verify':
        prune_stale_fallbacks(ctx)
        write_fallback_manifest(ctx)
        write_managed_gitignore(ctx)

    fails = sum(1 for lvl, _ in ctx.actions if lvl == 'FAIL')
    if a.command == 'plan':
        foreign = sum(1 for _, m in ctx.actions if m.startswith('SKIP FOREIGN-NS:'))
        print(f'kit-layout plan: {ctx.pending} pending action(s), {foreign} foreign-ns skip(s)')
        if a.strict and ctx.pending:
            return 1
    if a.command == 'verify':
        print(f'kit-layout verify: {"FAIL" if fails else "OK"}')
    return 1 if (failed or fails) else 0


if __name__ == '__main__':
    sys.exit(main())
