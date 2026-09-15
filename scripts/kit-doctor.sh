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
  if bash "$SCRIPT_DIR/verify-kit-links.sh" "$CONSUMER_ROOT" >"$vlog" 2>&1; then
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

  # 8. copy-fallback paths (tombstones blind spot: prune touches reparse only)
  copies=""
  declare -A overlay_local=() tools_local=()
  kit_load_manifest "$SYNC_DIR/local-overlay.txt" overlay_local
  kit_load_manifest "$SYNC_DIR/local-tools.txt" tools_local
  for sub in rules commands; do
    src="$HARNESS_ROOT/cursor/$sub"
    [[ -d "$src" ]] || continue
    for f in "$src"/*; do
      [[ -f "$f" ]] || continue
      name="$(basename "$f")"
      [[ -n "${overlay_local[$name]:-}" ]] && continue
      dst="$CONSUMER_ROOT/.cursor/$sub/$name"
      [[ -e "$dst" && ! -L "$dst" ]] && copies+=".cursor/$sub/$name"$'\n'
    done
  done
  if [[ -z "${tools_local[git-partial-stage.py]:-}" && -f "$HARNESS_ROOT/tools/git-partial-stage.py" ]]; then
    dst="$CONSUMER_ROOT/tools/git-partial-stage.py"
    [[ -e "$dst" && ! -L "$dst" ]] && copies+="tools/git-partial-stage.py"$'\n'
  fi
  if [[ -n "$copies" ]]; then
    n="$(grep -c . <<<"$copies")"
    warn "$n kit path(s) are copy-fallback (no symlink privilege) - prune blind; content still refreshed on bootstrap:"
    grep . <<<"$copies" | sed 's/^/       /'
  else
    ok "no copy-fallback kit paths"
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
fi

echo "=== kit-doctor: $([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL) ==="
exit "$FAIL"
