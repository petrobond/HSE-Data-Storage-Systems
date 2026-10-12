"""Скачивание датасета с Kaggle в data/raw/.

Два пути (первый предпочтительный, второй — гарантированный фолбэк):
 1) официальный SDK kagglehub (как в сниппете из задания), авторизация через
    переменную окружения KAGGLE_API_TOKEN;
 2) прямой REST-запрос к api.kaggle.com с Bearer-токеном и распаковка zip
    средствами стандартной библиотеки — работает даже если kagglehub не
    установлен/несовместим с версией Python.

Результат: data/raw/<файл>.csv и data/raw/MANIFEST.json с sha256 (lineage).
"""

from __future__ import annotations

import hashlib
import io
import json
import pathlib
import sys
import urllib.request
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from lib.gp import ROOT, load_env  # noqa: E402

DATASET = "roopacalistus/superstore"
RAW_DIR = ROOT / "data" / "raw"


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_via_kagglehub(token: str, target_dir: pathlib.Path) -> pathlib.Path:
    """Путь №1: официальный SDK (сниппет из задания)."""
    import kagglehub  # noqa: PLC0415

    path = pathlib.Path(kagglehub.dataset_download(DATASET))
    return path


def download_via_rest(token: str, target_dir: pathlib.Path) -> pathlib.Path:
    """Путь №2: REST API Kaggle + распаковка zip стандартной библиотекой."""
    url = f"https://www.kaggle.com/api/v1/datasets/download/{DATASET}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=180) as response:  # noqa: S310
        payload = response.read()
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        names = [n for n in archive.namelist() if n.lower().endswith(".csv")]
        if not names:
            raise RuntimeError("в архиве Kaggle не найдено CSV")
        archive.extract(names[0], target_dir)
        return target_dir / names[0]


def main() -> int:
    env = load_env()
    token = env.get("KAGGLE_API_KEY") or env.get("KAGGLE_API_TOKEN") or ""
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    source = "n/a"
    csv_path: pathlib.Path | None = None

    if token:
        try:
            csv_path = download_via_kagglehub(token, RAW_DIR)
            source = "kagglehub"
        except Exception as exc:  # noqa: BLE001 — фолбэк обязателен
            print(f"[warn] kagglehub недоступен ({exc!r}), переходим на REST-фолбэк")

    if csv_path is None or not pathlib.Path(csv_path).exists():
        if not token:
            print("[error] в .env нет KAGGLE_API_KEY", file=sys.stderr)
            return 2
        csv_path = download_via_rest(token, RAW_DIR)
        source = "kaggle-rest"

    csv_path = pathlib.Path(csv_path)
    target = RAW_DIR / csv_path.name
    if csv_path.resolve() != target.resolve():
        target.write_bytes(csv_path.read_bytes())

    with target.open(encoding="utf-8") as handle:
        header = handle.readline().strip()
        rows = sum(1 for _ in handle)

    manifest = {
        "dataset": DATASET,
        "source": source,
        "file": target.relative_to(ROOT).as_posix(),
        "bytes": target.stat().st_size,
        "sha256": sha256_of(target),
        "columns": header.split(","),
        "data_rows": rows,
    }
    (RAW_DIR / "MANIFEST.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
