#!/usr/bin/env python3
"""Разметка мест под скриншоты в docs/report/report.md + PNG-заглушки.

Гарантии:
  * нумерация рисунков СКВОЗНАЯ и идёт по порядку чтения отчёта (Рис. 1 … Рис. 20);
  * у диаграммы модели тоже есть номер и подпись (Рис. 1);
  * разметка идемпотентна: перед вставкой прежние блоки рисунков удаляются,
    поэтому повторный запуск не дублирует и не ломает нумерацию;
  * существующие PNG (реальные скриншоты) не перезаписываются — создаются только заглушки;
  * Приложение C («План скриншотов») полностью генерируется: таблица соответствия
    «рисунок -> раздел -> файл -> команда подготовки».

Запуск: python3 scripts/mark_screenshots.py   (или make mark-screenshots)
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMG_DIR = ROOT / "docs" / "report" / "img"
REPORT = ROOT / "docs" / "report" / "report.md"
DIAGRAM_IMG = "diagrams/dv_model.png"
DIAGRAM_BARE = "![Модель Data Vault: хабы, ссылки, сателлиты, Business Vault и витрины](diagrams/dv_model.png)"

# Рисунки в порядке чтения отчёта: (номер, файл, подпись, команда подготовки, раздел)
FIGURES: list[tuple[str, str, str, str, str]] = [
    ("1", DIAGRAM_IMG, "Спроектированная модель Data Vault 2.0: хабы, ссылки, сателлиты, Business Vault и витрины",
     "python3 scripts/make_diagram.py", "2.5 Диаграмма модели"),
    ("2", "img/04_tables_vault.png", "Все 18 таблиц схемы vault созданы",
     "psql ... -c '\\dt vault.*'", "3.1 Состав DDL-скриптов"),
    ("3", "img/05_ddl_link.png", "DDL транзакционной ссылки: PK, FK, DISTRIBUTED BY, комментарии",
     "psql ... -c '\\d+ vault.lnk_sales_line'", "3.1 Состав DDL-скриптов"),
    ("4", "img/06_ddl_satellite.png", "DDL сателлита мер: AO/column, zstd, PK, CHECK, партиционирование",
     "psql ... -c '\\d+ vault.sat_sales_line'", "3.4 Пример DDL"),
    ("5", "img/19_vscode_ddl.png", "Исходный код DDL с комментариями в редакторе VS Code",
     "открыть sql/02_vault/10_ddl_hubs.sql", "3.4 Пример DDL"),
    ("6", "img/01_greenplum_running.png", "Локальный кластер Greenplum запущен в Docker (контейнер gp7)",
     "docker ps", "4.1 Окружение"),
    ("7", "img/02_version.png", "Версия СУБД: Greenplum Database 7.0.0",
     "psql ... -c 'SELECT version();'", "4.1 Окружение"),
    ("8", "img/03_mpp_topology.png", "MPP-топология: координатор и 4 сегмента",
     "psql ... -c 'SELECT * FROM gp_segment_configuration;'", "4.1 Окружение"),
    ("9", "img/09_table_counts.png", "Таблицы заполнены данными: число строк по каждой таблице",
     "psql ... -f sql/99_checks/10_table_counts.sql", "4.3 Результат в цифрах"),
    ("10", "img/10_reconciliation.png", "Сходимость контрольных сумм: источник = DDS = Business Vault = витрина",
     "psql ... -f sql/99_checks/20_reconciliation.sql", "4.3 Результат в цифрах"),
    ("11", "img/07_load_staging.png", "Загрузка датасета в staging: 9994 строки, карантин пуст",
     "make stage", "4.4 Загрузка (ELT)"),
    ("12", "img/08_load_dds.png", "ELT: загрузка хабов, ссылок, сателлитов и реконсиляция",
     "make load", "4.4 Загрузка (ELT)"),
    ("13", "img/11_tests_all_pass.png", "Результат автотестов: 118 проверок, 0 провалено",
     "make test", "5.2 Результат тестов"),
    ("14", "img/16_marts.png", "Аналитические витрины, построенные поверх Data Vault",
     "psql ... -c 'SELECT * FROM dm.dm_sales_by_region_category;'", "6, E1 Витрины"),
    ("15", "img/17_dq_profile.png", "Профиль качества источника: дубли строк, восстановленные ZIP, убыточные строки",
     "psql ... -c 'SELECT * FROM dm.dm_dq_source_profile;'", "6, E3 Качество данных"),
    ("16", "img/13_dq_metrics.png", "Метрики качества данных (audit.dq_metrics) и журнал загрузок",
     "psql ... -f sql/99_checks/60_audit_metrics.sql", "6, E3 Качество данных"),
    ("17", "img/12_e4_explain.png", "E4: co-location (Gather Motion) против случайной дистрибуции (Redistribute Motion)",
     "psql ... -f sql/99_checks/50_e4_explain_distribution.sql", "6, E4 EXPLAIN"),
    ("18", "img/18_explain_partitions.png", "E4: отсечение партиций по дате загрузки",
     "psql ... -c \"EXPLAIN SELECT ... FROM staging.stg_superstore_raw WHERE load_dts ...\"", "6, E4 EXPLAIN"),
    ("19", "img/14_lineage.png", "E6: прослеживаемость «строка файла -> строка хранилища»",
     "psql ... -f sql/99_checks/40_lineage_trace.sql", "6, E6 Lineage"),
    ("20", "img/20_google_doc.png", "Итоговый документ, собранный в Google Docs",
     "загрузить DOCX в Google Docs и вставить скриншоты", "Приложение C"),
]

SHOTS = [(name.replace("img/", "", 1), caption, command)
         for _, name, caption, command, _ in FIGURES if name.startswith("img/")]

DIAGRAM_CAPTION = FIGURES[0][2]
FIG_RE = re.compile(r"!\[Рис\. \d+\.[^\]]*\]\([^)]+\)\n\n\*Рис\. \d+\.[^\n]*\*\n*")


def fig_block(number: str, path: str, caption: str, command: str) -> str:
    """Markdown-блок рисунка: изображение + видимая подпись с командой подготовки."""
    return (
        f"![Рис. {number}. {caption}]({path})\n\n"
        f"*Рис. {number}. {caption}. Подготовка: `{command}`.*\n"
    )


def strip_figures(text: str) -> str:
    """Убирает все ранее размеченные блоки рисунков (чтобы пересобрать нумерацию заново)."""
    return FIG_RE.sub("", text)


def insert(anchor: str, block: str, text: str, before: bool = True) -> str:
    """Вставляет блок рядом с уникальным якорем."""
    if text.count(anchor) != 1:
        raise SystemExit(f"якорь не уникален ({text.count(anchor)} совпадений): {anchor[:70]!r}")
    replacement = f"{block}\n{anchor}" if before else f"{anchor}\n\n{block}"
    return text.replace(anchor, replacement, 1)


def build_appendix() -> str:
    """Полностью генерирует Приложение C (таблицу соответствия) и рисунок 20."""
    rows = []
    for number, path, caption, command, section in FIGURES:
        rows.append(f"| Рис. {number} | {section} | `{path}` | `{command}` |")
    table = "\n".join(rows)
    figure20 = FIGURES[-1]
    return (
        "## Приложение C. План скриншотов\n\n"
        "Пошаговая инструкция с точными командами и указанием, что должно быть видно на каждом снимке, —\n"
        "в файле `docs/tmp/screenshots_plan.md` (генерируется командой `make screenshots`).\n"
        "В отчёте места под рисунки уже размечены: **Рис. 1 … Рис. 20** — нумерация сквозная,\n"
        "в порядке чтения. В `docs/report/img/` лежат PNG-заглушки: замените их реальными\n"
        "скриншотами с теми же именами и пересоберите отчёт (`make report`).\n\n"
        "Номера внутри имён файлов соответствуют плану (`screenshots_plan.md`), а не номерам рисунков.\n\n"
        "| Рисунок | Раздел отчёта | Файл | Подготовка |\n"
        "|---|---|---|---|\n"
        f"{table}\n\n"
        + fig_block(figure20[0], figure20[1], figure20[2], figure20[3])
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
    """Рисует PNG-заглушку; существующий файл (реальный скриншот) не перезаписывает."""
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
PRINT_RE = re.compile(r"!\[Рис\. (\d+)\.")


def main() -> int:
    text = REPORT.read_text(encoding="utf-8")

    # 1. Снимаем прежнюю разметку: нумерация пересобирается с нуля
    text = strip_figures(text)

    # 2. Диаграмма модели: возвращаем «голую» картинку и нумеруем её как Рис. 1
    if DIAGRAM_BARE not in text:
        text = insert("Источник диаграммы: `docs/report/diagrams/dv_model.dot`",
                      DIAGRAM_BARE, text, before=True)
    text = text.replace(DIAGRAM_BARE, fig_block(*FIGURES[0][:4]), 1)

    by_number = {number: (path, caption, command)
                 for number, path, caption, command, _ in FIGURES}

    def block(*numbers: str) -> str:
        return "\n".join(fig_block(number, *by_number[number]) for number in numbers)

    # 3. Остальные рисунки — в порядке чтения отчёта (нумерация сквозная)
    text = insert("В коде — построчные комментарии", block("2", "3"), text, before=True)
    text = insert("Полный DDL — в каталогах `sql/02_vault`", block("4", "5"), text, before=True)
    text = insert("Версия СУБД: `PostgreSQL 12.12", block("6", "7", "8"), text, before=True)
    text = insert("Динамика: `staging` 9994 строки", block("9", "10"), text, before=True)
    text = insert("## 5. Тесты корректности", block("11", "12"), text, before=True)
    text = insert("**Итог: 118 проверок", block("13"), text, before=True)
    text = insert("- `dm.dm_sales_star` — витрина-«звезда» из bridge", block("14"), text, before=True)
    text = insert("### E4. Измеримое доказательство выбора `DISTRIBUTED BY`",
                  block("15", "16"), text, before=True)
    text = insert("Транскрипт: `docs/tmp/transcripts/50_e4_explain_distribution.txt`.",
                  block("17", "18"), text, before=False)
    text = insert("Транскрипт: `40_lineage_trace.txt`.", block("19"), text, before=False)

    # 4. Приложение C генерируется целиком (таблица соответствия + Рис. 20)
    appendix_anchor = "## Приложение C. План скриншотов"
    if text.count(appendix_anchor) != 1:
        raise SystemExit("не найден заголовок Приложения C — проверьте отчёт")
    text = text[:text.index(appendix_anchor)] + build_appendix()

    REPORT.write_text(text, encoding="utf-8")

    # 5. Контроль: нумерация должна идти строго 1, 2, 3, …
    order = [int(m.group(1)) for m in PRINT_RE.finditer(text)]
    expected = [int(number) for number, *_ in FIGURES]
    status = "ОК" if order == expected else f"ОШИБКА: {order}"
    print(f"Рисунков в отчёте: {len(order)} -> порядок нумерации: {order} ({status})")

    created = 0
    for name, caption, command in SHOTS:
        created += bool(make_placeholder(name, caption, command))
    print(f"Заглушек создано в {IMG_DIR.relative_to(ROOT)}: {created} "
          f"(существующие файлы не перезаписывались)")

    print("\nСоответствие «рисунок -> файл -> команда подготовки»:")
    for number, path, caption, command, section in FIGURES:
        print(f"  Рис. {number:>2}  [{section}]  {path:<32} {command}")
    return 0 if order == expected else 1


if __name__ == "__main__":
    raise SystemExit(main())
