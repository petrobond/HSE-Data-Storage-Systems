#!/usr/bin/env python3
"""Проверяет собранные артефакты отчёта: ориентацию страниц, размер DOCX/PDF,
число листингов и изображений. Используется как контроль после `make report`.

Использование: python3 scripts/check_report_artifacts.py [каталог]
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

MEDIABOX_RE = re.compile(rb"/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]")
PG_SZ_RE = re.compile(r'<w:pgSz\b[^>]*/>')
ATTR_RE = re.compile(r'(w:[\w]+)="([^"]*)"')


def pdf_orientation(path: pathlib.Path) -> str:
    """Ориентация PDF: через mdls (macOS) либо через MediaBox (для несжатых PDF)."""
    width = height = None
    if shutil.which("mdls"):
        output = subprocess.run(
            ["mdls", "-name", "kMDItemPageWidth", "-name", "kMDItemPageHeight", str(path)],
            capture_output=True, text=True,
        ).stdout
        values = dict(re.findall(r"kMDItem(PageWidth|PageHeight)\s*=\s*([\d.]+)", output))
        width = float(values["PageWidth"]) if "PageWidth" in values else None
        height = float(values["PageHeight"]) if "PageHeight" in values else None

    if width is None or height is None:
        match = MEDIABOX_RE.search(path.read_bytes())
        if match:
            x1, y1, x2, y2 = (float(value) for value in match.groups())
            width, height = x2 - x1, y2 - y1

    if width is None or height is None:
        return "ориентация не определена"
    kind = "ландшафт" if width > height else "портрет"
    return f"{kind} ({width:.0f}x{height:.0f} pt)"


def docx_summary(path: pathlib.Path) -> str:
    with zipfile.ZipFile(path) as archive:
        document = archive.read("word/document.xml").decode("utf-8")
        media = sum(1 for name in archive.namelist() if name.startswith("word/media/"))
    tag = PG_SZ_RE.search(document)
    attrs = dict(ATTR_RE.findall(tag.group(0))) if tag else {}
    orient = attrs.get("w:orient", "")
    width, height = attrs.get("w:w", ""), attrs.get("w:h", "")
    landscape = orient == "landscape" or (
        width.isdigit() and height.isdigit() and int(width) > int(height)
    )
    kind = "ландшафт" if landscape else "портрет"
    if not width:
        return f"{kind} (размер страницы по умолчанию, изображений: {media})"
    return f"{kind} ({width}x{height} twips, изображений: {media})"


def main() -> int:
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("docs/tmp/report_build")
    files = sorted(out.glob("*.docx")) + sorted(out.glob("*.pdf"))
    if not files:
        print(f"в {out} нет файлов отчёта", file=sys.stderr)
        return 1

    report = pathlib.Path("docs/report/report.md")
    text = report.read_text(encoding="utf-8")
    print(f"Источник: {report} — строк {len(text.splitlines())}, "
          f"листингов {text.count(chr(10) + '*Листинг ')}, рисунков {text.count('![Рис.')}")
    print("Собранные документы:")
    for path in files:
        size = path.stat().st_size / 1024
        info = pdf_orientation(path) if path.suffix == ".pdf" else docx_summary(path)
        print(f"  {path.name:<72} {size:>8.1f} КБ  {info}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
