#!/usr/bin/env bash
# Скачивает bsl-language-server (BSLLS) с GitHub releases рядом со скриптом.
# Windows: bsl-language-server.exe + app/ + runtime/
# Linux (Docker sandbox / agent-container): bsl-language-server-linux/
#
# Бинарник НЕ в git. На новом хосте / после смены пина:
#   bash tools/bsl-check/update-bsl-language-server.sh
# Бамп пина (этот хост, потом commit BSLLS_VERSION в kit):
#   bash tools/bsl-check/update-bsl-language-server.sh --version 1.1.0-rc.3
#   bash tools/bsl-check/update-bsl-language-server.sh --latest   # GitHub Latest = stable, не RC
#
# Хост, не sandbox: нужны unzip + (gh или curl), сеть GitHub.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_DIR="${SCRIPT_DIR}"
VERSION_FILE="${TARGET_DIR}/BSLLS_VERSION"
LINUX_DIR="bsl-language-server-linux"
GITHUB_REPO="1c-syntax/bsl-language-server"

VERSION=""
USE_LATEST=0

usage() {
    cat <<'EOF'
Download bsl-language-server into tools/bsl-check/ (next to this script).

Binary is NOT in git. Other hosts: pull the pin (BSLLS_VERSION), then run
this script with NO flags. Do not commit exe/app/runtime/linux tree.

Options:
  (none)                  Download version from BSLLS_VERSION
  --version, -v VERSION   Bump pin to this tag (no leading v). Use for RC.
  --latest                GitHub Latest (= stable). Ignores pin. Skips pre-release.
  --help, -h              Show help

Need: unzip, gh or curl, GitHub network. Run on the host, not via sandbox/run.sh.
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

echo "Done. Pin: ${VERSION_FILE} = ${VERSION}"
echo "Other hosts: pull this pin, then run the same script with NO flags (not --latest)."
echo "Do not commit exe/app/runtime/${LINUX_DIR}."
echo "Smoke (host): bash tools/sandbox/run.sh python tools/bsl-check/check-bsl.py --min-severity Error <file.bsl>"
echo "Agent-slot image copies linux tree at docker build — rebuild slots after bump."
