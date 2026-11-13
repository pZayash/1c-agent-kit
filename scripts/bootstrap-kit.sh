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
  ps_exe="$(kit_powershell)" || { echo "ERROR: PowerShell не найден (Windows-ветка kit идёт через .ps1)" >&2; exit 1; }
  exec "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$PS1" "${args[@]}"
fi

# Consumer .gitattributes: без eol=lf на *.sh при core.autocrlf=true .sh
# чекаутятся с CRLF и падают ("syntax error $'{\r'"). Warn, не отказ.
# Эффективный атрибут через git check-attr (покрывает и глобальный
# `* text=auto eol=lf`, не только явный `*.sh`); grep — fallback без git.
# Здесь, а не до exec-блока: на Windows ветку проверяет bootstrap-kit.ps1.
sh_eol_lf=0
if eol_line="$(git -C "$CONSUMER_ROOT" check-attr eol -- probe.sh 2>/dev/null)" \
    && [[ "$eol_line" == *"eol: lf"* ]]; then
  sh_eol_lf=1
elif [[ -f "$CONSUMER_ROOT/.gitattributes" ]] \
    && grep -Eq '^[[:space:]]*\*(\.sh)?[[:space:]].*eol=lf' "$CONSUMER_ROOT/.gitattributes"; then
  sh_eol_lf=1
fi
if [[ "$sh_eol_lf" == "0" ]]; then
  cat >&2 <<'EOS'
WARN: у потребителя нет правила "*.sh text eol=lf" в .gitattributes —
при core.autocrlf=true .sh чекаутятся с CRLF и падают (syntax error).
Добавьте:
  printf '%s\n' '*.sh text eol=lf' '*.py text eol=lf' '*.ps1 text' \
    '*.bat text eol=crlf' '*.xml -text' '*.bsl -text' >> .gitattributes
  git add .gitattributes && git add --renormalize -- '*.sh' && git checkout -- '*.sh'
EOS
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

# Namespace guard: links created by another OS/namespace (Windows checkout seen
# from a Linux sandbox/WSL) must not be relinked here. Stop before ANY link or
# file step; otherwise bootstrap is a silent no-op (engine) or creates
# container-local links and fails verify with a misleading reason.
# `|| true`: belt-and-braces against a helper status leak under pipefail —
# the guard must print its ERROR (exit 2), never abort silently (exit 1).
foreign_out="$(kit_consumer_link_paths "$CONSUMER_ROOT" | kit_foreign_links "$CONSUMER_ROOT" || true)"
if [[ -n "$foreign_out" ]]; then
  n="$(printf '%s\n' "$foreign_out" | grep -c .)"
  {
    echo "ERROR: kit-ссылки созданы в другом namespace (target вне $CONSUMER_ROOT):"
    printf '%s\n' "$foreign_out" | head -5 | sed 's/^/  /'
    if [[ "$n" -gt 5 ]]; then echo "  ... и ещё $((n - 5))"; fi
    echo "Это не раскладка потребителя, а ссылки другого OS/namespace (Windows-checkout"
    echo "внутри Linux-sandbox/WSL). Перезапусти bootstrap на хосте:"
    echo "  Git Bash:   bash harness/scripts/bootstrap-kit.sh ."
    echo "  PowerShell: powershell -File harness/scripts/bootstrap-kit.ps1 -ConsumerRoot ."
  } >&2
  exit 2
fi
if kit_sandbox_namespace "$CONSUMER_ROOT"; then
  echo "WARN: sandbox namespace (/.dockerenv + /workspace), существующие ссылки внутри root — продолжаю" >&2
fi

PY="$(command -v python || command -v python3 || true)"
KIT_LAYOUT="$HARNESS_ROOT/tools/kit-layout/kit_layout.py"
KIT_STACKS=""
KIT_SPARSE=0
STACK_1C=0

if [[ "${LEGACY_LINKS:-0}" != "1" ]]; then
  echo "=== kit-layout (engine) ==="
  [[ -n "$PY" ]] || { echo "kit-layout needs python on PATH (or LEGACY_LINKS=1)" >&2; exit 1; }

  # 1) Конфиг: единственный парсер .kit.json — print-config --json (он же
  #    валидирует до любых мутаций). Под устаревшим sparse-паттерном
  #    stack.json выбранного стека может быть скрыт → расширяем checkout
  #    и повторяем (иначе ложный unknown-stack).
  if ! cfg="$(kit_print_config_json "$CONSUMER_ROOT" "$HARNESS_REL")"; then
    if [[ -f "$CONSUMER_ROOT/.kit.json" ]] \
        && git -C "$HARNESS_ROOT" sparse-checkout list >/dev/null 2>&1; then
      echo "WARN: print-config failed under sparse-checkout — widening to /* and retrying" >&2
      if [[ "$DRY_RUN" != "1" ]]; then
        MSYS_NO_PATHCONV=1 git -C "$HARNESS_ROOT" sparse-checkout set --no-cone '/*'
      fi
      cfg="$(kit_print_config_json "$CONSUMER_ROOT" "$HARNESS_REL")" || {
        echo "ERROR: .kit.json не проходит валидацию" >&2; exit 1; }
    else
      echo "ERROR: print-config failed" >&2; exit 1
    fi
  fi

  if [[ ! -f "$CONSUMER_ROOT/.kit.json" ]]; then
    cat >&2 <<'EOS'
HINT: .kit.json отсутствует — режим core-only (stacks: []).
Чтобы включить стек, создайте в корне потребителя, напр.:
  {"version": 1, "stacks": ["1c"], "source_root": "conf/", "sparse": false}
EOS
  fi

  eval "$("$PY" -c 'import json,sys
c=json.loads(sys.stdin.read())
s=c.get("stacks")
if s is None: s=c.get("effective_stacks") or []
print("KIT_STACKS=" + ("*" if s=="*" else " ".join(str(x) for x in s)))
print("KIT_SPARSE=" + ("1" if c.get("sparse") else "0"))' <<<"$cfg")"

  # 2) Sparse: позитивный паттерн (работает и когда stacks/* уже скрыты;
  #    stack.json ВСЕГДА в checkout — валидация имён). "*" под KIT_LEGACY
  #    требует всех файлов → снимаем sparse.
  sparse_active() { git -C "$HARNESS_ROOT" sparse-checkout list >/dev/null 2>&1; }
  if [[ "$KIT_STACKS" == "*" ]]; then
    if sparse_active; then
      echo "WARN: effective stacks = * (KIT_LEGACY) — sparse-checkout disable (все файлы нужны)" >&2
      if [[ "$DRY_RUN" == "1" ]]; then echo "WOULD: git -C $HARNESS_REL sparse-checkout disable"
      else git -C "$HARNESS_ROOT" sparse-checkout disable; fi
    fi
  elif [[ -f "$CONSUMER_ROOT/.kit.json" ]]; then
    if [[ "$KIT_SPARSE" == "1" ]]; then
      pats=('/*' '!/stacks/*' '/stacks/*/stack.json')
      for s in $KIT_STACKS; do pats+=("/stacks/$s/"); done
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "WOULD: git -C $HARNESS_REL sparse-checkout set --no-cone ${pats[*]}"
      else
        # MSYS_NO_PATHCONV: в Git Bash паттерны вида /stacks/x/ иначе
        # превращаются в C:/Program Files/Git/stacks/x/ и прячут стек.
        MSYS_NO_PATHCONV=1 git -C "$HARNESS_ROOT" sparse-checkout set --no-cone "${pats[@]}"
      fi
    elif sparse_active; then
      if [[ "$DRY_RUN" == "1" ]]; then echo "WOULD: git -C $HARNESS_REL sparse-checkout disable"
      else git -C "$HARNESS_ROOT" sparse-checkout disable; fi
    fi
  fi
  if [[ "${KIT_LEGACY:-0}" == "1" && "$KIT_SPARSE" == "1" ]]; then
    echo "WARN: KIT_LEGACY=1 под sparse — режим ['*'] требует всех файлов;" >&2
    echo "      задайте \"sparse\": false или git -C $HARNESS_REL sparse-checkout disable" >&2
  fi

  # 3) apply
  lcmd=apply
  [[ "$DRY_RUN" == "1" ]] && lcmd=plan
  HARNESS_REL="$HARNESS_REL" "$PY" "$KIT_LAYOUT" "$lcmd" "$CONSUMER_ROOT"

  if [[ "$KIT_STACKS" == "*" || " $KIT_STACKS " == *" 1c "* ]]; then STACK_1C=1; fi
else
  echo "=== link-cc-1c-skills ==="
  bash "$SCRIPT_DIR/link-cc-1c-skills.sh" "$CONSUMER_ROOT" "$(kit_local_manifest_rel "$CONSUMER_ROOT" skills)"

  echo "=== link-cursor-overlay ==="
  bash "$SCRIPT_DIR/link-cursor-overlay.sh" "$CONSUMER_ROOT" "$(kit_local_manifest_rel "$CONSUMER_ROOT" overlay)"

  echo "=== link-kit-tools ==="
  bash "$SCRIPT_DIR/link-kit-tools.sh" "$CONSUMER_ROOT" "$(kit_local_manifest_rel "$CONSUMER_ROOT" tools)"

  echo "=== link-editor-roots ==="
  bash "$SCRIPT_DIR/link-editor-roots.sh" "$CONSUMER_ROOT"

  echo "=== link-pi-roots ==="
  HARNESS_REL="$HARNESS_REL" bash "$SCRIPT_DIR/link-pi-roots.sh" "$CONSUMER_ROOT"

  STACK_1C=1
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
ENGINE="$HARNESS_ROOT/stacks/1c/tools/load-changed-files/load-changed-files.sh"
THIN_MARKER='harness/stacks/1c/tools/load-changed-files/load-changed-files.sh'
OLD_THIN_MARKER='harness/tools/load-changed-files/load-changed-files.sh'

# Wrapper генерируем только при выбранном стеке 1c — иначе core-only потребители и другие
# стеки получили бы 1С-скрипт.
if [[ "$STACK_1C" == "1" && -f "$ENGINE" ]]; then
  needs_write=0
  if [[ -f "$WRAPPER" ]] && grep -qF "$THIN_MARKER" "$WRAPPER" 2>/dev/null; then
    : # уже thin и на новый путь
  elif [[ -f "$WRAPPER" ]] && grep -qF "$OLD_THIN_MARKER" "$WRAPPER" 2>/dev/null; then
    echo "upgrade thin load-changed-files.sh wrapper (stacks/1c path)"
    needs_write=1
  elif [[ -f "$WRAPPER" ]]; then
    if [[ "$FORCE_WRAPPER" == "1" ]]; then
      echo "FORCE thin load-changed-files.sh wrapper"
      needs_write=1
    else
      echo "WARN: load-changed-files.sh looks fat/legacy; pass FORCE_WRAPPER=1 to replace" >&2
    fi
  else
    echo "create thin load-changed-files.sh"
    needs_write=1
  fi
  if [[ "$needs_write" == "1" && "$DRY_RUN" != "1" ]]; then
    cat >"$WRAPPER" <<'EOF'
#!/bin/bash
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $BASH, не bash из PATH: голый `bash` может резолвиться в WSL-лаунчер
# (C:\Windows\system32\bash) — пути и localhost в WSL другие.
exec "$BASH" "${_ROOT}/harness/stacks/1c/tools/load-changed-files/load-changed-files.sh" "$@"
EOF
    chmod +x "$WRAPPER"
  fi
fi

if [[ "$SKIP_VERIFY" != "1" ]]; then
  if [[ -n "$PY" && -f "$KIT_LAYOUT" ]]; then
    echo "=== kit_layout verify ==="
    HARNESS_REL="$HARNESS_REL" "$PY" "$KIT_LAYOUT" verify "$CONSUMER_ROOT"
  else
    echo "WARN: no python on PATH — verify (kit_layout) пропущен" >&2
  fi
fi

if [[ "${SKIP_DEPS:-0}" != "1" ]]; then
  echo "=== init-kit-deps (check) ==="
  if ! bash "$SCRIPT_DIR/init-kit-deps.sh" "$CONSUMER_ROOT"; then
    echo "WARN host deps incomplete — harness/core/docs/ai/kit-host-deps.md (INSTALL=1). Links still done." >&2
  fi
fi

echo "bootstrap-kit: Done."
