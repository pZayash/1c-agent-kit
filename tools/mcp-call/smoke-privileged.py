#!/usr/bin/env python3
"""Smoke всех privileged MCP tools через /hs/mcp-privileged (JWT из .cursor/mcp.json)."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

PRIVILEGED_TOOLS = [
    ("execute_code_privileged", "privileged-execute-code-args.json", "mcp_Инструмент_яя_ВыполнениеКодаПривилегированное"),
    ("ib_user_upsert", "privileged-ib-user-upsert-args.json", "mcp_Инструмент_яя_ПользовательИБ"),
    ("access_group_create", "privileged-access-group-create-args.json", "mcp_Инструмент_яя_ГруппаДоступаСоздать"),
    (
        "access_group_upsert_member",
        "privileged-access-group-upsert-member-args.json",
        "mcp_Инструмент_яя_ГруппаДоступаДобавитьУчастника",
    ),
    ("access_keys_refresh", "privileged-access-keys-refresh-args.json", "mcp_Инструмент_яя_КлючиДоступаОбновить"),
]

GENERAL_URL_KEY = "dev_dt"
EXAMPLES_DIR = Path(__file__).resolve().parent / "examples"
TIMEOUT = 120


def _reconfigure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8")


def _load_config() -> tuple[str, dict[str, str], str]:
    for candidate in (Path.cwd() / ".cursor" / "mcp.json", Path.cwd() / ".mcp.json"):
        if candidate.is_file():
            cfg = json.loads(candidate.read_text(encoding="utf-8"))
            srv = cfg["mcpServers"][GENERAL_URL_KEY]
            base = srv["url"].rstrip("/").replace("/rpc", "").replace("/hs/mcp", "/hs/mcp-privileged")
            if Path("/.dockerenv").is_file():
                base = base.replace("127.0.0.1", "host.docker.internal")
            return base, {str(k): str(v) for k, v in (srv.get("headers") or {}).items()}, str(candidate)
    raise FileNotFoundError("Не найден .cursor/mcp.json")


def _post_json(url: str, payload: dict, headers: dict[str, str]) -> tuple[int, dict | str]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    h = {
        "Content-Type": "application/json; charset=utf-8",
        "Accept": "application/json",
        **headers,
    }
    req = urllib.request.Request(url, data=body, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace") if exc.fp else exc.reason
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw


def _rpc(base: str, headers: dict[str, str], method: str, params: dict | None = None) -> tuple[int, dict | str]:
    return _post_json(base, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, headers)


def _tools_call(base: str, headers: dict[str, str], name: str, arguments: dict) -> tuple[int, dict | str]:
    return _rpc(
        base,
        headers,
        "tools/call",
        {"name": name, "arguments": arguments},
    )


def _general_rpc(method: str, params: dict) -> tuple[int, dict | str]:
    for candidate in (Path.cwd() / ".cursor" / "mcp.json", Path.cwd() / ".mcp.json"):
        if not candidate.is_file():
            continue
        cfg = json.loads(candidate.read_text(encoding="utf-8"))
        srv = cfg["mcpServers"][GENERAL_URL_KEY]
        url = srv["url"].rstrip("/")
        if not url.endswith("/rpc"):
            url += "/rpc"
        if Path("/.dockerenv").is_file():
            url = url.replace("127.0.0.1", "host.docker.internal")
        hdr = {str(k): str(v) for k, v in (srv.get("headers") or {}).items()}
        return _rpc(url, hdr, method, params)
    raise FileNotFoundError("mcp.json")


def _bsl_escape_json(payload: dict) -> str:
    """Строка JSON для литерала 1С (удвоение кавычек)."""
    raw = json.dumps(payload, ensure_ascii=False)
    return raw.replace('"', '""')


def _impl_call(tool_name: str, processor: str, args: dict) -> tuple[bool, str]:
    """Прямой вызов ManagerModule (без guard/registry), откат транзакции safe_transaction."""
    json_bsl = _bsl_escape_json(args)
    code = (
        f'Аргументы = mcp_ОбщегоНазначения.JSONВСтруктуру("{json_bsl}"); '
        f"Результат = mcp_ОбщегоНазначения.ПривестиЗначениеКJSON("
        f'Обработки.{processor}.ВыполнитьИнструмент("{tool_name}", Аргументы));'
    )
    status, body = _general_rpc(
        "tools/call",
        {"name": "execute_code_safe_transaction", "arguments": {"code": code}},
    )
    if status != 200 or not isinstance(body, dict):
        return False, f"HTTP {status}: {body}"
    if "error" in body:
        return False, json.dumps(body["error"], ensure_ascii=False)[:1500]
    ok, text = _extract_call_result(body)
    return ok, text


def _tool_names_from_list(body: dict) -> list[str]:
    tools = (body.get("result") or {}).get("tools") or []
    return [t.get("name", "") for t in tools if t.get("name")]


def _extract_call_result(body: dict) -> tuple[bool, str]:
    if "error" in body:
        err = body["error"]
        return False, json.dumps(err, ensure_ascii=False)[:1500]
    result = body.get("result") or {}
    if result.get("isError"):
        return False, json.dumps(result, ensure_ascii=False)[:1500]
    content = result.get("content") or []
    for part in content:
        if part.get("type") == "text":
            return True, part.get("text", "")[:2000]
    return True, json.dumps(result, ensure_ascii=False)[:1500]


def main() -> int:
    _reconfigure_stdio()
    base, headers, cfg_path = _load_config()
    print(f"config: {cfg_path}")
    print(f"privileged URL: {base}")

    code, body = _rpc(base, headers, "tools/list")
    if code != 200:
        print(f"tools/list HTTP {code}: {body}")
        return 1
    if isinstance(body, dict) and "error" in body:
        print(f"tools/list error: {body['error']}")
        return 1

    names = _tool_names_from_list(body) if isinstance(body, dict) else []
    print(f"tools/list: {len(names)} enabled -> {names}")

    use_http = len(names) >= len(PRIVILEGED_TOOLS)
    if not use_http:
        print(
            "HTTP: tools не включены в регистре — нужны mcp_УправлениеСервером "
            "+ «Разрешить здесь». Пока impl-smoke (ManagerModule, rollback tx)."
        )

    failed = 0
    for tool_name, example_file, processor in PRIVILEGED_TOOLS:
        args_path = EXAMPLES_DIR / example_file
        args = json.loads(args_path.read_text(encoding="utf-8"))
        print(f"\n--- {tool_name} ---")

        if use_http and tool_name in names:
            status, resp = _tools_call(base, headers, tool_name, args)
            if status != 200:
                print(f"FAIL HTTP {status}: {resp}")
                failed += 1
                continue
            if not isinstance(resp, dict):
                print(f"FAIL non-JSON: {resp}")
                failed += 1
                continue
            ok, text = _extract_call_result(resp)
            label = "OK HTTP"
        else:
            ok, text = _impl_call(tool_name, processor, args)
            label = "OK impl"

        if ok:
            print(f"{label}: {text}")
        else:
            print(f"FAIL: {text}")
            failed += 1

    mode = "HTTP" if use_http else "impl"
    print(f"\n=== {mode}: {len(PRIVILEGED_TOOLS) - failed}/{len(PRIVILEGED_TOOLS)} passed ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
