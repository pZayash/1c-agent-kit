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
