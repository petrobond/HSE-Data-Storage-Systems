-- =====================================================================
-- 03_load/99_analyze.sql
-- Сбор статистики оптимизатором после загрузки: обязательный шаг для
-- Greenplum (GPORCA/PG-планировщик принимает решения по join'ам и Motion
-- на основе статистики). ANALYZE выполняется по всем прикладным схемам.
-- =====================================================================

\echo '--- ANALYZE: сбор статистики ---'
ANALYZE staging.stg_superstore_raw;
ANALYZE staging.stg_superstore_clean;

ANALYZE vault.hub_country;
ANALYZE vault.hub_region;
ANALYZE vault.hub_state;
ANALYZE vault.hub_location;
ANALYZE vault.hub_category;
ANALYZE vault.hub_sub_category;
ANALYZE vault.hub_ship_mode;
ANALYZE vault.hub_segment;

ANALYZE vault.lnk_location_state;
ANALYZE vault.lnk_state_region;
ANALYZE vault.lnk_region_country;
ANALYZE vault.lnk_category_sub_category;
ANALYZE vault.lnk_sales_line;

ANALYZE vault.sat_location;
ANALYZE vault.sat_sub_category;
ANALYZE vault.sat_ship_mode;
ANALYZE vault.sat_segment;
ANALYZE vault.sat_sales_line;

ANALYZE bv.ref_ship_mode;
ANALYZE bv.ref_segment;
ANALYZE bv.efs_location_state;
ANALYZE bv.efs_state_region;
ANALYZE bv.rts_hub_record;
ANALYZE bv.pit_location;
ANALYZE bv.bridge_sales_line;

ANALYZE dm.dm_sales_star;

\echo '--- размеры объектов хранилища ---'
SELECT n.nspname AS schema_name, c.relname AS object, c.relkind,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('staging', 'vault', 'bv', 'dm', 'audit')
   AND c.relkind IN ('r', 'm')
 ORDER BY pg_total_relation_size(c.oid) DESC
 LIMIT 15;
