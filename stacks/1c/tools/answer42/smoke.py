#!/usr/bin/env python3
"""Smoke-проверка Answer42 через stdio MCP.

По умолчанию работает на встроенной демо-базе Answer42 (dev-ИБ и прод не
затрагиваются). С `--base-url` подключается к указанной ИБ, учётка берётся из
локального credential-стора Answer42 (~/.answer42-credentials.json).

Запускать интерпретатором venv Answer42:
    .venv-answer42\\Scripts\\python.exe tools/answer42/smoke.py

Коды возврата: 0 — ok, 1 — smoke не прошёл, 2 — ошибка аргументов.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
except ModuleNotFoundError:
    print("Нет пакета mcp — запускайте интерпретатором venv Answer42", file=sys.stderr)
    raise SystemExit(2)


def parse_result(result):
    texts = [getattr(item, "text", "") for item in result.content]
    if len(texts) == 1:
        try:
            return json.loads(texts[0])
        except json.JSONDecodeError:
            return texts[0]
    return texts


def line(label: str, value, limit: int = 400) -> None:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=str)
    print(f"{label}: {text[:limit]}", flush=True)


async def run(args: argparse.Namespace) -> int:
    env = {**os.environ, "ONEC_MCP_REQUEST_TIMEOUT": str(int(args.timeout))}
    if args.account_id:
        env["ONEC_MCP_ACCOUNT_ID"] = args.account_id
    # cwd сервера — вне проекта: Answer42 складывает рядом build/ (CF, RAG sqlite)
    work_dir = Path(tempfile.gettempdir()) / "answer42" / "smoke-stdio"
    work_dir.mkdir(parents=True, exist_ok=True)
    params = StdioServerParameters(command=args.bin, args=[], env=env, cwd=str(work_dir))
    session_id = args.session_id

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            line("tools_count", len(tools.tools))

            payload = {"session_id": session_id, "idle_timeout_minutes": 15}
            if args.base_url:
                payload["base_url"] = args.base_url
            started = await session.call_tool("start_session", payload, read_timeout_seconds=args.timeout)
            parsed = parse_result(started)
            if started.is_error:
                line("start_session_error", parsed, 1200)
                return 1
            if isinstance(parsed, dict):
                client = parsed.get("test_client") or {}
                line(
                    "start_session",
                    {
                        "version": parsed.get("version"),
                        "base_url": client.get("base_url"),
                        "connection_mode": client.get("connection_mode"),
                        "connected": client.get("connected"),
                    },
                )

            failed = False
            try:
                active = await session.call_tool("active_window", {"session_id": session_id})
                parsed_active = parse_result(active)
                if active.is_error:
                    line("active_window_error", parsed_active, 800)
                    failed = True
                elif isinstance(parsed_active, dict):
                    line("active_window", {"title": parsed_active.get("title"), "visible": parsed_active.get("visible")})
            finally:
                stopped = await session.call_tool(
                    "stop_session",
                    {"session_id": session_id, "clean_data": True},
                    read_timeout_seconds=args.timeout,
                )
                parsed_stopped = parse_result(stopped)
                if isinstance(parsed_stopped, dict):
                    line("stop_session", {"stopped": parsed_stopped.get("stopped")})
                else:
                    line("stop_session", parsed_stopped, 400)
                if stopped.is_error:
                    failed = True
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Answer42 smoke через stdio MCP")
    parser.add_argument("--bin", required=True, help="Путь к answer42(.exe)")
    parser.add_argument("--base-url", default="", help="ИБ для подключения; пусто = встроенная демо-база")
    parser.add_argument("--session-id", default="smoke")
    parser.add_argument("--account-id", default=os.environ.get("ANSWER42_ACCOUNT_ID", ""),
                        help="Namespace credential-стора Answer42 (как ONEC_MCP_ACCOUNT_ID)")
    parser.add_argument("--timeout", type=float, default=180.0, help="Таймаут запроса, сек")
    args = parser.parse_args()

    if not Path(args.bin).is_file() and not args.bin.endswith(("answer42", "answer42.exe")):
        print(f"Нет файла {args.bin}", file=sys.stderr)
        return 2
    try:
        return asyncio.run(run(args))
    except BaseExceptionGroup as exc:  # mcp-клиент заворачивает ошибку сервера
        print(f"smoke упал: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
