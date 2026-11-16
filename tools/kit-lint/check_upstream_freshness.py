#!/usr/bin/env python3
"""Upstream-freshness lint для kit: дрейф вендорных источников.

Источники — tools/kit-lint/upstream-sources.json. Два вида:

- git-sync: внешний git-репозиторий, синкаемый скриптом (cc-1c-skills).
  offline: возраст last-sync (WARN > warn_age_days) и дрейф по локальным
  refs клона (rev-list <synced>..<remote_ref>, если ref уже на руках).
  --online: git ls-remote — remote HEAD ушёл от synced-коммита.
- pypi-pin: минимум версии запинен в install-скриптах (answer42).
  offline: pin читается и сверяется между pin_files.
  --online: PyPI JSON API — есть версия новее запиненного минимума.
- github-release-pin: версия артефакта запинена в файле (BSLLS).
  --online only: GitHub releases — есть релиз новее пина. Понимает
  pre-release суффиксы (rc.N, beta, alpha) при include_prereleases.
- github-watch: адаптированная копия внешнего файла/каталога без sync
  (навыки mattpocock/skills, ponytail). --online only: последний
  upstream-коммит по path новее checked_at — «посмотреть, не перенять ли».

Без --online сеть не трогается: чек быстрый и не падает офлайн.
Сетевая недоступность в --online — WARN «не проверено», не FAIL.

Exit 0 — чисто, exit 1 — находки. В kit — гейт (CI); в kit-doctor — WARN.

Использование:
    python tools/kit-lint/check_upstream_freshness.py [KIT_ROOT] [--online]
"""

import json
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

NET_TIMEOUT = 10
PIN_RE = re.compile(r">=\s*([0-9][0-9.]*)")


def git(args, cwd, timeout=15):
    """git с поглощением ошибок -> (ok, stdout)."""
    try:
        r = subprocess.run(["git"] + args, cwd=cwd, timeout=timeout,
                           capture_output=True, text=True)
        return r.returncode == 0, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return False, ""


def ver_tuple(v):
    """'0.5.13' -> (0, 5, 13); хвосты -rc1 и т.п. отбрасываются."""
    out = []
    for part in v.split("."):
        m = re.match(r"\d+", part)
        out.append(int(m.group(0)) if m else 0)
    return tuple(out)


_PRE_RANK = {"alpha": 0, "beta": 1, "rc": 2}


def ver_key(v):
    """'1.1.0-rc.9' -> ((1,1,0), 0, 2, 9); stable > любой pre той же базы."""
    v = v.lstrip("v")
    base, _, pre = v.partition("-")
    nums = tuple(int(x) for x in re.findall(r"\d+", base)[:3] or ["0"])
    if not pre:
        return (nums, 1, 0, 0)
    m = re.match(r"(alpha|beta|rc)\.?(\d+)", pre)
    rank, num = (_PRE_RANK[m.group(1)], int(m.group(2))) if m else (0, 0)
    return (nums, 0, rank, num)


def gh_json(url):
    req = urllib.request.Request(
        url, headers={"User-Agent": "kit-upstream-freshness",
                      "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as r:
        return json.loads(r.read())


def check_git_sync(src, kit_root, online, findings):
    sid = src["id"]
    state_path = kit_root / src["sync_state"]
    if not state_path.is_file():
        findings.append(("WARN", f'{sid}: нет {src["sync_state"]} — '
                                 "история синка неизвестна"))
        return
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except ValueError as e:
        findings.append(("WARN", f"{sid}: {src['sync_state']}: {e}"))
        return
    synced = state.get("upstream_commit") or ""
    repo_url = state.get("upstream_repo") or ""
    synced_at = state.get("synced_at") or ""
    hint = src.get("sync_hint", "")

    if synced_at:
        try:
            ts = datetime.fromisoformat(synced_at.replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - ts).days
            if age > src.get("warn_age_days", 30):
                findings.append(
                    ("WARN", f"{sid}: последний sync {age} дн. назад "
                             f"({synced_at[:10]}); {hint}"))
        except ValueError:
            findings.append(("WARN", f"{sid}: synced_at '{synced_at}' "
                                     "не ISO-дата"))
    if not synced:
        findings.append(("WARN", f"{sid}: нет upstream_commit в "
                                 f"{src['sync_state']}"))
        return

    clone = kit_root / src["clone"]
    ref = src.get("remote_ref", "origin/main")
    if clone.is_dir():
        ok, _ = git(["rev-parse", "--verify", "--quiet", ref], cwd=clone)
        if ok:
            ok2, ahead = git(["rev-list", "--count",
                              f"{synced}..{ref}"], cwd=clone)
            if ok2 and ahead.isdigit() and int(ahead) > 0:
                findings.append(
                    ("WARN", f"{sid}: upstream на {ahead} комм. впереди "
                             f"sync ({ref} по локальным refs); {hint}"))
    else:
        findings.append(("WARN", f"{sid}: нет клона {src['clone']} — "
                                 "дрейф не проверить"))

    if online:
        if not repo_url:
            findings.append(("WARN", f"{sid}: нет upstream_repo в "
                                     f"{src['sync_state']}"))
        else:
            ok, out = git(["ls-remote", repo_url,
                           f"refs/heads/{ref.split('/')[-1]}"],
                          cwd=kit_root, timeout=NET_TIMEOUT)
            if not ok or not out:
                findings.append(("WARN", f"{sid}: ls-remote не удался — "
                                         "remote не проверен"))
            elif not out.split()[0].startswith(synced):
                findings.append(
                    ("WARN", f"{sid}: remote {ref.split('/')[-1]} = "
                             f"{out.split()[0][:8]} ≠ synced "
                             f"{synced[:8]}; {hint}"))


def check_pypi_pin(src, kit_root, online, findings):
    sid = src["id"]
    pins = {}
    for rel in src.get("pin_files", []):
        p = kit_root / rel
        if not p.is_file():
            findings.append(("WARN", f"{sid}: нет pin-файла {rel}"))
            continue
        m = PIN_RE.search(p.read_text(encoding="utf-8", errors="replace"))
        if m:
            pins[rel] = m.group(1)
        else:
            findings.append(("WARN", f"{sid}: pin '>=x.y.z' не найден "
                                     f"в {rel}"))
    if len(set(pins.values())) > 1:
        findings.append(("WARN", f"{sid}: минимум разнобоится: {pins}"))
    if not pins or not online:
        return

    pinned = min(pins.values(), key=ver_tuple)
    url = f"https://pypi.org/pypi/{src['package']}/json"
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "kit-upstream-freshness"})
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as r:
            latest = json.loads(r.read())["info"]["version"]
    except Exception as e:  # сеть/HTTP/JSON — недоступность, не находка кода
        findings.append(("WARN", f"{sid}: PyPI не проверен ({e})"))
        return
    if ver_tuple(latest) > ver_tuple(pinned):
        findings.append(
            ("WARN", f"{sid}: на PyPI {latest} > запиненного {pinned}; "
                     f"{src.get('bump_hint', 'проверить и поднять pin')}"))


def check_github_release_pin(src, kit_root, online, findings):
    """Версия в pin_file vs последний GitHub release (с/без pre)."""
    sid = src["id"]
    pin_path = kit_root / src["pin_file"]
    if not pin_path.is_file():
        findings.append(("WARN", f"{sid}: нет pin-файла {src['pin_file']}"))
        return
    pinned = pin_path.read_text(encoding="utf-8").strip()
    if not online:
        return
    try:
        rels = gh_json(f"https://api.github.com/repos/{src['repo']}"
                       "/releases?per_page=30")
        cands = [r["tag_name"] for r in rels
                 if src.get("include_prereleases") or not r["prerelease"]]
        if not cands:
            findings.append(("WARN", f"{sid}: нет подходящих релизов "
                                     f"в {src['repo']}"))
            return
        latest = max(cands, key=ver_key)
    except Exception as e:
        findings.append(("WARN", f"{sid}: GitHub releases не проверены ({e})"))
        return
    if ver_key(latest) > ver_key(pinned):
        findings.append(
            ("WARN", f"{sid}: release {latest} > pin {pinned} "
                     f"({src['pin_file']}); "
                     f"{src.get('bump_hint', 'поднять pin')}"))


def check_github_watch(src, kit_root, online, findings):
    """Информационно: upstream-коммит по path новее даты вендоринга."""
    sid = src["id"]
    checked_at = src.get("checked_at")
    if not online or not checked_at:
        return
    q = f"&path={src['path']}" if src.get("path") else ""
    try:
        commits = gh_json(f"https://api.github.com/repos/{src['repo']}"
                          f"/commits?per_page=1{q}")
        if not commits:
            return
        last = commits[0]["commit"]["committer"]["date"][:10]
    except Exception as e:
        findings.append(("WARN", f"{sid}: GitHub commits не проверены ({e})"))
        return
    if last > checked_at:
        findings.append(
            ("WARN", f"{sid}: upstream двигался после вендоринга "
                     f"({last} > {checked_at}) — копия адаптированная, "
                     f"синка нет; "
                     f"{src.get('bump_hint', 'сравнить руками, затем поднять '
                                             'checked_at')}"))


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    online = "--online" in sys.argv
    roots = [a for a in sys.argv[1:] if not a.startswith("-")]
    kit_root = Path(roots[0]).resolve() if roots else (
        Path(__file__).resolve().parents[2])

    cfg_path = kit_root / "tools" / "kit-lint" / "upstream-sources.json"
    if not cfg_path.is_file():
        print(f"WARN: нет {cfg_path.relative_to(kit_root)} — реестр "
              "вендорных источников", file=sys.stderr)
        return 1
    sources = json.loads(cfg_path.read_text(encoding="utf-8"))["sources"]

    findings = []
    for src in sources:
        kind = src.get("kind")
        if kind == "git-sync":
            check_git_sync(src, kit_root, online, findings)
        elif kind == "pypi-pin":
            check_pypi_pin(src, kit_root, online, findings)
        elif kind == "github-release-pin":
            check_github_release_pin(src, kit_root, online, findings)
        elif kind == "github-watch":
            check_github_watch(src, kit_root, online, findings)
        else:
            findings.append(("WARN", f"{src.get('id')}: неизвестный "
                                     f"kind '{kind}'"))

    for level, msg in findings:
        print(f"{level}: {msg}")
    if findings:
        print(f"\nupstream-freshness: {len(findings)} находок",
              file=sys.stderr)
        return 1
    print("upstream-freshness: чисто"
          + ("" if online else " (offline; --online — сверка с remote)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
