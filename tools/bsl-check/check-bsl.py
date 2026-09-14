#!/usr/bin/env python3
"""Run bsl-language-server on selected BSL code for agents."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from collections import Counter
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlparse


# tools/bsl-check → parents[2] = repo root.
# harness/tools/bsl-check → parents[2] = harness, root is parents[3].
_p2 = Path(__file__).resolve().parents[2]
REPO_ROOT = _p2.parent if _p2.name == "harness" else _p2
TOOL_DIR = Path(__file__).resolve().parent
is_windows = platform.system() == "Windows"
CONFIG_PATH = TOOL_DIR / "bsl-language-server.json"


class BslCheckError(RuntimeError):
    """Expected user-facing failure."""


def sidecar_launcher() -> Path:
    if is_windows:
        return TOOL_DIR / "bsl-language-server.exe"
    return TOOL_DIR / "bsl-language-server-linux" / "bin" / "bsl-language-server"


DEFAULT_BSL_LS = sidecar_launcher()


def read_bslls_pin() -> str:
    version_file = TOOL_DIR / "BSLLS_VERSION"
    if not version_file.is_file():
        raise BslCheckError(f"Missing pin file: {version_file}")
    pin = version_file.read_text(encoding="utf-8").strip().lstrip("v")
    if not pin:
        raise BslCheckError(f"Empty pin file: {version_file}")
    return pin


def default_cache_root() -> Path:
    override = os.environ.get("KIT_BSLLS_ROOT", "").strip()
    if override:
        return Path(override)
    if is_windows:
        local = os.environ.get("LOCALAPPDATA", "").strip()
        if local:
            return Path(local) / "1c-agent-kit" / "bslls"
        return Path.home() / "AppData" / "Local" / "1c-agent-kit" / "bslls"
    xdg = os.environ.get("XDG_CACHE_HOME", "").strip()
    if xdg:
        return Path(xdg) / "1c-agent-kit" / "bslls"
    return Path.home() / ".cache" / "1c-agent-kit" / "bslls"


def cache_dir_for_pin(root: Path, pin: str) -> Path:
    return root / pin


def cache_launcher(root: Path, pin: str) -> Path:
    cache = cache_dir_for_pin(root, pin)
    if is_windows:
        return cache / "bsl-language-server.exe"
    return cache / "bsl-language-server-linux" / "bin" / "bsl-language-server"


def install_recipe(pin: str) -> str:
    return (
        f"BSLLS runtime missing (pin {pin}). "
        "Set KIT_BSLLS_ROOT if a shared host cache is required "
        r"(example on SRV01: D:\tools\bslls), then run once per host:"
        "\n  bash harness/tools/bsl-check/update-bsl-language-server.sh\n"
        "Do not pass --latest. Do not download into each worktree. "
        "See harness/tools/bsl-check/README.md"
    )


def explicit_launcher_arg(args_bsl_ls: str | None) -> str | None:
    if args_bsl_ls:
        return args_bsl_ls
    env = os.environ.get("BSL_LANGUAGE_SERVER", "").strip()
    return env or None


def resolve_bsl_ls(explicit: str | None) -> Path:
    pin = read_bslls_pin()
    if explicit:
        path = Path(explicit)
        if not path.exists():
            raise BslCheckError(
                f"bsl-language-server not found: {path}\n{install_recipe(pin)}",
            )
        return path
    cached = cache_launcher(default_cache_root(), pin)
    if cached.exists():
        return cached
    sidecar = sidecar_launcher()
    if sidecar.exists():
        return sidecar
    raise BslCheckError(install_recipe(pin))


REPORT_NAME = "bsl-json.json"
SEVERITY_ORDER = {
    "Error": 4,
    "Warning": 3,
    "Information": 2,
    "Hint": 1,
}


@dataclass(frozen=True)
class DiagnosticItem:
    path: str
    line: int
    column: int
    severity: str
    code: str
    message: str
    root: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check BSL code with local bsl-language-server.",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="BSL files to check. If omitted, changed .bsl files are checked.",
    )
    parser.add_argument(
        "--stdin",
        action="store_true",
        help="Read BSL source from stdin and check it as one temporary file.",
    )
    parser.add_argument(
        "--path",
        default="Module.bsl",
        help="Logical .bsl path for --stdin diagnostics, default: Module.bsl.",
    )
    parser.add_argument(
        "--min-severity",
        choices=("Error", "Warning", "Information", "Hint"),
        default="Warning",
        help="Minimum severity printed and used for exit code, default: Warning.",
    )
    parser.add_argument(
        "--bsl-ls",
        default=None,
        help="Path to bsl-language-server launcher. Env: BSL_LANGUAGE_SERVER.",
    )
    parser.add_argument(
        "--which",
        action="store_true",
        help="Print resolved launcher path and exit. Does not start BSLLS.",
    )
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Do not remove temporary analysis directory.",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="Output format. Default: text.",
    )
    parser.add_argument(
        "--max-diagnostics",
        type=int,
        default=200,
        help="Max diagnostics to print; 0 means all. Default: 200.",
    )
    parser.add_argument(
        "--summary",
        dest="summary",
        action="store_true",
        default=True,
        help="Print summary in text output (default: on).",
    )
    parser.add_argument(
        "--no-summary",
        dest="summary",
        action="store_false",
        help="Disable summary in text output.",
    )
    return parser.parse_args()


def run_git(args: list[str]) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def changed_bsl_files() -> list[Path]:
    tracked = run_git(
        ["diff", "--name-only", "--diff-filter=ACMR", "HEAD", "--", "*.bsl"],
    )
    untracked = run_git(["ls-files", "--others", "--exclude-standard", "--", "*.bsl"])
    seen: set[str] = set()
    files: list[Path] = []
    for item in [*tracked, *untracked]:
        normalized = item.replace("\\", "/")
        if normalized in seen:
            continue
        seen.add(normalized)
        files.append(REPO_ROOT / normalized)
    return files


def display_path(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def resolve_input_path(raw_path: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        path = REPO_ROOT / path
    return path


def safe_logical_path(raw_path: str) -> PurePosixPath:
    logical = PurePosixPath(raw_path.replace("\\", "/"))
    if logical.is_absolute() or ".." in logical.parts:
        raise BslCheckError("--path must be a relative path without '..'")
    if logical.suffix.lower() != ".bsl":
        raise BslCheckError("--path must point to a .bsl file")
    return logical


def file_path_from_uri(raw_path: str) -> Path:
    if raw_path.startswith("file:"):
        parsed = urlparse(raw_path)
        value = unquote(parsed.path)
        if len(value) >= 3 and value[0] == "/" and value[2] == ":":
            value = value[1:]
        return Path(value)
    return Path(raw_path)


def prepare_sources(args: argparse.Namespace, src_dir: Path) -> dict[Path, str]:
    mapping: dict[Path, str] = {}

    if args.stdin:
        if args.paths:
            raise BslCheckError("Use either --stdin or file paths, not both")
        logical = safe_logical_path(args.path)
        target = src_dir / Path(*logical.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(sys.stdin.buffer.read())
        mapping[target.resolve()] = logical.as_posix()
        return mapping

    source_files = [resolve_input_path(path) for path in args.paths] if args.paths else changed_bsl_files()
    bsl_files = [path for path in source_files if path.suffix.lower() == ".bsl"]

    if not bsl_files:
        return mapping

    for source in bsl_files:
        if not source.exists():
            raise BslCheckError(f"File not found: {display_path(source)}")
        relative = Path(display_path(source))
        target = src_dir / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        mapping[target.resolve()] = relative.as_posix()

    return mapping


def run_analyzer(args: argparse.Namespace, src_dir: Path, out_dir: Path) -> None:
    bsl_ls = resolve_bsl_ls(explicit_launcher_arg(args.bsl_ls))

    command = [
        str(bsl_ls),
        "analyze",
        "-s",
        str(src_dir),
        "-o",
        str(out_dir),
        "-r",
        "json",
        "-q",
    ]
    if CONFIG_PATH.exists():
        command.extend(["-c", str(CONFIG_PATH)])

    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        details = "\n".join(part for part in (result.stdout, result.stderr) if part.strip())
        raise BslCheckError(f"bsl-language-server failed with code {result.returncode}\n{details}")


def load_report(out_dir: Path) -> dict:
    report_path = out_dir / REPORT_NAME
    if not report_path.exists():
        raise BslCheckError(f"Analyzer report not found: {report_path}")
    return json.loads(report_path.read_text(encoding="utf-8-sig"))


SUSPECT_DASHES = {
    "\u2010",  # HYPHEN
    "\u2011",  # NON-BREAKING HYPHEN
    "\u2012",  # FIGURE DASH
    "\u2013",  # EN DASH
    "\u2014",  # EM DASH
    "\u2015",  # HORIZONTAL BAR
    "\u2212",  # MINUS SIGN
    "\u2043",  # HYPHEN BULLET
    "\uFE58",  # SMALL EM DASH
    "\uFE63",  # SMALL HYPHEN-MINUS
    "\uFF0D",  # FULLWIDTH HYPHEN-MINUS
}


def extract_invalid_char_hint(path: str, line: int) -> str:
    full_path = resolve_input_path(path)
    if not full_path.exists():
        return ""
    try:
        lines = full_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    if line < 1 or line > len(lines):
        return ""
    source_line = lines[line - 1]
    found: list[str] = []
    for index, symbol in enumerate(source_line, start=1):
        if symbol not in SUSPECT_DASHES:
            continue
        codepoint = f"U+{ord(symbol):04X}"
        try:
            symbol_name = unicodedata.name(symbol)
        except ValueError:
            symbol_name = "UNKNOWN"
        found.append(f'pos {index}: "{symbol}" ({codepoint}, {symbol_name})')
        if len(found) >= 5:
            break
    if not found:
        return ""
    return " [suspect dash-like chars: " + "; ".join(found) + "]"


def collect_diagnostics(report: dict, mapping: dict[Path, str], min_severity: str) -> list[DiagnosticItem]:
    min_level = SEVERITY_ORDER[min_severity]
    items: list[DiagnosticItem] = []

    for file_info in report.get("fileinfos", []):
        analyzed_path = file_path_from_uri(file_info.get("path", "")).resolve()
        shown_path = mapping.get(analyzed_path, display_path(analyzed_path))
        for diagnostic in file_info.get("diagnostics", []):
            severity = diagnostic.get("severity", "")
            if SEVERITY_ORDER.get(severity, 0) < min_level:
                continue
            start = diagnostic.get("range", {}).get("start", {})
            line = int(start.get("line", 0)) + 1
            col = int(start.get("character", 0)) + 1
            code = diagnostic.get("code", "Unknown")
            message = " ".join(str(diagnostic.get("message", "")).split())
            if code == "InvalidCharacterInFile":
                message += extract_invalid_char_hint(shown_path, line)
            root = shown_path.split("/", 1)[0] if "/" in shown_path else shown_path
            items.append(
                DiagnosticItem(
                    path=shown_path,
                    line=line,
                    column=col,
                    severity=severity,
                    code=code,
                    message=message,
                    root=root,
                ),
            )

    return sorted(
        items,
        key=lambda item: (
            -SEVERITY_ORDER.get(item.severity, 0),
            item.path,
            item.line,
            item.column,
            item.code,
        ),
    )


def build_summary(diagnostics: list[DiagnosticItem], files_checked: int) -> dict:
    severity_counts: Counter[str] = Counter(item.severity for item in diagnostics)
    rule_counts: Counter[str] = Counter(item.code for item in diagnostics)
    root_counts: Counter[str] = Counter(item.root for item in diagnostics)
    files_with_diagnostics = len({item.path for item in diagnostics})
    return {
        "status": "FAILED" if diagnostics else "OK",
        "files_checked": files_checked,
        "files_with_diagnostics": files_with_diagnostics,
        "severity": {
            "Error": severity_counts.get("Error", 0),
            "Warning": severity_counts.get("Warning", 0),
            "Information": severity_counts.get("Information", 0),
            "Hint": severity_counts.get("Hint", 0),
        },
        "top_rules": dict(rule_counts.most_common(10)),
        "roots": dict(root_counts.most_common()),
        "total_diagnostics": len(diagnostics),
    }


def format_text_diagnostic(item: DiagnosticItem) -> str:
    return f"{item.path}:{item.line}:{item.column} {item.severity} {item.code}: {item.message}"


def print_text_output(
    diagnostics: list[DiagnosticItem],
    files_checked: int,
    min_severity: str,
    max_diagnostics: int,
    show_summary: bool,
) -> None:
    visible = diagnostics if max_diagnostics == 0 else diagnostics[:max_diagnostics]
    for item in visible:
        print(format_text_diagnostic(item))

    if max_diagnostics > 0 and len(diagnostics) > max_diagnostics:
        print(
            f"Showing first {len(visible)} of {len(diagnostics)} diagnostics. "
            "Re-run with --max-diagnostics 0 to show all.",
        )

    if show_summary:
        summary = build_summary(diagnostics, files_checked)
        print(f"BSL check: {summary['status']}")
        print(f"Files checked: {summary['files_checked']}")
        print(f"Files with diagnostics: {summary['files_with_diagnostics']}")
        print(f"Errors: {summary['severity']['Error']}")
        print(f"Warnings: {summary['severity']['Warning']}")
        if summary["top_rules"]:
            top_rules_text = ", ".join(f"{key}={value}" for key, value in summary["top_rules"].items())
            print(f"Top rules: {top_rules_text}")
        if summary["roots"]:
            roots_text = ", ".join(f"{key}={value}" for key, value in summary["roots"].items())
            print(f"Roots: {roots_text}")
    else:
        print(f"BSL check: FAILED ({len(diagnostics)} diagnostics, min severity: {min_severity})")


def print_json_output(
    diagnostics: list[DiagnosticItem],
    files_checked: int,
    temp_directory: str | None = None,
) -> None:
    summary = build_summary(diagnostics, files_checked)
    payload = {
        "summary": summary,
        "diagnostics": [
            {
                "path": item.path,
                "line": item.line,
                "column": item.column,
                "severity": item.severity,
                "code": item.code,
                "message": item.message,
                "root": item.root,
            }
            for item in diagnostics
        ],
    }
    if temp_directory:
        payload["temp_directory"] = temp_directory
    print(json.dumps(payload, ensure_ascii=False))


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")

    args = parse_args()
    if args.which:
        try:
            print(resolve_bsl_ls(explicit_launcher_arg(args.bsl_ls)))
            return 0
        except BslCheckError as error:
            print(f"BSL check error: {error}", file=sys.stderr)
            return 2

    tmp_dir = Path(tempfile.mkdtemp(prefix="bsl-check-"))

    try:
        src_dir = tmp_dir / "src"
        out_dir = tmp_dir / "out"
        src_dir.mkdir()
        out_dir.mkdir()

        mapping = prepare_sources(args, src_dir)
        if not mapping:
            print("BSL check: no .bsl files to analyze")
            return 0

        run_analyzer(args, src_dir, out_dir)
        diagnostics = collect_diagnostics(load_report(out_dir), mapping, args.min_severity)
        temp_directory = str(tmp_dir) if args.keep_temp else None

        if args.keep_temp and args.format != "json":
            print(f"Temp directory: {tmp_dir}")

        if diagnostics:
            if args.format == "json":
                print_json_output(diagnostics, len(mapping), temp_directory=temp_directory)
            else:
                print_text_output(
                    diagnostics=diagnostics,
                    files_checked=len(mapping),
                    min_severity=args.min_severity,
                    max_diagnostics=max(0, args.max_diagnostics),
                    show_summary=args.summary,
                )
            return 1

        if args.format == "json":
            print_json_output(diagnostics, len(mapping), temp_directory=temp_directory)
            return 0

        print(f"BSL check: OK ({len(mapping)} file(s), min severity: {args.min_severity})")
        return 0

    except BslCheckError as error:
        print(f"BSL check error: {error}", file=sys.stderr)
        return 2
    finally:
        if not args.keep_temp:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
