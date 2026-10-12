"""Профилирование датасета (EDA) на стандартной библиотеке Python.

Скрипт отвечает на вопросы, необходимые для проектирования Data Vault:
  * полный список колонок и их кардинальности;
  * какие поля являются бизнес-ключами (уникальность и устойчивость);
  * какие иерархии присутствуют (подкатегория -> категория, штат -> регион, ...);
  * сколько получится строк в хабах/ссылках/сателлитах;
  * качество данных: дубли, NULL, потерянные ведущие нули в ZIP, диапазоны мер;
  * контрольные суммы для последующей сверки с хранилищем.

Результат: отчёт в консоль + data/tmp/profile.json (используется в отчёте и тестами).
"""

from __future__ import annotations

import csv
import json
import pathlib
import sys
from decimal import Decimal

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from lib.gp import ROOT  # noqa: E402

RAW_DIR = ROOT / "data" / "raw"
TMP_DIR = ROOT / "data" / "tmp"

MEASURES = ["Sales", "Quantity", "Discount", "Profit"]
HUB_KEYS = ["City", "State", "Postal Code", "Sub-Category", "Ship Mode", "Segment"]


def read_rows(path: pathlib.Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        columns = list(reader.fieldnames or [])
        rows = [{k: (v or "").strip() for k, v in row.items()} for row in reader]
    return columns, rows


def main() -> int:
    csv_files = sorted(RAW_DIR.glob("*.csv"))
    if not csv_files:
        raise SystemExit(f"в {RAW_DIR} нет CSV. Сначала: make download")
    path = csv_files[0]
    columns, rows = read_rows(path)
    total = len(rows)

    distinct: dict[str, int] = {}
    low_card: dict[str, list[str]] = {}
    for column in columns:
        values = {row[column] for row in rows}
        distinct[column] = len(values)
        if len(values) <= 6:
            low_card[column] = sorted(values)

    cat_of_sub: dict[str, set[str]] = {}
    region_of_state: dict[str, set[str]] = {}
    state_of_city_postal: dict[tuple[str, str], set[str]] = {}
    for row in rows:
        cat_of_sub.setdefault(row["Sub-Category"], set()).add(row["Category"])
        region_of_state.setdefault(row["State"], set()).add(row["Region"])
        state_of_city_postal.setdefault(
            (row["Postal Code"], row["City"]), set()
        ).add(row["State"])

    combos = {
        "(City, State)": len({(r["City"], r["State"]) for r in rows}),
        "(Postal Code, City)": len({(r["Postal Code"], r["City"]) for r in rows}),
        "(Postal Code, City, State)": len(
            {(r["Postal Code"], r["City"], r["State"]) for r in rows}
        ),
        "(State, Region)": len({(r["State"], r["Region"]) for r in rows}),
        "(Sub-Category, Category)": len({(r["Sub-Category"], r["Category"]) for r in rows}),
    }

    full_duplicates = total - len({tuple(row[c] for c in columns) for row in rows})
    sales_line_combos = len({tuple(row[c] for c in HUB_KEYS) for row in rows})
    line_versions = len({tuple(row[c] for c in HUB_KEYS + MEASURES) for row in rows})
    sums = {m: sum(Decimal(row[m]) for row in rows) for m in MEASURES}
    zip_lengths: dict[str, int] = {}
    for row in rows:
        key = str(len(row["Postal Code"]))
        zip_lengths[key] = zip_lengths.get(key, 0) + 1

    profile = {
        "file": str(path.relative_to(ROOT)),
        "rows": total,
        "columns": columns,
        "distinct_values": distinct,
        "low_cardinality_values": low_card,
        "unique_combinations": combos,
        "sub_category_has_single_category": all(len(v) == 1 for v in cat_of_sub.values()),
        "state_region_is_1_to_1": all(len(v) == 1 for v in region_of_state.values()),
        "postal_city_determines_state": all(
            len(v) == 1 for v in state_of_city_postal.values()
        ),
        "full_duplicate_rows": full_duplicates,
        "expected_rows": {
            "hub_country": distinct["Country"],
            "hub_region": distinct["Region"],
            "hub_state": distinct["State"],
            "hub_location": combos["(Postal Code, City)"],
            "hub_category": distinct["Category"],
            "hub_sub_category": distinct["Sub-Category"],
            "hub_ship_mode": distinct["Ship Mode"],
            "hub_segment": distinct["Segment"],
            "lnk_location_state": combos["(Postal Code, City)"],
            "lnk_state_region": combos["(State, Region)"],
            "lnk_region_country": distinct["Region"],
            "lnk_category_sub_category": distinct["Sub-Category"],
            "lnk_sales_line": sales_line_combos,
            "sat_sales_line": line_versions,
            "sat_location": combos["(Postal Code, City)"],
            "sat_sub_category": distinct["Sub-Category"],
            "sat_ship_mode": distinct["Ship Mode"],
            "sat_segment": distinct["Segment"],
        },
        "postal_code_lengths": zip_lengths,
        "measures_sum": {k: str(v) for k, v in sums.items()},
        "measures_min_max": {
            m: [str(min(Decimal(r[m]) for r in rows)), str(max(Decimal(r[m]) for r in rows))]
            for m in MEASURES
        },
    }

    TMP_DIR.mkdir(parents=True, exist_ok=True)
    (TMP_DIR / "profile.json").write_text(
        json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print(f"Файл            : {profile['file']}")
    print(f"Строк           : {total}, колонок: {len(columns)}")
    print("\nКардинальности (число уникальных значений):")
    for column in columns:
        print(f"  {column:<15} {distinct[column]}")
    print("\nУникальность комбинаций бизнес-ключей:")
    for name, value in combos.items():
        print(f"  {name:<28} {value}")
    print(f"\nПолных дублей строк       : {full_duplicates}")
    print(f"Комбинаций 4 хабов        : {sales_line_combos}")
    print(f"Версий мер (ключи + меры) : {line_versions}")
    print(f"Подкатегория -> категория : 1:N, "
          f"у каждой подкатегории одна категория: {profile['sub_category_has_single_category']}")
    print(f"Штат -> регион            : 1:1 = {profile['state_region_is_1_to_1']}")
    print(f"(ZIP, город) -> штат      : 1:1 = {profile['postal_city_determines_state']}")
    print(f"Длины ZIP                 : {zip_lengths}")
    print(f"Суммы мер                 : {profile['measures_sum']}")
    print(f"Мин/макс мер              : {profile['measures_min_max']}")
    print("\nОжидаемое число строк в объектах хранилища:")
    for name, value in profile["expected_rows"].items():
        print(f"  {name:<26} {value}")
    print(f"\nПрофиль сохранён: {(TMP_DIR / 'profile.json').relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

