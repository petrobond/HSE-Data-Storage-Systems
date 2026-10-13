---
title: "Итоговое домашнее задание — модуль 1. Проектирование и реализация хранилища данных методом Data Vault в Greenplum"
author: "Бондарев Пётр"
date: "2026"
---

# Бондарев Пётр. Итоговое ДЗ, модуль 1: Data Vault в Greenplum

**Датасет:** Kaggle `roopacalistus/superstore` («Retail Supermarket», файл `SampleSuperstore.csv`).
**СУБД:** Greenplum Database 7.0.0 (локальный кластер: координатор + 4 сегмента в Docker).
**Артефакты работы:** скрипты DDL/ELT — каталоги `sql/`, автотесты — `tests/`, воспроизведение — `Makefile`.

Состав работы по частям задания:

| Часть задания | Что сделано | Где смотреть |
|---|---|---|
| Часть 1. Проектирование | Спроектирована модель Data Vault 2.0: 8 хабов, 5 ссылок, 5 сателлитов + слой Business Vault и витрины; диаграмма и обоснование решений | раздел 2, `docs/report/diagrams/dv_model.png` |
| Часть 2. DDL | 7 комментированных SQL-скриптов создания объектов для Greenplum (схемы, staging, хабы, ссылки, сателлиты, Business Vault, витрины) | раздел 3, `sql/00_init … 05_marts` |
| Часть 3. Реализация | Все объекты созданы и заполнены данными датасета; контрольные суммы сходятся с источником; 118 автотестов проходят | разделы 4–5, `sql/03_load`, `tests/` |
| Сверх программы | Business Vault (PIT/Bridge/EFS/RTS/reference), доказательство выбора дистрибуции через `EXPLAIN ANALYZE`, карантин данных, метрики качества, lineage, CI | раздел 6 |

## 1. Исходные данные и их профиль

### 1.1. Что содержит датасет

В датасете **9994 строки и 13 колонок** — это «плоская» выгрузка строк продаж:

`Ship Mode, Segment, Country, City, State, Postal Code, Region, Category, Sub-Category, Sales, Quantity, Discount, Profit`.

Важно: это **не** классический Superstore-датасет. В нём **нет** `Order ID`, `Customer ID`, `Product ID/Name`,
`Order Date`, `Ship Date`, `Row ID` — то есть **нет идентификаторов событий и нет ни одной даты`.
Именно этот факт определил ключевое проектное решение модели (см. п. 2.4): гранулярность «строка продажи»
пришлось описать как комбинацию бизнес-сущностей, а меры вынести в сателлит ссылки.

### 1.2. Профиль (получен скриптом `src/profile_dataset.py`, не «на глаз»)

| Показатель | Значение |
|---|---|
| Строк в файле | 9994 |
| Колонок | 13 |
| Страна / регион / штат | 1 / 4 / 49 |
| Город / индекс (ZIP) | 531 / 631 |
| Категория / подкатегория | 3 / 17 |
| Способ доставки / сегмент покупателя | 4 / 3 |
| Уникальных пар (Postal Code, City) | **632** |
| Уникальных комбинаций «город+штат» | 604 |
| Полных дублей строк | **17** |
| Уникальных комбинаций четырёх хабов | **6868** |
| Уникальных пар «комбинация + меры» | **9977** |
| Сумма Sales / Profit / Quantity | **2 297 200.8603** / **286 397.0217** / **37 873** |
| Размеры значений | Sales, Profit — до 4 знаков после запятой; Discount — от 0 до 0.8 |

### 1.3. Проблемы качества данных, которые пришлось решать

1. **Потерянные ведущие нули в ZIP.** Индекс в файле хранится как число, поэтому 9545 строк имеют 5-значный
   индекс, а 449 строк — 4-значный (например, `1060` вместо `01060`). Решение: в очищенном слое индекс восстанавливается
   до 5 знаков (`lpad(…,5,'0')`) и хранится как `char(5)`; проблема измерена и зафиксирована метрикой качества.
2. **Полные дубли строк (17 штук).** В «классическом» Data Vault каждая строка транзакции — отдельная запись
   линка, но здесь нет ни номера строки заказа, ни даты, поэтому одинаковые строки неразличимы. Решение:
   одинаковые строки «схлопываются» в одну версию сателлита, а их количество сохраняется множителем
   `SALES_LINE_COUNT` — за счёт этого модель **точно** сходится с источником (9994 строки, суммы совпадают).
3. **Отсутствие дат.** Версии в сателлитах не имеют временной шкалы источника; `VALID_FROM` фиксирует дату
   загрузки, `VALID_TO` открыт (`NULL`), метки `ACTIVE_FLAG`/`DELETED_FLAG` заполнены. При появлении в источнике
   даты заказа механизм type-2 включится штатно — структура таблиц не меняется.
## 2. Часть 1. Проектирование хранилища методом Data Vault

### 2.1. Архитектура слоёв

Реализована трёхуровневая архитектура Data Vault 2.0 (материалы вебинара 3) плюс служебный слой:

| Слой | Схема | Назначение |
|---|---|---|
| Staging/ODS | `staging` | сырые данные источника «как есть» + очищенный типизированный слой с хеш-ключами |
| DDS (raw vault) | `vault` | хабы, ссылки, сателлиты — модель Data Vault 2.0 |
| Business Vault | `bv` | производные структуры: reference-таблицы, PIT, Bridge, effectivity- и record-tracking-сателлиты |
| Data marts | `dm` | витрины и представления для аналитики |
| Служебный | `audit` | журнал загрузок, карантин, метрики качества, lineage, результаты тестов |

### 2.2. Состав модели

**Хабы (8)** — центральные бизнес-сущности; состав: `<HUB>_KEY char(32) PK`, бизнес-ключ, `LOAD_DTS`, `REC_SRC`:

| Хаб | Бизнес-ключ | Записей (без ghost) |
|---|---|---|
| `hub_country` | `country_name` | 1 |
| `hub_region` | `region_name` | 4 |
| `hub_state` | `state_name` | 49 |
| `hub_location` | `postal_code` + `city_name` | **632** |
| `hub_category` | `category_name` | 3 |
| `hub_sub_category` | `sub_category_name` | 17 |
| `hub_ship_mode` | `ship_mode_name` | 4 |
| `hub_segment` | `segment_name` | 3 |

**Ссылки (5)** — связи и иерархии; состав: `<LNK>_KEY char(32) PK`, хеш-ключи хабов-участников (FK),
денормализованные бизнес-ключи, `LOAD_DTS`, `REC_SRC`:

| Ссылка | Смысл | Записей |
|---|---|---|
| `lnk_location_state` | локация → штат | 632 |
| `lnk_state_region` | штат → регион | 49 |
| `lnk_region_country` | регион → страна | 4 |
| `lnk_category_sub_category` | категория → подкатегория | 17 |
| `lnk_sales_line` | **транзакционная ссылка «строка продажи»**: локация + подкатегория + способ доставки + сегмент | **6868** |

**Сателлиты (5)** — описательные атрибуты и история; состав: родительский хеш-ключ, `HASH_DIFF`, атрибуты,
`LOAD_DTS`, `REC_SRC`, `VALID_FROM`, `VALID_TO`, `ACTIVE_FLAG`, `DELETED_FLAG`:

| Сателлит | Атрибуты | Записей |
|---|---|---|
| `sat_location` | штат, регион, страна локации | 632 |
| `sat_sub_category` | категория подкатегории | 17 |
| `sat_ship_mode` | способ доставки + производный `SHIP_SPEED_RANK` | 4 |
| `sat_segment` | сегмент + производный `SEGMENT_TYPE` (B2B/B2C) | 3 |
| `sat_sales_line` | **меры строки продажи**: `SALES_AMOUNT`, `QUANTITY`, `DISCOUNT_RATE`, `PROFIT_AMOUNT`, `SALES_LINE_COUNT` | **9977** |

**Business Vault и витрины** (см. раздел 6): `ref_ship_mode`, `ref_segment`, `efs_location_state`,
`efs_state_region`, `rts_hub_record`, `pit_location`, `bridge_sales_line`,
`dm_sales_by_region_category`, `dm_product_hierarchy`, `dm_sales_star`, `dm_dq_source_profile`, `v_sales_line_current`.

### 2.3. Правила именования и хеширования

- Хеш-ключи: `md5()` → `char(32)` (как в методологии и в примерах вебинара 3).
- Нормализация бизнес-ключей перед хешированием: `upper(trim(coalesce(x,'')))` — устраняет различия регистра и
  пробелов, а `coalesce` защищает от NULL-семантики конкатенации.
- Хеш-ключ **ссылки** считается от **бизнес-ключей** хабов-участников (а не от их хеш-ключей), порядок
  фиксирован и задокументирован, например:
  `lnk_sales_line_key = md5(upper(postal_code) || '|' || upper(city_name) || '|' || upper(sub_category_name) || '|' || upper(ship_mode_name) || '|' || upper(segment_name))`.
- `HASH_DIFF` сателлита — `md5` от набора атрибутов; для `sat_sales_line` это меры:
  `md5(sales_amount || '|' || quantity || '|' || discount_rate || '|' || profit_amount)`.
- **Ghost-записи (zero-key)** `000…0` = «неизвестный член» загружаются во все хабы — стандартная практика DV 2.0,
  гарантирующая, что ссылки никогда не «сломаются» при появлении неполных данных.

### 2.4. Ключевое проектное решение (и рассмотренные альтернативы)

**Проблема:** в источнике нет ни идентификатора строки продажи, ни даты, а 17 строк полностью дублируются.
Прямолинейный подход «хаб заказа + сателлит» здесь невозможен.

**Принятое решение:** гранулярность «строка продажи» описана **транзакционной ссылкой** `lnk_sales_line`
по четырём хабам, а сами меры хранятся в **сателлите ссылки** `sat_sales_line`, где:

- идентичность строки задаёт пара `(LNK_SALES_LINE_KEY, HASH_DIFF)` → 9977 уникальных версий мер;
- количество совпавших строк источника сохраняет множитель `SALES_LINE_COUNT` (17 дублей);
- итог сходится с источником: `SUM(SALES_LINE_COUNT) = 9994`,
  `SUM(SALES_LINE_COUNT × SALES) = 2 297 200.8603`, `SUM(SALES_LINE_COUNT × PROFIT) = 286 397.0217`,
  `SUM(SALES_LINE_COUNT × QUANTITY) = 37 873`.

**Рассмотренные альтернативы и почему отклонены:**

| Альтернатива | Причина отказа |
|---|---|
| Включить меры в хеш-ключ самой ссылки (row-hash) | ссылка перестала бы быть «связью сущностей»; правка меры в источнике создавала бы новую «сделку», а не новую версию; теряется смысл линка как ассоциации |
| Добавить синтетический `ROW ID` (последовательность) как бизнес-ключ | ключ не является устойчивым: перезагрузка файла меняет нумерацию → нарушается идемпотентность и история |
| Моделировать «заказ» и «клиента» | в датасете нет `Order ID`/`Customer ID` — хаб был бы пустой абстракцией. Модель готова к расширению: при появлении источника с идентификаторами добавляются `hub_customer`, `hub_order`, `hub_product` и связывающие ссылки **без изменения существующих таблиц** |
| Хранить меры прямо в ссылке (non-historized link) | допустимо, но тогда теряется разделение «связь» и «изменяемые атрибуты связи»; версионирование мер через сателлит даёт историю |

### 2.5. Диаграмма модели

![Рис. 1. Спроектированная модель Data Vault 2.0: хабы, ссылки, сателлиты, Business Vault и витрины](diagrams/dv_model.png)

*Рис. 1. Спроектированная модель Data Vault 2.0: хабы, ссылки, сателлиты, Business Vault и витрины. Диаграмма генерируется из `docs/report/diagrams/dv_model.dot` (`python3 scripts/make_diagram.py`).*

Источник диаграммы: `docs/report/diagrams/dv_model.dot` (рендер — `scripts/make_diagram.py`).

## 3. Часть 2. SQL-код создания таблиц (DDL) для Greenplum

### 3.1. Состав скриптов

| Скрипт | Что создаёт |
|---|---|
| `sql/00_init/00_create_database.sql` | база `vault_dv` (идемпотентно) |
| `sql/00_init/10_create_schemas.sql` | схемы `staging`, `vault`, `bv`, `dm`, `audit` + комментарии |
| `sql/00_init/20_audit_tables.sql` | журнал загрузок, карантин, метрики качества, lineage |
| `sql/01_staging/10_ddl_staging.sql` | `stg_superstore_raw` (TEXT 1:1, AO/column, zstd, партиции по дате) и `stg_superstore_clean` (типы + хеш-ключи) |
| `sql/02_vault/10_ddl_hubs.sql` | 8 хабов (heap, PK, комментарии) |
| `sql/02_vault/20_ddl_links.sql` | 5 ссылок (heap, PK, 12 внешних ключей, комментарии) |
| `sql/02_vault/30_ddl_satellites.sql` | 5 сателлитов (AO/column + zstd, PK, CHECK, партиционирование `sat_sales_line`) |
| `sql/04_bv/10_ddl_business_vault.sql` | 7 объектов Business Vault (reference, EFS, RTS, PIT, Bridge) |
| `sql/05_marts/10_ddl_marts.sql` | 3 materialized view, витрина-«звезда», представление |

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "\dt vault.*"
                           List of tables
 Schema |             Name             |       Type        |  Owner  
--------+------------------------------+-------------------+---------
 vault  | hub_category                 | table             | gpadmin
 vault  | hub_country                  | table             | gpadmin
 vault  | hub_location                 | table             | gpadmin
 vault  | hub_region                   | table             | gpadmin
 vault  | hub_segment                  | table             | gpadmin
 vault  | hub_ship_mode                | table             | gpadmin
 vault  | hub_state                    | table             | gpadmin
 vault  | hub_sub_category             | table             | gpadmin
 vault  | lnk_category_sub_category    | table             | gpadmin
 vault  | lnk_location_state           | table             | gpadmin
 vault  | lnk_region_country           | table             | gpadmin
 vault  | lnk_sales_line               | table             | gpadmin
 vault  | lnk_state_region             | table             | gpadmin
 vault  | sat_location                 | table             | gpadmin
 vault  | sat_sales_line               | partitioned table | gpadmin
 vault  | sat_sales_line_1_prt_10      | table             | gpadmin
 vault  | sat_sales_line_1_prt_11      | table             | gpadmin
 vault  | sat_sales_line_1_prt_12      | table             | gpadmin
 vault  | sat_sales_line_1_prt_13      | table             | gpadmin
 vault  | sat_sales_line_1_prt_2       | table             | gpadmin
 vault  | sat_sales_line_1_prt_3       | table             | gpadmin
 vault  | sat_sales_line_1_prt_4       | table             | gpadmin
 vault  | sat_sales_line_1_prt_5       | table             | gpadmin
 vault  | sat_sales_line_1_prt_6       | table             | gpadmin
 vault  | sat_sales_line_1_prt_7       | table             | gpadmin
 vault  | sat_sales_line_1_prt_8       | table             | gpadmin
 vault  | sat_sales_line_1_prt_9       | table             | gpadmin
 vault  | sat_sales_line_1_prt_p_other | table             | gpadmin
 vault  | sat_segment                  | table             | gpadmin
 vault  | sat_ship_mode                | table             | gpadmin
 vault  | sat_sub_category             | table             | gpadmin
(31 rows)
```

*Листинг 1. Созданные таблицы схемы vault.*

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "\d+ vault.lnk_sales_line"
                                                                                                                                              Table "vault.lnk_sales_line"
        Column        |              Type              | Collation | Nullable | Default | Storage  | Stats target |                                                                                             Description                                                                                             
----------------------+--------------------------------+-----------+----------+---------+----------+--------------+-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 lnk_sales_line_key   | character(32)                  |           | not null |         | extended |              | Хеш-ключ ссылки = md5(upper(trim(postal_code)) || '|' || upper(trim(city_name)) || '|' || upper(trim(sub_category_name)) || '|' || upper(trim(ship_mode_name)) || '|' || upper(trim(segment_name)))
 hub_location_key     | character(32)                  |           | not null |         | extended |              | FK на хаб гео-локаций
 hub_sub_category_key | character(32)                  |           | not null |         | extended |              | FK на хаб подкатегорий товаров
 hub_ship_mode_key    | character(32)                  |           | not null |         | extended |              | FK на хаб способов доставки
 hub_segment_key      | character(32)                  |           | not null |         | extended |              | FK на хаб сегментов покупателей
 postal_code          | character(5)                   |           | not null |         | extended |              | Бизнес-ключ локации (денормализован для профилирования без join)
 city_name            | character varying(100)         |           | not null |         | extended |              | Бизнес-ключ локации (денормализован)
 sub_category_name    | character varying(100)         |           | not null |         | extended |              | Бизнес-ключ подкатегории (денормализован)
 ship_mode_name       | character varying(50)          |           | not null |         | extended |              | Бизнес-ключ способа доставки (денормализован)
 segment_name         | character varying(50)          |           | not null |         | extended |              | Бизнес-ключ сегмента покупателя (денормализован)
 lnk_load_dts         | timestamp(0) without time zone |           | not null |         | plain    |              | Дата загрузки строки продажи
 lnk_rec_src          | character varying(20)          |           | not null |         | extended |              | Источник записи
Indexes:
    "lnk_sales_line_pk" PRIMARY KEY, btree (lnk_sales_line_key)
Foreign-key constraints:
    "lnk_sales_line_fk_location" FOREIGN KEY (hub_location_key) REFERENCES vault.hub_location(hub_location_key)
    "lnk_sales_line_fk_segment" FOREIGN KEY (hub_segment_key) REFERENCES vault.hub_segment(hub_segment_key)
    "lnk_sales_line_fk_ship_mode" FOREIGN KEY (hub_ship_mode_key) REFERENCES vault.hub_ship_mode(hub_ship_mode_key)
    "lnk_sales_line_fk_sub_category" FOREIGN KEY (hub_sub_category_key) REFERENCES vault.hub_sub_category(hub_sub_category_key)
Disabled internal triggers:
    "RI_ConstraintTrigger_c_19458" AFTER INSERT ON vault.lnk_sales_line FROM vault.hub_location NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_ins"()
    "RI_ConstraintTrigger_c_19459" AFTER UPDATE ON vault.lnk_sales_line FROM vault.hub_location NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_upd"()
    "RI_ConstraintTrigger_c_19463" AFTER INSERT ON vault.lnk_sales_line FROM vault.hub_sub_category NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_ins"()
    "RI_ConstraintTrigger_c_19464" AFTER UPDATE ON vault.lnk_sales_line FROM vault.hub_sub_category NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_upd"()
    "RI_ConstraintTrigger_c_19468" AFTER INSERT ON vault.lnk_sales_line FROM vault.hub_ship_mode NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_ins"()
    "RI_ConstraintTrigger_c_19469" AFTER UPDATE ON vault.lnk_sales_line FROM vault.hub_ship_mode NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_upd"()
    "RI_ConstraintTrigger_c_19473" AFTER INSERT ON vault.lnk_sales_line FROM vault.hub_segment NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_ins"()
    "RI_ConstraintTrigger_c_19474" AFTER UPDATE ON vault.lnk_sales_line FROM vault.hub_segment NOT DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION "RI_FKey_check_upd"()
Access method: heap
```

*Листинг 2. DDL транзакционной ссылки: PK, FK, DISTRIBUTED BY, комментарии.*

В коде — построчные комментарии, объясняющие выбор решения; **для каждой таблицы и каждой колонки схемы
`vault` в БД выполнен `COMMENT ON`** (это проверяется автотестом t01 через `pg_description`).

### 3.2. Ключевые решения по типам данных

| Данные | Тип | Почему |
|---|---|---|
| Хеш-ключи (`*_KEY`, `HASH_DIFF`) | `char(32)` | фиксированная длина md5; по методологии DV 2.0 |
| ZIP | `char(5)` | ровно 5 знаков, ведущий ноль восстанавливается при загрузке |
| Наименования сущностей | `varchar(n)` | переменная длина, `n` ≈ фактический максимум по данным (city 100, category 50, …) |
| Меры Sales/Profit | `numeric(14,4)` | точная арифметика (деньги), в источнике до 4 знаков после запятой |
| Quantity | `smallint` | диапазон 1…14 по данным |
| Discount | `numeric(4,2)` | диапазон 0…0.8, плюс `CHECK (0…1)` |
| Даты загрузки | `timestamp(0)` | секунды достаточны |
| Источник записи | `varchar(20)` | короткий код системы (`kaggle_superstore`) |
| Флаги, ранг | `boolean`, `smallint` | компактность |

### 3.3. Специфика Greenplum в DDL (всё проверено на живой СУБД)

| Решение в DDL | Что даёт | Результат проверки |
|---|---|---|
| `DISTRIBUTED BY (<хеш-ключ>)` для хабов, ссылок и сателлитов | co-location: сателлит и родитель лежат на одном сегменте | `EXPLAIN`: в правильной схеме только `Gather Motion`; в антипримере — `Redistribute Motion 4:4` |
| Сателлиты: `WITH (appendonly=true, orientation=column, compresstype=zstd, compresslevel=3)` | append-only + колоночное хранение + компрессия (сателлиты только дописываются) | `pg_am.amname = ao_column`, `reloptions` содержит `compresstype=zstd` |
| Хабы и ссылки — heap (`appendonly=false`) | точечный поиск и возможность объявить FK | 13 таблиц с `amname = heap` |
| `PARTITION BY RANGE (sat_load_dts)` + `DEFAULT PARTITION` | стандарт для больших сателлитов; отсечение партиций | `EXPLAIN`: «Number of partitions to scan: 1 (out of 13)» |
| `PRIMARY KEY` на хеш-ключе; у сателлитов `(parent_key, hash_diff[, load_dts])` | уникальность уровня DV | 18 PK создано; требования GP (PK обязан включать ключ дистрибуции и ключ партиции) выполнены |
| `FOREIGN KEY` в ссылках на хабы (12 ограничений) | декларация целостности | GP предупреждает: *«referential integrity (FOREIGN KEY) constraints are not supported in Greenplum Database, will not be enforced»* → целостность проверяют тесты t03 |
| `CHECK` на меры и справочники | защита от «мусорных» значений | CHECK **реально enforced**: вставка `discount = 1.5` отклонена |
| `COMMENT ON TABLE/COLUMN` | самодокументируемая схема (критерий оценки) | t01: 0 таблиц и 0 колонок в `vault` без комментария |
| Раздельные схемы по слоям + `audit` | изоляция уровней архитектуры | 5 схем с комментариями |

**Важное ограничение, обнаруженное экспериментально:** на append-optimized таблицах Greenplum **нельзя объявить
внешний ключ** — попытка даёт ошибку `Trigger is not supported on AOCS yet` (FK в GP реализуется триггером, а
триггеры на AO/CO не поддерживаются). Поэтому сателлиты объявлены без FK, а целостность «сателлит → родитель»
обеспечивается процессом загрузки и тестами t03/t04. Следствие: **уникальность бизнес-ключей в хабах** нельзя
объявить отдельным `UNIQUE` — он не содержит ключ дистрибуции (ключ дистрибуции — хеш-ключ); GP разрешает такой
`UNIQUE` только при включении в него хеш-ключа. Поэтому уникальность бизнес-ключей обеспечивается конструкцией
модели (хеш-ключ) и проверяется тестом t02.

### 3.4. Пример DDL (фрагмент сателлита мер)

```sql
CREATE TABLE vault.sat_sales_line
(
    lnk_sales_line_key char(32)      NOT NULL, -- PK 1/3: хеш-ключ родительской ссылки = ключ дистрибуции
    hash_diff          char(32)      NOT NULL, -- PK 2/3: md5 мер строки
    sat_load_dts       timestamp(0)  NOT NULL, -- PK 3/3: дата загрузки (ключ партиционирования)
    sat_rec_src        varchar(20)   NOT NULL,
    sales_amount       numeric(14,4) NOT NULL,
    quantity           smallint      NOT NULL,
    discount_rate      numeric(4,2)  NOT NULL,
    profit_amount      numeric(14,4) NOT NULL,
    sales_line_count   integer       NOT NULL, -- множитель одинаковых строк источника
    valid_from         timestamp(0)  NOT NULL,
    valid_to           timestamp(0),
    active_flag        boolean       NOT NULL DEFAULT true,
    deleted_flag       boolean       NOT NULL DEFAULT false,
    CONSTRAINT sat_sales_line_pk PRIMARY KEY (lnk_sales_line_key, hash_diff, sat_load_dts),
    CONSTRAINT sat_sales_line_qty_chk      CHECK (quantity > 0),
    CONSTRAINT sat_sales_line_discount_chk CHECK (discount_rate >= 0 AND discount_rate <= 1),
    CONSTRAINT sat_sales_line_count_chk    CHECK (sales_line_count > 0)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (lnk_sales_line_key)
PARTITION BY RANGE (sat_load_dts)
(
    START (TIMESTAMP '2026-01-01 00:00:00') INCLUSIVE
    END   (TIMESTAMP '2027-01-01 00:00:00') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION p_other
);
```

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "\d+ vault.sat_sales_line"
                                                                                          Partitioned table "vault.sat_sales_line"
       Column       |              Type              | Collation | Nullable | Default | Storage  | Stats target |                                                Description                                                
--------------------+--------------------------------+-----------+----------+---------+----------+--------------+-----------------------------------------------------------------------------------------------------------
 lnk_sales_line_key | character(32)                  |           | not null |         | extended |              | Хеш-ключ родительской ссылки vault.lnk_sales_line (ключ дистрибуции)
 hash_diff          | character(32)                  |           | not null |         | extended |              | Хеш-дифф md5(sales_amount::text||'|'||quantity::text||'|'||discount_rate::text||'|'||profit_amount::text)
 sat_load_dts       | timestamp(0) without time zone |           | not null |         | plain    |              | Дата загрузки версии (ключ партиционирования)
 sat_rec_src        | character varying(20)          |           | not null |         | extended |              | Источник записи
 sales_amount       | numeric(14,4)                  |           | not null |         | main     |              | Сумма продажи (Sales)
 quantity           | smallint                       |           | not null |         | plain    |              | Количество единиц товара (Quantity)
 discount_rate      | numeric(4,2)                   |           | not null |         | main     |              | Ставка скидки (Discount), 0..1
 profit_amount      | numeric(14,4)                  |           | not null |         | main     |              | Прибыль (Profit)
 sales_line_count   | integer                        |           | not null |         | plain    |              | Число идентичных строк источника, схлопнутых в эту версию (для точной реконсиляции)
 valid_from         | timestamp(0) without time zone |           | not null |         | plain    |              | Начало действия версии
 valid_to           | timestamp(0) without time zone |           |          |         | plain    |              | Окончание действия версии (NULL — активна)
 active_flag        | boolean                        |           | not null | true    | plain    |              | Признак активной версии
 deleted_flag       | boolean                        |           | not null | false   | plain    |              | Признак логического удаления
Partition key: RANGE (sat_load_dts)
Indexes:
    "sat_sales_line_pk" PRIMARY KEY, btree (lnk_sales_line_key, hash_diff, sat_load_dts)
Check constraints:
    "sat_sales_line_count_chk" CHECK (sales_line_count > 0)
    "sat_sales_line_discount_chk" CHECK (discount_rate >= 0::numeric AND discount_rate <= 1::numeric)
    "sat_sales_line_qty_chk" CHECK (quantity > 0)
Partitions: vault.sat_sales_line_1_prt_10 FOR VALUES FROM ('2026-09-01 00:00:00') TO ('2026-10-01 00:00:00'),
            vault.sat_sales_line_1_prt_11 FOR VALUES FROM ('2026-10-01 00:00:00') TO ('2026-11-01 00:00:00'),
            vault.sat_sales_line_1_prt_12 FOR VALUES FROM ('2026-11-01 00:00:00') TO ('2026-12-01 00:00:00'),
            vault.sat_sales_line_1_prt_13 FOR VALUES FROM ('2026-12-01 00:00:00') TO ('2027-01-01 00:00:00'),
            vault.sat_sales_line_1_prt_2 FOR VALUES FROM ('2026-01-01 00:00:00') TO ('2026-02-01 00:00:00'),
            vault.sat_sales_line_1_prt_3 FOR VALUES FROM ('2026-02-01 00:00:00') TO ('2026-03-01 00:00:00'),
            vault.sat_sales_line_1_prt_4 FOR VALUES FROM ('2026-03-01 00:00:00') TO ('2026-04-01 00:00:00'),
            vault.sat_sales_line_1_prt_5 FOR VALUES FROM ('2026-04-01 00:00:00') TO ('2026-05-01 00:00:00'),
            vault.sat_sales_line_1_prt_6 FOR VALUES FROM ('2026-05-01 00:00:00') TO ('2026-06-01 00:00:00'),
            vault.sat_sales_line_1_prt_7 FOR VALUES FROM ('2026-06-01 00:00:00') TO ('2026-07-01 00:00:00'),
            vault.sat_sales_line_1_prt_8 FOR VALUES FROM ('2026-07-01 00:00:00') TO ('2026-08-01 00:00:00'),
            vault.sat_sales_line_1_prt_9 FOR VALUES FROM ('2026-08-01 00:00:00') TO ('2026-09-01 00:00:00'),
            vault.sat_sales_line_1_prt_p_other DEFAULT
Access method: ao_column
Options: compresstype=zstd, compresslevel=3
```

*Листинг 3. DDL сателлита мер: AO/column, zstd, PK, CHECK, партиционирование.*

```console
$ sed -n '1,44p' sql/02_vault/10_ddl_hubs.sql
-- =====================================================================
-- 02_vault/10_ddl_hubs.sql
-- ХАБЫ (Hubs) — центральные бизнес-сущности модели Data Vault 2.0.
--
-- Состав хаба (методология Data Vault 2.0, вебинар 3):
--   <HUB>_KEY      char(32) PK  — суррогатный хеш-ключ = md5(нормализованный бизнес-ключ);
--   бизнес-ключ(и)              — натуральный ключ источника (устойчивый, уникальный);
--   <HUB>_LOAD_DTS timestamp(0) — дата появления записи с этим бизнес-ключом;
--   <HUB>_REC_SRC  varchar(20)  — источник записи (record source).
--
-- Проектные решения и их обоснование:
--  1) Перед хешированием бизнес-ключи нормализуются: upper(trim(coalesce(x,''))).
--     Это защищает от «дублей» вида 'Consumer' и ' Consumer ', а coalesce — от
--     NULL-семантики склейки (NULL || 'x' = NULL в SQL).
--  2) Хеш-функция md5 -> char(32): выбрана в методологии Data Vault 2.0 (вебинар 3);
--     128 бит с запасом покрывают объёмы поствавтомобильного учёта, ключ имеет
--     фиксированную длину и не требует обмена с sequence-генераторами.
--  3) Хабы — heap-таблицы (WITH (appendonly = false)): они малы, читаются
--     точечно при загрузке, а на heap можно объявить внешние ключи из ссылок
--     (на append-optimized таблицах GP FK невозможен — проверено: "Trigger is
--     not supported on AOCS yet").
--  4) DISTRIBUTED BY (<HUB>_KEY): линки и сателлиты дистрибутируются по тем же
--     ключам, поэтому соединения выполняются локально, без Motion (см. E4).
--  5) Ограничение PK в GP обязано включать столбцы ключа дистрибуции — здесь
--     это один и тот же <HUB>_KEY, поэтому PK (хеш-ключ) корректен.
--     Следствие: UNIQUE по одному бизнес-ключу объявить нельзя (он не содержит
--     ключ дистрибуции), поэтому уникальность бизнес-ключей обеспечивается
--     конструкцией модели (хеш-ключ) и проверяется автотестами (t02).
--  6) Zero-key (ghost) запись '000...0' = «неизвестный член» — стандарт DV 2.0:
--     загружается всегда, чтобы ссылки на несуществующего члена не «ломались».
-- =====================================================================

-- ---------------------------------------------------------------------
-- HUB_COUNTRY — страна
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_country CASCADE;
CREATE TABLE vault.hub_country
(
    hub_country_key char(32)     NOT NULL, -- PK: md5(upper(trim(country_name)))
    country_name    varchar(100) NOT NULL, -- бизнес-ключ
    hub_load_dts    timestamp(0) NOT NULL,
    hub_rec_src     varchar(20)  NOT NULL,
    CONSTRAINT hub_country_pk PRIMARY KEY (hub_country_key)
)
```

*Листинг 4. Фрагмент исходного DDL хаба вместе с комментариями к таблице и колонкам.*

Полный DDL — в каталогах `sql/02_vault`, `sql/04_bv`, `sql/05_marts`; листинг объектов — в транскриптах
`docs/tmp/transcripts/05_ddl_objects.txt` и `30_storage_distribution.txt`.

## 4. Часть 3. Реализация в Greenplum

### 4.1. Окружение

Задание предполагает Greenplum в Yandex Cloud, однако на момент выполнения кластеров Managed Greenplum в облаке
учётной записи нет, а создание нового — отдельное платное решение. Чтобы реализация была воспроизводимой и не
зависела от внешнего сервиса, развёрнут **локальный Greenplum 7** в Docker (координатор + 4 сегмента, образ
`andruche/greenplum:7-4seg`, arm64 без эмуляции). Все скрипты — обычные SQL-файлы и вызовы `psql`, поэтому тот же
набор команд выполняется и в Managed Greenplum YC: достаточно подставить параметры подключения в `.env`
(в файле оставлен готовый блок для YC: порт 6432, `sslmode=require`).

```console
$ docker ps --format table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}
NAMES     IMAGE                       STATUS        PORTS
gp7       andruche/greenplum:7-4seg   Up 12 hours   0.0.0.0:15432->5432/tcp, [::]:15432->5432/tcp
```

*Листинг 5. Локальный кластер Greenplum запущен в Docker.*

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "SELECT version();"
                                                                                             version                                                                                              
--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 PostgreSQL 12.12 (Greenplum Database 7.0.0 build dev) on aarch64-unknown-linux-gnu, compiled by gcc (Ubuntu 11.4.0-1ubuntu1~22.04.2) 11.4.0, 64-bit compiled on Jan 15 2026 18:28:13 Bhuvnesh C.
(1 row)
```

*Листинг 6. Версия СУБД.*

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "SELECT dbid, content, role, hostname, port, status FROM gp_segment_configuration ORDER BY content, role;"
 dbid | content | role | hostname  | port | status 
------+---------+------+-----------+------+--------
    1 |      -1 | p    | localhost | 5432 | u
    2 |       0 | p    | localhost | 6000 | u
    3 |       1 | p    | localhost | 6001 | u
    4 |       2 | p    | localhost | 6002 | u
    5 |       3 | p    | localhost | 6003 | u
(5 rows)
```

*Листинг 7. MPP-топология: координатор и 4 сегмента.*

Версия СУБД: `PostgreSQL 12.12 (Greenplum Database 7.0.0)`; топология — координатор + 4 сегмента
(транскрипт `00_environment.txt`, представление `gp_segment_configuration`).

### 4.2. Порядок выполнения

```bash
make up && make wait     # поднять Greenplum (Docker) и дождаться готовности
make ddl                 # создать БД, схемы и все таблицы
make download            # скачать датасет с Kaggle (sha256 фиксируется как версия данных)
make profile             # профилирование датасета (EDA)
make stage               # загрузить CSV в staging: raw -> clean + хеш-ключи
make load                # ELT: хабы -> ссылки -> сателлиты -> Business Vault -> витрины
make test                # 118 автотестов корректности
make screenshots         # текстовые транскрипты проверок (docs/tmp)
make evidence            # собрать в отчёт реальные выводы команд (листинги)
make report              # собрать DOCX/PDF для Google Docs
```

### 4.3. Что получилось в цифрах

| Объект | Строк | Комментарий |
|---|---|---|
| `staging.stg_superstore_raw` | 9994 | сырые строки CSV без изменений (TEXT) |
| `staging.stg_superstore_clean` | 9994 | очищенные строки + все хеш-ключи |
| Хабы (8) | 1 / 4 / 49 / 632 / 3 / 17 / 4 / 3 | + ghost-запись `000…0` в каждом |
| Ссылки (5) | 632 / 49 / 4 / 17 / **6868** | иерархии и транзакционная ссылка |
| Сателлиты (5) | 632 / 17 / 4 / 3 / **9977** | версии атрибутов и мер |
| Business Vault | ref 4/3, efs 632/49, rts 721, pit 632, bridge 9977 | производные структуры |
| Витрины | `dm_sales_star` 9977 + 3 materialized view | агрегаты по регионам и категориям |

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -f sql/99_checks/10_table_counts.sql
=== Созданные таблицы и число строк ===
 schema_name |         object_name         |       kind        | rows_ 
-------------+-----------------------------+-------------------+-------
 audit       | dq_metrics                  | table             | 96
 audit       | load_run_log                | table             | 112
 audit       | record_lineage              | table             | 9994
 audit       | rejected_records            | table             | 0
 audit       | test_results                | table             | 118
 bv          | bridge_sales_line           | table             | 9977
 bv          | efs_location_state          | table             | 632
 bv          | efs_state_region            | table             | 49
 bv          | pit_location                | table             | 5056
 bv          | ref_segment                 | table             | 3
 bv          | ref_ship_mode               | table             | 4
 bv          | rts_hub_record              | table             | 721
 dm          | dm_dq_source_profile        | matview           | 
 dm          | dm_product_hierarchy        | matview           | 
 dm          | dm_sales_by_region_category | matview           | 
 dm          | dm_sales_star               | table             | 9977
 dm          | v_sales_line_current        | view              | 
 staging     | stg_superstore_clean        | table             | 9994
 staging     | stg_superstore_raw          | partitioned table | 9994
 vault       | hub_category                | table             | 4
 vault       | hub_country                 | table             | 2
 vault       | hub_location                | table             | 633
 vault       | hub_region                  | table             | 5
 vault       | hub_segment                 | table             | 4
 vault       | hub_ship_mode               | table             | 5
 vault       | hub_state                   | table             | 50
 vault       | hub_sub_category            | table             | 18
 vault       | lnk_category_sub_category   | table             | 17
 vault       | lnk_location_state          | table             | 632
 vault       | lnk_region_country          | table             | 4
 vault       | lnk_sales_line              | table             | 6868
 vault       | lnk_state_region            | table             | 49
 vault       | sat_location                | table             | 632
 vault       | sat_sales_line              | partitioned table | 9977
 vault       | sat_segment                 | table             | 3
 vault       | sat_ship_mode               | table             | 4
 vault       | sat_sub_category            | table             | 17
(37 rows)

=== Итоги по слоям ===
            layer             | tables 
------------------------------+--------
 staging (ODS)                |      2
 vault (DDS: hubs+links+sats) |     18
 bv (Business Vault)          |      7
 dm (витрины и представления) |      5
 audit (служебные)            |      5
(5 rows)
```

*Листинг 8. Таблицы заполнены данными: число строк в каждом объекте.*

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -f sql/99_checks/20_reconciliation.sql
=== Сходимость: источник -> Data Vault -> Business Vault -> витрина ===
                 object                  | lines |    sales     |   profit    | quantity 
-----------------------------------------+-------+--------------+-------------+----------
 staging.stg_superstore_clean (источник) |  9994 | 2297200.8603 | 286397.0217 |    37873
 vault.sat_sales_line (DDS)              |  9994 | 2297200.8603 | 286397.0217 |    37873
 bv.bridge_sales_line                    |  9994 | 2297200.8603 | 286397.0217 |    37873
 dm.dm_sales_star (витрина)              |  9994 | 2297200.8603 | 286397.0217 |    37873
(4 rows)

=== Профиль исходных данных и решённые проблемы качества ===
 rows_total | unique_sales_lines | unique_hub_combinations | unique_locations | zip_with_leading_zero_restored | lines_with_discount | loss_lines | sales_amount | profit_amount | quantity 
------------+--------------------+-------------------------+------------------+--------------------------------+---------------------+------------+--------------+---------------+----------
       9994 |               9977 |                    6868 |              632 |                            449 |                5196 |       1871 | 2297200.8603 |   286397.0217 |    37873
(1 row)

=== Продажи по регионам и категориям (витрина из Data Vault) ===
 region_name |  category_name  | sales_lines | sales_amount | profit_amount | profit_margin_pct 
-------------+-----------------+-------------+--------------+---------------+-------------------
 Central     | Furniture       |         481 |  163797.1638 |    -2871.0494 |             -1.75
 Central     | Office Supplies |        1422 |  167026.4150 |     8879.9799 |              5.32
 Central     | Technology      |         420 |  170416.3120 |    33697.4320 |             19.77
 East        | Furniture       |         601 |  208291.2040 |     3046.1658 |              1.46
 East        | Office Supplies |        1712 |  205516.0550 |    41014.5791 |             19.96
 East        | Technology      |         535 |  264973.9810 |    47462.0351 |             17.91
 South       | Furniture       |         332 |  117298.6840 |     6771.2061 |              5.77
 South       | Office Supplies |         995 |  125651.3130 |    19986.3928 |             15.91
 South       | Technology      |         293 |  148771.9080 |    19991.8314 |             13.44
 West        | Furniture       |         707 |  252612.7435 |    11504.9503 |              4.55
 West        | Office Supplies |        1897 |  220853.2490 |    52609.8490 |             23.82
 West        | Technology      |         599 |  251991.8320 |    44303.6496 |             17.58
(12 rows)
```

*Листинг 9. Сходимость контрольных сумм на всех слоях хранилища.*

Динамика: `staging` 9994 строки → `vault.sat_sales_line` 9977 версий мер, восстанавливающих все 9994 строки
источника → `bv.bridge_sales_line` 9977 → `dm.dm_sales_star` 9977. Контрольные суммы совпадают на всех слоях:
**Sales = 2 297 200.8603**, **Profit = 286 397.0217**, **Quantity = 37 873** (транскрипт `20_reconciliation.txt`).

### 4.4. Особенности реализации загрузки (ELT на SQL)

- CSV загружается клиентским `\copy` (прав на серверные каталоги не требуется — работает и в Docker, и в YC).
- Идемпотентность: каждый шаг — анти-join по хеш-ключу (`INSERT … LEFT JOIN … WHERE … IS NULL`), а перезагрузка
  файла удаляет предыдущий срез по `sha256` → повторный запуск не меняет содержимое хранилища (тест t06).
- Валидация: строки, нарушившие правила качества (R1…R5), **целиком уходят в карантин**
  `audit.rejected_records` с указанием нарушенных правил и не «роняют» загрузку (тест t08).
- Lineage: `audit.record_lineage` связывает номер строки CSV с парой `(lnk_sales_line_key, hash_diff)`, что
  позволяет пройти путь «строка файла → строка хранилища → обратно» (`40_lineage_trace.txt`).
- Защита от «тихой» загрузки: если staging пуст, скрипты ELT останавливаются с ошибкой (`DO $$ … RAISE EXCEPTION`).

```console
$ make stage
python3 src/load_staging.py
Источник       : data/raw/SampleSuperstore.csv
sha256 (версия): ce8db84b6b049b19177ecdc43e46f8da6ce9c3d1784da4bf5dcf597c8b763611
Подготовлено   : data/tmp/stg_superstore_with_rowno.csv (строк данных: 9994)
Greenplum      : localhost:15432 / vault_dv
Версия сервера : PostgreSQL 12.12 (Greenplum Database 7.0.0 build dev) on aarch64-unknown-linux-gnu

=== 20_load_staging.sql ===
--- staging: загрузка CSV в staging.stg_superstore_raw ---
 raw_rows | distinct_row_nums | first_row | last_row 
----------+-------------------+-----------+----------
     9994 |              9994 |         1 |     9994
(1 row)

=== 30_transform_staging.sql ===
--- staging: валидация строк, карантин, формирование очищенного слоя ---
 clean_rows | rejected_rows 
------------+---------------
       9994 |             0
(1 row)

=== 40_load_lineage.sql ===
--- staging: lineage и журнал загрузки ---
--- staging: контрольные суммы (для сверки с источником) ---
 rows_ |  sales_sum   | profit_sum  | quantity_sum | sales_line_combos | measure_versions 
-------+--------------+-------------+--------------+-------------------+------------------
```

*Листинг 10. Загрузка датасета в staging: 9994 строки, карантин пуст. Вывод сокращён; полный текст — в `docs/tmp/transcripts/` (скрипты `sql/99_checks/`) либо по указанной команде.*

```console
$ make load
--- vault: zero-key (ghost) записи ---
--- vault: загрузка новых бизнес-ключей в хабы ---
--- vault: состав хабов (реальные ключи + zero-key) ---
       hub        | real_keys | with_zero_key 
------------------+-----------+---------------
 hub_category     |         3 |             4
 hub_country      |         1 |             2
 hub_location     |       632 |           633
 hub_region       |         4 |             5
 hub_segment      |         3 |             4
 hub_ship_mode    |         4 |             5
 hub_state        |        49 |            50
 hub_sub_category |        17 |            18
(8 rows)

--- vault: ссылки ---
--- vault: состав ссылок ---
           link            | rows_ 
---------------------------+-------
 lnk_category_sub_category |    17
 lnk_location_state        |   632
 lnk_region_country        |     4
 lnk_sales_line            |  6868
 lnk_state_region          |    49
(5 rows)

--- vault: сателлиты хабов ---
--- vault: состав сателлитов хабов ---
    satellite     | rows_ 
------------------+-------
 sat_location     |   632
 sat_segment      |     3
 sat_ship_mode    |     4
 sat_sub_category |    17
(4 rows)

--- vault: сателлит мер строки продажи: агрегация версий мер ---
--- vault: вставка новых версий мер в sat_sales_line ---
--- vault: реконсиляция сателлита мер с источником ---
 versions_expected | versions_loaded | rows_reconciled | sales_reconciled | profit_reconciled | quantity_reconciled 
-------------------+-----------------+-----------------+------------------+-------------------+---------------------
              9977 |            9977 |            9994 |     2297200.8603 |       286397.0217 |               37873
(1 row)

--- bv: reference-таблицы (E7) ---
--- bv: effectivity satellites (E2) ---
--- bv: record tracking satellite по всем хабам (E2) ---
--- bv: point-in-time по гео-локациям (E1) ---
--- bv: bridge продаж (E1: «расплющенная» модель для быстрых запросов) ---
--- bv: состав Business Vault ---
       object       | rows_ 
--------------------+-------
 bridge_sales_line  |  9977
 efs_location_state |   632
 efs_state_region   |    49
 pit_location       |  5688
 ref_segment        |     3
 ref_ship_mode      |     4
 rts_hub_record     |   721
(7 rows)

--- dm: обновление материализованных представлений ---
--- dm: загрузка витрины-«звезды» ---
--- dm: проверка сходимости витрин с источником ---
           object           | lines |    sales     |   profit    
----------------------------+-------+--------------+-------------
 staging (источник)         |  9994 | 2297200.8603 | 286397.0217
 vault.sat_sales_line (DDS) |  9994 | 2297200.8603 | 286397.0217
 bv.bridge_sales_line       |  9994 | 2297200.8603 | 286397.0217
 dm.dm_sales_star           |  9994 | 2297200.8603 | 286397.0217
```

*Листинг 11. ELT: загрузка хабов, ссылок и сателлитов, реконсиляция с источником. Вывод сокращён; полный текст — в `docs/tmp/transcripts/` (скрипты `sql/99_checks/`) либо по указанной команде.*

## 5. Тесты корректности

### 5.1. Как устроены тесты

`tests/run_tests.py` + 8 групп SQL-проверок (`tests/sql/`). Каждая проверка возвращает строку
`test_id | имя | ожидаемое | фактическое | PASS/FAIL`; Python собирает результаты в таблицу `audit.test_results`,
печатает сводный отчёт и возвращает код 1 при наличии FAIL (пригодно для CI). Всего **118 проверок**.

Техническое замечание: проверки реализованы как «чистые» SELECT-функции (`audit.mk_check`), а не как процедуры,
пишущие в таблицу: иначе Greenplum падает с ошибкой *«query plan with multiple segworker groups is not supported»*
при одновременном сканировании распределённой таблицы и записи из функции.

### 5.2. Состав проверок и результат

| Группа | Содержание | Проверок |
|---|---|---|
| t01 | структура DDL: 18 таблиц vault, PK/FK/CHECK, комментарии к каждой таблице и колонке, политика дистрибуции = хеш-ключу, heap для хабов и ссылок, AO/column + zstd для сателлитов, партиционирование | 16 |
| t02 | хеш-ключи: формулы `md5`, уникальность, отсутствие коллизий, нормализация регистра и пробелов, ghost-записи | 16 |
| t03 | ссылочная целостность: 22 анти-join по связям «ссылка→хаб», «сателлит→родитель», «Business Vault→raw vault» | 22 |
| t04 | логика сателлитов: пересчёт `HASH_DIFF`, одна активная версия, непересекающиеся интервалы, множитель дублей | 13 |
| t05 | сходимость с источником: количества, контрольные суммы, кардинальности, агрегаты по разрезам | 25 |
| t06 | идемпотентность: повторная загрузка не меняет счётчики (8 объектов) | 8 |
| t07 | качество данных, Business Vault, reference-таблицы, метрики DQ | 15 |
| t08 | карантин: «плохая» строка отклоняется реальным загрузчиком и не попадает в очищенный слой | 3 |

```console
$ make test
 t06     | повторная загрузка не изменила число строк в vault.hub_location      | 633          | 633          | PASS
 t06     | повторная загрузка не изменила число строк в vault.hub_state         | 50           | 50           | PASS
 t06     | повторная загрузка не изменила число строк в vault.lnk_sales_line    | 6868         | 6868         | PASS
 t06     | повторная загрузка не изменила число строк в vault.sat_location      | 632          | 632          | PASS
 t06     | повторная загрузка не изменила число строк в vault.sat_sales_line    | 9977         | 9977         | PASS
 t07     | bv.ref_segment эквивалентна hub+sat по сегментам                     | 0            | 0            | PASS
 t07     | bv.ref_ship_mode эквивалентна hub+sat по способам доставки           | 0            | 0            | PASS
 t07     | discount всегда в диапазоне 0..1                                     | 0            | 0            | PASS
 t07     | lineage содержит строку для каждой строки источника                  | 9994         | 9994         | PASS
 t07     | pit_location покрывает все гео-локации (последний снимок)            | 632          | 632          | PASS
 t07     | quantity всегда > 0                                                  | 0            | 0            | PASS
 t07     | rts_hub_record покрывает все записи восьми хабов                     | 0            | 0            | PASS
 t07     | в источнике действительно были 4-значные ZIP (проблема качества)     | 449          | 449          | PASS
 t07     | все ZIP в очищенном слое имеют длину 5                               | 0            | 0            | PASS
 t07     | все метрики DQ в статусе OK (audit.dq_metrics)                       | 0            | 0            | PASS
 t07     | гранулярность мер сохранена (4 знака после запятой)                  | true         | true         | PASS
 t07     | журнал загрузки заполнен (audit.load_run_log)                        | true         | true         | PASS
 t07     | карантин пуст: все 9994 строки прошли валидацию                      | 0            | 0            | PASS
 t07     | нет NULL в бизнес-ключах очищенного слоя                             | 0            | 0            | PASS
 t07     | нет NULL в мерах                                                     | 0            | 0            | PASS
 t08     | в карантине указаны конкретные нарушенные правила                    | true         | true         | PASS
 t08     | в очищенный слой «плохая» строка не попала                           | 0            | 0            | PASS
 t08     | строка с нарушением правил отклонена в карантин                      | 1            | 1            | PASS
(118 rows)
--- ИТОГ ---
 checks_total | passed | failed |                                 verdict                                  
--------------+--------+--------+--------------------------------------------------------------------------
          118 |    118 |      0 | ВСЕ ТЕСТЫ ПРОЙДЕНЫ — модель Data Vault корректна и сходится с источником
(1 row)
============================================================
Итого проверок: 118, провалено: 0
Отчёт сохранён: docs/tmp/transcripts/tests_report.txt
```

*Листинг 12. Автотесты корректности: 118 проверок — все PASS. Вывод сокращён; полный текст — в `docs/tmp/transcripts/` (скрипты `sql/99_checks/`) либо по указанной команде.*

**Итог: 118 проверок — 118 PASS, 0 FAIL** («ВСЕ ТЕСТЫ ПРОЙДЕНЫ — модель Data Vault корректна и сходится с
источником»). Полный отчёт: `docs/tmp/transcripts/tests_report.txt`.

### 5.3. Примеры наиболее показательных проверок

```sql
-- сходимость: сумма Sales в хранилище равна сумме в источнике
SELECT audit.mk_check_num('t05', 'сумма Sales в DDS = сумме в источнике', 2297200.8603,
       (SELECT sum(sales_line_count * sales_amount) FROM vault.sat_sales_line));

-- целостность (FK в GP не enforced — проверяем анти-join'ом)
SELECT audit.mk_check('t03', 'lnk_sales_line -> hub_location (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_sales_line l LEFT JOIN vault.hub_location h
    ON h.hub_location_key = l.hub_location_key WHERE h.hub_location_key IS NULL;

-- формула хеш-ключа пересчитывается из данных
SELECT audit.mk_check('t02', 'hub_location_key = md5(postal|city)', '0', count(*)::text)
  FROM vault.hub_location
 WHERE hub_location_key <> repeat('0', 32)
   AND hub_location_key <> md5(upper(postal_code) || '|' || upper(city_name));
```

## 6. Дополнительно реализовано (сверх программы)

Каждый пункт проверен тестами или измерением.

### E1. Business Vault: PIT, Bridge и витрина-«звезда»

- `bv.pit_location` — Point-In-Time: для каждого снимка (даты загрузки) хранит ссылку на актуальную версию
  сателлита локации и на текущие связи иерархии (632 строки на снимок) — избавляет аналитику от дорогих
  временных join'ов.
- `bv.bridge_sales_line` — Bridge: «расплющенная» строка продажи со всеми измерениями и мерами (9977 строк).
  Соединения Data Vault материализуются один раз, после чего витрины считаются без повторных join'ов.
```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "SELECT region_name, category_name, sales_lines, sales_amount, profit_amount, profit_margin_pct FROM dm.dm_sales_by_region_category ORDER BY 1, 2;"
-- витрина «регион x категория»
 region_name |  category_name  | sales_lines | sales_amount | profit_amount | profit_margin_pct 
-------------+-----------------+-------------+--------------+---------------+-------------------
 Central     | Furniture       |         481 |  163797.1638 |    -2871.0494 |             -1.75
 Central     | Office Supplies |        1422 |  167026.4150 |     8879.9799 |              5.32
 Central     | Technology      |         420 |  170416.3120 |    33697.4320 |             19.77
 East        | Furniture       |         601 |  208291.2040 |     3046.1658 |              1.46
 East        | Office Supplies |        1712 |  205516.0550 |    41014.5791 |             19.96
 East        | Technology      |         535 |  264973.9810 |    47462.0351 |             17.91
 South       | Furniture       |         332 |  117298.6840 |     6771.2061 |              5.77
 South       | Office Supplies |         995 |  125651.3130 |    19986.3928 |             15.91
 South       | Technology      |         293 |  148771.9080 |    19991.8314 |             13.44
 West        | Furniture       |         707 |  252612.7435 |    11504.9503 |              4.55
 West        | Office Supplies |        1897 |  220853.2490 |    52609.8490 |             23.82
 West        | Technology      |         599 |  251991.8320 |    44303.6496 |             17.58
(12 rows)

$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "SELECT sub_category_name, category_name, sales_lines, sales_amount, profit_amount, profit_margin_pct FROM dm.dm_product_hierarchy ORDER BY profit_amount DESC LIMIT 10;"
-- топ-10 подкатегорий по прибыли
 sub_category_name |  category_name  | sales_lines | sales_amount | profit_amount | profit_margin_pct 
-------------------+-----------------+-------------+--------------+---------------+-------------------
 Copiers           | Technology      |          68 |  149528.0300 |    55617.8249 |             37.20
 Phones            | Technology      |         889 |  330007.0540 |    44515.7306 |             13.49
 Accessories       | Technology      |         775 |  167380.3180 |    41936.6357 |             25.05
 Paper             | Office Supplies |        1370 |   78479.2060 |    34053.5693 |             43.39
 Binders           | Office Supplies |        1523 |  203412.7330 |    30221.7633 |             14.86
 Chairs            | Furniture       |         617 |  328449.1030 |    26590.1663 |              8.10
 Storage           | Office Supplies |         846 |  223843.6080 |    21278.8264 |              9.51
 Appliances        | Office Supplies |         466 |  107532.1610 |    18138.0054 |             16.87
 Furnishings       | Furniture       |         957 |   91705.1640 |    13059.1436 |             14.24
 Envelopes         | Office Supplies |         254 |   16476.4020 |     6964.1767 |             42.27
(10 rows)
```

*Листинг 13. Аналитические витрины, построенные поверх Data Vault.*

- `dm.dm_sales_star` — витрина-«звезда» из bridge; `dm.dm_sales_by_region_category`, `dm.dm_product_hierarchy` —
  materialized view с маржой прибыли.

### E2. Effectivity Satellite и Record Tracking Satellite

- `bv.efs_location_state`, `bv.efs_state_region` — сателлиты эффективности связей: интервалы активности
  (`valid_from`/`valid_to`) и метки `active_flag`/`deleted_flag`. Если источник перестанет сообщать о связи,
  она закрывается без изменения самой ссылки в raw vault.
- `bv.rts_hub_record` — Record Tracking Satellite: единая «лента» появления записей по всем 8 хабам
  (721 строка — все записи хабов, включая ghost).

### E3. Ghost-записи, карантин и мониторинг качества

- Ghost-записи `000…0` во всех хабах — «неизвестный член» (стандарт Data Vault 2.0).
- `audit.rejected_records` — карантин строк, нарушивших правила качества: тест t08 подкладывает строку с
  `quantity = -5` и `discount = 1.5` и доказывает, что она уходит в карантин с указанием нарушений R3/R4.

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "SELECT * FROM dm.dm_dq_source_profile;"
 rows_total | unique_sales_lines | unique_hub_combinations | unique_locations | zip_with_leading_zero_restored | lines_with_discount | loss_lines | sales_amount | profit_amount | quantity 
------------+--------------------+-------------------------+------------------+--------------------------------+---------------------+------------+--------------+---------------+----------
       9994 |               9977 |                    6868 |              632 |                            449 |                5196 |       1871 | 2297200.8603 |   286397.0217 |    37873
(1 row)
```

*Листинг 14. Профиль качества источника: дубли строк, восстановленные ZIP, убыточные строки.*

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -f sql/99_checks/60_audit_metrics.sql
=== Журнал загрузок (audit.load_run_log) ===
 run_id |   stage   |                         target_table                          | rows_inserted |      load_dts       |      rec_src      |                                     note                                     
--------+-----------+---------------------------------------------------------------+---------------+---------------------+-------------------+------------------------------------------------------------------------------
    921 | staging   | staging.stg_superstore_clean                                  |          9994 | 2026-10-12 21:39:33 | kaggle_superstore | очищенный слой staging с хеш-ключами и lineage
    922 | staging   | audit.record_lineage                                          |          9994 | 2026-10-12 21:39:33 | kaggle_superstore | lineage строк источника
    941 | hub       | vault.hub_*                                                   |           632 | 2026-10-12 21:39:33 | kaggle_superstore | загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)
    961 | link      | vault.lnk_*                                                   |          6868 | 2026-10-12 21:39:33 | kaggle_superstore | загрузка ссылок (индикатор — lnk_sales_line)
    981 | satellite | vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment |           656 | 2026-10-12 21:39:33 | kaggle_superstore | загрузка атрибутивных сателлитов
   1001 | satellite | vault.sat_sales_line                                          |          9977 | 2026-10-12 21:39:33 | kaggle_superstore | версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)
   1021 | bv        | bv.*                                                          |          9977 | 2026-10-12 21:39:33 | kaggle_superstore | Business Vault: ref/efs/rts/pit/bridge
   1041 | dm        | dm.*                                                          |          9977 | 2026-10-12 21:39:34 | kaggle_superstore | витрины: 3 materialized view + dm_sales_star
   1061 | hub       | vault.hub_*                                                   |           632 | 2026-10-12 21:39:36 | kaggle_superstore | загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)
   1081 | link      | vault.lnk_*                                                   |          6868 | 2026-10-12 21:39:36 | kaggle_superstore | загрузка ссылок (индикатор — lnk_sales_line)
   1101 | satellite | vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment |           656 | 2026-10-12 21:39:36 | kaggle_superstore | загрузка атрибутивных сателлитов
   1121 | satellite | vault.sat_sales_line                                          |          9977 | 2026-10-12 21:39:36 | kaggle_superstore | версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)
   1141 | bv        | bv.*                                                          |          9977 | 2026-10-12 21:39:37 | kaggle_superstore | Business Vault: ref/efs/rts/pit/bridge
   1161 | dm        | dm.*                                                          |          9977 | 2026-10-12 21:39:38 | kaggle_superstore | витрины: 3 materialized view + dm_sales_star
   1181 | hub       | vault.hub_*                                                   |           632 | 2026-10-12 21:45:29 | kaggle_superstore | загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)
   1201 | link      | vault.lnk_*                                                   |          6868 | 2026-10-12 21:45:29 | kaggle_superstore | загрузка ссылок (индикатор — lnk_sales_line)
   1221 | satellite | vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment |           656 | 2026-10-12 21:45:29 | kaggle_superstore | загрузка атрибутивных сателлитов
   1241 | satellite | vault.sat_sales_line                                          |          9977 | 2026-10-12 21:45:29 | kaggle_superstore | версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)
   1261 | bv        | bv.*                                                          |          9977 | 2026-10-12 21:45:30 | kaggle_superstore | Business Vault: ref/efs/rts/pit/bridge
   1281 | dm        | dm.*                                                          |          9977 | 2026-10-12 21:45:30 | kaggle_superstore | витрины: 3 materialized view + dm_sales_star
   1301 | staging   | staging.stg_superstore_clean                                  |          9994 | 2026-10-13 08:29:38 | kaggle_superstore | очищенный слой staging с хеш-ключами и lineage
   1302 | staging   | audit.record_lineage                                          |          9994 | 2026-10-13 08:29:38 | kaggle_superstore | lineage строк источника
   1321 | hub       | vault.hub_*                                                   |           632 | 2026-10-13 08:31:25 | kaggle_superstore | загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)
   1341 | link      | vault.lnk_*                                                   |          6868 | 2026-10-13 08:31:25 | kaggle_superstore | загрузка ссылок (индикатор — lnk_sales_line)
   1361 | satellite | vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment |           656 | 2026-10-13 08:31:26 | kaggle_superstore | загрузка атрибутивных сателлитов
   1381 | satellite | vault.sat_sales_line                                          |          9977 | 2026-10-13 08:31:26 | kaggle_superstore | версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)
   1401 | bv        | bv.*                                                          |          9977 | 2026-10-13 08:31:27 | kaggle_superstore | Business Vault: ref/efs/rts/pit/bridge
   1421 | dm        | dm.*                                                          |          9977 | 2026-10-13 08:31:27 | kaggle_superstore | витрины: 3 materialized view + dm_sales_star
   1441 | staging   | staging.stg_superstore_clean                                  |          9994 | 2026-10-13 08:43:39 | kaggle_superstore | очищенный слой staging с хеш-ключами и lineage
   1442 | staging   | audit.record_lineage                                          |          9994 | 2026-10-13 08:43:39 | kaggle_superstore | lineage строк источника
   1461 | hub       | vault.hub_*                                                   |           632 | 2026-10-13 08:43:39 | kaggle_superstore | загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)
   1481 | link      | vault.lnk_*                                                   |          6868 | 2026-10-13 08:43:39 | kaggle_superstore | загрузка ссылок (индикатор — lnk_sales_line)
   1501 | satellite | vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment |           656 | 2026-10-13 08:43:39 | kaggle_superstore | загрузка атрибутивных сателлитов
   1521 | satellite | vault.sat_sales_line                                          |          9977 | 2026-10-13 08:43:39 | kaggle_superstore | версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)
   1541 | bv        | bv.*                                                          |          9977 | 2026-10-13 08:43:40 | kaggle_superstore | Business Vault: ref/efs/rts/pit/bridge
   1561 | dm        | dm.*                                                          |          9977 | 2026-10-13 08:43:40 | kaggle_superstore | витрины: 3 materialized view + dm_sales_star
   1581 | hub       | vault.hub_*                                                   |           632 | 2026-10-13 08:43:42 | kaggle_superstore | загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)
   1601 | link      | vault.lnk_*                                                   |          6868 | 2026-10-13 08:43:42 | kaggle_superstore | загрузка ссылок (индикатор — lnk_sales_line)
   1621 | satellite | vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment |           656 | 2026-10-13 08:43:42 | kaggle_superstore | загрузка атрибутивных сателлитов
   1641 | satellite | vault.sat_sales_line                                          |          9977 | 2026-10-13 08:43:42 | kaggle_superstore | версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)
   1661 | bv        | bv.*                                                          |          9977 | 2026-10-13 08:43:43 | kaggle_superstore | Business Vault: ref/efs/rts/pit/bridge
   1681 | dm        | dm.*                                                          |          9977 | 2026-10-13 08:43:43 | kaggle_superstore | витрины: 3 materialized view + dm_sales_star
```

*Листинг 15. Метрики качества данных (audit.dq_metrics) и журнал загрузок. Вывод сокращён; полный текст — в `docs/tmp/transcripts/` (скрипты `sql/99_checks/`) либо по указанной команде.*

### E4. Измеримое доказательство выбора `DISTRIBUTED BY`

| Вариант дистрибуции | Что показывает `EXPLAIN ANALYZE` |
|---|---|
| ссылка и сателлит по `lnk_sales_line_key` (принято) | `Hash Join` и только `Gather Motion 4:1` — перераспределения данных нет |
| сателлит `DISTRIBUTED RANDOMLY` (антипример) | появляется **`Redistribute Motion 4:4`** — данные гоняются между сегментами |

Дополнительно доказано отсечение партиций: «Number of partitions to scan: 1 (out of 13)».
Транскрипт: `docs/tmp/transcripts/50_e4_explain_distribution.txt`.

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "DROP TABLE IF EXISTS vault.tmp_sat_random; CREATE TABLE vault.tmp_sat_random WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3) AS SELECT * FROM vault.sat_sales_line DISTRIBUTED RANDOMLY;"
-- антипример: копия сателлита, распределённая случайно
NOTICE:  table "tmp_sat_random" does not exist, skipping

$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "EXPLAIN SELECT count(*) FROM vault.lnk_sales_line l JOIN vault.sat_sales_line m ON m.lnk_sales_line_key = l.lnk_sales_line_key;"
-- A. принятая схема (обе таблицы по lnk_sales_line_key) — перераспределения нет
                                               QUERY PLAN                                               
--------------------------------------------------------------------------------------------------------
 Finalize Aggregate  (cost=0.00..864.68 rows=1 width=8)
   ->  Gather Motion 4:1  (slice1; segments: 4)  (cost=0.00..864.68 rows=1 width=8)
         ->  Partial Aggregate  (cost=0.00..864.68 rows=1 width=8)
               ->  Hash Join  (cost=0.00..864.68 rows=2495 width=1)
                     Hash Cond: (sat_sales_line.lnk_sales_line_key = lnk_sales_line.lnk_sales_line_key)
                     ->  Dynamic Seq Scan on sat_sales_line  (cost=0.00..431.22 rows=2495 width=33)
                           Number of partitions to scan: 13 (out of 13)
                     ->  Hash  (cost=431.25..431.25 rows=1717 width=33)
                           ->  Seq Scan on lnk_sales_line  (cost=0.00..431.25 rows=1717 width=33)
 Optimizer: GPORCA
(10 rows)

$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "EXPLAIN SELECT count(*) FROM vault.lnk_sales_line l JOIN vault.tmp_sat_random m ON m.lnk_sales_line_key = l.lnk_sales_line_key;"
-- B. антипример (сателлит распределён случайно) — Redistribute Motion на соединении
                                                QUERY PLAN                                                
----------------------------------------------------------------------------------------------------------
 Aggregate  (cost=0.00..437.00 rows=1 width=8)
   ->  Gather Motion 4:1  (slice1; segments: 4)  (cost=0.00..437.00 rows=1 width=1)
         ->  Nested Loop  (cost=0.00..437.00 rows=1 width=1)
               Join Filter: true
               ->  Redistribute Motion 4:4  (slice2; segments: 4)  (cost=0.00..431.00 rows=1 width=8)
                     Hash Key: tmp_sat_random.lnk_sales_line_key
                     ->  Seq Scan on tmp_sat_random  (cost=0.00..431.00 rows=1 width=8)
               ->  Index Scan using lnk_sales_line_pk on lnk_sales_line  (cost=0.00..6.00 rows=1 width=1)
                     Index Cond: (lnk_sales_line_key = tmp_sat_random.lnk_sales_line_key)
 Optimizer: GPORCA
(10 rows)

$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "DROP TABLE IF EXISTS vault.tmp_sat_random;"
-- убираем временную копию

```

*Листинг 16. E4: соединение ссылки и сателлита — co-location без перераспределения против случайной дистрибуции сателлита (появляется Redistribute Motion).*

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -c "EXPLAIN SELECT count(*) FROM staging.stg_superstore_raw WHERE load_dts >= TIMESTAMP '2026-10-01 00:00:00' AND load_dts < TIMESTAMP '2026-11-01 00:00:00';"
                                                                             QUERY PLAN                                                                             
--------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Finalize Aggregate  (cost=0.00..431.46 rows=1 width=8)
   ->  Gather Motion 4:1  (slice1; segments: 4)  (cost=0.00..431.46 rows=1 width=8)
         ->  Partial Aggregate  (cost=0.00..431.46 rows=1 width=8)
               ->  Dynamic Seq Scan on stg_superstore_raw  (cost=0.00..431.46 rows=2499 width=8)
                     Number of partitions to scan: 1 (out of 13)
                     Filter: ((load_dts >= '2026-10-01 00:00:00'::timestamp without time zone) AND (load_dts < '2026-11-01 00:00:00'::timestamp without time zone))
 Optimizer: GPORCA
(7 rows)
```

*Листинг 17. E4: отсечение партиций по дате загрузки.*


### E5. CI: воспроизводимый прогон в GitHub Actions

`.github/workflows/dv-pipeline.yml` поднимает Greenplum 7 в контейнере, выполняет DDL → загрузку → тесты и
публикует отчёт тестов артефактом сборки. Для доступа к датасету в CI используется секрет репозитория
`KAGGLE_API_TOKEN` (добавляется один раз в настройках репозитория; без него шаг загрузки пропускается с пояснением).

### E6. Прослеживаемость (lineage)

`audit.record_lineage` даёт двустороннюю трассировку: по номеру строки CSV находятся её строки в
`lnk_sales_line`/`sat_sales_line`, и наоборот — от строки хранилища к строкам источника. В staging хранится
`sha256` файла (версия датасета). Транскрипт: `40_lineage_trace.txt`.

```console
$ psql -h localhost -p 15432 -U gpadmin -d vault_dv -f sql/99_checks/40_lineage_trace.sql
=== 1. Строка источника (src_row_num = 1) ===
 src_row_num |  ship_mode   | segment  |    country    |   city    |  state   | postal_code | region | category  | sub_category | sales  | quantity | discount | profit  |      file_name       |                            file_hash                             
-------------+--------------+----------+---------------+-----------+----------+-------------+--------+-----------+--------------+--------+----------+----------+---------+----------------------+------------------------------------------------------------------
           1 | Second Class | Consumer | United States | Henderson | Kentucky | 42420       | South  | Furniture | Bookcases    | 261.96 | 2        | 0        | 41.9136 | SampleSuperstore.csv | ce8db84b6b049b19177ecdc43e46f8da6ce9c3d1784da4bf5dcf597c8b763611
(1 row)

=== 2. Порождённые строки Data Vault (lineage) ===
 src_row_num |        lnk_sales_line_key        |            hash_diff             | postal_code | city_name | sub_category_name | ship_mode_name | segment_name | sales_amount | quantity | discount_rate | profit_amount | sales_line_count 
-------------+----------------------------------+----------------------------------+-------------+-----------+-------------------+----------------+--------------+--------------+----------+---------------+---------------+------------------
           1 | 22b11d2cebeb117920db700b373ffd6a | b46138de58487514826e554306f58a75 | 42420       | Henderson | Bookcases         | Second Class   | Consumer     |     261.9600 |        2 |          0.00 |       41.9136 |                1
(1 row)

=== 3. Обратная трассировка: какие строки файла дали эту строку хранилища ===
 src_row_num |                            file_hash                             |      load_dts       
-------------+------------------------------------------------------------------+---------------------
           1 | ce8db84b6b049b19177ecdc43e46f8da6ce9c3d1784da4bf5dcf597c8b763611 | 2026-10-13 08:52:14
(1 row)

=== 4. Полнота lineage ===
 lineage_rows | source_rows | without_target 
--------------+-------------+----------------
         9994 |        9994 |              0
(1 row)
```

*Листинг 18. E6: прослеживаемость «строка файла -> строка хранилища».*


### E7. Reference-таблицы как альтернатива хабам

`bv.ref_ship_mode` и `bv.ref_segment` — справочники низкой кардинальности, распределённые **по бизнес-ключу**,
поэтому их `UNIQUE`/`PRIMARY KEY` реально enforced (в хабах так нельзя из-за ключа дистрибуции). Тест t07
доказывает эквивалентность reference-таблиц паре «хаб + сателлит».

### E10/E11. Документирование и метрики

- Диаграмма модели генерируется из DOT (`scripts/make_diagram.py` → PNG/SVG); отчёт собирается в DOCX и PDF.
- `audit.dq_metrics` — персистентные метрики качества по каждому прогону (12 метрик: строки, суммы, дубли,
  восстановленные ZIP, ghost-записи, lineage) с историей для отслеживания тренда.

## 7. Выводы и ограничения

**Выводы.** Спроектировано и реализовано хранилище данных по методологии Data Vault 2.0 на датасете
Superstore: 8 хабов, 5 ссылок, 5 сателлитов, слой Business Vault и витрины. Модель корректна по конструктивным
признакам (хеш-ключи, PK/FK/CHECK, комментарии, co-location, AO/column, партиционирование) и сходится с
источником по контрольным суммам. Все 118 автотестов проходят, повторная загрузка идемпотентна, «грязные»
строки изолируются в карантине, прослеживаемость обеспечена от строки CSV до строки хранилища.

**Ограничения (осознанные).**

1. В источнике нет дат и идентификаторов — версии сателлитов не имеют временной шкалы источника, поэтому
   `valid_to` открыт, а повторяющиеся строки учтены множителем `SALES_LINE_COUNT`. Структура таблиц готова к
   появлению даты в источнике — состав ключей при этом не меняется.
2. Greenplum не проверяет FK, а на AO/CO-таблицах FK объявить невозможно — целостность обеспечивается
   загрузкой (анти-join) и тестами t03.
3. Реализация выполнена в локальном Greenplum 7; перенос в Managed Greenplum Yandex Cloud требует только смены
   параметров подключения (скрипты версионно-нейтральны: тот же DDL работает и в GP 6, если для сателлитов
   использовать вариант heap — см. `sql/02_vault_gp6_heap/`).

## Приложение A. Как воспроизвести результат

```bash
git clone git@github.com:petrobond/HSE-Data-Storage-Systems.git && cd HSE-Data-Storage-Systems
cp .env.example .env      # заполнить KAGGLE_API_KEY (при необходимости — параметры Greenplum)
make up && make wait      # Greenplum 7 в Docker (координатор + 4 сегмента, порт 15432)
make ddl                  # схемы и таблицы
make download && make stage && make load   # загрузка данных датасета
make test                 # 118 автотестов
make screenshots && make evidence && make report   # транскрипты, листинги в отчёт, DOCX/PDF (портрет + ландшафт)
make teardown             # в конце: удалить контейнер, образ, тома и временные данные
```

Для Managed Greenplum в Yandex Cloud: указать в `.env` `GP_HOST`, `GP_PORT=6432`, `GP_USER`, `GP_PASSWORD`,
`GP_SSLMODE=require` и выполнить те же цели `make ddl`, `make stage`, `make load`, `make test`.

## Приложение B. Структура репозитория

```
Makefile, .env.example, .gitignore, README.md
docker/docker-compose.yml                  # Greenplum 7 (4 сегмента), healthcheck
src/                                       # скачивание датасета, профилирование, загрузка staging, обёртка psql
sql/00_init 01_staging 02_vault 03_load 04_bv 05_marts 99_checks
tests/run_tests.py, tests/sql/t01..t08, 99_report.sql
scripts/make_transcripts.sh, make_diagram.py, build_report.sh, teardown_greenplum.sh
yandex/                                    # опциональный путь в Managed Greenplum
docs/report/report.md, diagrams/           # этот отчёт и диаграмма модели
docs/tmp/                                  # НЕ коммитится: транскрипты, сборки отчёта
```

## Приложение C. Перечень доказательств

Все доказательства в документе — текстовые и воспроизводимые: диаграмма модели (Рис. 1)
и реальные выводы команд — **листинги 1…18**. Любую строку таблицы можно повторить
на своём окружении; при желании листинг легко дополнить скриншотом той же команды.
Полные тексты проверок сохранены в `docs/tmp/transcripts/`, сборка документа — `make report`.

| Листинг | Раздел отчёта | Что показывает | Команда |
|---|---|---|---|
| Листинг 1 | 3.1 Состав DDL-скриптов | Созданные таблицы схемы vault | `psql -c "\dt vault.*"` |
| Листинг 2 | 3.1 Состав DDL-скриптов | DDL транзакционной ссылки: PK, FK, DISTRIBUTED BY, комментарии | `psql -c "\d+ vault.lnk_sales_line"` |
| Листинг 3 | 3.4 Пример DDL | DDL сателлита мер: AO/column, zstd, PK, CHECK, партиционирование | `psql -c "\d+ vault.sat_sales_line"` |
| Листинг 4 | 3.4 Пример DDL | Фрагмент исходного DDL хаба вместе с комментариями к таблице и колонкам | `sed -n '1,44p' sql/02_vault/10_ddl_hubs.sql` |
| Листинг 5 | 4.1 Окружение | Локальный кластер Greenplum запущен в Docker | `docker ps --format table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}` |
| Листинг 6 | 4.1 Окружение | Версия СУБД | `psql -c "SELECT version();"` |
| Листинг 7 | 4.1 Окружение | MPP-топология: координатор и 4 сегмента | `psql -c "SELECT dbid, content, role, hostname, port, status FROM gp_segment_con…"` |
| Листинг 8 | 4.3 Результат в цифрах | Таблицы заполнены данными: число строк в каждом объекте | `psql -f sql/99_checks/10_table_counts.sql` |
| Листинг 9 | 4.3 Результат в цифрах | Сходимость контрольных сумм на всех слоях хранилища | `psql -f sql/99_checks/20_reconciliation.sql` |
| Листинг 10 | 4.4 Загрузка (ELT) | Загрузка датасета в staging: 9994 строки, карантин пуст | `make stage` |
| Листинг 11 | 4.4 Загрузка (ELT) | ELT: загрузка хабов, ссылок и сателлитов, реконсиляция с источником | `make load` |
| Листинг 12 | 5.2 Результат тестов | Автотесты корректности: 118 проверок — все PASS | `make test` |
| Листинг 13 | 6, E1 Витрины | Аналитические витрины, построенные поверх Data Vault | `несколько команд (см. листинг)` |
| Листинг 14 | 6, E3 Качество данных | Профиль качества источника: дубли строк, восстановленные ZIP, убыточные строки | `psql -c "SELECT * FROM dm.dm_dq_source_profile;"` |
| Листинг 15 | 6, E3 Качество данных | Метрики качества данных (audit.dq_metrics) и журнал загрузок | `psql -f sql/99_checks/60_audit_metrics.sql` |
| Листинг 16 | 6, E4 EXPLAIN | E4: соединение ссылки и сателлита — co-location без перераспределения против случайной дистрибуции сателлита (появляется Redistribute Motion) | `psql: создание копии + EXPLAIN + DROP (см. листинг)` |
| Листинг 17 | 6, E4 EXPLAIN | E4: отсечение партиций по дате загрузки | `psql -c "EXPLAIN SELECT count(*) FROM staging.stg_superstore_raw WHERE load_dts…"` |
| Листинг 18 | 6, E6 Lineage | E6: прослеживаемость «строка файла -> строка хранилища» | `psql -f sql/99_checks/40_lineage_trace.sql` |
