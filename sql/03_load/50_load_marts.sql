-- =====================================================================
-- 03_load/50_load_marts.sql
-- Обновление витрин уровня представления: материализованные представления
-- пересчитываются, «звезда» догружается идемпотентно.
-- =====================================================================

\echo '--- dm: обновление материализованных представлений ---'
REFRESH MATERIALIZED VIEW dm.dm_sales_by_region_category;
REFRESH MATERIALIZED VIEW dm.dm_product_hierarchy;
REFRESH MATERIALIZED VIEW dm.dm_dq_source_profile;

\echo '--- dm: загрузка витрины-«звезды» ---'
BEGIN;

INSERT INTO dm.dm_sales_star
      (lnk_sales_line_key, hash_diff, postal_code, city_name, state_name, region_name,
       country_name, category_name, sub_category_name, ship_mode_name, ship_speed_rank,
       segment_name, segment_type, sales_amount, quantity, discount_rate, profit_amount,
       sales_line_count)
SELECT b.lnk_sales_line_key, b.hash_diff, b.postal_code, b.city_name, b.state_name,
       b.region_name, b.country_name, b.category_name, b.sub_category_name,
       b.ship_mode_name, b.ship_speed_rank, b.segment_name, b.segment_type,
       b.sales_amount, b.quantity, b.discount_rate, b.profit_amount, b.sales_line_count
  FROM bv.bridge_sales_line b
  LEFT JOIN dm.dm_sales_star t
         ON t.lnk_sales_line_key = b.lnk_sales_line_key AND t.hash_diff = b.hash_diff
 WHERE t.lnk_sales_line_key IS NULL;

COMMIT;

\echo '--- dm: проверка сходимости витрин с источником ---'
SELECT 'staging (источник)' AS object            , count(*) AS lines, sum(sales_amount) AS sales, sum(profit_amount) AS profit FROM staging.stg_superstore_clean
UNION ALL SELECT 'vault.sat_sales_line (DDS)', sum(sales_line_count), sum(sales_line_count*sales_amount), sum(sales_line_count*profit_amount) FROM vault.sat_sales_line
UNION ALL SELECT 'bv.bridge_sales_line', sum(sales_line_count), sum(sales_line_count*sales_amount), sum(sales_line_count*profit_amount) FROM bv.bridge_sales_line
UNION ALL SELECT 'dm.dm_sales_star', sum(sales_line_count), sum(sales_line_count*sales_amount), sum(sales_line_count*profit_amount) FROM dm.dm_sales_star;

\echo '--- dm: топ-10 подкатегорий по прибыли (пример аналитического запроса) ---'
SELECT sub_category_name, category_name, sales_lines, sales_amount, profit_amount, profit_margin_pct
  FROM dm.dm_product_hierarchy
 ORDER BY profit_amount DESC
 LIMIT 10;

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, rec_src, note)
SELECT 'dm', 'dm.*', (SELECT count(*) FROM dm.dm_sales_star), now()::timestamp(0),
       'kaggle_superstore', 'витрины: 3 materialized view + dm_sales_star';
