#!/usr/bin/env python3
"""Smoke всех MCP-серверов из .cursor/mcp.json / .mcp.json (подключённые в Cursor)."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

TIMEOUT = 120
MCP_PROTOCOL = "2025-03-26"


def _reconfigure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8")


def _find_config() -> Path:
    for candidate in (Path.cwd() / ".cursor" / "mcp.json", Path.cwd() / ".mcp.json"):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("Не найден .cursor/mcp.json или .mcp.json")


def _sandbox_url(url: str) -> str:
    if Path("/.dockerenv").is_file():
        return url.replace("127.0.0.1", "host.docker.internal")
    return url


def _detect_kind(url: str) -> str:
    if "/hs/mcp" in url:
        return "1c"
    base = url.rstrip("/")
    if base.endswith("/mcp") and "/hs/" not in url:
        return "streamable"
    return "jsonrpc"


def _rpc_url(base_url: str) -> str:
    url = _sandbox_url(base_url.rstrip("/"))
    if not url.endswith("/rpc"):
        url += "/rpc"
    return url


def _streamable_url(base_url: str) -> str:
    return _sandbox_url(base_url.rstrip("/"))


def _health_url(base_url: str) -> str | None:
    parsed = _sandbox_url(base_url.rstrip("/"))
    if parsed.endswith("/mcp"):
        return parsed[:-4] + "/health"
    return None


def _post_raw(
    url: str,
    payload: dict,
    headers: dict[str, str],
    accept: str = "application/json",
) -> tuple[int, dict | str, dict[str, str]]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    h = {
        "Content-Type": "application/json; charset=utf-8",
        "Accept": accept,
        **headers,
    }
    req = urllib.request.Request(url, data=body, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
            try:
                return resp.status, json.loads(raw), resp_headers
            except json.JSONDecodeError:
                return resp.status, raw, resp_headers
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace") if exc.fp else str(exc.reason)
        resp_headers = {k.lower(): v for k, v in exc.headers.items()} if exc.headers else {}
        try:
            return exc.code, json.loads(raw) if raw.strip() else {}, resp_headers
        except json.JSONDecodeError:
            return exc.code, raw, resp_headers
    except urllib.error.URLError as exc:
        return 0, f"URLError: {exc.reason}", {}


def _get_health(url: str) -> tuple[int, str]:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")[:200]
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace") if exc.fp else str(exc.reason)
        return exc.code, raw[:200]
    except urllib.error.URLError as exc:
        return 0, f"URLError: {exc.reason}"


def _rpc_jsonrpc(url: str, headers: dict[str, str], method: str, params: dict | None = None) -> tuple[int, dict | str]:
    status, body, _ = _post_raw(url, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}, headers)
    return status, body


def _session_id(resp_headers: dict[str, str]) -> str | None:
    return resp_headers.get("mcp-session-id")


def _streamable_rpc(
    url: str,
    headers: dict[str, str],
    method: str,
    params: dict | None = None,
    session_id: str | None = None,
    request_id: int = 1,
) -> tuple[int, dict | str, str | None]:
    h = {
        "MCP-Protocol-Version": MCP_PROTOCOL,
        **headers,
    }
    if session_id:
        h["Mcp-Session-Id"] = session_id
    status, body, resp_headers = _post_raw(
        url,
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}},
        h,
        accept="application/json, text/event-stream",
    )
    return status, body, _session_id(resp_headers)


def _tool_names(status: int, body: dict | str) -> list[str]:
    if status != 200 or not isinstance(body, dict):
        return []
    tools = (body.get("result") or {}).get("tools") or []
    return [str(t.get("name", "")) for t in tools if t.get("name")]


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


@dataclass
class ServerCase:
    key: str
    url: str
    headers: dict[str, str]
    kind: str


def _load_servers(cfg_path: Path) -> list[ServerCase]:
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    servers = cfg.get("mcpServers") or {}
    cases: list[ServerCase] = []
    for key, srv in servers.items():
        url = str(srv.get("url") or "").strip()
        if not url:
            continue
        headers = {str(k): str(v) for k, v in (srv.get("headers") or {}).items()}
        cases.append(ServerCase(key=key, url=url, headers=headers, kind=_detect_kind(url)))
    return cases


def _test_1c(case: ServerCase) -> tuple[bool, list[str]]:
    rpc = _rpc_url(case.url)
    lines = [f"URL: {case.url}", f"RPC: {rpc}"]
    failed = False

    st, body = _rpc_jsonrpc(rpc, case.headers, "tools/list")
    names = _tool_names(st, body)
    if st == 200:
        lines.append(f"tools/list: OK ({len(names)} tools)")
        if names:
            preview = ", ".join(names[:8])
            if len(names) > 8:
                preview += f", … (+{len(names) - 8})"
            lines.append(f"  tools: {preview}")
    else:
        body_s = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        lines.append(f"tools/list: FAIL HTTP {st}: {body_s[:300]}")
        failed = True

    if not failed:
        st2, body2 = _rpc_jsonrpc(
            rpc,
            case.headers,
            "tools/call",
            {"name": "version_get", "arguments": {}},
        )
        ok, txt = _tool_result(st2, body2)
        if ok:
            lines.append(f"version_get: OK {txt[:200]}")
        elif "version_get" in names:
            lines.append(f"version_get: FAIL {txt}")
            failed = True
        else:
            lines.append("version_get: SKIP (tool не в tools/list)")

    return not failed, lines


def _test_streamable(case: ServerCase) -> tuple[bool, list[str]]:
    mcp_url = _streamable_url(case.url)
    health = _health_url(case.url)
    lines = [f"URL: {mcp_url}", "transport: streamable HTTP"]
    failed = False

    if health:
        hst, hbody = _get_health(health)
        if hst == 200:
            lines.append(f"health: OK {hbody[:120]}")
        else:
            lines.append(f"health: FAIL HTTP {hst}: {hbody[:120]}")
            failed = True

    st, body, session = _streamable_rpc(
        mcp_url,
        case.headers,
        "initialize",
        {
            "protocolVersion": MCP_PROTOCOL,
            "capabilities": {},
            "clientInfo": {"name": "test-connected-mcp", "version": "1.0"},
        },
    )
    if st != 200 or not session:
        body_s = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        lines.append(f"initialize: FAIL HTTP {st}: {body_s[:300]}")
        return False, lines

    server_name = ""
    if isinstance(body, dict):
        info = (body.get("result") or {}).get("serverInfo") or {}
        server_name = f"{info.get('name', '?')} {info.get('version', '')}".strip()
    lines.append(f"initialize: OK session={session} server={server_name}")

    st2, body2, _ = _streamable_rpc(
        mcp_url,
        case.headers,
        "tools/list",
        session_id=session,
        request_id=2,
    )
    names = _tool_names(st2, body2)
    if st2 == 200:
        lines.append(f"tools/list: OK ({len(names)} tools)")
        if names:
            preview = ", ".join(names[:8])
            if len(names) > 8:
                preview += f", … (+{len(names) - 8})"
            lines.append(f"  tools: {preview}")
    else:
        body_s = body2 if isinstance(body2, str) else json.dumps(body2, ensure_ascii=False)
        lines.append(f"tools/list: FAIL HTTP {st2}: {body_s[:300]}")
        failed = True

    return not failed, lines


def _test_jsonrpc(case: ServerCase) -> tuple[bool, list[str]]:
    rpc = _rpc_url(case.url)
    lines = [f"URL: {case.url}", f"RPC: {rpc}"]
    st, body = _rpc_jsonrpc(rpc, case.headers, "tools/list")
    names = _tool_names(st, body)
    if st == 200:
        lines.append(f"tools/list: OK ({len(names)} tools)")
        if names:
            lines.append(f"  tools: {', '.join(names[:12])}")
        return True, lines
    body_s = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
    lines.append(f"tools/list: FAIL HTTP {st}: {body_s[:300]}")
    return False, lines


def _test_server(case: ServerCase) -> tuple[bool, list[str]]:
    if case.kind == "1c":
        return _test_1c(case)
    if case.kind == "streamable":
        return _test_streamable(case)
    return _test_jsonrpc(case)


def main() -> int:
    _reconfigure_stdio()
    cfg_path = _find_config()
    cases = _load_servers(cfg_path)
    if not cases:
        print(f"config: {cfg_path}")
        print("FAIL: mcpServers пуст")
        return 1

    print(f"config: {cfg_path}")
    print(f"servers: {len(cases)}\n")

    failed = 0
    for case in cases:
        print(f"=== {case.key} ({case.kind}) ===")
        ok, lines = _test_server(case)
        for line in lines:
            print(line)
        print("RESULT:", "OK" if ok else "FAIL")
        if not ok:
            failed += 1
        print()

    print(f"=== summary: {len(cases) - failed}/{len(cases)} passed, failed={failed} ===")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
