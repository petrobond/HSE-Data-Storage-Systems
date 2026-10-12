-- =====================================================================
-- 01_staging/20_load_staging.sql
-- Загрузка CSV в staging-слой. Выполняется клиентским \copy (файл читается на
-- стороне клиента — прав на серверные каталоги не требуется; работает одинаково
-- и в локальном Docker, и в YC Managed Greenplum).
--
-- Особенности:
--  * Входной файл — data/tmp/stg_superstore_with_rowno.csv: его формирует
--    src/load_staging.py, добавляя ПЕРВОЙ колонкой row_num (номер строки данных
--    исходного CSV). Это делает src_row_num детерминированным и даёт точную
--    прослеживаемость «строка файла -> строки Data Vault».
--  * Путь к файлу указан статически: psql не интерполирует psql-переменные
--    внутри \copy (проверено на psql 18). Параметры версии датасета
--    (file_name/file_hash/rec_src) передаются переменными psql и используются
--    уже в SQL-инструкции INSERT, где интерполяция :'var' работает.
--
-- Параметры psql (-v): file_name, file_hash, rec_src.
-- =====================================================================

\if :{?file_name}
\else
  \set file_name 'SampleSuperstore.csv'
\endif
\if :{?file_hash}
\else
  \set file_hash '0000000000000000000000000000000000000000000000000000000000000000'
\endif
\if :{?rec_src}
\else
  \set rec_src 'kaggle_superstore'
\endif

\echo '--- staging: загрузка CSV в staging.stg_superstore_raw ---'
BEGIN;

-- Идемпотентность: убираем предыдущую загрузку этого же файла (по sha256),
-- чтобы повторный запуск не удваивал данные.
DELETE FROM staging.stg_superstore_raw WHERE file_hash = :'file_hash';

-- Временная таблица-приёмник: DISTRIBUTED BY (src_row_num) — ключ уникален,
-- поэтому данные распределяются равномерно и без предупреждений планировщика.
CREATE TEMP TABLE stg_load_tmp
(
    src_row_num  integer,
    ship_mode    text, segment     text, country     text, city        text,
    state        text, postal_code text, region      text, category    text,
    sub_category text, sales       text, quantity    text, discount    text,
    profit       text
) ON COMMIT DROP DISTRIBUTED BY (src_row_num);

\copy stg_load_tmp (src_row_num,ship_mode,segment,country,city,state,postal_code,region,category,sub_category,sales,quantity,discount,profit) FROM 'data/tmp/stg_superstore_with_rowno.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO staging.stg_superstore_raw
      (src_row_num, ship_mode, segment, country, city, state, postal_code, region,
       category, sub_category, sales, quantity, discount, profit,
       file_name, file_hash, load_dts, rec_src)
SELECT src_row_num, ship_mode, segment, country, city, state, postal_code, region,
       category, sub_category, sales, quantity, discount, profit,
       :'file_name', :'file_hash', now()::timestamp(0), :'rec_src'
  FROM stg_load_tmp;

COMMIT;

ANALYZE staging.stg_superstore_raw;

SELECT count(*) AS raw_rows,
       count(DISTINCT src_row_num) AS distinct_row_nums,
       min(src_row_num) AS first_row, max(src_row_num) AS last_row
  FROM staging.stg_superstore_raw
 WHERE file_hash = :'file_hash';


