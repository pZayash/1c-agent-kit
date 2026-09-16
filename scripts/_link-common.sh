# Shared bash helpers for kit link scripts (Linux / native).
# shellcheck shell=bash
# Source: # shellcheck source=./_link-common.sh
#          source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_link-common.sh"

kit_is_windows() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# WSL-bash (Linux userland под Windows).
kit_is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
  [[ -r /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null && return 0
  return 1
}

# WSL-bash + проект на Windows-диске (/mnt/<drive>/...): Linux-ветка создаст
# symlink'и на /mnt/..., невидимые из Windows-инструментов. Такой запуск
# опасен — нужен Windows Git Bash или .ps1 (bootstrap-kit это проверяет).
kit_wsl_windows_fs() {
  local root="$1"
  kit_is_wsl || return 1
  [[ "$root" == /mnt/[a-zA-Z]/* || "$root" == /mnt/[a-zA-Z] ]]
}

kit_load_manifest() {
  # $1=file $2=nameref assoc array
  local manifest_file="$1"
  local -n _out="$2"
  [[ -f "$manifest_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -n "$line" ]] || continue
    _out["$line"]=1
  done < "$manifest_file"
}

kit_ensure_link_slot() {
  local link_path="$1"
  if [[ -e "$link_path" || -L "$link_path" ]]; then
    if [[ -L "$link_path" ]]; then
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "rm -f \"$link_path\""
      else
        rm -f "$link_path"
      fi
    else
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "rm -rf \"$link_path\""
      else
        rm -rf "$link_path"
      fi
    fi
  fi
}

kit_ln_sfn() {
  local target="$1"
  local link_path="$2"
  kit_ensure_link_slot "$link_path"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "ln -sfn \"$target\" \"$link_path\""
  else
    ln -sfn "$target" "$link_path"
  fi
  echo "LINK: $(basename "$link_path")"
}

# File fallback chain when a symlink is not available: hardlink (same volume,
# no privilege), then copy. Linux symlinks rarely fail, but this keeps parity
# with the Windows/engine path and documents the policy.
kit_ln_file_fallback() {
  local target="$1"
  local link_path="$2"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "WOULD FILELINK: $link_path -> $target"
    return 0
  fi
  if ln -f "$target" "$link_path" 2>/dev/null; then
    echo "HARDLINK: $(basename "$link_path")"
  else
    cp -f "$target" "$link_path"
    echo "COPY: $(basename "$link_path")"
  fi
}

# Regenerate a kit-managed .gitignore block (one marker id per link script) so
# kit links/fallbacks do not show up as untracked paths in the consumer repo.
# $1=consumer root $2=id; remaining args = consumer-rel managed paths.
kit_update_gitignore() {
  local root="$1" id="$2"; shift 2
  local gi="$root/.gitignore"
  local begin="# >>> kit-managed: $id (bootstrap-kit) >>>"
  local end="# <<< kit-managed: $id <<<"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  local kept
  kept="$(mktemp)"
  if [[ -f "$gi" ]]; then
    local skip=0 line s
    while IFS= read -r line || [[ -n "$line" ]]; do
      s="${line#"${line%%[![:space:]]*}"}"
      s="${s%"${s##*[![:space:]]}"}"
      if [[ "$s" == "$begin" ]]; then skip=1; continue; fi
      if [[ "$s" == "$end" ]]; then skip=0; continue; fi
      [[ "$skip" == "1" ]] && continue
      printf '%s\n' "$line" >> "$kept"
    done < "$gi"
  fi
  {
    awk '
      { a[n++] = $0 }
      END {
        last = -1
        for (i = 0; i < n; i++) if (a[i] ~ /[^[:space:]]/) last = i
        for (i = 0; i <= last; i++) print a[i]
      }' "$kept"
    if grep -q '[^[:space:]]' "$kept" 2>/dev/null; then echo; fi
    echo "$begin"
    printf '%s\n' "$@" | sed 's#\\#/#g' | sed 's#^#/#' | LC_ALL=C sort -u
    echo "/tools/cc-1c-skills-sync/kit-fallback.txt"
    echo "$end"
  } > "$gi"
  rm -f "$kept"
}

# Tombstones (idea: teamai .removed) — prune stale kit-owned links.
# Removes symlinks in $1 (link_root) that point into $2 (kit_source) but whose
# basename no longer exists in kit_source (skill/tool removed or renamed upstream).
# Only kit-owned symlinks are touched: local copies and foreign links stay.
# $3 = nameref to assoc array of local names to skip (pass an empty one if none).
kit_prune_stale_links() {
  local link_root="$1"
  local kit_source="$2"
  local -n _kpl_local="$3"
  [[ -d "$link_root" ]] || return 0
  local entry name target
  for entry in "$link_root"/*; do
    [[ -L "$entry" ]] || continue
    name="$(basename "$entry")"
    [[ -n "${_kpl_local[$name]:-}" ]] && continue
    target="$(readlink "$entry")" || continue
    case "$target" in
      "$kit_source"/*|"$kit_source") ;;
      *) continue ;;
    esac
    if [[ ! -e "$kit_source/$name" ]]; then
      if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "WOULD PRUNE: $name"
      else
        rm -f "$entry"
        echo "PRUNE: $name"
      fi
    fi
  done
}
