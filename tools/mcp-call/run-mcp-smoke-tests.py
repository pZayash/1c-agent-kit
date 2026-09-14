#!/usr/bin/env python3
"""Smoke MCP после загрузки: общий канал, privileged, тест изоляции ПолныеПрава."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

TIMEOUT = 120


def _reconfigure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8")


def _load_urls() -> tuple[str, str, dict[str, str]]:
    for candidate in (Path.cwd() / ".cursor" / "mcp.json", Path.cwd() / ".mcp.json"):
        if not candidate.is_file():
            continue
        cfg = json.loads(candidate.read_text(encoding="utf-8"))
        srv = cfg["mcpServers"]["dev_dt"]
        base = srv["url"].rstrip("/").replace("/rpc", "")
        if "/hs/mcp-privileged" in base:
            base = base.replace("/hs/mcp-privileged", "/hs/mcp")
        priv = base.replace("/hs/mcp", "/hs/mcp-privileged")
        if Path("/.dockerenv").is_file():
            base = base.replace("127.0.0.1", "host.docker.internal")
            priv = priv.replace("127.0.0.1", "host.docker.internal")
        hdr = {str(k): str(v) for k, v in (srv.get("headers") or {}).items()}
        return base, priv, hdr
    raise FileNotFoundError(".cursor/mcp.json")


def _post(url: str, payload: dict, headers: dict[str, str]) -> tuple[int, dict | str]:
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
            return exc.code, json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError:
            return exc.code, raw


def _rpc(url: str, headers: dict[str, str], method: str, params: dict | None = None) -> tuple[int, dict | str]:
    return _post(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, headers)


def _tool_result(status: int, body: dict | str) -> tuple[bool, str]:
    if status != 200 or not isinstance(body, dict):
        return False, f"HTTP {status}: {body}"
    if "error" in body:
        return False, json.dumps(body["error"], ensure_ascii=False)[:800]
    result = body.get("result") or {}
    if result.get("isError"):
        return False, json.dumps(result, ensure_ascii=False)[:800]
    for part in result.get("content") or []:
        if part.get("type") == "text":
            return True, part.get("text", "")[:500]
    return True, json.dumps(result, ensure_ascii=False)[:300]


def _tool_names(status: int, body: dict | str) -> list[str]:
    if status != 200 or not isinstance(body, dict):
        return []
    tools = (body.get("result") or {}).get("tools") or []
    return [str(t.get("name", "")) for t in tools if t.get("name")]


def main() -> int:
    _reconfigure_stdio()
    base, priv, hdr = _load_urls()
    failed = 0

    print(f"general: {base}")
    print(f"privileged: {priv}\n")

    print("=== version_get (/mcp) ===")
    st, body = _rpc(base, hdr, "tools/call", {"name": "version_get", "arguments": {}})
    ok, txt = _tool_result(st, body)
    print(("OK" if ok else "FAIL"), txt)
    failed += 0 if ok else 1

    print("\n=== tools/list (/mcp) ===")
    st, body = _rpc(base, hdr, "tools/list")
    names = _tool_names(st, body)
    has_no_tx = "execute_code" in names
    cross = [n for n in names if n in ("ib_user_upsert", "execute_code_privileged", "access_group_create")]
    print(f"tools={len(names)} execute_code(no-tx)={has_no_tx} privileged_on_general={cross}")
    if has_no_tx or cross:
        print("FAIL: unexpected tools on /mcp")
        failed += 1
    else:
        print("OK")

    print("\n=== tools/list (/mcp-privileged) ===")
    st, body = _rpc(priv, hdr, "tools/list")
    if st == 403:
        body_s = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        print(f"OK HTTP 403 (нет mcp_Роль или HTTP Use): {body_s[:200]}")
    elif st == 200:
        pnames = _tool_names(st, body)
        print(f"OK HTTP 200, tools={pnames}")
    else:
        print(f"FAIL HTTP {st}: {body}")
        failed += 1

    print("\n=== Тест_MCP_ПолныеПраваНеИмеютДоступаКПривилегированным ===")
    code = "яя_тестыСервер.Тест_MCP_ПолныеПраваНеИмеютДоступаКПривилегированным();"
    st, body = _rpc(
        base,
        hdr,
        "tools/call",
        {"name": "execute_code_safe_transaction", "arguments": {"code": code}},
    )
    ok, txt = _tool_result(st, body)
    print(("OK" if ok else "FAIL"), txt)
    failed += 0 if ok else 1

    print("\n=== smoke-privileged (HTTP tools enabled) ===")
    st, body = _rpc(priv, hdr, "tools/list")
    pnames = _tool_names(st, body)
    if st != 200:
        print(f"SKIP (privileged list HTTP {st})")
    elif len(pnames) < 5:
        print(f"SKIP tools not enabled in registry: {pnames}")
    else:
        from pathlib import Path as P

        examples = P(__file__).resolve().parent / "examples"
        cases = [
            ("execute_code_privileged", "privileged-execute-code-args.json"),
            ("ib_user_upsert", "privileged-ib-user-upsert-args.json"),
        ]
        for tool, ex in cases:
            if tool not in pnames:
                print(f"SKIP {tool}")
                continue
            args = json.loads((examples / ex).read_text(encoding="utf-8"))
            st2, body2 = _rpc(priv, hdr, "tools/call", {"name": tool, "arguments": args})
            ok2, txt2 = _tool_result(st2, body2)
            print(f"{tool}: {'OK' if ok2 else 'FAIL'}", txt2[:200])
            failed += 0 if ok2 else 1

    print(f"\n=== failed={failed} ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
