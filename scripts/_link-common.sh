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
