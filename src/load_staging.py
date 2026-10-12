"""Загрузка датасета в staging-слой Greenplum.

Шаги:
  1) читает data/raw/MANIFEST.json (создаётся src/download_dataset.py) — берёт имя
     файла и sha256 (это же значение используется как версия датасета в хранилище);
  2) готовит CSV с первой колонкой row_num — детерминированный номер строки данных,
     что даёт точную прослеживаемость «строка файла -> строки Data Vault»;
  3) последовательно выполняет sql/01_staging/20_load_staging.sql,
     30_transform_staging.sql и 40_load_lineage.sql (передавая параметры -v);
  4) печатает контрольные суммы — их сверяет с источником набор тестов.

Запуск: python3 src/load_staging.py  (или make stage)
"""

from __future__ import annotations

import csv
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from lib.gp import ROOT, Greenplum, load_env  # noqa: E402

RAW_DIR = ROOT / "data" / "raw"
TMP_DIR = ROOT / "data" / "tmp"
SQL_DIR = ROOT / "sql" / "01_staging"
REC_SRC = "kaggle_superstore"


def sha256_of(path: pathlib.Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare_rowno_csv(src: pathlib.Path, dst: pathlib.Path) -> int:
    """Добавляет колонку row_num (1..N по строкам данных) и убирает BOM/пустые строки."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with src.open(encoding="utf-8-sig", newline="") as fin, \
            dst.open("w", encoding="utf-8", newline="") as fout:
        reader = csv.reader(fin)
        writer = csv.writer(fout)
        writer.writerow(["row_num"] + [c.strip() for c in next(reader)])
        for row in reader:
            if not row or all(not cell.strip() for cell in row):
                continue
            written += 1
            writer.writerow([written] + [cell.strip() for cell in row])
    return written


def resolve_inputs() -> tuple[pathlib.Path, dict[str, str]]:
    """Определяет исходный CSV и его версию (по MANIFEST.json или пересчётом sha256)."""
    manifest_path = RAW_DIR / "MANIFEST.json"
    manifest: dict[str, str] = {}
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    csv_name = pathlib.Path(manifest.get("file", "data/raw/SampleSuperstore.csv")).name
    csv_path = RAW_DIR / csv_name
    if not csv_path.exists():
        candidates = sorted(RAW_DIR.glob("*.csv"))
        if not candidates:
            raise SystemExit(
                f"не найден CSV в {RAW_DIR}. Сначала выполните: make download"
            )
        csv_path = candidates[0]

    file_hash = manifest.get("sha256") or sha256_of(csv_path)
    return csv_path, {
        "file_name": csv_path.name,
        "file_hash": file_hash,
        "rec_src": REC_SRC,
    }


def main() -> int:
    load_env()
    csv_path, params = resolve_inputs()

    prepared = TMP_DIR / "stg_superstore_with_rowno.csv"
    rows = prepare_rowno_csv(csv_path, prepared)
    params["file_path"] = prepared.as_posix()

    print(f"Источник       : {csv_path.relative_to(ROOT)}")
    print(f"sha256 (версия): {params['file_hash']}")
    print(f"Подготовлено   : {prepared.relative_to(ROOT)} (строк данных: {rows})")

    gp = Greenplum()
    print(f"Greenplum      : {gp.env['PGHOST']}:{gp.env['PGPORT']} / {gp.database}")
    print(f"Версия сервера : {gp.server_version().split(',')[0]}")

    for script in ("20_load_staging.sql", "30_transform_staging.sql", "40_load_lineage.sql"):
        print(f"\n=== {script} ===")
        gp.psql(file=SQL_DIR / script, variables=params, tuples_only=False, echo=True)

    print("\nStaging загружен. Далее: make load")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
