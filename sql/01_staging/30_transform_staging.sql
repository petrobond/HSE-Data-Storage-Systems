-- =====================================================================
-- 01_staging/30_transform_staging.sql
-- Преобразование «сырых» строк в очищенный типизированный слой staging:
--   1) валидация строк по правилам качества; нарушившие правила целиком
--      отправляются в карантин audit.rejected_records (данные не теряются);
--   2) нормализация бизнес-ключей (btrim) и восстановление ZIP до 5 знаков;
--   3) приведение типов мер;
--   4) расчёт ВСЕХ хеш-ключей Data Vault (хабы и ссылки) и хеш-диффа мер.
--
-- Правила качества (нарушение любого -> строка в карантин):
--   R1: postal_code — 4 или 5 цифр (в источнике терялся ведущий ноль);
--   R2: sales / profit — числовой формат;
--   R3: quantity — целое > 0;
--   R4: discount — число в диапазоне 0..1;
--   R5: обязательные бизнес-ключи не пустые.
-- =====================================================================

\if :{?file_hash}
\else
  \set file_hash '0000000000000000000000000000000000000000000000000000000000000000'
\endif
\if :{?rec_src}
\else
  \set rec_src 'kaggle_superstore'
\endif

\echo '--- staging: валидация строк, карантин, формирование очищенного слоя ---'

BEGIN;

CREATE TEMP TABLE stg_validated ON COMMIT DROP AS
WITH src AS (
    SELECT r.*,
           (trim(coalesce(r.postal_code, '')) ~ '^[0-9]{4,5}$')       AS r1_postal,
           (trim(coalesce(r.sales, ''))    ~ '^-?[0-9]+(\.[0-9]+)?$') AS r2_sales,
           (trim(coalesce(r.profit, ''))   ~ '^-?[0-9]+(\.[0-9]+)?$') AS r2_profit,
           (trim(coalesce(r.quantity, '')) ~ '^[0-9]+$')              AS r3_quantity,
           (trim(coalesce(r.discount, '')) ~ '^-?[0-9]+(\.[0-9]+)?$') AS r4_discount,
           (coalesce(trim(r.ship_mode), '') <> '' AND coalesce(trim(r.segment), '') <> ''
            AND coalesce(trim(r.country), '') <> '' AND coalesce(trim(r.city), '') <> ''
            AND coalesce(trim(r.state), '') <> '' AND coalesce(trim(r.region), '') <> ''
            AND coalesce(trim(r.category), '') <> ''
            AND coalesce(trim(r.sub_category), '') <> '')             AS r5_bk
      FROM staging.stg_superstore_raw r
     WHERE r.file_hash = :'file_hash'
)
SELECT s.src_row_num,
       s.file_hash,
       btrim(s.ship_mode)     AS ship_mode_name,
       btrim(s.segment)       AS segment_name,
       btrim(s.country)       AS country_name,
       btrim(s.state)         AS state_name,
       btrim(s.city)          AS city_name,
       lpad(btrim(s.postal_code), 5, '0') AS postal_code,
       btrim(s.region)        AS region_name,
       btrim(s.category)      AS category_name,
       btrim(s.sub_category)  AS sub_category_name,
       trim(s.sales)::numeric(14,4)   AS sales_amount,
       trim(s.quantity)::smallint     AS quantity,
       trim(s.discount)::numeric(4,2) AS discount_rate,
       trim(s.profit)::numeric(14,4)  AS profit_amount,
       (s.r1_postal AND s.r2_sales AND s.r2_profit AND s.r3_quantity AND s.r4_discount
        AND s.r5_bk
        AND trim(s.discount)::numeric(4,2) BETWEEN 0 AND 1
        AND trim(s.quantity)::smallint > 0) AS is_valid,
       concat_ws('; ',
           CASE WHEN NOT s.r1_postal   THEN 'R1: postal_code не 4-5 цифр' END,
           CASE WHEN NOT s.r2_sales    THEN 'R2: sales не число' END,
           CASE WHEN NOT s.r2_profit   THEN 'R2: profit не число' END,
           CASE WHEN NOT s.r3_quantity THEN 'R3: quantity не целое' END,
           CASE WHEN NOT s.r4_discount THEN 'R4: discount не число' END,
           CASE WHEN s.r4_discount AND NOT (trim(s.discount)::numeric(4,2) BETWEEN 0 AND 1)
                THEN 'R4: discount вне диапазона 0..1' END,
           CASE WHEN s.r3_quantity AND NOT (trim(s.quantity)::smallint > 0)
                THEN 'R3: quantity <= 0' END,
           CASE WHEN NOT s.r5_bk       THEN 'R5: пустой бизнес-ключ' END
       ) AS reject_reason
  FROM src s
DISTRIBUTED RANDOMLY;

-- 1. Карантин строк, не прошедших валидацию
INSERT INTO audit.rejected_records
      (src_row_num, file_hash, rule_name, raw_record, detected_dts, rec_src)
SELECT v.src_row_num, v.file_hash, v.reject_reason,
       concat_ws('|', v.ship_mode_name, v.segment_name, v.country_name, v.city_name,
                 v.state_name, v.postal_code, v.region_name, v.category_name,
                 v.sub_category_name, v.sales_amount::text, v.quantity::text,
                 v.discount_rate::text, v.profit_amount::text),
       now()::timestamp(0), :'rec_src'
  FROM stg_validated v
 WHERE NOT v.is_valid;

-- 2. Очищенный слой с хеш-ключами (идемпотентно: сначала убираем строки этого файла)
DELETE FROM staging.stg_superstore_clean WHERE file_hash = :'file_hash';

INSERT INTO staging.stg_superstore_clean
      (src_row_num, file_hash, ship_mode_name, segment_name, country_name, state_name,
       city_name, postal_code, region_name, category_name, sub_category_name,
       sales_amount, quantity, discount_rate, profit_amount,
       hub_country_key, hub_region_key, hub_state_key, hub_location_key,
       hub_category_key, hub_sub_category_key, hub_ship_mode_key, hub_segment_key,
       lnk_location_state_key, lnk_state_region_key, lnk_region_country_key,
       lnk_category_sub_category_key, lnk_sales_line_key, hash_diff, load_dts, rec_src)
SELECT v.src_row_num, v.file_hash,
       v.ship_mode_name, v.segment_name, v.country_name, v.state_name,
       v.city_name, v.postal_code, v.region_name, v.category_name, v.sub_category_name,
       v.sales_amount, v.quantity, v.discount_rate, v.profit_amount,
       -- хеш-ключи хабов: md5 от нормализованных (upper/trim) бизнес-ключей
       md5(upper(v.country_name))::char(32),
       md5(upper(v.region_name))::char(32),
       md5(upper(v.state_name))::char(32),
       md5(upper(v.postal_code) || '|' || upper(v.city_name))::char(32),
       md5(upper(v.category_name))::char(32),
       md5(upper(v.sub_category_name))::char(32),
       md5(upper(v.ship_mode_name))::char(32),
       md5(upper(v.segment_name))::char(32),
       -- ключи ссылок: md5 от бизнес-ключей связанных хабов, порядок фиксирован
       md5(upper(v.postal_code) || '|' || upper(v.city_name) || '|' || upper(v.state_name))::char(32),
       md5(upper(v.state_name) || '|' || upper(v.region_name))::char(32),
       md5(upper(v.region_name) || '|' || upper(v.country_name))::char(32),
       md5(upper(v.category_name) || '|' || upper(v.sub_category_name))::char(32),
       md5(upper(v.postal_code) || '|' || upper(v.city_name) || '|' || upper(v.sub_category_name)
           || '|' || upper(v.ship_mode_name) || '|' || upper(v.segment_name))::char(32),
       -- хеш-дифф мер строки продажи
       md5(v.sales_amount::text || '|' || v.quantity::text || '|' || v.discount_rate::text
           || '|' || v.profit_amount::text)::char(32),
       now()::timestamp(0), :'rec_src'
  FROM stg_validated v
 WHERE v.is_valid;

COMMIT;

ANALYZE staging.stg_superstore_clean;
ANALYZE audit.rejected_records;

SELECT (SELECT count(*) FROM staging.stg_superstore_clean WHERE file_hash = :'file_hash') AS clean_rows,
       (SELECT count(*) FROM audit.rejected_records   WHERE file_hash = :'file_hash') AS rejected_rows;

