"""Оркестратор автотестов корректности Data Vault-хранилища в Greenplum.

Запуск: python3 tests/run_tests.py   (или make test)

Что делает:
  1) создаёт каркас тестов (audit.test_results + функции audit.check/check_num);
  2) прогоняет тесты t01..t05, t07 (SQL-скрипты, каждая проверка пишет строку);
  3) t06 — идемпотентность: снимает счётчики, повторно выполняет загрузку и
     сравнивает счётчики (это проверка главного инварианта Data Vault);
  4) t08 — карантин: подкладывает заведомо «плохую» строку и запускает реальный
     загрузчик очищенного слоя с отдельным file_hash, затем проверяет результат;
  5) печатает сводный отчёт и сохраняет его в docs/tmp/transcripts/.

Код возврата: 0 — все проверки PASS, 1 — есть FAIL, 2 — инфраструктурная ошибка.
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "src"))
from lib.gp import ROOT, Greenplum  # noqa: E402

TESTS_DIR = ROOT / "tests" / "sql"
TRANSCRIPTS = ROOT / "docs" / "tmp" / "transcripts"
SEP = "\x1f"  # разделитель полей в строке результата проверки (chr(31) в SQL)

TEST_FILES = [
    "t01_ddl_structure.sql",
    "t02_hash_keys.sql",
    "t03_referential_integrity.sql",
    "t04_satellite_logic.sql",
    "t05_reconciliation.sql",
    "t07_data_quality.sql",
]

LOAD_SCRIPTS = [
    "sql/03_load/10_load_hubs.sql",
    "sql/03_load/20_load_links.sql",
    "sql/03_load/30_load_satellites.sql",
    "sql/03_load/35_load_sat_sales_line.sql",
    "sql/03_load/40_load_business_vault.sql",
    "sql/03_load/50_load_marts.sql",
]

COUNTED_OBJECTS = [
    "vault.hub_location",
    "vault.hub_state",
    "vault.lnk_sales_line",
    "vault.sat_location",
    "vault.sat_sales_line",
    "bv.bridge_sales_line",
    "dm.dm_sales_star",
    "audit.record_lineage",
]

BAD_ROW = """
INSERT INTO staging.stg_superstore_raw
      (src_row_num, ship_mode, segment, country, city, state, postal_code, region,
       category, sub_category, sales, quantity, discount, profit,
       file_name, file_hash, load_dts, rec_src)
VALUES (999999, 'Second Class', 'Consumer', 'United States', 'Testville', 'Test State',
        '1234', 'South', 'Furniture', 'Chairs', '100.00', '-5', '1.50', '10.00',
        'TEST', 'test_hash_bad_row', now()::timestamp(0), 'test');
"""


def count_objects(gp: Greenplum) -> dict[str, int]:
    return {name: int(gp.scalar(f"SELECT count(*) FROM {name}")) for name in COUNTED_OBJECTS}


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def insert_results(gp: Greenplum, rows: list[list[str]]) -> None:
    """Пакетно вставляет результаты проверок в audit.test_results."""
    for start in range(0, len(rows), 25):
        chunk = rows[start:start + 25]
        values = ",\n".join(
            "(" + ", ".join(quote(part) for part in row) + ")" for row in chunk
        )
        gp.psql(
            sql="INSERT INTO audit.test_results "
                "(test_id, test_name, expected, actual, result) VALUES " + values
        )


def run_checks(gp: Greenplum, filename: str, variables: dict[str, str] | None = None) -> int:
    """Выполняет файл проверок и складывает строки результата в audit.test_results."""
    result = gp.psql(file=TESTS_DIR / filename, variables=variables or {}, tuples_only=True)
    rows = [
        line.split(SEP)
        for line in result.stdout.splitlines()
        if SEP in line and len(line.split(SEP)) == 5
    ]
    insert_results(gp, rows)
    failed = sum(1 for row in rows if row[4] == "FAIL")
    print(f"  {filename:<36} проверок: {len(rows):<3} провалено: {failed}")
    return len(rows)


def test_idempotency(gp: Greenplum) -> None:
    """t06: повторная загрузка не должна менять содержимое хранилища."""
    print("\n=== t06: идемпотентность повторной загрузки ===")
    before = count_objects(gp)
    for script in LOAD_SCRIPTS:
        gp.psql(file=ROOT / script, check=True)
    after = count_objects(gp)
    rows = []
    for name in COUNTED_OBJECTS:
        rows.append([
            "t06",
            f"повторная загрузка не изменила число строк в {name}",
            str(before[name]),
            str(after[name]),
            "PASS" if before[name] == after[name] else "FAIL",
        ])
        print(f"  {name:<28} до={before[name]:<8} после={after[name]:<8} {rows[-1][4]}")
    insert_results(gp, rows)


def test_quarantine(gp: Greenplum) -> None:
    """t08: карантин отклоняет некорректную строку реальным загрузчиком."""
    print("\n=== t08: карантин некорректных строк ===")
    gp.psql(sql=BAD_ROW)
    print("  тестовая строка в staging :",
          gp.scalar("SELECT count(*) FROM staging.stg_superstore_raw "
                    "WHERE file_hash = 'test_hash_bad_row'"))
    gp.psql(
        file=ROOT / "sql" / "01_staging" / "30_transform_staging.sql",
        variables={"file_hash": "test_hash_bad_row", "rec_src": "test"},
    )
    print("  отклонено в карантин      :",
          gp.scalar("SELECT count(*) FROM audit.rejected_records "
                    "WHERE file_hash = 'test_hash_bad_row'"))
    run_checks(gp, "t08_quarantine.sql")


def main() -> int:
    gp = Greenplum()
    print(f"Greenplum: {gp.env['PGHOST']}:{gp.env['PGPORT']} / {gp.database}")
    print(f"Версия   : {gp.server_version().split(',')[0]}")

    TRANSCRIPTS.mkdir(parents=True, exist_ok=True)

    print("\n=== подготовка каркаса тестов ===")
    gp.psql(file=TESTS_DIR / "00_test_framework.sql")

    print("\n=== группы проверок ===")
    for name in TEST_FILES:
        run_checks(gp, name)

    test_idempotency(gp)
    test_quarantine(gp)

    print("\n=== сводный отчёт ===")
    report = gp.psql(file=TESTS_DIR / "99_report.sql", tuples_only=False, echo=True)
    (TRANSCRIPTS / "tests_report.txt").write_text(report.stdout, encoding="utf-8")

    failed = int(gp.scalar("SELECT count(*) FROM audit.test_results WHERE result = 'FAIL'"))
    total = int(gp.scalar("SELECT count(*) FROM audit.test_results"))
    print(f"\nИтого проверок: {total}, провалено: {failed}")
    print(f"Отчёт сохранён: {(TRANSCRIPTS / 'tests_report.txt').relative_to(ROOT)}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
