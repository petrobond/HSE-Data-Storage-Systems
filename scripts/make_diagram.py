#!/usr/bin/env python3
"""Рендер диаграммы модели Data Vault: docs/report/diagrams/dv_model.dot -> PNG/SVG.

Запуск: python3 scripts/make_diagram.py   (или make diagram)
Требуется graphviz (`dot`), на macOS: brew install graphviz.
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIAGRAMS = ROOT / "docs" / "report" / "diagrams"
DOT_FILE = DIAGRAMS / "dv_model.dot"


def main() -> int:
    if not DOT_FILE.exists():
        print(f"не найден {DOT_FILE}", file=sys.stderr)
        return 2

    dot_bin = shutil.which("dot")
    if not dot_bin:
        print("graphviz (dot) не найден: brew install graphviz", file=sys.stderr)
        return 1

    for fmt in ("png", "svg"):
        target = DIAGRAMS / f"dv_model.{fmt}"
        subprocess.run(
            [dot_bin, f"-T{fmt}", "-Gdpi=140", str(DOT_FILE), "-o", str(target)],
            check=True,
        )
        print(f"создан {target.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
