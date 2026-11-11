#!/usr/bin/env python3
"""Свежесть answer42: установленная версия, последняя на PyPI, вердикт.

Запускать интерпретатором того venv, где установлен answer42: importlib.metadata
видит дистрибутив своего окружения, поэтому проверка не зависит от того, какой
именно бинарь прописан в ANSWER42_BIN.

Вывод (строки key: value):

    installed: 0.5.3
    latest: 0.5.13
    channel: pypi | editable | local
    verdict: ok | outdated | unknown
    reason: ...          # только при verdict=unknown

Код возврата: 0 — актуально, 1 — есть новее, 2 — не удалось определить
(нет пакета в этом интерпретаторе, нет сети, битый PyPI-ответ).
`--json` — тот же результат одной строкой JSON.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from importlib.metadata import PackageNotFoundError, distribution, version

DEFAULT_PYPI_URL = "https://pypi.org/pypi/{name}/json"


def _version_key(value: str) -> tuple[int, ...]:
    """Грубый semver-ключ: 0.5.13 > 0.5.9; суффиксы (rc1/dev) игнорируются."""
    parts: list[int] = []
    for chunk in str(value or "").split("."):
        digits = "".join(ch for ch in chunk if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)


def _channel(dist_name: str) -> str:
    """pypi | editable | local — по direct_url.json из метаданных дистрибутива."""
    try:
        raw = distribution(dist_name).read_text("direct_url.json")
    except Exception:  # noqa: BLE001 - диагностика не должна падать
        return "pypi"
    if not raw:
        return "pypi"
    try:
        data = json.loads(raw)
    except Exception:  # noqa: BLE001
        return "pypi"
    if data.get("dir_info", {}).get("editable"):
        return "editable"
    if str(data.get("url", "")).startswith("file:"):
        return "local"
    return "pypi"


def _latest(dist_name: str, url_template: str, timeout: float) -> str:
    url = url_template.format(name=dist_name)
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return str(json.load(response)["info"]["version"])


def _force_utf8_stdout() -> None:
    """Windows: python в pipe пишет cp1251 — кириллица в reason превращается в мусор.

    Штатные вызывающие (answer42.sh/.ps1, kit-doctor) читают stdout как UTF-8.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass


def main(argv: list[str] | None = None) -> int:
    _force_utf8_stdout()
    parser = argparse.ArgumentParser(description="Проверка свежести пакета answer42")
    parser.add_argument("--dist", default="answer42", help="имя дистрибутива (по умолчанию answer42)")
    parser.add_argument("--pypi-url", default=DEFAULT_PYPI_URL, help="шаблон JSON-эндпоинта PyPI")
    parser.add_argument("--timeout", type=float, default=5.0, help="таймаут запроса к PyPI, с")
    parser.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    args = parser.parse_args(argv)

    installed = ""
    latest = ""
    reason = ""
    try:
        installed = version(args.dist)
    except PackageNotFoundError:
        reason = f"пакет {args.dist} не установлен в этом интерпретаторе"
    except Exception as exc:  # noqa: BLE001
        reason = f"не удалось прочитать метаданные: {exc}"

    if installed:
        try:
            latest = _latest(args.dist, args.pypi_url, args.timeout)
        except Exception as exc:  # noqa: BLE001
            reason = f"PyPI недоступен: {exc}"

    if installed and latest:
        verdict = "outdated" if _version_key(latest) > _version_key(installed) else "ok"
    else:
        verdict = "unknown"

    result = {
        "installed": installed or "?",
        "latest": latest or "?",
        "channel": _channel(args.dist) if installed else "unknown",
        "verdict": verdict,
    }
    if verdict == "unknown" and reason:
        result["reason"] = reason

    if args.json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        for key in ("installed", "latest", "channel", "verdict", "reason"):
            if key in result:
                print(f"{key}: {result[key]}")

    return {"ok": 0, "outdated": 1}.get(verdict, 2)


if __name__ == "__main__":
    sys.exit(main())
