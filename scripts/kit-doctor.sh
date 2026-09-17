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
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/kit-doctor.ps1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"
SYNC_DIR="$CONSUMER_ROOT/tools/cc-1c-skills-sync"

FAIL=0
ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; }
bad()  { echo "[FAIL] $*"; FAIL=1; }
info() { echo "[INFO] $*"; }

echo "=== kit-doctor: $CONSUMER_ROOT ==="

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
  # 4. verify links
  vlog="$(mktemp)"
  if [[ "$FOREIGN_NS" == "1" ]]; then
    info "verify-kit-links skipped (foreign namespace; see check 0)"
  elif bash "$SCRIPT_DIR/verify-kit-links.sh" "$CONSUMER_ROOT" >"$vlog" 2>&1; then
    ok "verify-kit-links"
  else
    bad "verify-kit-links:"
    sed 's/^/       /' "$vlog"
  fi
  rm -f "$vlog"

  # 5. stale kit links (DRY_RUN prune detection; read-only)
  stale=""
  if [[ -d "$HARNESS_ROOT/skills/cc-1c" ]]; then
    stale+="$(DRY_RUN=1 bash "$SCRIPT_DIR/link-cc-1c-skills.sh" "$CONSUMER_ROOT" \
      "tools/cc-1c-skills-sync/local-skills.txt" 2>/dev/null | grep 'WOULD PRUNE:' || true)"$'\n'
  fi
  if [[ -d "$HARNESS_ROOT/cursor" ]]; then
    stale+="$(DRY_RUN=1 bash "$SCRIPT_DIR/link-cursor-overlay.sh" "$CONSUMER_ROOT" \
      "tools/cc-1c-skills-sync/local-overlay.txt" 2>/dev/null | grep 'WOULD PRUNE:' || true)"$'\n'
  fi
  if [[ -d "$HARNESS_ROOT/tools" ]]; then
    stale+="$(DRY_RUN=1 bash "$SCRIPT_DIR/link-kit-tools.sh" "$CONSUMER_ROOT" \
      "tools/cc-1c-skills-sync/local-tools.txt" 2>/dev/null | grep 'WOULD PRUNE:' || true)"$'\n'
  fi
  stale="$(grep 'WOULD PRUNE:' <<<"$stale" || true)"
  if [[ -n "$stale" ]]; then
    warn "stale kit links - run bootstrap-kit to prune:"
    sed 's/^/       /' <<<"$stale"
  else
    ok "no stale kit links"
  fi

  # 6. host deps (check mode; WARN only - links already work without them)
  if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
    if bash "$SCRIPT_DIR/init-kit-deps.sh" "$CONSUMER_ROOT" >/dev/null 2>&1; then
      ok "host deps (node / openspec / rtk)"
    else
      warn "host deps incomplete - docs/ai/kit-host-deps.md (INSTALL=1 to install)"
    fi
  fi

  # 7. ps1 encoding hygiene (BOM-less ps1 must be ASCII: PS 5.1 ParserError guard)
  if bash "$SCRIPT_DIR/check-ps1-ascii.sh" "$HARNESS_ROOT" >/dev/null 2>&1; then
    ok "ps1 encoding hygiene"
  else
    bad "non-ASCII in BOM-less *.ps1 under $HARNESS_REL - PS 5.1 ParserError risk (check-ps1-ascii)"
  fi

  # 8. file fallbacks (hardlink then copy when no symlink privilege). In sync is
  #    fine; drift/orphans are visible via manifest + hash (no longer prune blind).
  #    If symlink privilege has appeared (Developer Mode), hint the upgrade.
  kit_symlink_possible() {
    local d t l
    d="$(mktemp -d)"
    t="$d/t"; l="$d/l"
    printf 'probe' > "$t"
    if ln -s "$t" "$l" 2>/dev/null; then rm -rf "$d"; return 0; fi
    rm -rf "$d"
    return 1
  }
  _sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
  }
  declare -A recorded=() pair_rels=()
  manifest="$SYNC_DIR/kit-fallback.txt"
  if [[ -f "$manifest" ]]; then
    while IFS=$'\t' read -r r s h || [[ -n "$r" ]]; do
      [[ -z "$r" || "$r" == \#* ]] && continue
      [[ -n "$h" ]] && recorded["$r"]="$s|$h"
    done < "$manifest"
  fi
  declare -A overlay_local=() tools_local=()
  kit_load_manifest "$SYNC_DIR/local-overlay.txt" overlay_local
  kit_load_manifest "$SYNC_DIR/local-tools.txt" tools_local
  stale=""
  in_sync=0
  links=0
  hardlinks=0
  copies=0
  file_link_kind() { # echo symlink|hardlink|copy
    local f="$1" n
    if [[ -L "$f" ]]; then echo symlink; return; fi
    n="$(stat -c %h "$f" 2>/dev/null || echo 1)"
    if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 1 ]]; then echo hardlink; else echo copy; fi
  }
  check_fallback() { # $1=rel $2=src
    local rel="$1" src="$2" dst="$CONSUMER_ROOT/$1" kind
    pair_rels["$rel"]=1
    if [[ ! -e "$dst" ]]; then
      stale+="$rel (fallback missing - run bootstrap-kit)"$'\n'; return
    fi
    kind="$(file_link_kind "$dst")"
    if [[ "$kind" == "symlink" ]]; then
      links=$((links + 1)); return
    fi
    if [[ -f "$src" ]] && cmp -s "$dst" "$src"; then
      in_sync=$((in_sync + 1))
      case "$kind" in
        hardlink) hardlinks=$((hardlinks + 1)) ;;
        *) copies=$((copies + 1)) ;;
      esac
      return
    fi
    stale+="$rel (content differs from kit - run bootstrap-kit)"$'\n'
  }
  for sub in rules commands; do
    src="$HARNESS_ROOT/cursor/$sub"
    [[ -d "$src" ]] || continue
    for f in "$src"/*; do
      [[ -f "$f" ]] || continue
      name="$(basename "$f")"
      [[ -n "${overlay_local[$name]:-}" ]] && continue
      check_fallback ".cursor/$sub/$name" "$f"
    done
  done
  if [[ -z "${tools_local[git-partial-stage.py]:-}" && -f "$HARNESS_ROOT/tools/git-partial-stage.py" ]]; then
    check_fallback "tools/git-partial-stage.py" "$HARNESS_ROOT/tools/git-partial-stage.py"
  fi
  for rel in "${!recorded[@]}"; do
    [[ -n "${pair_rels[$rel]:-}" ]] && continue
    dst="$CONSUMER_ROOT/$rel"
    [[ -e "$dst" && ! -L "$dst" ]] || continue
    src="$CONSUMER_ROOT/${recorded[$rel]%%|*}"
    [[ -e "$src" ]] && continue
    if [[ "$(_sha256 "$dst")" == "${recorded[$rel]##*|}" ]]; then
      stale+="$rel (orphan: source removed upstream - bootstrap-kit will prune)"$'\n'
    else
      stale+="$rel (orphan with local edits - kept)"$'\n'
    fi
  done
  if [[ -n "$stale" ]]; then
    n="$(grep -c . <<<"$stale")"
    warn "$n file fallback(s) out of sync:"
    grep . <<<"$stale" | sed 's/^/       /'
  elif [[ "$links" -eq 0 && "$in_sync" -eq 0 ]]; then
    ok "no file fallback kit paths"
  elif [[ "$in_sync" -gt 0 ]] && kit_symlink_possible; then
    warn "$in_sync in-sync file fallback(s) are not links ($hardlinks hardlink(s), $copies copy(ies); $links link(s)) - run bootstrap-kit to upgrade"
  else
    ok "$links link(s), $hardlinks hardlink(s), $copies copy(ies) in sync"
  fi

  # 9. SKILL.md frontmatter (idea: teamai ensureSkillFrontmatter; WARN only)
  PY="$(command -v python || command -v python3 || true)"
  if [[ -n "$PY" && -f "$HARNESS_ROOT/tools/skill-frontmatter/skill-frontmatter.py" ]]; then
    sflog="$(mktemp)"
    if "$PY" "$HARNESS_ROOT/tools/skill-frontmatter/skill-frontmatter.py" lint \
         "$HARNESS_ROOT/skills" "$HARNESS_ROOT/cursor/skills" >"$sflog" 2>&1; then
      ok "skill frontmatter"
    else
      warn "skill frontmatter issues (fix: python harness/tools/skill-frontmatter/skill-frontmatter.py fix ...):"
      sed 's/^/       /' "$sflog"
    fi
    rm -f "$sflog"
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
fi

echo "=== kit-doctor: $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$FAIL"
