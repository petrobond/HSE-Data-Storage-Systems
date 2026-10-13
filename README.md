# HSE Data Storage Systems — Data Vault в Greenplum

Итоговое домашнее задание модуля 1: **проектирование и реализация хранилища данных методом Data Vault 2.0
в СУБД Greenplum** на датасете Kaggle [`roopacalistus/superstore`](https://www.kaggle.com/datasets/roopacalistus/superstore)
(`SampleSuperstore.csv`, 9994 строки, 13 колонок).

## Что сделано

| Часть задания | Результат |
|---|---|
| **Часть 1. Проектирование** | Модель Data Vault 2.0: **8 хабов, 5 ссылок, 5 сателлитов**, слои staging → raw vault → Business Vault → витрины. Диаграмма: `docs/report/diagrams/dv_model.png` |
| **Часть 2. DDL** | 9 комментированных SQL-скриптов для Greenplum: схемы, staging, хабы, ссылки, сателлиты, Business Vault, витрины. Для каждой таблицы и каждой колонки `vault` — `COMMENT ON` |
| **Часть 3. Реализация** | Хранилище развёрнуто в Greenplum 7 (Docker, координатор + 4 сегмента) и заполнено данными датасета: 9994 строки источника → 6868 ссылок продаж → 9977 версий мер; контрольные суммы сходятся на всех слоях |
| **Тесты** | **118 автотестов — 118 PASS, 0 FAIL** (`make test`) |
| **Сверх программы** | Business Vault (PIT, Bridge, EFS, RTS, reference-таблицы), доказательство выбора дистрибуции через `EXPLAIN ANALYZE`, карантин «грязных» данных, метрики качества, lineage, CI, GP6-совместимый вариант DDL |

Итоговый документ (для Google Docs) собирается командой `make report` → DOCX + PDF
(`docs/tmp/report_build/Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault.{docx,pdf}`).

## Требования

- Docker (Docker Desktop) — локальный Greenplum;
- `psql` (клиент PostgreSQL/Greenplum) — весь ELT и тесты идут через него;
- Python 3.11+ (только стандартная библиотека + `csv`/`json`);
- `pandoc` и (опционально) `xelatex` — сборка DOCX/PDF; `graphviz` — диаграмма.

## Быстрый старт

```bash
cp .env.example .env          # заполнить KAGGLE_API_KEY (см. https://www.kaggle.com/settings/api)
make up && make wait          # поднять Greenplum 7 в Docker (порт 15432)
make ddl                      # создать БД, схемы и все таблицы
make download && make profile # скачать датасет и посмотреть его профиль (EDA)
make stage                    # загрузить CSV в staging (raw -> clean + хеш-ключи)
make load                     # ELT: хабы -> ссылки -> сателлиты -> Business Vault -> витрины
make test                     # 118 автотестов корректности
make screenshots              # текстовые транскрипты проверок (docs/tmp, + опциональный план скриншотов)
make evidence                 # собрать в отчёт реальные выводы команд (листинги)
make report                   # собрать DOCX/PDF для Google Docs
make teardown                 # в конце: снести все следы Greenplum
```

Всё вместе: `make all` (без teardown).

## Структура

```
docker/docker-compose.yml     Greenplum 7 (координатор + 4 сегмента), healthcheck, порт 15432
src/                          скачивание датасета (kagglehub + REST-фолбэк), профилирование, загрузка staging
sql/00_init/                  база, схемы, служебные таблицы audit
sql/01_staging/               DDL staging, загрузка CSV, валидация и карантин, lineage
sql/02_vault/                 DDL: хабы, ссылки, сателлиты (GP7: AO/column + PK)
sql/02_vault_gp6_heap/        вариант сателлитов для Greenplum 6 (heap — в GP6 PK на AO запрещён)
sql/03_load/                  идемпотентный ELT: хабы -> ссылки -> сателлиты -> BV -> витрины -> метрики
sql/04_bv/, sql/05_marts/     Business Vault и витрины
sql/99_checks/                скрипты-доказательства (счётчики, сходимость, EXPLAIN, lineage, метрики)
tests/                        run_tests.py + 8 групп проверок (t01..t08) + сводный отчёт
scripts/                      сбор доказательств в отчёт, транскрипты, диаграмма, сборка отчёта, teardown
yandex/                       опциональные скрипты для Managed Greenplum в Yandex Cloud
docs/report/                  итоговый отчёт (markdown) и диаграмма модели
docs/tmp/                     НЕ коммитится: транскрипты, план скриншотов, сборки отчёта
```

## Модель (кратко)

- **Хабы:** `hub_country`(1), `hub_region`(4), `hub_state`(49), `hub_location`(632; BK = ZIP + город),
  `hub_category`(3), `hub_sub_category`(17), `hub_ship_mode`(4), `hub_segment`(3). В каждом — ghost-запись `000…0`.
- **Ссылки:** иерархии `lnk_location_state`, `lnk_state_region`, `lnk_region_country`,
  `lnk_category_sub_category` + транзакционная `lnk_sales_line` (6868 уникальных комбинаций).
- **Сателлиты:** атрибутивные `sat_location`, `sat_sub_category`, `sat_ship_mode`, `sat_segment` и сателлит мер
  `sat_sales_line` (9977 версий; `HASH_DIFF` по мерам + множитель `SALES_LINE_COUNT`).
- В датасете нет ни дат, ни идентификаторов заказов/клиентов, поэтому гранулярность «строка продажи» описана
  транзакционной ссылкой из четырёх хабов, а меры — в её сателлите. Это позволяет модели **точно** сходиться
  с источником: `SUM(SALES_LINE_COUNT) = 9994`, `SUM(SALES_LINE_COUNT × SALES) = 2 297 200.8603`,
  `SUM(SALES_LINE_COUNT × PROFIT) = 286 397.0217`.

## Проверенные особенности Greenplum (важно для DDL)

| Факт | Как проверено |
|---|---|
| `PRIMARY KEY` на append-optimized/column-oriented таблицах **работает в GP7 и запрещён в GP6** | probe-скрипты на живом сервере; альтернатива для GP6 — `sql/02_vault_gp6_heap/` |
| На AO/CO-таблицах **нельзя объявить FK** (`Trigger is not supported on AOCS yet`) | попытка создать FK на AO-таблице |
| Greenplum **не проверяет FK** даже там, где их можно объявить | предупреждение сервера + тесты t03 (анти-join) |
| `PK`/`UNIQUE` обязан включать ключ дистрибуции, а на партиционированной таблице — и ключ партиции | ошибки сервера при нарушении |
| `CHECK` **реально исполняется** | вставка `discount = 1.5` отклонена |
| `DISTRIBUTED BY` по хеш-ключу убирает `Redistribute Motion` | `EXPLAIN ANALYZE`: co-location vs `DISTRIBUTED RANDOMLY` |
| Отсечение партиций по дате загрузки работает | `EXPLAIN`: «Number of partitions to scan: 1 (out of 13)» |
| `psql` не подставляет переменные внутри `\copy` | задокументировано в `sql/01_staging/20_load_staging.sql` |
| Вложенная запись из функции + чтение распределённой таблицы в одном плане запрещены (`multiple segworker groups`) | архитектура тестов: «чистые» SELECT + сбор результатов в Python |

## Managed Greenplum в Yandex Cloud (опционально)

Скрипты версионно-нейтральны. Для прогона в YC:

1. создать кластер (Greenplum 6 или 7) и получить параметры подключения (`yandex/`);
2. в `.env` указать `GP_HOST`, `GP_PORT=6432`, `GP_USER`, `GP_PASSWORD`, `GP_SSLMODE=require`;
3. выполнить `make ddl && make stage && make load && make test` (на GP6 предварительно применить
   `sql/02_vault_gp6_heap/30_ddl_satellites_gp6.sql` вместо `sql/02_vault/30_ddl_satellites.sql`).

## CI

`.github/workflows/dv-pipeline.yml`: поднимает Greenplum 7 в контейнере, выполняет DDL → загрузку → тесты и
публикует отчёт тестов артефактом. Для доступа к датасету нужно добавить секрет репозитория `KAGGLE_API_TOKEN`
(Settings → Secrets and variables → Actions). Без секрета шаг загрузки данных пропускается с пояснением.

## Итоговый документ

`docs/report/report.md` → `make report` → **четыре** артефакта в `docs/tmp/report_build/`:

| Файл | Формат | Ориентация |
|---|---|---|
| `Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault.docx` | DOCX (импорт в Google Docs) | портрет |
| `Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault.pdf` | PDF (xelatex) | портрет |
| `Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault_landscape.docx` | DOCX | ландшафт |
| `Бондарев_Петр_Итоговое_ДЗ_модуль_1_Data_Vault_landscape.pdf` | PDF | ландшафт |

Отдельные цели: `make report-portrait`, `make report-landscape`, проверка собранного — `make report-check`
(скрипт `scripts/check_report_artifacts.py` печатает ориентацию и размер каждого файла).
Ландшафтная версия удобна для широких терминальных выводов: страница A4 landscape, поля 2 см;
ориентация DOCX задаётся патчем `sectPr/pgSz` (`scripts/make_landscape_docx.py`), PDF — через
`geometry:a4paper,landscape`.

Отчёт построен на **текстовых доказательствах**: диаграмма модели (Рис. 1) и 18 **листингов** —
реальные выводы команд (`docker ps`, `psql`, `make stage/load/test`), которые вставляются в отчёт
автоматически командой `make evidence` (`scripts/collect_evidence.py`). Нумерация листингов сквозная
(1…18) в порядке чтения; Приложение C содержит перечень «листинг → раздел → команда».
Скриншоты не обязательны: любую строку таблицы достаточно повторить на своём окружении
(опциональный план съёмки — `make screenshots` → `docs/tmp/screenshots_plan.md`).

