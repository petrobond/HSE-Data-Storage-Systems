-- =====================================================================
-- 03_load/30_load_satellites.sql
-- Загрузка САТЕЛЛИТОВ ХАБОВ (справочные атрибуты: локация, подкатегория,
-- способ доставки, сегмент).
--
-- Логика (type-2 по хеш-диффу):
--   * hash_diff считается здесь из атрибутов (в staging его нет — для атрибутивных
--     сателлитов это нормально: staging знает только ключи и меры);
--   * вставляются только новые пары (parent_key, hash_diff) — повторный запуск
--     ничего не добавляет (идемпотентность);
--   * valid_from = момент загрузки, valid_to = NULL (версия активна),
--     active_flag = true, deleted_flag = false (в источнике удалений нет).
-- =====================================================================

-- Защита от «тихой» загрузки: если staging пуст, скрипт останавливается с ошибкой.
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.stg_superstore_clean) = 0 THEN
        RAISE EXCEPTION 'staging.stg_superstore_clean пуст — сначала выполните: make stage';
    END IF;
END $$;

\echo '--- vault: сателлиты хабов ---'
BEGIN;
CREATE TEMP TABLE src_clean ON COMMIT DROP AS
SELECT * FROM staging.stg_superstore_clean
 WHERE load_dts = (SELECT max(load_dts) FROM staging.stg_superstore_clean)
DISTRIBUTED BY (hub_location_key);

-- SAT_LOCATION: географическая принадлежность локации
INSERT INTO vault.sat_location
      (hub_location_key, hash_diff, state_name, region_name, country_name,
       sat_load_dts, sat_rec_src, valid_from, valid_to, active_flag, deleted_flag)
SELECT s.hub_location_key,
       md5(upper(s.state_name) || '|' || upper(s.region_name) || '|' || upper(s.country_name))::char(32),
       min(s.state_name), min(s.region_name), min(s.country_name),
       max(s.load_dts), min(s.rec_src), max(s.load_dts), NULL, true, false
  FROM src_clean s
  LEFT JOIN vault.sat_location t
         ON t.hub_location_key = s.hub_location_key
        AND t.hash_diff = md5(upper(s.state_name) || '|' || upper(s.region_name) || '|' || upper(s.country_name))::char(32)
 WHERE t.hub_location_key IS NULL
 GROUP BY s.hub_location_key,
          md5(upper(s.state_name) || '|' || upper(s.region_name) || '|' || upper(s.country_name))::char(32);

-- SAT_SUB_CATEGORY: категория подкатегории товара
INSERT INTO vault.sat_sub_category
      (hub_sub_category_key, hash_diff, category_name, sat_load_dts, sat_rec_src,
       valid_from, valid_to, active_flag, deleted_flag)
SELECT s.hub_sub_category_key,
       md5(upper(s.sub_category_name) || '|' || upper(s.category_name))::char(32),
       min(s.category_name), max(s.load_dts), min(s.rec_src), max(s.load_dts), NULL, true, false
  FROM src_clean s
  LEFT JOIN vault.sat_sub_category t
         ON t.hub_sub_category_key = s.hub_sub_category_key
        AND t.hash_diff = md5(upper(s.sub_category_name) || '|' || upper(s.category_name))::char(32)
 WHERE t.hub_sub_category_key IS NULL
 GROUP BY s.hub_sub_category_key,
          md5(upper(s.sub_category_name) || '|' || upper(s.category_name))::char(32);

-- SAT_SHIP_MODE: способ доставки + производный ранг скорости
INSERT INTO vault.sat_ship_mode
      (hub_ship_mode_key, hash_diff, ship_mode_name, ship_speed_rank,
       sat_load_dts, sat_rec_src, valid_from, valid_to, active_flag, deleted_flag)
SELECT s.hub_ship_mode_key,
       md5(upper(s.ship_mode_name) || '|' || r.rank::text)::char(32),
       min(s.ship_mode_name), min(r.rank), max(s.load_dts), min(s.rec_src),
       max(s.load_dts), NULL, true, false
  FROM src_clean s
  JOIN (VALUES ('Same Day', 1), ('First Class', 2), ('Second Class', 3), ('Standard Class', 4))
       AS r(ship_mode, rank) ON upper(r.ship_mode) = upper(s.ship_mode_name)
  LEFT JOIN vault.sat_ship_mode t
         ON t.hub_ship_mode_key = s.hub_ship_mode_key
        AND t.hash_diff = md5(upper(s.ship_mode_name) || '|' || r.rank::text)::char(32)
 WHERE t.hub_ship_mode_key IS NULL
 GROUP BY s.hub_ship_mode_key, md5(upper(s.ship_mode_name) || '|' || r.rank::text)::char(32);

-- SAT_SEGMENT: сегмент покупателя + производный тип B2B/B2C
INSERT INTO vault.sat_segment
      (hub_segment_key, hash_diff, segment_name, segment_type,
       sat_load_dts, sat_rec_src, valid_from, valid_to, active_flag, deleted_flag)
SELECT s.hub_segment_key,
       md5(upper(s.segment_name) || '|' || t.segment_type)::char(32),
       min(s.segment_name), min(t.segment_type), max(s.load_dts), min(s.rec_src),
       max(s.load_dts), NULL, true, false
  FROM src_clean s
  JOIN (VALUES ('Consumer', 'B2C'), ('Corporate', 'B2B'), ('Home Office', 'B2C'))
       AS t(segment, segment_type) ON upper(t.segment) = upper(s.segment_name)
  LEFT JOIN vault.sat_segment sat
         ON sat.hub_segment_key = s.hub_segment_key
        AND sat.hash_diff = md5(upper(s.segment_name) || '|' || t.segment_type)::char(32)
 WHERE sat.hub_segment_key IS NULL
 GROUP BY s.hub_segment_key, md5(upper(s.segment_name) || '|' || t.segment_type)::char(32);

\echo '--- vault: состав сателлитов хабов ---'
SELECT 'sat_location' AS satellite, count(*) AS rows_ FROM vault.sat_location
UNION ALL SELECT 'sat_sub_category', count(*) FROM vault.sat_sub_category
UNION ALL SELECT 'sat_ship_mode', count(*) FROM vault.sat_ship_mode
UNION ALL SELECT 'sat_segment', count(*) FROM vault.sat_segment
ORDER BY 1;

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, rec_src, note)
SELECT 'satellite', 'vault.sat_location/sat_sub_category/sat_ship_mode/sat_segment',
       (SELECT count(*) FROM vault.sat_location) + (SELECT count(*) FROM vault.sat_sub_category)
       + (SELECT count(*) FROM vault.sat_ship_mode) + (SELECT count(*) FROM vault.sat_segment),
       now()::timestamp(0), 'kaggle_superstore', 'загрузка атрибутивных сателлитов';
COMMIT;

