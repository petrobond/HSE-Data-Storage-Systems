-- =====================================================================
-- 03_load/40_load_business_vault.sql
-- Загрузка BUSINESS VAULT: reference-таблицы (E7), Effectivity Satellites (E2),
-- Record Tracking Satellite (E2), Point-In-Time (E1) и Bridge (E1).
-- Все вставки идемпотентны (анти-join по естественному ключу).
-- =====================================================================

\echo '--- bv: reference-таблицы (E7) ---'
BEGIN;

INSERT INTO bv.ref_ship_mode (ship_mode_name, ship_speed_rank, effective_from)
SELECT s.ship_mode_name, s.ship_speed_rank, s.valid_from
  FROM vault.sat_ship_mode s
  LEFT JOIN bv.ref_ship_mode r ON r.ship_mode_name = s.ship_mode_name
 WHERE r.ship_mode_name IS NULL;

INSERT INTO bv.ref_segment (segment_name, segment_type, effective_from)
SELECT s.segment_name, s.segment_type, s.valid_from
  FROM vault.sat_segment s
  LEFT JOIN bv.ref_segment r ON r.segment_name = s.segment_name
 WHERE r.segment_name IS NULL;

\echo '--- bv: effectivity satellites (E2) ---'
INSERT INTO bv.efs_location_state
      (lnk_location_state_key, load_dts, valid_from, valid_to, active_flag, deleted_flag)
SELECT l.lnk_location_state_key, l.lnk_load_dts, l.lnk_load_dts, NULL, true, false
  FROM vault.lnk_location_state l
  LEFT JOIN bv.efs_location_state e
         ON e.lnk_location_state_key = l.lnk_location_state_key
        AND e.load_dts = l.lnk_load_dts
 WHERE e.lnk_location_state_key IS NULL;

INSERT INTO bv.efs_state_region
      (lnk_state_region_key, load_dts, valid_from, valid_to, active_flag, deleted_flag)
SELECT l.lnk_state_region_key, l.lnk_load_dts, l.lnk_load_dts, NULL, true, false
  FROM vault.lnk_state_region l
  LEFT JOIN bv.efs_state_region e
         ON e.lnk_state_region_key = l.lnk_state_region_key
        AND e.load_dts = l.lnk_load_dts
 WHERE e.lnk_state_region_key IS NULL;

COMMIT;

\echo '--- bv: record tracking satellite по всем хабам (E2) ---'
BEGIN;

INSERT INTO bv.rts_hub_record (hub_name, hub_key, load_dts, rec_src)
WITH hubs AS (
    SELECT 'hub_country'      AS hub_name, hub_country_key      AS hub_key, hub_load_dts AS load_dts, hub_rec_src AS rec_src FROM vault.hub_country
    UNION ALL SELECT 'hub_region',         hub_region_key,         hub_load_dts, hub_rec_src FROM vault.hub_region
    UNION ALL SELECT 'hub_state',          hub_state_key,          hub_load_dts, hub_rec_src FROM vault.hub_state
    UNION ALL SELECT 'hub_location',       hub_location_key,       hub_load_dts, hub_rec_src FROM vault.hub_location
    UNION ALL SELECT 'hub_category',       hub_category_key,       hub_load_dts, hub_rec_src FROM vault.hub_category
    UNION ALL SELECT 'hub_sub_category',   hub_sub_category_key,   hub_load_dts, hub_rec_src FROM vault.hub_sub_category
    UNION ALL SELECT 'hub_ship_mode',      hub_ship_mode_key,      hub_load_dts, hub_rec_src FROM vault.hub_ship_mode
    UNION ALL SELECT 'hub_segment',        hub_segment_key,        hub_load_dts, hub_rec_src FROM vault.hub_segment
)
SELECT h.hub_name, h.hub_key, h.load_dts, h.rec_src
  FROM hubs h
  LEFT JOIN bv.rts_hub_record r
         ON r.hub_name = h.hub_name AND r.hub_key = h.hub_key AND r.load_dts = h.load_dts
 WHERE r.hub_key IS NULL;

\echo '--- bv: point-in-time по гео-локациям (E1) ---'
INSERT INTO bv.pit_location
      (snapshot_dts, hub_location_key, sat_location_hash_diff, hub_state_key,
       hub_region_key, hub_country_key)
WITH snap AS (SELECT max(load_dts) AS snapshot_dts FROM staging.stg_superstore_clean)
SELECT (SELECT snapshot_dts FROM snap), l.hub_location_key, s.hash_diff,
       ls.hub_state_key, sr.hub_region_key, rc.hub_country_key
  FROM vault.hub_location l
  JOIN vault.sat_location s        ON s.hub_location_key = l.hub_location_key AND s.valid_to IS NULL
  JOIN vault.lnk_location_state ls ON ls.hub_location_key = l.hub_location_key
  JOIN vault.lnk_state_region sr   ON sr.hub_state_key = ls.hub_state_key
  JOIN vault.lnk_region_country rc ON rc.hub_region_key = sr.hub_region_key
  LEFT JOIN bv.pit_location p
         ON p.snapshot_dts = (SELECT snapshot_dts FROM snap)
        AND p.hub_location_key = l.hub_location_key
        AND p.sat_location_hash_diff = s.hash_diff
 WHERE p.hub_location_key IS NULL;

COMMIT;

\echo '--- bv: bridge продаж (E1: «расплющенная» модель для быстрых запросов) ---'
BEGIN;

INSERT INTO bv.bridge_sales_line
      (lnk_sales_line_key, hash_diff, postal_code, city_name, state_name, region_name,
       country_name, sub_category_name, category_name, ship_mode_name, ship_speed_rank,
       segment_name, segment_type, sales_amount, quantity, discount_rate, profit_amount,
       sales_line_count)
SELECT l.lnk_sales_line_key, m.hash_diff,
       l.postal_code, l.city_name, sl.state_name, sl.region_name, sl.country_name,
       l.sub_category_name, sc.category_name, l.ship_mode_name, sm.ship_speed_rank,
       l.segment_name, sg.segment_type, m.sales_amount, m.quantity, m.discount_rate,
       m.profit_amount, m.sales_line_count
  FROM vault.lnk_sales_line l
  JOIN vault.sat_sales_line m    ON m.lnk_sales_line_key = l.lnk_sales_line_key
  JOIN vault.sat_location sl     ON sl.hub_location_key = l.hub_location_key
  JOIN vault.sat_sub_category sc ON sc.hub_sub_category_key = l.hub_sub_category_key
  JOIN vault.sat_ship_mode sm    ON sm.hub_ship_mode_key = l.hub_ship_mode_key
  JOIN vault.sat_segment sg      ON sg.hub_segment_key = l.hub_segment_key
  LEFT JOIN bv.bridge_sales_line b
         ON b.lnk_sales_line_key = l.lnk_sales_line_key AND b.hash_diff = m.hash_diff
 WHERE b.lnk_sales_line_key IS NULL;

COMMIT;

\echo '--- bv: состав Business Vault ---'
SELECT 'ref_ship_mode' AS object, count(*) AS rows_ FROM bv.ref_ship_mode
UNION ALL SELECT 'ref_segment', count(*) FROM bv.ref_segment
UNION ALL SELECT 'efs_location_state', count(*) FROM bv.efs_location_state
UNION ALL SELECT 'efs_state_region', count(*) FROM bv.efs_state_region
UNION ALL SELECT 'rts_hub_record', count(*) FROM bv.rts_hub_record
UNION ALL SELECT 'pit_location', count(*) FROM bv.pit_location
UNION ALL SELECT 'bridge_sales_line', count(*) FROM bv.bridge_sales_line
ORDER BY 1;

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, rec_src, note)
SELECT 'bv', 'bv.*', (SELECT count(*) FROM bv.bridge_sales_line), now()::timestamp(0),
       'kaggle_superstore', 'Business Vault: ref/efs/rts/pit/bridge';

