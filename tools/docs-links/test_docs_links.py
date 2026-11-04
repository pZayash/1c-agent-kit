#!/usr/bin/env python3
"""Тесты docs-links: ссылки, достижимость, заглушки, индекс памяти."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check as docs_links  # noqa: E402


class DocsLinksTest(unittest.TestCase):
    def make_root(self, files: dict[str, str], config: dict | None = None) -> Path:
        base = Path.cwd() / ".tmp"
        base.mkdir(exist_ok=True)
        tmp = base / f"docs-links-{uuid.uuid4().hex}"
        tmp.mkdir()
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        for name, content in files.items():
            path = tmp / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        cfg = {
            "entry": ["ENTRY.md"],
            "roots": ["ENTRY.md", "docs", "memory"],
            "exclude": [],
        }
        if config:
            cfg.update(config)
        (tmp / ".docs-links.json").write_text(json.dumps(cfg), encoding="utf-8")
        return tmp

    def audit(self, files: dict[str, str], config: dict | None = None):
        root = self.make_root(files, config)
        cfg = docs_links.deep_merge(docs_links.DEFAULT_CONFIG, docs_links.load_config(root, None))
        # Тестовый каталог лежит внутри рабочего репозитория: отключаем git-список,
        # чтобы инструмент обходил только файлы теста.
        with mock.patch.object(docs_links, "list_tracked", return_value=None):
            return docs_links.analyze(root, cfg)

    def kinds(self, audit) -> dict[str, list[str]]:
        result: dict[str, list[str]] = {}
        for finding in audit.findings:
            result.setdefault(finding.kind, []).append(finding.file)
        return result

    def test_chain_is_reachable(self):
        audit = self.audit(
            {
                "ENTRY.md": "[Оглавление](docs/README.md)\n",
                "docs/README.md": "[Документ](ai/doc.md)\n",
                "docs/ai/doc.md": "# Документ\n",
            }
        )
        self.assertEqual(audit.findings, [])

    def test_broken_link_reported(self):
        found = self.kinds(self.audit({"ENTRY.md": "[Нет](docs/nope.md)\n"}))
        self.assertEqual(found.get("broken"), ["ENTRY.md"])

    def test_unreachable_and_dangling(self):
        found = self.kinds(
            self.audit({"ENTRY.md": "# Вход\n", "docs/orphan.md": "# Сирота\n"})
        )
        self.assertIn("docs/orphan.md", found.get("unreachable", []))
        self.assertIn("docs/orphan.md", found.get("dangling", []))

    def test_stub_is_skipped(self):
        audit = self.audit(
            {
                "ENTRY.md": "# Вход\n",
                "docs/stub.md": "Перенесено в kit: harness/docs/stub.md\n",
            }
        )
        self.assertEqual(audit.findings, [])

    def test_broken_anchor(self):
        found = self.kinds(
            self.audit(
                {
                    "ENTRY.md": "[Док](docs/doc.md#нет-такого)\n",
                    "docs/doc.md": "# Есть заголовок\n",
                }
            )
        )
        self.assertEqual(found.get("anchor"), ["ENTRY.md"])

    def test_index_generates_month_sections(self):
        root = self.make_root(
            {
                "ENTRY.md": "# Вход\n",
                "memory/README.md": "# Формат\n",
                "memory/2026-10-01-first.md": "# Первый факт\n\n## Теги\n\nобмен, qmd\n",
                "memory/2026-11-02-second.md": "# Второй факт\n",
            }
        )
        config = docs_links.load_config(root, None)
        args = docs_links.build_parser().parse_args(
            ["index", "--root", str(root), "--path", "memory", "--out", "memory/INDEX.md"]
        )
        docs_links.command_index(args, config)
        text = (root / "memory/INDEX.md").read_text(encoding="utf-8")
        self.assertIn("## 2026-11", text)
        self.assertLess(text.index("## 2026-11"), text.index("## 2026-10"))
        self.assertIn("[Первый факт](2026-10-01-first.md) — теги: обмен, qmd", text)
        self.assertNotIn("- [Формат](README.md)", text)

    def test_index_recursive_groups_by_subdir(self):
        root = self.make_root(
            {
                "ENTRY.md": "# Вход\n",
                "research/2026-09-01-dated.md": "# Датированное\n",
                "research/topic/inner.md": "# Тематическое\n",
            }
        )
        config = docs_links.load_config(root, None)
        args = docs_links.build_parser().parse_args(
            ["index", "--root", str(root), "--path", "research", "--out", "research/INDEX.md"]
        )
        docs_links.command_index(args, config)
        text = (root / "research/INDEX.md").read_text(encoding="utf-8")
        self.assertIn("## 2026-09", text)
        self.assertIn("## topic", text)
        self.assertIn("[Тематическое](topic/inner.md)", text)


if __name__ == "__main__":
    unittest.main()
