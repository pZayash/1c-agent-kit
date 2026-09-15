#!/usr/bin/env python3
"""section-patch - managed sections in consumer markdown (idea: teamai section-patcher).

Kit owns marked sections in the consumer's AGENTS.md / CLAUDE.md and updates
only those; user content outside anchors and user edits inside drifted
sections are never silently overwritten.

Anchor format (HTML comments, invisible in rendered markdown):

    <!-- kit-section: <slug>, hash: <sha1-16>, source: harness -->
    ## Title
    body...
    <!-- /kit-section: <slug> -->

Semantics:
  - hash is sha1[:16] of the normalized body (LF, trimmed blank edges).
  - body hash == marker hash  -> user did not touch it -> safe to update.
  - body hash != marker hash  -> user edited (drift)  -> apply skips with a
    warning unless --on-conflict overwrite.
  - unclosed anchor -> error (whole document refused, like teamai).

Commands:
  apply   TARGET --slug S (--body-file F | --body TEXT) [--source SRC]
          [--on-conflict skip|overwrite] [--dry-run]
  check   TARGET            - exit 1 if any section drifted
  list    TARGET            - slug + status per section
  remove  TARGET --slug S   - remove section block

Stdlib only. UTF-8; preserves BOM and CRLF/LF of the target file.
"""
import argparse
import hashlib
import re
import sys

OPEN_RE = re.compile(
    r'<!--\s*kit-section:\s*([A-Za-z0-9_.-]+),\s*hash:\s*([0-9a-f]{16})'
    r'(?:,\s*source:\s*([^>]*?))?\s*-->')
CLOSE_RE = re.compile(r'<!--\s*/kit-section:\s*([A-Za-z0-9_.-]+)\s*-->')


def norm(body):
    """Normalize for hashing/compare: LF endings, trim blank edges."""
    body = body.replace('\r\n', '\n').replace('\r', '\n')
    lines = [l.rstrip() for l in body.split('\n')]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return '\n'.join(lines)


def body_hash(body):
    return hashlib.sha1(norm(body).encode('utf-8')).hexdigest()[:16]


class Doc:
    def __init__(self, path):
        self.path = path
        raw = open(path, 'rb').read()
        self.bom = raw.startswith(b'\xef\xbb\xbf')
        if self.bom:
            raw = raw[3:]
        text = raw.decode('utf-8')
        self.crlf = '\r\n' in text
        self.text = text.replace('\r\n', '\n').replace('\r', '\n')
        self.sections = self._parse(self.text)

    @staticmethod
    def _parse(text):
        sections = []
        pos = 0
        while True:
            m = OPEN_RE.search(text, pos)
            if not m:
                break
            slug, h, source = m.group(1), m.group(2), (m.group(3) or '').strip()
            c = CLOSE_RE.search(text, m.end())
            if not c:
                raise ValueError(f'unclosed anchor: {slug}')
            if c.group(1) != slug:
                raise ValueError(f'anchor mismatch: open {slug}, close {c.group(1)}')
            sections.append({
                'slug': slug, 'hash': h, 'source': source,
                'open': (m.start(), m.end()),
                'close': (c.start(), c.end()),
                'body': text[m.end():c.start()],
            })
            pos = c.end()
        # stray close anchors
        rest = CLOSE_RE.search(text, pos)
        if rest:
            raise ValueError(f'stray close anchor: {rest.group(1)}')
        return sections

    def find(self, slug):
        for s in self.sections:
            if s['slug'] == slug:
                return s
        return None

    def save(self):
        text = self.text
        if self.crlf:
            text = text.replace('\n', '\r\n')
        raw = text.encode('utf-8')
        if self.bom:
            raw = b'\xef\xbb\xbf' + raw
        open(self.path, 'wb').write(raw)


def render(slug, body, source):
    block = [f'<!-- kit-section: {slug}, hash: {body_hash(body)}, source: {source} -->']
    block.append(norm(body))
    block.append(f'<!-- /kit-section: {slug} -->')
    return '\n'.join(block)


def cmd_apply(a):
    body = a.body if a.body is not None else open(a.body_file, encoding='utf-8').read()
    body_n = norm(body)
    doc = Doc(a.target)
    s = doc.find(a.slug)

    if s is None:
        if a.dry_run:
            print(f'WOULD ADD: {a.slug}')
            return 0
        text = doc.text.rstrip('\n')
        doc.text = text + '\n\n' + render(a.slug, body_n, a.source) + '\n'
        doc.save()
        print(f'ADD: {a.slug}')
        return 0

    cur_n = norm(s['body'])
    drifted = body_hash(cur_n) != s['hash']
    if cur_n == body_n:
        if drifted:
            # content equals desired anyway - just refresh the marker hash
            if a.dry_run:
                print(f'WOULD REFRESH-HASH: {a.slug}')
                return 0
            doc.text = doc.text[:s['open'][0]] + render(a.slug, body_n, a.source) + doc.text[s['close'][1]:]
            doc.save()
            print(f'REFRESH-HASH: {a.slug}')
            return 0
        print(f'OK (unchanged): {a.slug}')
        return 0

    if drifted and a.on_conflict == 'skip':
        print(f'SKIP (user-modified, drift): {a.slug} '
              f'[--on-conflict overwrite to replace]', file=sys.stderr)
        return 0
    why = 'OVERWRITE (drift)' if drifted else 'UPDATE'
    if a.dry_run:
        print(f'WOULD {why}: {a.slug}')
        return 0
    doc.text = doc.text[:s['open'][0]] + render(a.slug, body_n, a.source) + doc.text[s['close'][1]:]
    doc.save()
    print(f'{why}: {a.slug}')
    return 0


def cmd_check(a):
    doc = Doc(a.target)
    bad = 0
    for s in doc.sections:
        drifted = body_hash(s['body']) != s['hash']
        status = 'DRIFT' if drifted else 'ok'
        if drifted:
            bad = 1
        print(f'{status}: {s["slug"]} (source: {s["source"] or "-"})')
    if not doc.sections:
        print('no kit-sections')
    return bad


def cmd_list(a):
    doc = Doc(a.target)
    for s in doc.sections:
        print(f'{s["slug"]}\thash={s["hash"]}\tsource={s["source"] or "-"}')
    return 0


def cmd_remove(a):
    doc = Doc(a.target)
    s = doc.find(a.slug)
    if s is None:
        print(f'not found: {a.slug}')
        return 1
    if a.dry_run:
        print(f'WOULD REMOVE: {a.slug}')
        return 0
    text = doc.text[:s['open'][0]] + doc.text[s['close'][1]:]
    doc.text = re.sub(r'\n{3,}', '\n\n', text)
    doc.save()
    print(f'REMOVE: {a.slug}')
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog='section-patch', description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    pa = sub.add_parser('apply', help='insert or update a managed section')
    pa.add_argument('target')
    pa.add_argument('--slug', required=True)
    g = pa.add_mutually_exclusive_group(required=True)
    g.add_argument('--body-file')
    g.add_argument('--body')
    pa.add_argument('--source', default='harness')
    pa.add_argument('--on-conflict', choices=['skip', 'overwrite'], default='skip')
    pa.add_argument('--dry-run', action='store_true')
    pa.set_defaults(fn=cmd_apply)

    for name, fn, helptext in [
            ('check', cmd_check, 'exit 1 if any section drifted (user-modified)'),
            ('list', cmd_list, 'list managed sections')]:
        ps = sub.add_parser(name, help=helptext)
        ps.add_argument('target')
        ps.set_defaults(fn=fn)

    pr = sub.add_parser('remove', help='remove a managed section')
    pr.add_argument('target')
    pr.add_argument('--slug', required=True)
    pr.add_argument('--dry-run', action='store_true')
    pr.set_defaults(fn=cmd_remove)

    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except (ValueError, OSError) as e:
        print(f'section-patch: error: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
