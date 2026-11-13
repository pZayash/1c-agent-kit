#!/usr/bin/env bash
# kit-doctor - read-only aggregated diagnostics for a kit consumer
# (idea: teamai doctor). Prints [OK]/[WARN]/[FAIL] per check; exit 1 on any FAIL.
# Nothing on disk is modified: stale-link detection reuses link scripts in DRY_RUN.
#
# Usage:
#   bash harness/scripts/kit-doctor.sh [ConsumerRoot]
# Env:
#   HARNESS_REL=harness
#   SKIP_DEPS=1   - skip host deps check
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"

if kit_is_windows; then
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL")
  [[ "${SKIP_DEPS:-0}" == "1" ]] && args+=(-SkipDeps)
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/kit-doctor.ps1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"

if [[ "${WSL_ALLOW:-0}" != "1" ]] && kit_wsl_windows_fs "$CONSUMER_ROOT"; then
  cat >&2 <<'EOS'
ERROR: WSL-bash + Windows-проект (/mnt/<drive>/...). Диагностика из WSL
видит чужой namespace и бесполезна (голый `bash` в Git Bash может
резолвиться в C:\Windows\System32\bash.exe — WSL-лаунчер).
Запусти на хосте:
  Git Bash:   "$BASH" harness/scripts/kit-doctor.sh .
  PowerShell: powershell -File harness/scripts/kit-doctor.ps1 -ConsumerRoot .
Осознанно продолжить в WSL: WSL_ALLOW=1.
EOS
  exit 1
fi

FAIL=0
ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
info() { echo "[INFO] $*"; }

PY="$(command -v python || command -v python3 || true)"
KIT_LAYOUT="$HARNESS_ROOT/tools/kit-layout/kit_layout.py"
KIT_STACKS=""

echo "=== kit-doctor: $CONSUMER_ROOT ==="

# Конфиг потребителя — только через движок (единственный парсер .kit.json).
if [[ -n "$PY" && -f "$KIT_LAYOUT" ]]; then
  if cfg="$(kit_print_config_json "$CONSUMER_ROOT" "$HARNESS_REL" 2>/dev/null)"; then
    printf '%s\n' "$cfg" | "$PY" -m json.tool | sed 's/^/  /'
    KIT_STACKS="$("$PY" -c 'import json,sys
c=json.loads(sys.stdin.read())
s=c.get("stacks")
if s is None: s=c.get("effective_stacks") or []
print("*" if s=="*" else " ".join(str(x) for x in s))' <<<"$cfg")"
  else
    warn "print-config failed"
  fi
else
  info "no python / kit_layout.py — print-config skipped"
fi

# 0. namespace: links created in another OS/namespace (Windows checkout seen
#    from a Linux sandbox/WSL, or a moved consumer tree) cannot be diagnosed
#    here - verify/fallback checks would be meaningless (or falsely green).
FOREIGN_NS=0
foreign_out="$(kit_consumer_link_paths "$CONSUMER_ROOT" | kit_foreign_links "$CONSUMER_ROOT" || true)"
if [[ -n "$foreign_out" ]]; then
  FOREIGN_NS=1
  n="$(printf '%s\n' "$foreign_out" | grep -c .)"
  if kit_sandbox_namespace "$CONSUMER_ROOT"; then
    bad "sandbox namespace: $n kit link(s) point outside $CONSUMER_ROOT (Windows layout in a Linux container)"
  else
    bad "foreign namespace: $n kit link(s) point outside $CONSUMER_ROOT (moved tree / another OS)"
  fi
  printf '%s\n' "$foreign_out" | head -3 | sed 's/^/       /'
  info "run on the host (Git Bash / PowerShell), not through tools/sandbox/run.sh"
fi

# 1. harness presence + gitlink (logic: hooks/pre-commit-harness)
if [[ ! -e "$HARNESS_ROOT" ]]; then
  bad "missing $HARNESS_REL/ (git submodule update --init?)"
else
  mode="$(git -C "$CONSUMER_ROOT" ls-files -s -- "$HARNESS_REL" 2>/dev/null | awk '{print $1}' | head -1)"
  if [[ "$mode" == "160000" ]]; then
    ok "$HARNESS_REL is gitlink 160000"
  elif [[ -z "$mode" ]]; then
    warn "$HARNESS_REL not in index (untracked copy blocks merge - rm -rf before merging gitlink)"
  else
    bad "$HARNESS_REL staged as blobs (mode $mode) - must be submodule, see hooks/pre-commit-harness"
  fi
fi

# 2. harness git alive (worktree file-gitdir pitfall)
if [[ -e "$HARNESS_ROOT" ]]; then
  if sha="$(git -C "$HARNESS_ROOT" rev-parse --short HEAD 2>/dev/null)"; then
    ok "harness git alive (HEAD $sha)"
    if git -C "$HARNESS_ROOT" rev-parse --verify -q origin/master >/dev/null 2>&1; then
      if git -C "$HARNESS_ROOT" merge-base --is-ancestor HEAD origin/master 2>/dev/null; then
        info "harness HEAD is ancestor of local origin/master"
      else
        warn "harness HEAD not on local origin/master (pinned SHA or stale refs, offline-safe check)"
      fi
    fi
  else
    bad "git -C $HARNESS_REL broken (worktree file-gitdir?) - run fix-harness-gitdir"
  fi

  # 2b. gitlink vs HEAD drift (' M harness')
  recorded="$(git -C "$CONSUMER_ROOT" ls-files -s -- "$HARNESS_REL" 2>/dev/null | awk '{print $2}' | head -1)"
  full="$(git -C "$HARNESS_ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$recorded" && -n "$full" ]]; then
    if [[ "$recorded" != "$full" ]]; then
      warn "harness HEAD (${full:0:7}) != recorded gitlink (${recorded:0:7}) - ' M harness'; submodule update or bump gitlink"
    else
      ok "harness HEAD matches recorded gitlink"
    fi
  fi

  # 2c. harness working tree dirty: hardlink fallback edits land in the kit
  hf_dirty="$(git -C "$HARNESS_ROOT" status --porcelain -uno 2>/dev/null || true)"
  if [[ -n "$hf_dirty" ]]; then
    warn "harness working tree dirty ($(grep -c . <<<"$hf_dirty") tracked file(s)) - hardlink fallback edit? git -C $HARNESS_REL status"
  else
    ok "harness working tree clean"
  fi
fi

# 3. parent git alive
if git -C "$CONSUMER_ROOT" status --porcelain >/dev/null 2>&1; then
  ok "parent git status"
else
  bad "parent git status fails - check $HARNESS_REL/.git gitdir (fix-harness-gitdir)"
fi

if [[ -e "$HARNESS_ROOT" ]]; then
  # 4. verify links (engine, отфильтрованный по effective stacks plan)
  vlog="$(mktemp)"
  if [[ "$FOREIGN_NS" == "1" ]]; then
    info "kit_layout verify skipped (foreign namespace; see check 0)"
  elif [[ -z "$PY" || ! -f "$KIT_LAYOUT" ]]; then
    info "verify skipped (no python / kit_layout.py)"
  elif "$PY" "$KIT_LAYOUT" verify "$CONSUMER_ROOT" --harness-rel "$HARNESS_REL" >"$vlog" 2>&1; then
    ok "kit_layout verify"
  else
    bad "kit_layout verify:"
    sed 's/^/       /' "$vlog"
    echo "       -> исправить: bash $HARNESS_REL/scripts/bootstrap-kit.sh ."
  fi
  rm -f "$vlog"

  # 5+8. stale kit links и drift фолбэков — engine plan (pending actions).
  #      Заменяет DRY_RUN link-* и чтение старых манифестов SYNC_DIR.
  if [[ "$FOREIGN_NS" == "1" ]]; then
    info "kit_layout plan skipped (foreign namespace; see check 0)"
  elif [[ -n "$PY" && -f "$KIT_LAYOUT" ]]; then
    plog="$(mktemp)"
    if "$PY" "$KIT_LAYOUT" plan "$CONSUMER_ROOT" --harness-rel "$HARNESS_REL" >"$plog" 2>&1; then
      pending="$(grep -cE 'WOULD|PENDING|PRUNE|REMOVE|REPLACE|stale|drift|orphan|fallback' "$plog" || true)"
      if [[ "$pending" -gt 0 ]]; then
        warn "layout pending actions ($pending) — run bootstrap-kit:"
        grep -E 'WOULD|PENDING|PRUNE|REMOVE|REPLACE|stale|drift|orphan|fallback' "$plog" | head -15 | sed 's/^/       /'
      else
        ok "layout in sync (plan: no pending actions)"
      fi
    else
      bad "kit_layout plan failed:"
      sed 's/^/       /' "$plog" | head -20
    fi
    rm -f "$plog"
  fi

  # 6. host deps (check mode; WARN only - links already work without them).
  #    Секциями: core всегда, выбранные стеки — через init-kit-deps.
  if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    if bash "$SCRIPT_DIR/init-kit-deps.sh" "$CONSUMER_ROOT" >/dev/null 2>&1; then
      ok "host deps"
    else
      warn "host deps incomplete - core/docs/ai/kit-host-deps.md (INSTALL=1 to install)"
    fi
    all_stacks=""
    for sj in "$HARNESS_ROOT"/stacks/*/stack.json; do
      [[ -f "$sj" ]] || continue
      all_stacks+="$(basename "$(dirname "$sj")") "
    done
    skipped=""
    for s in $all_stacks; do
      [[ "$KIT_STACKS" == "*" || " $KIT_STACKS " == *" $s "* ]] || skipped+="$s "
    done
    [[ -n "$skipped" ]] && info "host deps SKIP stack(s): ${skipped% } (не выбраны в .kit.json)"
  fi

  # 7. ps1 encoding hygiene (BOM-less ps1 must be ASCII: PS 5.1 ParserError guard)
  if bash "$SCRIPT_DIR/check-ps1-ascii.sh" "$HARNESS_ROOT" >/dev/null 2>&1; then
    ok "ps1 encoding hygiene"
  else
    bad "non-ASCII in BOM-less *.ps1 under $HARNESS_REL - PS 5.1 ParserError risk (check-ps1-ascii)"
  fi

  # 8. (удалён) — drift фолбэков теперь показывает engine plan (check 5+8)
  #    и verify (check 4); orphan'ы отвечает orphan-sweep в apply.

  # 9. SKILL.md frontmatter (idea: teamai ensureSkillFrontmatter; WARN only).
  #    Пути: core/cursor/skills + stacks/*/cursor/skills + stacks/*/skills.
  if [[ -n "$PY" && -f "$HARNESS_ROOT/tools/skill-frontmatter/skill-frontmatter.py" ]]; then
    sflog="$(mktemp)"
    sf_dirs=()
    [[ -d "$HARNESS_ROOT/core/cursor/skills" ]] && sf_dirs+=("$HARNESS_ROOT/core/cursor/skills")
    for d in "$HARNESS_ROOT"/stacks/*/cursor/skills "$HARNESS_ROOT"/stacks/*/skills; do
      [[ -d "$d" ]] && sf_dirs+=("$d")
    done
    if [[ ${#sf_dirs[@]} -eq 0 ]]; then
      info "skill frontmatter: no skill dirs found"
    elif "$PY" "$HARNESS_ROOT/tools/skill-frontmatter/skill-frontmatter.py" lint \
         "${sf_dirs[@]}" >"$sflog" 2>&1; then
      ok "skill frontmatter"
    else
      warn "skill frontmatter issues (fix: python harness/tools/skill-frontmatter/skill-frontmatter.py fix ...):"
      sed 's/^/       /' "$sflog"
    fi
    rm -f "$sflog"
  fi

  # 9b. kit-lint suite (WARN only in doctor; in kit CI these are gates):
  #     core purity, cross-layer links, stack structural rules.
  if [[ -n "$PY" ]]; then
    for chk in check_core_purity.py check_cross_layer_links.py kit_lint.py; do
      script="$HARNESS_ROOT/tools/kit-lint/$chk"
      [[ -f "$script" ]] || continue
      clog="$(mktemp)"
      if "$PY" "$script" "$HARNESS_ROOT" >"$clog" 2>&1; then
        ok "kit-lint ${chk%.py}"
      else
        warn "kit-lint ${chk%.py}:"
        sed 's/^/       /' "$clog" | head -15
      fi
      rm -f "$clog"
    done
  fi

  # 10. kit links tracked in the consumer index (Windows junction traversal:
  #     git follows reparse points with core.symlinks=false and records kit
  #     content as ordinary blobs -> fresh clone gets stale copies, not links).
  if [[ -n "$PY" && -f "$HARNESS_ROOT/tools/kit-layout/kit_layout.py" ]]; then
    tklog="$(mktemp)"
    if "$PY" "$HARNESS_ROOT/tools/kit-layout/kit_layout.py" tracked "$CONSUMER_ROOT" \
         --harness-rel "$HARNESS_REL" >"$tklog" 2>&1; then
      ok "no kit links tracked in consumer index"
    else
      warn "kit links tracked as blobs (git follows junction; run bootstrap-kit to untrack):"
      sed 's/^/       /' "$tklog" | head -20
    fi
    rm -f "$tklog"
  fi

  # 11. .gitignore hygiene: hand-written kit paths now covered by the managed
  #     block (the block is regenerated, the hand lines are dead weight).
  gi="$CONSUMER_ROOT/.gitignore"
  if [[ -f "$gi" ]]; then
    overlap="$(awk '
      /^# >>> kit-managed: begin/ { managed=1; next }
      /^# <<< kit-managed: end/   { managed=0; next }
      {
        line=$0; sub(/#.*/, "", line)
        gsub(/^[ \t]+|[ \t\r]+$/, "", line)
        if (line == "") next
        key=line; sub(/^\/+/, "", key); sub(/\/+$/, "", key)
        if (managed) m[key]=1; else h[key]=1
      }
      END { for (k in h) if (k in m) print k }
    ' "$gi" | sort)"
    if [[ -n "$overlap" ]]; then
      on="$(grep -c . <<<"$overlap")"
      warn "$on hand-written .gitignore line(s) duplicate the kit-managed block (remove them):"
      grep . <<<"$overlap" | head -5 | sed 's/^/       /'
    fi
  fi

  # 12. answer42 freshness (optional tool; WARN only). Свежесть важна: до 0.5.13
  #     HTTP-сервис не запускал сборщик сирот, и занятые session_id не
  #     освобождались сами. Сеть проверки — с таймаутом внутри version_check.py.
  _a42_field() { sed -n "s/^$2: //p" "$1" | head -1; }
  a42_script="$CONSUMER_ROOT/tools/answer42/answer42.sh"
  if [[ -f "$a42_script" ]]; then
    a42log="$(mktemp)"
    ANSWER42_ROOT="$CONSUMER_ROOT" bash "$a42_script" check >"$a42log" 2>&1
    a42code=$?
    case "$a42code" in
      0) ok "answer42 $(_a42_field "$a42log" installed) (latest $(_a42_field "$a42log" latest))" ;;
      1) warn "answer42 outdated: installed $(_a42_field "$a42log" installed) -> latest $(_a42_field "$a42log" latest) ($(_a42_field "$a42log" channel)) - answer42.sh install|update" ;;
      *) info "answer42: версия не определена (не установлен / offline)" ;;
    esac
    rm -f "$a42log"
  fi
fi

echo "=== kit-doctor: $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$FAIL"
