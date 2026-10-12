#!/usr/bin/env python3
"""Разметка мест под скриншоты в docs/report/report.md + генерация PNG-заглушек.

Зачем: итоговый документ должен собираться (DOCX/PDF) даже до того, как сняты
скриншоты, и в нём должны быть явно размечены места под каждый рисунок.

Что делает:
  1) создаёт в docs/report/img/ PNG-заглушки с номером, описанием и командой подготовки
     (существующие файлы — реальные скриншоты — НЕ перезаписывает);
  2) вставляет в docs/report/report.md markdown-блоки рисунков с подписями
     (`![Рис. N. ...](img/NN_xxx.png)` + «Рис. N. …»), привязывая их к нужным разделам;
     операция идемпотентна — повторный запуск ничего не дублирует.

Запуск: python3 scripts/mark_screenshots.py
"""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMG_DIR = ROOT / "docs" / "report" / "img"
REPORT = ROOT / "docs" / "report" / "report.md"

# (файл, подпись под рисунком, команда подготовки скриншота)
SHOTS: list[tuple[str, str, str]] = [
    ("01_greenplum_running.png", "Локальный кластер Greenplum запущен в Docker (контейнер gp7)", "docker ps"),
    ("02_version.png", "Версия СУБД Greenplum Database 7.0.0", "psql ... -c 'SELECT version();'"),
    ("03_mpp_topology.png", "MPP-топология: координатор и 4 сегмента", "psql ... -c 'SELECT * FROM gp_segment_configuration;'"),
    ("04_tables_vault.png", "Все 18 таблиц схемы vault созданы", "psql ... -c '\\dt vault.*'"),
    ("05_ddl_link.png", "DDL транзакционной ссылки: PK, FK, DISTRIBUTED BY, комментарии", "psql ... -c '\\d+ vault.lnk_sales_line'"),
    ("06_ddl_satellite.png", "DDL сателлита мер: AO/column, zstd, PK, CHECK, партиции", "psql ... -c '\\d+ vault.sat_sales_line'"),
    ("07_load_staging.png", "Загрузка датасета в staging: 9994 строки, карантин пуст", "make stage"),
    ("08_load_dds.png", "ELT: загрузка хабов, ссылок, сателлитов и реконсиляция", "make load"),
    ("09_table_counts.png", "Таблицы заполнены данными: число строк по каждой таблице", "psql ... -f sql/99_checks/10_table_counts.sql"),
    ("10_reconciliation.png", "Сходимость контрольных сумм: источник = DDS = Business Vault = витрина", "psql ... -f sql/99_checks/20_reconciliation.sql"),
    ("11_tests_all_pass.png", "Результат автотестов: 118 проверок, 0 провалено", "make test"),
    ("12_e4_explain.png", "E4: co-location (Gather Motion) против случайной дистрибуции (Redistribute Motion)", "psql ... -f sql/99_checks/50_e4_explain_distribution.sql"),
    ("13_dq_metrics.png", "Метрики качества данных (audit.dq_metrics) и журнал загрузок", "psql ... -f sql/99_checks/60_audit_metrics.sql"),
    ("14_lineage.png", "E6: прослеживаемость «строка файла -> строка хранилища»", "psql ... -f sql/99_checks/40_lineage_trace.sql"),
    ("16_marts.png", "Аналитические витрины, построенные поверх Data Vault", "psql ... -c 'SELECT * FROM dm.dm_sales_by_region_category;'"),
    ("17_dq_profile.png", "Профиль качества источника: дубли строк, восстановленные ZIP, убыточные строки", "psql ... -c 'SELECT * FROM dm.dm_dq_source_profile;'"),
    ("18_explain_partitions.png", "E4: отсечение партиций по дате загрузки", "psql ... -c \"EXPLAIN SELECT ... FROM staging.stg_superstore_raw WHERE load_dts ...\""),
    ("19_vscode_ddl.png", "Исходный код DDL с комментариями в редакторе VS Code", "открыть sql/02_vault/10_ddl_hubs.sql"),
    ("20_google_doc.png", "Итоговый документ, собранный в Google Docs", "загрузить DOCX в Google Docs и вставить скриншоты"),
]


def figure(number: str, filename: str, caption: str, command: str) -> str:
    """Markdown-блок рисунка: изображение + видимая подпись."""
    return (
        f"![Рис. {number}. {caption}](img/{filename})\n\n"
        f"*Рис. {number}. {caption}. Подготовка: `{command}`.*\n"
    )


def _wrap(text: str, width: int) -> list[str]:
    words, lines, current = text.split(), [], ""
    for word in words:
        if len(current) + len(word) + 1 > width:
            lines.append(current)
            current = word
        else:
            current = f"{current} {word}".strip()
    if current:
        lines.append(current)
    return lines


def make_placeholder(filename: str, caption: str, command: str) -> bool:
    """Рисует PNG-заглушку; существующий файл (реальный скриншот) не трогает."""
    target = IMG_DIR / filename
    if target.exists():
        return False
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        print("Pillow не установлен — заглушка не создана (pip install pillow)", file=sys.stderr)
        return False

    width, height = 1280, 400
    image = Image.new("RGB", (width, height), "#F5F6F8")
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width - 1, height - 1], outline="#9AA0A6", width=3)

    font_path = "/Library/Fonts/Arial Unicode.ttf"
    if not pathlib.Path(font_path).exists():
        font_path = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
    try:
        title_font = ImageFont.truetype(font_path, 34)
        text_font = ImageFont.truetype(font_path, 24)
        hint_font = ImageFont.truetype(font_path, 20)
    except OSError:
        title_font = text_font = hint_font = ImageFont.load_default()

    draw.text((40, 36), f"МЕСТО ДЛЯ СКРИНШОТА: {filename}", font=title_font, fill="#3C4043")
    y = 104
    for line in _wrap(caption, 70)[:2]:
        draw.text((40, y), line, font=text_font, fill="#202124")
        y += 32
    y += 12
    draw.text((40, y), "Подготовка:", font=hint_font, fill="#5F6368")
    y += 30
    for line in _wrap(command, 84)[:3]:
        draw.text((40, y), line, font=hint_font, fill="#1A73E8")
        y += 28
    draw.text((40, height - 44), "Замените этот файл реальным скриншотом (имя файла сохранить)",
              font=hint_font, fill="#9AA0A6")

    IMG_DIR.mkdir(parents=True, exist_ok=True)
    image.save(target)
    return True


def insert(anchor: str, block: str, text: str, before: bool = True, marker: str = "") -> str:
    """Вставляет блок рядом с уникальным якорем (идемпотентно по marker)."""
    if marker and marker in text:
        return text
    if text.count(anchor) != 1:
        raise SystemExit(f"якорь не уникален ({text.count(anchor)} совпадений): {anchor[:70]!r}")
    replacement = f"{block}\n{anchor}" if before else f"{anchor}\n\n{block}"
    return text.replace(anchor, replacement, 1)


def main() -> int:
    text = REPORT.read_text(encoding="utf-8")
    by_name = {name: (caption, command) for name, caption, command in SHOTS}

    def fig(number: str, name: str) -> str:
        caption, command = by_name[name]
        return figure(number, name, caption, command)

    # --- Часть 2 (DDL): листинг таблиц и DDL ссылки ---
    text = insert(
        "В коде — построчные комментарии, объясняющие выбор решения",
        fig("4", "04_tables_vault.png") + "\n" + fig("5", "05_ddl_link.png"),
        text, before=True, marker="img/04_tables_vault.png",
    )
    # --- Часть 2: пример DDL сателлита + исходник в редакторе ---
    text = insert(
        "Полный DDL — в каталогах `sql/02_vault`",
        fig("6", "06_ddl_satellite.png") + "\n" + fig("19", "19_vscode_ddl.png"),
        text, before=True, marker="img/06_ddl_satellite.png",
    )
    # --- Часть 3: окружение (контейнер, версия, MPP-топология) ---
    text = insert(
        "Версия СУБД: `PostgreSQL 12.12",
        fig("1", "01_greenplum_running.png") + "\n"
        + fig("2", "02_version.png") + "\n" + fig("3", "03_mpp_topology.png"),
        text, before=True, marker="img/01_greenplum_running.png",
    )
    # --- Часть 3: цифры и сходимость ---
    text = insert(
        "Динамика: `staging` 9994 строки",
        fig("9", "09_table_counts.png") + "\n" + fig("10", "10_reconciliation.png"),
        text, before=True, marker="img/09_table_counts.png",
    )
    # --- Загрузка в staging и Data Vault (перед разделом тестов) ---
    text = insert(
        "## 5. Тесты корректности",
        fig("7", "07_load_staging.png") + "\n" + fig("8", "08_load_dds.png"),
        text, before=True, marker="img/07_load_staging.png",
    )
    # --- Тесты: сводный отчёт ---
    text = insert(
        "**Итог: 118 проверок — 118 PASS, 0 FAIL**",
        fig("11", "11_tests_all_pass.png"),
        text, before=True, marker="img/11_tests_all_pass.png",
    )
    # --- Профиль качества источника (конец раздела 1) ---
    text = insert(
        "## 2. Часть 1. Проектирование хранилища методом Data Vault",
        fig("17", "17_dq_profile.png"),
        text, before=True, marker="img/17_dq_profile.png",
    )
    # --- E1: витрины ---
    text = insert(
        "- `dm.dm_sales_star` — витрина-«звезда» из bridge",
        fig("16", "16_marts.png"),
        text, before=True, marker="img/16_marts.png",
    )
    # --- E3: метрики качества ---
    text = insert(
        "### E4. Измеримое доказательство выбора `DISTRIBUTED BY`",
        fig("13", "13_dq_metrics.png"),
        text, before=True, marker="img/13_dq_metrics.png",
    )
    # --- E4: планы запросов и партиции ---
    text = insert(
        "Транскрипт: `docs/tmp/transcripts/50_e4_explain_distribution.txt`.",
        fig("12", "12_e4_explain.png") + "\n" + fig("18", "18_explain_partitions.png"),
        text, before=False, marker="img/12_e4_explain.png",
    )
    # --- E6: lineage ---
    text = insert(
        "Транскрипт: `40_lineage_trace.txt`.",
        fig("14", "14_lineage.png"),
        text, before=False, marker="img/14_lineage.png",
    )
    # --- Финал: как выглядит документ в Google Docs ---
    text = insert(
        "в `docs/report/img/` и подставляются в этот документ.",
        fig("20", "20_google_doc.png"),
        text, before=False, marker="img/20_google_doc.png",
    )

    REPORT.write_text(text, encoding="utf-8")

    created = 0
    for name, caption, command in SHOTS:
        created += bool(make_placeholder(name, caption, command))

    order = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
             "11", "12", "13", "14", "16", "17", "18", "19", "20"]
    print(f"Размечено рисунков в отчёте: {len(SHOTS)}")
    print(f"Заглушек создано в {IMG_DIR.relative_to(ROOT)}: {created} "
          f"(существующие файлы не перезаписывались)")
    print("\nСоответствие «рисунок -> файл скриншота -> команда подготовки»:")
    for number, (name, caption, command) in zip(order, SHOTS):
        print(f"  Рис. {number:>2}  {name:<28} {command}")
    print("\nЗамените заглушки реальными скриншотами с теми же именами "
          "и пересоберите отчёт: make report")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

