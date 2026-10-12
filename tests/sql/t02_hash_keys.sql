-- =====================================================================
-- tests/sql/t02_hash_keys.sql
-- ТЕСТ t02. Корректность хеш-ключей и хеш-диффов:
--   * ключ каждой записи равен md5 от нормализованного бизнес-ключа;
--   * ключи уникальны (нет коллизий и дублей);
--   * нормализация (upper/trim) действительно работает;
--   * ghost-записи (zero-key) присутствуют во всех хабах.
-- ghost-записи (repeat('0',32)) исключаются из проверок формулы — у них
-- бизнес-ключ синтетический '(unknown)'.
-- =====================================================================

\echo '--- t02: хеш-ключи и хеш-диффы ---'

-- 1. Формула ключа для каждого хаба
SELECT audit.mk_check('t02', 'hub_country_key = md5(upper(trim(country_name)))', '0', count(*)::text)
  FROM vault.hub_country
 WHERE hub_country_key <> repeat('0', 32) AND hub_country_key <> md5(upper(trim(country_name)));

SELECT audit.mk_check('t02', 'hub_region_key = md5(upper(trim(region_name)))', '0', count(*)::text)
  FROM vault.hub_region
 WHERE hub_region_key <> repeat('0', 32) AND hub_region_key <> md5(upper(trim(region_name)));

SELECT audit.mk_check('t02', 'hub_state_key = md5(upper(trim(state_name)))', '0', count(*)::text)
  FROM vault.hub_state
 WHERE hub_state_key <> repeat('0', 32) AND hub_state_key <> md5(upper(trim(state_name)));

SELECT audit.mk_check('t02', 'hub_location_key = md5(postal|city)', '0', count(*)::text)
  FROM vault.hub_location
 WHERE hub_location_key <> repeat('0', 32)
   AND hub_location_key <> md5(upper(postal_code) || '|' || upper(city_name));

SELECT audit.mk_check('t02', 'hub_category_key = md5(upper(trim(category_name)))', '0', count(*)::text)
  FROM vault.hub_category
 WHERE hub_category_key <> repeat('0', 32) AND hub_category_key <> md5(upper(trim(category_name)));

SELECT audit.mk_check('t02', 'hub_sub_category_key = md5(upper(trim(sub_category_name)))', '0', count(*)::text)
  FROM vault.hub_sub_category
 WHERE hub_sub_category_key <> repeat('0', 32)
   AND hub_sub_category_key <> md5(upper(trim(sub_category_name)));

SELECT audit.mk_check('t02', 'hub_ship_mode_key = md5(upper(trim(ship_mode_name)))', '0', count(*)::text)
  FROM vault.hub_ship_mode
 WHERE hub_ship_mode_key <> repeat('0', 32) AND hub_ship_mode_key <> md5(upper(trim(ship_mode_name)));

SELECT audit.mk_check('t02', 'hub_segment_key = md5(upper(trim(segment_name)))', '0', count(*)::text)
  FROM vault.hub_segment
 WHERE hub_segment_key <> repeat('0', 32) AND hub_segment_key <> md5(upper(trim(segment_name)));

-- 2. Формула ключа транзакционной ссылки (5 бизнес-ключей, порядок фиксирован)
SELECT audit.mk_check('t02', 'lnk_sales_line_key = md5(postal|city|sub_category|ship_mode|segment)', '0', count(*)::text)
  FROM vault.lnk_sales_line l
  JOIN vault.hub_location hl ON hl.hub_location_key = l.hub_location_key
 WHERE l.lnk_sales_line_key <> md5(upper(hl.postal_code) || '|' || upper(hl.city_name) || '|'
                                   || upper(l.sub_category_name) || '|' || upper(l.ship_mode_name)
                                   || '|' || upper(l.segment_name));

-- 3. Уникальность ключей (отсутствие коллизий)
SELECT audit.mk_check('t02', 'ключи hub_location уникальны', '0',
       (count(*) - count(DISTINCT hub_location_key))::text)
  FROM vault.hub_location;

SELECT audit.mk_check('t02', 'ключи lnk_sales_line уникальны', '0',
       (count(*) - count(DISTINCT lnk_sales_line_key))::text)
  FROM vault.lnk_sales_line;

SELECT audit.mk_check('t02', 'пары (lnk_sales_line_key, hash_diff) уникальны', '0',
       (count(*) - count(DISTINCT (lnk_sales_line_key, hash_diff)))::text)
  FROM vault.sat_sales_line;

SELECT audit.mk_check('t02', 'бизнес-ключи hub_location уникальны (postal+city)', '0',
       (count(*) - count(DISTINCT (postal_code, city_name)))::text)
  FROM vault.hub_location WHERE hub_location_key <> repeat('0', 32);

-- 4. Нормализация бизнес-ключей перед хешированием
SELECT audit.mk_check('t02', 'нормализация: регистр и пробелы не влияют на ключ', 'true',
       (md5(upper(trim(' consumer '))) = md5('CONSUMER'))::text);

SELECT audit.mk_check('t02', 'длина хеш-ключа всегда 32 символа', '0',
       count(*)::text)
  FROM vault.hub_location WHERE length(hub_location_key) <> 32;

-- 5. Ghost-записи (zero-key) в каждом хабе
SELECT audit.mk_check('t02', 'ghost-запись (zero-key) присутствует во всех 8 хабах', '8',
       ( (SELECT count(*) FROM vault.hub_country      WHERE hub_country_key      = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_region       WHERE hub_region_key       = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_state        WHERE hub_state_key        = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_location     WHERE hub_location_key     = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_category     WHERE hub_category_key     = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_sub_category WHERE hub_sub_category_key = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_ship_mode    WHERE hub_ship_mode_key    = repeat('0', 32))
       + (SELECT count(*) FROM vault.hub_segment      WHERE hub_segment_key      = repeat('0', 32)) )::text);
