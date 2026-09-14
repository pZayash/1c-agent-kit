#!/usr/bin/env bash
# Скачивает bsl-language-server (BSLLS) в кэш хоста, не в worktree.
# Windows: bsl-language-server.exe + app/ + runtime/
# Linux (Docker sandbox / agent-container): bsl-language-server-linux/
#
# Бинарник НЕ в git. Kit / bootstrap этот скрипт НЕ вызывает.
# Один раз на (хост × пин):
#   bash harness/tools/bsl-check/update-bsl-language-server.sh
# Общий корень (пример SRV01):
#   KIT_BSLLS_ROOT=D:/tools/bslls bash harness/tools/bsl-check/update-bsl-language-server.sh
# Sidecar (слот-сборка / аварийно):
#   bash harness/tools/bsl-check/update-bsl-language-server.sh --local
# Бамп пина (этот хост, потом commit BSLLS_VERSION в kit):
#   bash harness/tools/bsl-check/update-bsl-language-server.sh --version 1.1.0-rc.3
#   bash harness/tools/bsl-check/update-bsl-language-server.sh --latest
#
# Хост, не sandbox: нужны unzip + (gh или curl), сеть GitHub.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERSION_FILE="${SCRIPT_DIR}/BSLLS_VERSION"
LINUX_DIR="bsl-language-server-linux"
GITHUB_REPO="1c-syntax/bsl-language-server"

VERSION=""
USE_LATEST=0
USE_LOCAL=0

bslls_default_cache_root() {
    if [[ -n "${KIT_BSLLS_ROOT:-}" ]]; then
        printf '%s\n' "${KIT_BSLLS_ROOT}"
        return
    fi
    if [[ -n "${LOCALAPPDATA:-}" ]]; then
        printf '%s\n' "${LOCALAPPDATA}/1c-agent-kit/bslls"
        return
    fi
    printf '%s\n' "${HOME}/.cache/1c-agent-kit/bslls"
}

usage() {
    cat <<'EOF'
Download bsl-language-server into the host cache (not the worktree).

Default: $KIT_BSLLS_ROOT/<pin>/  or  %LOCALAPPDATA%/1c-agent-kit/bslls/<pin>
         (Linux: ~/.cache/1c-agent-kit/bslls/<pin>)
Binary is NOT in git. bootstrap-kit does not run this script.
Other hosts: pull the pin (BSLLS_VERSION), then run with NO flags.
Do not commit exe/app/runtime/linux tree. Do not pass --latest to "install
like everyone else".

Options:
  (none)                  Download version from BSLLS_VERSION into the cache
  --local                 Install next to this script (sidecar; slot build)
  --version, -v VERSION   Bump pin to this tag (no leading v). Use for RC.
  --latest                GitHub Latest (= stable). Ignores pin. Skips pre-release.
  --help, -h              Show help

Need: unzip, gh or curl, GitHub network. Run on the host, not via sandbox/run.sh.
Env: KIT_BSLLS_ROOT — shared cache root (example 42: D:\tools\bslls).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v)
            VERSION="${2#v}"
            shift 2
            ;;
        --latest)
            USE_LATEST=1
            shift
            ;;
        --local)
            USE_LOCAL=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! command -v unzip >/dev/null 2>&1; then
    echo "Need unzip on PATH (Git for Windows / apt unzip)" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    echo "Need gh or curl on PATH" >&2
    exit 2
fi

if [[ "$USE_LATEST" -eq 1 ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "gh is required for --latest" >&2
        exit 2
    fi
    VERSION="$(gh release view --repo "${GITHUB_REPO}" --json tagName -q '.tagName' | sed 's/^v//')"
elif [[ -z "$VERSION" ]]; then
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "Missing ${VERSION_FILE}; pass --version or --latest" >&2
        exit 2
    fi
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE" | sed 's/^v//')"
fi

if [[ -z "$VERSION" ]]; then
    echo "Failed to resolve BSLLS version" >&2
    exit 2
fi

if [[ "$USE_LOCAL" -eq 1 ]]; then
    TARGET_DIR="${SCRIPT_DIR}"
else
    TARGET_DIR="$(bslls_default_cache_root)/${VERSION}"
fi
mkdir -p "$TARGET_DIR"

TAG="v${VERSION}"
WIN_ZIP="bsl-language-server_win.zip"
NIX_ZIP="bsl-language-server_nix.zip"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bslls-update.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

download_release() {
    local pattern="$1"
    local dest="$2"
    if command -v gh >/dev/null 2>&1; then
        gh release download "$TAG" --repo "${GITHUB_REPO}" --pattern "$pattern" --dir "$dest"
        return
    fi
    local url="https://github.com/${GITHUB_REPO}/releases/download/${TAG}/${pattern}"
    curl -fsSL -o "${dest}/${pattern}" "$url"
}

echo "BSLLS update: ${TAG} -> ${TARGET_DIR}"

download_release "$WIN_ZIP" "$TMP_DIR"
download_release "$NIX_ZIP" "$TMP_DIR"

unzip -q "${TMP_DIR}/${WIN_ZIP}" -d "${TMP_DIR}/win"
unzip -q "${TMP_DIR}/${NIX_ZIP}" -d "${TMP_DIR}/nix"

WIN_ROOT="${TMP_DIR}/win/bsl-language-server"
NIX_ROOT="${TMP_DIR}/nix/bsl-language-server"

for required in "$WIN_ROOT/bsl-language-server.exe" "$WIN_ROOT/app" "$WIN_ROOT/runtime" \
    "$NIX_ROOT/bin/bsl-language-server"; do
    if [[ ! -e "$required" ]]; then
        echo "Unexpected archive layout, missing: $required" >&2
        exit 2
    fi
done

rm -rf "${TARGET_DIR}/app" "${TARGET_DIR}/runtime" "${TARGET_DIR}/${LINUX_DIR}"
cp -a "${WIN_ROOT}/bsl-language-server.exe" "${TARGET_DIR}/"
cp -a "${WIN_ROOT}/app" "${WIN_ROOT}/runtime" "${TARGET_DIR}/"
cp -a "${NIX_ROOT}" "${TARGET_DIR}/${LINUX_DIR}"
# NTFS unzip often drops +x; Linux sandbox/slot need the launcher and JRE
chmod +x "${TARGET_DIR}/${LINUX_DIR}/bin/bsl-language-server" 2>/dev/null || true
find "${TARGET_DIR}/${LINUX_DIR}" \( -name java -o -name 'bsl-language-server' \) -exec chmod +x {} + 2>/dev/null || true

printf '%s\n' "$VERSION" > "$VERSION_FILE"

if [[ -f "${TARGET_DIR}/bsl-language-server.exe" ]]; then
    echo -n "Windows: "
    "${TARGET_DIR}/bsl-language-server.exe" --version 2>/dev/null | tail -1 || echo "(exe --version failed)"
fi

echo "Done. Cache: ${TARGET_DIR}"
echo "Pin file (git): ${VERSION_FILE} = ${VERSION}"
echo "Other hosts: pull this pin, then run the same script with NO flags (not --latest)."
echo "Do not commit exe/app/runtime/${LINUX_DIR}."
echo "Smoke: python harness/tools/bsl-check/check-bsl.py --which"
echo "        python harness/tools/bsl-check/check-bsl.py --min-severity Error <file.bsl>"
echo "Agent-slot image copies linux tree at docker build — rebuild slots after bump."
echo "Sidecar install: pass --local (slot image / emergency). New installs: cache, not worktree."
