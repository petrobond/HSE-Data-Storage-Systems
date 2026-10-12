-- =====================================================================
-- 03_load/10_load_hubs.sql
-- Загрузка ХАБОВ (идемпотентный ELT на SQL).
--
-- Логика:
--   1) сначала гарантируются zero-key (ghost) записи '000…0' — «неизвестный член»
--      (стандарт Data Vault 2.0), чтобы ссылки никогда не ломались;
--   2) затем из последнего среза staging берутся НОВЫЕ бизнес-ключи
--      (LEFT JOIN ... IS NULL = «ещё не загруженные»), при этом:
--        * GROUP BY по хеш-ключу устраняет повторы внутри файла;
--        * MIN() по бизнес-ключу и метаданным даёт детерминированный представитель;
--   3) результат журналируется в audit.load_run_log.
-- Повторный запуск ничего не добавляет (проверяется тестом идемпотентности t06).
-- =====================================================================

-- Защита от «тихой» загрузки: если staging пуст, скрипт останавливается с ошибкой.
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.stg_superstore_clean) = 0 THEN
        RAISE EXCEPTION 'staging.stg_superstore_clean пуст — сначала выполните: make stage';
    END IF;
END $$;

\echo '--- vault: zero-key (ghost) записи ---'
BEGIN;
INSERT INTO vault.hub_country (hub_country_key, country_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_country WHERE hub_country_key = repeat('0', 32));
INSERT INTO vault.hub_region (hub_region_key, region_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_region WHERE hub_region_key = repeat('0', 32));
INSERT INTO vault.hub_state (hub_state_key, state_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_state WHERE hub_state_key = repeat('0', 32));
INSERT INTO vault.hub_location (hub_location_key, postal_code, city_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '00000', '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_location WHERE hub_location_key = repeat('0', 32));
INSERT INTO vault.hub_category (hub_category_key, category_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_category WHERE hub_category_key = repeat('0', 32));
INSERT INTO vault.hub_sub_category (hub_sub_category_key, sub_category_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_sub_category WHERE hub_sub_category_key = repeat('0', 32));
INSERT INTO vault.hub_ship_mode (hub_ship_mode_key, ship_mode_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_ship_mode WHERE hub_ship_mode_key = repeat('0', 32));
INSERT INTO vault.hub_segment (hub_segment_key, segment_name, hub_load_dts, hub_rec_src)
SELECT repeat('0', 32), '(unknown)', now()::timestamp(0), 'zero_key'
 WHERE NOT EXISTS (SELECT 1 FROM vault.hub_segment WHERE hub_segment_key = repeat('0', 32));

\echo '--- vault: загрузка новых бизнес-ключей в хабы ---'
-- «Последний срез» staging = строки с максимальным load_dts (перезагрузка файла
-- удаляет старые строки, поэтому max(load_dts) однозначно задаёт срез).
CREATE TEMP TABLE src_clean ON COMMIT DROP AS
SELECT * FROM staging.stg_superstore_clean
 WHERE load_dts = (SELECT max(load_dts) FROM staging.stg_superstore_clean)
DISTRIBUTED BY (hub_location_key);

INSERT INTO vault.hub_country (hub_country_key, country_name, hub_load_dts, hub_rec_src)
SELECT s.hub_country_key, min(s.country_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_country h ON h.hub_country_key = s.hub_country_key
 WHERE h.hub_country_key IS NULL GROUP BY s.hub_country_key;

INSERT INTO vault.hub_region (hub_region_key, region_name, hub_load_dts, hub_rec_src)
SELECT s.hub_region_key, min(s.region_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_region h ON h.hub_region_key = s.hub_region_key
 WHERE h.hub_region_key IS NULL GROUP BY s.hub_region_key;

INSERT INTO vault.hub_state (hub_state_key, state_name, hub_load_dts, hub_rec_src)
SELECT s.hub_state_key, min(s.state_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_state h ON h.hub_state_key = s.hub_state_key
 WHERE h.hub_state_key IS NULL GROUP BY s.hub_state_key;


INSERT INTO vault.hub_location (hub_location_key, postal_code, city_name, hub_load_dts, hub_rec_src)
SELECT s.hub_location_key, min(s.postal_code), min(s.city_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_location h ON h.hub_location_key = s.hub_location_key
 WHERE h.hub_location_key IS NULL GROUP BY s.hub_location_key;

INSERT INTO vault.hub_category (hub_category_key, category_name, hub_load_dts, hub_rec_src)
SELECT s.hub_category_key, min(s.category_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_category h ON h.hub_category_key = s.hub_category_key
 WHERE h.hub_category_key IS NULL GROUP BY s.hub_category_key;

INSERT INTO vault.hub_sub_category (hub_sub_category_key, sub_category_name, hub_load_dts, hub_rec_src)
SELECT s.hub_sub_category_key, min(s.sub_category_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_sub_category h ON h.hub_sub_category_key = s.hub_sub_category_key
 WHERE h.hub_sub_category_key IS NULL GROUP BY s.hub_sub_category_key;

INSERT INTO vault.hub_ship_mode (hub_ship_mode_key, ship_mode_name, hub_load_dts, hub_rec_src)
SELECT s.hub_ship_mode_key, min(s.ship_mode_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_ship_mode h ON h.hub_ship_mode_key = s.hub_ship_mode_key
 WHERE h.hub_ship_mode_key IS NULL GROUP BY s.hub_ship_mode_key;

INSERT INTO vault.hub_segment (hub_segment_key, segment_name, hub_load_dts, hub_rec_src)
SELECT s.hub_segment_key, min(s.segment_name), min(s.load_dts), min(s.rec_src)
  FROM src_clean s LEFT JOIN vault.hub_segment h ON h.hub_segment_key = s.hub_segment_key
 WHERE h.hub_segment_key IS NULL GROUP BY s.hub_segment_key;

\echo '--- vault: состав хабов (реальные ключи + zero-key) ---'
SELECT 'hub_country' AS hub, count(*) FILTER (WHERE hub_country_key <> repeat('0',32)) AS real_keys,
       count(*) AS with_zero_key FROM vault.hub_country
UNION ALL SELECT 'hub_region', count(*) FILTER (WHERE hub_region_key <> repeat('0',32)), count(*) FROM vault.hub_region
UNION ALL SELECT 'hub_state', count(*) FILTER (WHERE hub_state_key <> repeat('0',32)), count(*) FROM vault.hub_state
UNION ALL SELECT 'hub_location', count(*) FILTER (WHERE hub_location_key <> repeat('0',32)), count(*) FROM vault.hub_location
UNION ALL SELECT 'hub_category', count(*) FILTER (WHERE hub_category_key <> repeat('0',32)), count(*) FROM vault.hub_category
UNION ALL SELECT 'hub_sub_category', count(*) FILTER (WHERE hub_sub_category_key <> repeat('0',32)), count(*) FROM vault.hub_sub_category
UNION ALL SELECT 'hub_ship_mode', count(*) FILTER (WHERE hub_ship_mode_key <> repeat('0',32)), count(*) FROM vault.hub_ship_mode
UNION ALL SELECT 'hub_segment', count(*) FILTER (WHERE hub_segment_key <> repeat('0',32)), count(*) FROM vault.hub_segment
ORDER BY 1;

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, rec_src, note)
SELECT 'hub', 'vault.hub_*',
       (SELECT count(*) FROM vault.hub_location WHERE hub_location_key <> repeat('0',32)),
       now()::timestamp(0), 'kaggle_superstore',
       'загрузка хабов (запись по hub_location как индикатор; zero-key не считаются)';
COMMIT;


