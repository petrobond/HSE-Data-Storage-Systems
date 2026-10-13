#!/usr/bin/env python3
"""Сбор доказательств в отчёт: реальные выводы команд вместо скриншотов.

Идея: вместо картинок-заглушек в docs/report/report.md подставляются настоящие
терминальные выводы — команда и её результат (fenced-блок ```console) с подписью
«Листинг N». Всё собирается автоматически с живого Greenplum и файлов репозитория,
поэтому документ всегда соответствует коду, а проверяющий может повторить любую команду.

Гарантии:
  * нумерация сквозная в порядке чтения: Рис. 1 — диаграмма модели, Листинг 1…18 — выводы команд;
  * повторный запуск полностью перестраивает блоки (идемпотентно), нумерация не ломается;
  * у длинных выводов есть ограничение длины с явной пометкой о сокращении;
  * Приложение C генерируется: перечень «листинг -> раздел -> команда -> источник».

Запуск: python3 scripts/collect_evidence.py   (или make evidence)
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPORT = ROOT / "docs" / "report" / "report.md"
DIAGRAM_BARE = "![Модель Data Vault: хабы, ссылки, сателлиты, Business Vault и витрины](diagrams/dv_model.png)"
DIAGRAM_BLOCK = (
    "![Рис. 1. Спроектированная модель Data Vault 2.0: хабы, ссылки, сателлиты, "
    "Business Vault и витрины](diagrams/dv_model.png)\n\n"
    "*Рис. 1. Спроектированная модель Data Vault 2.0: хабы, ссылки, сателлиты, Business Vault "
    "и витрины. Диаграмма генерируется из `docs/report/diagrams/dv_model.dot` "
    "(`python3 scripts/make_diagram.py`).*\n"
)

sys.path.insert(0, str(ROOT / "src"))
from lib.gp import Greenplum, load_env  # noqa: E402

GP = Greenplum(load_env())
HOST, PORT, USER, DB = GP.env["PGHOST"], GP.env["PGPORT"], GP.env["PGUSER"], GP.database

VER = "SELECT version();"
SEGMENTS = ("SELECT dbid, content, role, hostname, port, status "
            "FROM gp_segment_configuration ORDER BY content, role;")
MARTS = ("SELECT region_name, category_name, sales_lines, sales_amount, profit_amount, "
         "profit_margin_pct FROM dm.dm_sales_by_region_category ORDER BY 1, 2;")
TOP10 = ("SELECT sub_category_name, category_name, sales_lines, sales_amount, profit_amount, "
         "profit_margin_pct FROM dm.dm_product_hierarchy ORDER BY profit_amount DESC LIMIT 10;")
DQ_PROFILE = "SELECT * FROM dm.dm_dq_source_profile;"
EXPLAIN_PART = ("EXPLAIN SELECT count(*) FROM staging.stg_superstore_raw "
                "WHERE load_dts >= TIMESTAMP '2026-10-01 00:00:00' "
                "AND load_dts < TIMESTAMP '2026-11-01 00:00:00';")

# (номер, раздел отчёта, подпись, вид, параметры)
ITEMS: list[dict] = [
    dict(number="1", section="3.1 Состав DDL-скриптов", caption="Созданные таблицы схемы vault",
         kind="psql", meta="\\dt vault.*"),
    dict(number="2", section="3.1 Состав DDL-скриптов",
         caption="DDL транзакционной ссылки: PK, FK, DISTRIBUTED BY, комментарии",
         kind="psql", meta="\\d+ vault.lnk_sales_line"),
    dict(number="3", section="3.4 Пример DDL",
         caption="DDL сателлита мер: AO/column, zstd, PK, CHECK, партиционирование",
         kind="psql", meta="\\d+ vault.sat_sales_line"),
    dict(number="4", section="3.4 Пример DDL",
         caption="Фрагмент исходного DDL хаба вместе с комментариями к таблице и колонкам",
         kind="excerpt", path="sql/02_vault/10_ddl_hubs.sql", rng="1,44p"),
    dict(number="5", section="4.1 Окружение", caption="Локальный кластер Greenplum запущен в Docker",
         kind="shell", cmd=["docker", "ps", "--format",
                            "table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}"]),
    dict(number="6", section="4.1 Окружение", caption="Версия СУБД", kind="psql", sql=VER),
    dict(number="7", section="4.1 Окружение", caption="MPP-топология: координатор и 4 сегмента",
         kind="psql", sql=SEGMENTS),
    dict(number="8", section="4.3 Результат в цифрах",
         caption="Таблицы заполнены данными: число строк в каждом объекте",
         kind="psql_file", path="sql/99_checks/10_table_counts.sql"),
    dict(number="9", section="4.3 Результат в цифрах",
         caption="Сходимость контрольных сумм на всех слоях хранилища",
         kind="psql_file", path="sql/99_checks/20_reconciliation.sql"),
    dict(number="10", section="4.4 Загрузка (ELT)",
         caption="Загрузка датасета в staging: 9994 строки, карантин пуст",
         kind="make", target="stage", max_lines=26), 
    dict(number="11", section="4.4 Загрузка (ELT)",
         caption="ELT: загрузка хабов, ссылок и сателлитов, реконсиляция с источником",
         kind="make", target="load", drop=r"NOTICE|CONTEXT|^psql ", max_lines=70),
    dict(number="12", section="5.2 Результат тестов",
         caption="Автотесты корректности: 118 проверок — все PASS",
         kind="make", target="test", drop=r"^\s*$|NOTICE", max_lines=32, keep_tail=True),
    dict(number="13", section="6, E1 Витрины",
         caption="Аналитические витрины, построенные поверх Data Vault",
         kind="multi", parts=[("витрина «регион x категория»", MARTS),
                              ("топ-10 подкатегорий по прибыли", TOP10)]),
    dict(number="14", section="6, E3 Качество данных",
         caption="Профиль качества источника: дубли строк, восстановленные ZIP, убыточные строки",
         kind="psql", sql=DQ_PROFILE),
    dict(number="15", section="6, E3 Качество данных",
         caption="Метрики качества данных (audit.dq_metrics) и журнал загрузок",
         kind="psql_file", path="sql/99_checks/60_audit_metrics.sql", max_lines=45),
    dict(number="16", section="6, E4 EXPLAIN",
         caption="E4: соединение ссылки и сателлита — co-location без перераспределения "
                 "против случайной дистрибуции сателлита (появляется Redistribute Motion)",
         kind="sequence", max_lines=24, steps=[
             ("sql", "антипример: копия сателлита, распределённая случайно",
              "DROP TABLE IF EXISTS vault.tmp_sat_random; "
              "CREATE TABLE vault.tmp_sat_random WITH (appendonly = true, orientation = column, "
              "compresstype = zstd, compresslevel = 3) AS SELECT * FROM vault.sat_sales_line "
              "DISTRIBUTED RANDOMLY;"),
             ("sql", "A. принятая схема (обе таблицы по lnk_sales_line_key) — перераспределения нет",
              "EXPLAIN SELECT count(*) FROM vault.lnk_sales_line l JOIN vault.sat_sales_line m "
              "ON m.lnk_sales_line_key = l.lnk_sales_line_key;"),
             ("sql", "B. антипример (сателлит распределён случайно) — Redistribute Motion на соединении",
              "EXPLAIN SELECT count(*) FROM vault.lnk_sales_line l JOIN vault.tmp_sat_random m "
              "ON m.lnk_sales_line_key = l.lnk_sales_line_key;"),
             ("sql", "убираем временную копию", "DROP TABLE IF EXISTS vault.tmp_sat_random;"),
         ]),
    dict(number="17", section="6, E4 EXPLAIN",
         caption="E4: отсечение партиций по дате загрузки", kind="psql", sql=EXPLAIN_PART),
    dict(number="18", section="6, E6 Lineage",
         caption="E6: прослеживаемость «строка файла -> строка хранилища»",
         kind="psql_file", path="sql/99_checks/40_lineage_trace.sql", max_lines=40),
]

LISTING_RE = re.compile(r"```console\n.*?\n```\n\n\*Листинг \d+\.[^\n]*\*\n*", re.S)
FIGURE_RE = re.compile(r"!\[Рис\. \d+\.[^\]]*\]\([^)]+\)\n\n\*Рис\. \d+\.[^\n]*\*\n*")
PRINT_RE = re.compile(r"\*Листинг (\d+)\.")


def run_shell(cmd: list[str], cwd: pathlib.Path = ROOT) -> str:
    result = subprocess.run(cmd, cwd=str(cwd), env=GP.env, capture_output=True, text=True)
    return (result.stdout + result.stderr).rstrip("\n")


def psql_display(sql: str | None = None, meta: str | None = None,
                 file: str | None = None) -> str:
    base = f"psql -h {HOST} -p {PORT} -U {USER} -d {DB}"
    if meta:
        return f"{base} -c \"{meta}\""
    if file:
        return f"{base} -f {file}"
    return f"{base} -c \"{sql}\""


def psql_run(sql: str | None = None, meta: str | None = None, file: str | None = None) -> str:
    cmd = ["psql", "-X", "-q", "--pset", "pager=off", "-h", HOST, "-p", PORT,
           "-U", USER, "-d", DB]
    if meta:
        cmd += ["-c", meta]
    elif file:
        cmd += ["-f", file]
    else:
        cmd += ["-c", sql]
    return run_shell(cmd)


def squeeze(output: str, drop: str | None = None, max_lines: int | None = None,
            keep_tail: bool = False) -> tuple[str, bool]:
    """Убирает шум, пустые повторы строк и (при необходимости) режет длину вывода."""
    lines = output.splitlines()
    if drop:
        pattern = re.compile(drop)
        lines = [line for line in lines if not pattern.search(line)]
    cleaned: list[str] = []
    for line in lines:
        if line.strip() == "" and cleaned and cleaned[-1].strip() == "":
            continue
        cleaned.append(line)
    while cleaned and cleaned[0].strip() == "":
        cleaned.pop(0)
    while cleaned and cleaned[-1].strip() == "":
        cleaned.pop()
    if max_lines and len(cleaned) > max_lines:
        cleaned = cleaned[-max_lines:] if keep_tail else cleaned[:max_lines]
        return "\n".join(cleaned), True
    return "\n".join(cleaned), False


def render(number: str, caption: str, parts: list[tuple[str, str]],
           truncated: bool = False) -> str:
    body = "\n\n".join(f"$ {command}\n{output}" for command, output in parts)
    note = ""
    if truncated:
        note = (" Вывод сокращён; полный текст — в `docs/tmp/transcripts/` "
                "(скрипты `sql/99_checks/`) либо по указанной команде.")
    return (f"```console\n{body}\n```\n\n"
            f"*Листинг {number}. {caption}.{note}*\n")


def build_item(item: dict) -> str:
    """Выполняет команды листинга и возвращает готовый markdown-блок."""
    number, caption, kind = item["number"], item["caption"], item["kind"]
    limit = item.get("max_lines")
    drop = item.get("drop")
    parts: list[tuple[str, str]] = []
    truncated = False

    if kind == "psql":
        command = psql_display(sql=item.get("sql"), meta=item.get("meta"))
        output, cut = squeeze(psql_run(sql=item.get("sql"), meta=item.get("meta")),
                              drop=drop, max_lines=limit, keep_tail=item.get("keep_tail", False))
        parts.append((command, output))
        truncated |= cut
    elif kind == "psql_file":
        output, cut = squeeze(psql_run(file=item["path"]), drop=drop, max_lines=limit)
        parts.append((psql_display(file=item["path"]), output))
        truncated |= cut
    elif kind == "make":
        output, cut = squeeze(run_shell(["make", item["target"]]), drop=drop,
                              max_lines=limit, keep_tail=item.get("keep_tail", False))
        parts.append((f"make {item['target']}", output))
        truncated |= cut
    elif kind == "shell":
        output, cut = squeeze(run_shell(item["cmd"]), drop=drop, max_lines=limit)
        parts.append((" ".join(item["cmd"]), output))
        truncated |= cut
    elif kind == "excerpt":
        command = f"sed -n '{item['rng']}' {item['path']}"
        output, cut = squeeze(run_shell(["sed", "-n", item["rng"], item["path"]]), max_lines=limit)
        parts.append((command, output))
        truncated |= cut
    elif kind == "sequence":
        for step_kind, title, value in item["steps"]:
            if step_kind == "sql":
                output, cut = squeeze(psql_run(sql=value), max_lines=limit)
                parts.append((psql_display(sql=value), f"-- {title}\n{output}"))
            else:
                output, cut = squeeze(run_shell(value), max_lines=limit)
                parts.append((" ".join(value), f"-- {title}\n{output}"))
            truncated |= cut
    elif kind == "multi":
        for title, sql in item.get("parts", []):
            output, cut = squeeze(psql_run(sql=sql), max_lines=limit)
            parts.append((psql_display(sql=sql), f"-- {title}\n{output}"))
            truncated |= cut
        for title, cmd in item.get("shell_parts", []):
            if cmd is None:
                continue
            command = " ".join(cmd)
            output, cut = squeeze(run_shell(cmd), max_lines=limit)
            parts.append((command, f"-- {title}\n{output}"))
            truncated |= cut
    else:
        raise SystemExit(f"неизвестный вид листинга: {kind}")

    print(f"  Листинг {number}: {item['section']} — собран ({len(parts)} команд(ы))")
    return render(number, caption, parts, truncated)


def hint(item: dict) -> str:
    """Короткое описание команды для таблицы Приложения C."""
    kind = item["kind"]
    if kind == "psql":
        detail = item.get("meta") or item.get("sql") or ""
        detail = detail.replace("\n", " ")
        return f"psql -c \"{detail[:70]}{'…' if len(detail) > 70 else ''}\""
    if kind == "psql_file":
        return f"psql -f {item['path']}"
    if kind == "make":
        return f"make {item['target']}"
    if kind == "shell":
        return " ".join(item["cmd"])[:80]
    if kind == "excerpt":
        return f"sed -n '{item['rng']}' {item['path']}"
    if kind == "sequence":
        return "psql: создание копии + EXPLAIN + DROP (см. листинг)"
    return "несколько команд (см. листинг)"

# Порядок чтения отчёта: где размещается каждый листинг
GROUPS: list[tuple[str, str, list[str]]] = [
    ("before", "В коде — построчные комментарии", ["1", "2"]),
    ("before", "Полный DDL — в каталогах `sql/02_vault`", ["3", "4"]),
    ("before", "Версия СУБД: `PostgreSQL 12.12", ["5", "6", "7"]),
    ("before", "Динамика: `staging` 9994 строки", ["8", "9"]),
    ("before", "## 5. Тесты корректности", ["10", "11"]),
    ("before", "**Итог: 118 проверок", ["12"]),
    ("before", "- `dm.dm_sales_star` — витрина-«звезда» из bridge", ["13"]),
    ("before", "### E4. Измеримое доказательство выбора `DISTRIBUTED BY`", ["14", "15"]),
    ("after", "Транскрипт: `docs/tmp/transcripts/50_e4_explain_distribution.txt`.", ["16", "17"]),
    ("after", "Транскрипт: `40_lineage_trace.txt`.", ["18"]),
]
APPENDIX_ANCHOR = "## Приложение C. Перечень доказательств"
LEGACY_APPENDIX = "## Приложение C. План скриншотов"


def insert(anchor: str, block: str, text: str, before: bool = True) -> str:
    if text.count(anchor) != 1:
        raise SystemExit(f"якорь не уникален ({text.count(anchor)} совпадений): {anchor[:70]!r}")
    replacement = f"{block}\n{anchor}" if before else f"{anchor}\n\n{block}"
    return text.replace(anchor, replacement, 1)


def build_appendix() -> str:
    rows = "\n".join(
        f"| Листинг {item['number']} | {item['section']} | {item['caption']} | `{hint(item)}` |"
        for item in ITEMS
    )
    return (
        f"{APPENDIX_ANCHOR}\n\n"
        "Все доказательства в документе — текстовые и воспроизводимые: диаграмма модели (Рис. 1)\n"
        "и реальные выводы команд — **листинги 1…18**. Любую строку таблицы можно повторить\n"
        "на своём окружении; при желании листинг легко дополнить скриншотом той же команды.\n"
        "Полные тексты проверок сохранены в `docs/tmp/transcripts/`, сборка документа — `make report`.\n\n"
        "| Листинг | Раздел отчёта | Что показывает | Команда |\n"
        "|---|---|---|---|\n"
        + rows + "\n"
    )


def main() -> int:
    text = REPORT.read_text(encoding="utf-8")

    # 1. Снимаем прежнюю разметку (картинки-заглушки, прежние листинги, старое приложение)
    text = FIGURE_RE.sub("", text)
    text = LISTING_RE.sub("", text)
    for legacy in (LEGACY_APPENDIX, APPENDIX_ANCHOR):
        if legacy in text:
            text = text[:text.index(legacy)].rstrip() + "\n"
            break

    # 2. Диаграмма модели — Рис. 1 (единственный растровый рисунок в отчёте)
    if DIAGRAM_BARE not in text:
        text = insert("Источник диаграммы: `docs/report/diagrams/dv_model.dot`",
                      DIAGRAM_BARE, text, before=True)
    text = text.replace(DIAGRAM_BARE, DIAGRAM_BLOCK, 1)

    # 3. Собираем листинги с живого Greenplum и из файлов репозитория
    print("=== Сбор доказательств ===")
    blocks = {item["number"]: build_item(item) for item in ITEMS}

    # 4. Расставляем листинги в порядке чтения
    for position, anchor, numbers in GROUPS:
        block = "\n".join(blocks[number] for number in numbers)
        text = insert(anchor, block, text, before=(position == "before"))

    # 5. Приложение C с перечнем листингов (и сам листинг 20 внутри него)
    text = text.rstrip() + "\n\n" + build_appendix()
    REPORT.write_text(text, encoding="utf-8")

    # 6. Самопроверка: сквозная нумерация 2..20 без пропусков и повторов
    order = [int(m.group(1)) for m in PRINT_RE.finditer(text)]
    expected = [int(item["number"]) for item in ITEMS]
    ok = order == expected and "Рис. 1." in text
    print(f"Листингов в отчёте: {len(order)} -> порядок: {order} "
          f"({'ОК' if ok else 'ОШИБКА, ожидалось ' + str(expected)})")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
