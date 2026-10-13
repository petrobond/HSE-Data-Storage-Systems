#!/usr/bin/env python3
"""Делает ландшафтную версию DOCX: меняет параметры страницы (sectPr/pgSz) на A4 landscape.

Pandoc (docx-writer) не имеет флага ориентации: ориентация хранится в самом DOCX —
в атрибутах <w:pgSz w:w="..." w:h="..." w:orient="..."/> внутри <w:sectPr>.
Скрипт распаковывает DOCX (это zip), во всех XML-частях меняет размеры страницы
на ландшафтные и собирает архив обратно; остальное содержимое не трогается.

Использование: python3 scripts/make_landscape_docx.py <файл.docx>
Портретная версия рядом сохраняется как есть.
"""

from __future__ import annotations

import pathlib
import re
import shutil
import sys
import zipfile

# A4 в twips (1/1440 дюйма): портрет 11906x16838, ландшафт — те же значения, но поменянные местами
LANDSCAPE_W = "16838"
LANDSCAPE_H = "11906"
PG_SZ_RE = re.compile(r"<w:pgSz\b[^>]*/?>")
SECT_END = "</w:sectPr>"
# Поля 2 см + место под колонтитулы: для широких терминальных выводов в ландшафте
LANDSCAPE_MARGINS = (
    '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" '
    'w:header="720" w:footer="720" w:gutter="0"/>'
)


def patch_pg_sz(xml: str) -> tuple[str, int]:
    """Ставит ландшафтные размеры страницы: правит существующий <w:pgSz> либо добавляет его.

    Порядок элементов внутри <w:sectPr> по схеме OOXML: footnotePr, endnotePr, type,
    pgSz, pgMar, ... — поэтому, если размеров страницы не было (pandoc их не выводит),
    pgSz и pgMar добавляются прямо перед закрывающим </w:sectPr>.
    """
    count = 0

    def repl(match: re.Match) -> str:
        nonlocal count
        tag = match.group(0)
        attrs: dict[str, str] = dict(re.findall(r'(w:[\w]+)="([^"]*)"', tag))
        attrs["w:w"] = LANDSCAPE_W
        attrs["w:h"] = LANDSCAPE_H
        attrs["w:orient"] = "landscape"
        count += 1
        body = " ".join(f'{key}="{value}"' for key, value in attrs.items())
        return f"<w:pgSz {body}/>"

    if PG_SZ_RE.search(xml):
        return PG_SZ_RE.sub(repl, xml), count

    landscape = (f'<w:pgSz w:w="{LANDSCAPE_W}" w:h="{LANDSCAPE_H}" w:orient="landscape"/>'
                 f"{LANDSCAPE_MARGINS}")
    return xml.replace(SECT_END, landscape + SECT_END), xml.count(SECT_END)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    target = pathlib.Path(sys.argv[1])
    if not target.exists():
        print(f"не найден файл: {target}", file=sys.stderr)
        return 2

    tmp = target.with_suffix(".landscape.tmp.docx")
    patched_parts = 0
    with zipfile.ZipFile(target) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            data = src.read(item.filename)
            if item.filename.endswith(".xml") and (b"w:pgSz" in data or SECT_END.encode() in data):
                text = data.decode("utf-8")
                text, count = patch_pg_sz(text)
                patched_parts += count
                data = text.encode("utf-8")
            dst.writestr(item, data)

    if patched_parts == 0:
        tmp.unlink(missing_ok=True)
        print("не найдено ни одного <w:pgSz>: ориентация не изменена", file=sys.stderr)
        return 1

    shutil.move(str(tmp), str(target))
    print(f"  {target.name}: параметры страницы переведены в ландшафт "
          f"({patched_parts} секций, {LANDSCAPE_W}x{LANDSCAPE_H} twips)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
