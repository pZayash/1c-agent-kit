#!/usr/bin/env python3
"""skill-frontmatter - lint/fix YAML frontmatter of SKILL.md (idea: teamai ensureSkillFrontmatter).

Every skill dir under the given roots must contain SKILL.md with frontmatter
holding non-empty `name` (== dir name) and `description`.

  lint ROOT [ROOT...]   - report FAIL/WARN per skill; exit 1 on any FAIL
  fix  ROOT [ROOT...]   - repair what is safely repairable:
                          * no frontmatter      -> inject block (name=dir,
                                                   description derived from content)
                          * missing name/description -> append fields before the
                                                   closing '---' WITHOUT
                                                   reformatting existing YAML
                                                   (comments/quoting/order/EOL kept)
                          * name != dir         -> report only, never auto-fixed

Stdlib only. Top-level keys are detected by indent-0 `key:` lines (full YAML
parsing is intentionally out of scope). UTF-8; BOM and CRLF/LF preserved.
"""
import re
import sys
from pathlib import Path

KEY_RE = re.compile(r'^([A-Za-z_-][\w-]*):(?:[ \t]*(.*))?$')
NAME_OK_RE = re.compile(r'^[a-z0-9-]+$')
MAX_DESC = 160


def split_frontmatter(text):
    """Return (fm_lines, body_lines) or (None, None) if no frontmatter block.

    fm_lines excludes the opening/closing '---' delimiters.
    """
    lines = text.split('\n')
    if not lines or lines[0].rstrip() != '---':
        return None, None
    for i in range(1, len(lines)):
        if lines[i].rstrip() == '---':
            return lines[1:i], lines[i + 1:]
    return None, None  # unclosed -> treat as missing


def top_keys(fm_lines):
    """Map of indent-0 keys to (inline_value, line_idx)."""
    keys = {}
    for i, line in enumerate(fm_lines):
        if line[:1] in (' ', '\t') or line.lstrip().startswith('#'):
            continue
        m = KEY_RE.match(line)
        if m:
            keys[m.group(1)] = (m.group(2) or '', i)
    return keys


def field_nonempty(fm_lines, keys, name):
    """Key present with a non-empty inline value or non-empty folded block."""
    if name not in keys:
        return False
    inline, idx = keys[name]
    inline = inline.strip()
    if inline and inline not in ('|', '>', '|-', '>-', '|+', '>+'):
        return True
    # folded/literal block: scan following indented lines
    for line in fm_lines[idx + 1:]:
        if line[:1] in (' ', '\t'):
            if line.strip():
                return True
            continue
        break
    return False


def derive_description(body_lines, fallback):
    """First markdown heading, else first meaningful line; plain text, truncated."""
    candidate = ''
    for line in body_lines:
        s = line.strip()
        if not s or s.startswith('<!--'):
            continue
        if s.startswith('#'):
            candidate = s.lstrip('#').strip()
            break
        if s.startswith('```'):
            continue
        candidate = s
        break
    candidate = re.sub(r'[*_`\[\]()]', '', candidate).strip() or fallback
    candidate = ' '.join(candidate.split())
    return candidate[:MAX_DESC]


def yaml_quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


class Skill:
    def __init__(self, path):
        self.dir = path
        self.name = path.name
        self.md = path / 'SKILL.md'
        self.issues = []   # (level, message, fixable)
        self.warns = []

    def fail(self, msg, fixable=False):
        self.issues.append(('FAIL', msg, fixable))

    def warn(self, msg):
        self.warns.append(msg)


def read_skill(path):
    raw = path.read_bytes()
    bom = raw.startswith(b'\xef\xbb\xbf')
    if bom:
        raw = raw[3:]
    text = raw.decode('utf-8')
    eol = '\r\n' if '\r\n' in text else '\n'
    return text.replace('\r\n', '\n').replace('\r', '\n'), bom, eol


def write_skill(path, text, bom, eol):
    out = text.replace('\n', eol) if eol == '\r\n' else text
    raw = out.encode('utf-8')
    path.write_bytes((b'\xef\xbb\xbf' if bom else b'') + raw)


def scan_dir(d, out):
    """A dir with SKILL.md is a skill; otherwise descend (container like skills/cc-1c)."""
    if (d / 'SKILL.md').is_file():
        out.append(check_skill(d))
        return
    for sub in sorted(d.iterdir()):
        if sub.is_dir():
            scan_dir(sub, out)


def check_skill(d):
    sk = Skill(d)
    if not sk.md.is_file():
        sk.fail('SKILL.md missing')
        return sk
    text, sk.bom, sk.eol = read_skill(sk.md)
    fm, body = split_frontmatter(text)
    sk.text, sk.body = text, body
    if fm is None:
        sk.fail('frontmatter missing', fixable=True)
        return sk
    sk.fm = fm
    keys = top_keys(fm)
    if not field_nonempty(fm, keys, 'name'):
        sk.fail('frontmatter: name missing/empty', fixable=True)
    elif keys['name'][0].strip().strip('"\'') != sk.name:
        sk.fail(f'name mismatch: "{keys["name"][0].strip()}" != dir "{sk.name}"')
    if not NAME_OK_RE.match(sk.name):
        sk.warn(f'dir name "{sk.name}" not [a-z0-9-]')
    if not field_nonempty(fm, keys, 'description'):
        sk.fail('frontmatter: description missing/empty', fixable=True)
    return sk


def scan(root):
    """Collect Skill objects with detected issues (no writes)."""
    out = []
    scan_dir(root, out)
    return out


def fix_skill(sk):
    """Apply safe repairs. Returns list of actions."""
    actions = []
    body_lines = sk.body if sk.body is not None else sk.text.split('\n')
    desc = derive_description(body_lines, f'Skill {sk.name}')
    if not hasattr(sk, 'fm'):
        # no frontmatter at all: inject a fresh block on top
        body_text = sk.text
        block = ['---', f'name: {sk.name}', f'description: {yaml_quote(desc)}', '---']
        write_skill(sk.md, '\n'.join(block) + '\n' + body_text, sk.bom, sk.eol)
        actions.append('inject frontmatter')
        return actions
    keys = top_keys(sk.fm)
    add = []
    if not field_nonempty(sk.fm, keys, 'name'):
        add.append(f'name: {sk.name}')
    if not field_nonempty(sk.fm, keys, 'description'):
        add.append(f'description: {yaml_quote(desc)}')
    if add:
        # append fields right before the closing '---', preserving everything else
        lines = sk.text.split('\n')
        close_idx = len(sk.fm) + 1  # index of closing '---' line
        lines[close_idx:close_idx] = add
        write_skill(sk.md, '\n'.join(lines), sk.bom, sk.eol)
        actions.append('add ' + ', '.join(a.split(':')[0] for a in add))
    return actions


def iter_roots(args):
    for root in args.roots:
        r = Path(root)
        if not r.is_dir():
            print(f'WARN: root not a dir: {r}', file=sys.stderr)
            continue
        yield r


def cmd_lint(args):
    fails = 0
    for root in iter_roots(args):
        for sk in scan(root):
            for level, msg, _ in sk.issues:
                print(f'{level}: {sk.name}: {msg}')
                fails += 1
            for msg in sk.warns:
                print(f'WARN: {sk.name}: {msg}')
    if fails == 0:
        print('skill-frontmatter: OK')
        return 0
    print(f'skill-frontmatter: {fails} FAIL')
    return 1


def cmd_fix(args):
    for root in iter_roots(args):
        for sk in scan(root):
            fixable = [m for lvl, m, f in sk.issues if f]
            hard = [m for lvl, m, f in sk.issues if not f]
            for msg in hard:
                print(f'FAIL (manual fix): {sk.name}: {msg}')
            if fixable:
                if args.dry_run:
                    print(f'WOULD FIX: {sk.name}: {"; ".join(fixable)}')
                else:
                    actions = fix_skill(sk)
                    print(f'FIX: {sk.name}: {"; ".join(actions)}')
    return 0


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser(prog='skill-frontmatter',
                                description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    pl = sub.add_parser('lint', help='report frontmatter issues; exit 1 on FAIL')
    pl.add_argument('roots', nargs='+')
    pl.set_defaults(fn=cmd_lint)
    pf = sub.add_parser('fix', help='safely repair frontmatter')
    pf.add_argument('roots', nargs='+')
    pf.add_argument('--dry-run', action='store_true')
    pf.set_defaults(fn=cmd_fix)
    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except OSError as e:
        print(f'skill-frontmatter: error: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
