#!/usr/bin/env python3
"""UNF-KPSR: lint Rights.xml — только правоносные виды объектов.

Платформа не имеет прав на Enum, XDTOPackage, Subsystem-не-правоносные виды и
прочие «не-данные» объекты. Агентская правка Rights.xml с <name>Enum.X</name>
кладёт LoadConfigFromFiles (зависание/ошибка загрузки) — 08.10.2026 роль
яя_БазовыеПрава получила права на Enum.яя_ВидФранкировки/Enum.яя_КатегорияФранкировки.

Usage:
    bash tools/sandbox/run.sh python tools/rights-xml-lint/check.py <path> [...]

Exit: 0 OK, 1 есть проблемы, 2 usage error.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Корень для относительных путей. После переезда kit на слои скрипт живёт в
# `harness/stacks/1c/tools/rights-xml-lint`, поэтому `parents[2]` — это сам kit,
# а не репозиторий потребителя (пути вида `cfe.xml/...` резолвились в
# `harness/stacks/1c/cfe.xml/...` → «not found»). Порядок: cwd потребителя →
# legacy-глубина (parents[2]) → новая глубина (parents[3]).
_HERE = Path(__file__).resolve()
_BASES = (Path.cwd(), _HERE.parents[2], _HERE.parents[3])


def _resolve(raw: str) -> Path:
    p = Path(raw)
    if p.is_absolute():
        return p
    for base in _BASES:
        candidate = base / p
        if candidate.exists():
            return candidate
    return _BASES[0] / p

# Виды метаданных, на которые платформа допускает права (8.3).
# Собрано по правилам платформы + сверено со всеми Rights.xml УНФ (26 видов
# встречаются фактически; Sequence/CalculationRegister/SettingsStorage — валидны,
# просто отсутствуют в конфигурации).
RIGHTS_KINDS = frozenset(
    """
    Configuration
    Constant Sequence DocumentJournal
    Catalog Document ChartOfAccounts ChartOfCharacteristicTypes
    ChartOfCalculationTypes
    InformationRegister AccumulationRegister AccountingRegister
    CalculationRegister
    BusinessProcess Task ExchangePlan ExternalDataSource
    Report DataProcessor SettingsStorage
    CommonAttribute CommonCommand CommonForm SessionParameter FilterCriterion
    Subsystem WebService HTTPService IntegrationService
    """.split()
)

# <object><name>Kind.Имя[.Child...]</name>; прав с точкой в имени не бывает —
# требование точки отсекает <right><name>Read</name>.
OBJECT_NAME_RE = re.compile(r"<name>([A-Za-z][A-Za-z0-9_]*)\.[^<\s]+</name>")


def scan_file(path: Path) -> list[str]:
    issues: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError as exc:
        return [f"не прочитан: {exc}"]
    for lineno, line in enumerate(lines, 1):
        for match in OBJECT_NAME_RE.finditer(line):
            kind = match.group(1)
            if kind not in RIGHTS_KINDS:
                issues.append(
                    f"строка {lineno}: объект '{match.group(0)[6:-7]}' — "
                    f"вид '{kind}' не имеет прав в платформе "
                    f"(Enum, XDTOPackage и др. ломают LoadConfigFromFiles)"
                )
    return issues


def main() -> int:
    ap = argparse.ArgumentParser(description="Rights.xml kinds lint (UNF-KPSR)")
    ap.add_argument("paths", nargs="+", help="Rights.xml files or directories")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    files: list[Path] = []
    for raw in args.paths:
        p = _resolve(raw)
        if p.is_dir():
            files.extend(sorted(p.rglob("Rights.xml")))
        elif p.is_file():
            files.append(p)
        else:
            print(f"{p}: not found", file=sys.stderr)
            return 2

    if not files:
        print("no files", file=sys.stderr)
        return 2

    failed = False
    for f in files:
        issues = scan_file(f)
        if issues:
            failed = True
            print(f"{f}:")
            for issue in issues:
                print(f"  [ERROR] {issue}")
        elif not args.quiet:
            print(f"{f}: OK")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
