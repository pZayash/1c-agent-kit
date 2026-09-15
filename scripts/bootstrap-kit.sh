#!/usr/bin/env bash
# One-shot kit bootstrap for consumer root (Linux native; Win → .ps1).
#
# Usage:
#   bash harness/scripts/bootstrap-kit.sh [ConsumerRoot]
# Env:
#   DRY_RUN=1
#   FORCE_WRAPPER=1   — replace fat load-changed-files.sh with thin wrapper
#   SKIP_VERIFY=1
#   SKIP_DEPS=1       — не звать init-kit-deps
#   SKIP_SECTIONS=1   — не патчить managed-секции AGENTS.md
#   LEGACY_LINKS=1    — раскладка legacy link-скриптами (дефолт: kit-layout)
#   HARNESS_REL=harness
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_link-common.sh
source "$SCRIPT_DIR/_link-common.sh"

CONSUMER_ROOT="${1:-.}"
HARNESS_REL="${HARNESS_REL:-harness}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_WRAPPER="${FORCE_WRAPPER:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"

if kit_is_windows; then
  PS1="$SCRIPT_DIR/bootstrap-kit.ps1"
  args=(-ConsumerRoot "$(cd "$CONSUMER_ROOT" && pwd)" -HarnessRel "$HARNESS_REL")
  [[ "$DRY_RUN" == "1" ]] && args+=(-DryRun)
  [[ "$FORCE_WRAPPER" == "1" ]] && args+=(-ForceWrapper)
  [[ "$SKIP_VERIFY" == "1" ]] && args+=(-SkipVerify)
  [[ "${SKIP_DEPS:-0}" == "1" ]] && args+=(-SkipDeps)
  [[ "${SKIP_SECTIONS:-0}" == "1" ]] && args+=(-SkipSections)
  [[ "${LEGACY_LINKS:-0}" == "1" ]] && args+=(-LegacyLinks)
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

CONSUMER_ROOT="$(cd "$CONSUMER_ROOT" && pwd)"
HARNESS_ROOT="$CONSUMER_ROOT/$HARNESS_REL"

if [[ "${WSL_ALLOW:-0}" != "1" ]] && kit_wsl_windows_fs "$CONSUMER_ROOT"; then
  cat >&2 <<'EOS'
ERROR: WSL-bash + Windows-проект (/mnt/<drive>/...). Linux-ветка создаст symlink'и
на /mnt/..., которые не резолвятся из Windows-инструментов.
Запусти bootstrap из Windows:
  Git Bash:   "C:\Program Files\Git\bin\bash.exe" harness/scripts/bootstrap-kit.sh .
  PowerShell: powershell -File harness/scripts/bootstrap-kit.ps1 -ConsumerRoot .
Осознанно продолжить в WSL: WSL_ALLOW=1.
EOS
  exit 1
fi

[[ -d "$HARNESS_ROOT" ]] || { echo "missing harness: $HARNESS_ROOT (git submodule update --init?)" >&2; exit 1; }

if [[ "${LEGACY_LINKS:-0}" != "1" ]]; then
  echo "=== kit-layout (engine) ==="
  PY="$(command -v python || command -v python3 || true)"
  [[ -n "$PY" ]] || { echo "kit-layout needs python on PATH (or LEGACY_LINKS=1)" >&2; exit 1; }
  lcmd=apply
  [[ "$DRY_RUN" == "1" ]] && lcmd=plan
  HARNESS_REL="$HARNESS_REL" "$PY" "$HARNESS_ROOT/tools/kit-layout/kit_layout.py" "$lcmd" "$CONSUMER_ROOT"
else
  echo "=== link-cc-1c-skills ==="
  bash "$SCRIPT_DIR/link-cc-1c-skills.sh" "$CONSUMER_ROOT" "tools/cc-1c-skills-sync/local-skills.txt"

  echo "=== link-cursor-overlay ==="
  bash "$SCRIPT_DIR/link-cursor-overlay.sh" "$CONSUMER_ROOT" "tools/cc-1c-skills-sync/local-overlay.txt"

  echo "=== link-kit-tools ==="
  bash "$SCRIPT_DIR/link-kit-tools.sh" "$CONSUMER_ROOT" "tools/cc-1c-skills-sync/local-tools.txt"

  echo "=== link-editor-roots ==="
  bash "$SCRIPT_DIR/link-editor-roots.sh" "$CONSUMER_ROOT"

  echo "=== link-pi-roots ==="
  HARNESS_REL="$HARNESS_REL" bash "$SCRIPT_DIR/link-pi-roots.sh" "$CONSUMER_ROOT"
fi

if [[ "${SKIP_SECTIONS:-0}" != "1" && -d "$HARNESS_ROOT/templates/sections" && -f "$CONSUMER_ROOT/AGENTS.md" ]]; then
  PY="$(command -v python || command -v python3 || true)"
  if [[ -n "$PY" ]]; then
    echo "=== section-patch (AGENTS.md) ==="
    for sf in "$HARNESS_ROOT/templates/sections/"*.md; do
      [[ -f "$sf" ]] || continue
      args=(apply "$CONSUMER_ROOT/AGENTS.md" --slug "$(basename "$sf" .md)" --body-file "$sf")
      [[ "$DRY_RUN" == "1" ]] && args+=(--dry-run)
      "$PY" "$HARNESS_ROOT/tools/section-patch/section-patch.py" "${args[@]}"
    done
  else
    echo "WARN: no python on PATH - skip section-patch" >&2
  fi
fi

WRAPPER="$CONSUMER_ROOT/load-changed-files.sh"
ENGINE="$HARNESS_ROOT/tools/load-changed-files/load-changed-files.sh"
THIN_MARKER='harness/tools/load-changed-files/load-changed-files.sh'

if [[ -f "$ENGINE" ]]; then
  if [[ -f "$WRAPPER" ]] && ! grep -qF "$THIN_MARKER" "$WRAPPER" 2>/dev/null; then
    if [[ "$FORCE_WRAPPER" == "1" ]]; then
      echo "FORCE thin load-changed-files.sh wrapper"
      if [[ "$DRY_RUN" != "1" ]]; then
        cat >"$WRAPPER" <<'EOF'
#!/bin/bash
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_ROOT}/harness/tools/load-changed-files/load-changed-files.sh" "$@"
EOF
        chmod +x "$WRAPPER"
      fi
    else
      echo "WARN: load-changed-files.sh looks fat/legacy; pass FORCE_WRAPPER=1 to replace" >&2
    fi
  elif [[ ! -e "$WRAPPER" ]]; then
    echo "create thin load-changed-files.sh"
    if [[ "$DRY_RUN" != "1" ]]; then
      cat >"$WRAPPER" <<'EOF'
#!/bin/bash
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${_ROOT}/harness/tools/load-changed-files/load-changed-files.sh" "$@"
EOF
      chmod +x "$WRAPPER"
    fi
  fi
fi

if [[ "$SKIP_VERIFY" != "1" ]]; then
  echo "=== verify-kit-links ==="
  bash "$SCRIPT_DIR/verify-kit-links.sh" "$CONSUMER_ROOT"
fi

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  echo "=== init-kit-deps (check) ==="
  if ! bash "$SCRIPT_DIR/init-kit-deps.sh" "$CONSUMER_ROOT"; then
    echo "WARN host deps incomplete — harness/docs/ai/kit-host-deps.md (INSTALL=1). Links still done." >&2
  fi
fi

echo "bootstrap-kit: Done."
