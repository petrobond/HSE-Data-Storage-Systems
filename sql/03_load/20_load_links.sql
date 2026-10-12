-- =====================================================================
-- 03_load/20_load_links.sql
-- Загрузка ССЫЛОК (идемпотентный ELT на SQL).
--
-- Каждая ссылка формируется из последнего среза staging:
--   * DISTINCT по хеш-ключу ссылки — в линке хранится уникальная КОМБИНАЦИЯ
--     бизнес-ключей (повторение строк источника не создаёт дублей ссылок);
--   * бизнес-ключи участников денормализуются в ссылку (как в примере вебинара
--     LNK_REGION_COUNTRY, где хранятся COUNTRY_ABBRV и REGION_NAME);
--   * уже загруженные комбинации отфильтровываются LEFT JOIN ... IS NULL.
-- Порядок загрузки: иерархические ссылки (гео, товарные категории) -> транзакционная.
-- =====================================================================

-- Защита от «тихой» загрузки: если staging пуст, скрипт останавливается с ошибкой.
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.stg_superstore_clean) = 0 THEN
        RAISE EXCEPTION 'staging.stg_superstore_clean пуст — сначала выполните: make stage';
    END IF;
END $$;

\echo '--- vault: ссылки ---'
BEGIN;
CREATE TEMP TABLE src_clean ON COMMIT DROP AS
SELECT * FROM staging.stg_superstore_clean
 WHERE load_dts = (SELECT max(load_dts) FROM staging.stg_superstore_clean)
DISTRIBUTED BY (lnk_sales_line_key);

INSERT INTO vault.lnk_location_state
      (lnk_location_state_key, hub_location_key, hub_state_key, postal_code, city_name,
       state_name, lnk_load_dts, lnk_rec_src)
SELECT DISTINCT s.lnk_location_state_key, s.hub_location_key, s.hub_state_key,
       s.postal_code, s.city_name, s.state_name, s.load_dts, s.rec_src
  FROM src_clean s
  LEFT JOIN vault.lnk_location_state l ON l.lnk_location_state_key = s.lnk_location_state_key
 WHERE l.lnk_location_state_key IS NULL;

INSERT INTO vault.lnk_state_region
      (lnk_state_region_key, hub_state_key, hub_region_key, state_name, region_name,
       lnk_load_dts, lnk_rec_src)
SELECT DISTINCT s.lnk_state_region_key, s.hub_state_key, s.hub_region_key,
       s.state_name, s.region_name, s.load_dts, s.rec_src
  FROM src_clean s
  LEFT JOIN vault.lnk_state_region l ON l.lnk_state_region_key = s.lnk_state_region_key
 WHERE l.lnk_state_region_key IS NULL;

INSERT INTO vault.lnk_region_country
      (lnk_region_country_key, hub_region_key, hub_country_key, region_name, country_name,
       lnk_load_dts, lnk_rec_src)
SELECT DISTINCT s.lnk_region_country_key, s.hub_region_key, s.hub_country_key,
       s.region_name, s.country_name, s.load_dts, s.rec_src
  FROM src_clean s
  LEFT JOIN vault.lnk_region_country l ON l.lnk_region_country_key = s.lnk_region_country_key
 WHERE l.lnk_region_country_key IS NULL;

INSERT INTO vault.lnk_category_sub_category
      (lnk_category_sub_category_key, hub_category_key, hub_sub_category_key,
       category_name, sub_category_name, lnk_load_dts, lnk_rec_src)
SELECT DISTINCT s.lnk_category_sub_category_key, s.hub_category_key, s.hub_sub_category_key,
       s.category_name, s.sub_category_name, s.load_dts, s.rec_src
  FROM src_clean s
  LEFT JOIN vault.lnk_category_sub_category l
         ON l.lnk_category_sub_category_key = s.lnk_category_sub_category_key
 WHERE l.lnk_category_sub_category_key IS NULL;

-- Транзакционная ссылка «строка продажи»: уникальные комбинации четырёх хабов
INSERT INTO vault.lnk_sales_line
      (lnk_sales_line_key, hub_location_key, hub_sub_category_key, hub_ship_mode_key,
       hub_segment_key, postal_code, city_name, sub_category_name, ship_mode_name,
       segment_name, lnk_load_dts, lnk_rec_src)
SELECT DISTINCT s.lnk_sales_line_key, s.hub_location_key, s.hub_sub_category_key,
       s.hub_ship_mode_key, s.hub_segment_key, s.postal_code, s.city_name,
       s.sub_category_name, s.ship_mode_name, s.segment_name, s.load_dts, s.rec_src
  FROM src_clean s
  LEFT JOIN vault.lnk_sales_line l ON l.lnk_sales_line_key = s.lnk_sales_line_key
 WHERE l.lnk_sales_line_key IS NULL;

\echo '--- vault: состав ссылок ---'
SELECT 'lnk_location_state' AS link, count(*) AS rows_ FROM vault.lnk_location_state
UNION ALL SELECT 'lnk_state_region', count(*) FROM vault.lnk_state_region
UNION ALL SELECT 'lnk_region_country', count(*) FROM vault.lnk_region_country
UNION ALL SELECT 'lnk_category_sub_category', count(*) FROM vault.lnk_category_sub_category
UNION ALL SELECT 'lnk_sales_line', count(*) FROM vault.lnk_sales_line
ORDER BY 1;

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, rec_src, note)
SELECT 'link', 'vault.lnk_*', (SELECT count(*) FROM vault.lnk_sales_line),
       now()::timestamp(0), 'kaggle_superstore',
       'загрузка ссылок (индикатор — lnk_sales_line)';
COMMIT;

