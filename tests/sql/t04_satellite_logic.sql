-- =====================================================================
-- tests/sql/t04_satellite_logic.sql
-- ТЕСТ t04. Логика сателлитов Data Vault:
--   * HASH_DIFF действительно равен md5 от набора атрибутов;
--   * у каждой версии не более одной активной записи на родителя;
--   * интервалы действия версий не пересекаются;
--   * множитель SALES_LINE_COUNT строго положителен (агрегация дублей).
-- =====================================================================

\echo '--- t04: логика сателлитов (хеш-дифф, версии, интервалы) ---'

SELECT audit.mk_check('t04', 'sat_location.hash_diff = md5(state|region|country)', '0', count(*)::text)
  FROM vault.sat_location
 WHERE hash_diff <> md5(upper(trim(state_name)) || '|' || upper(trim(region_name))
                        || '|' || upper(trim(country_name)));

SELECT audit.mk_check('t04', 'sat_sub_category.hash_diff = md5(sub_category|category)', '0', count(*)::text)
  FROM vault.sat_sub_category s
  JOIN vault.hub_sub_category h ON h.hub_sub_category_key = s.hub_sub_category_key
 WHERE s.hash_diff <> md5(upper(h.sub_category_name) || '|' || upper(s.category_name));

SELECT audit.mk_check('t04', 'sat_sales_line.hash_diff = md5(меры строки)', '0', count(*)::text)
  FROM vault.sat_sales_line
 WHERE hash_diff <> md5(sales_amount::text || '|' || quantity::text || '|'
                        || discount_rate::text || '|' || profit_amount::text);

SELECT audit.mk_check('t04', 'sat_ship_mode.hash_diff = md5(ship_mode|rank)', '0', count(*)::text)
  FROM vault.sat_ship_mode
 WHERE hash_diff <> md5(upper(trim(ship_mode_name)) || '|' || ship_speed_rank::text);

SELECT audit.mk_check('t04', 'sat_segment.hash_diff = md5(segment|segment_type)', '0', count(*)::text)
  FROM vault.sat_segment
 WHERE hash_diff <> md5(upper(trim(segment_name)) || '|' || upper(trim(segment_type)));

-- Не более одной активной версии на родителя
SELECT audit.mk_check('t04', 'sat_location: не более одной активной версии на локацию', '0', count(*)::text)
  FROM (SELECT hub_location_key FROM vault.sat_location
         WHERE active_flag AND valid_to IS NULL AND deleted_flag = false
         GROUP BY hub_location_key HAVING count(*) > 1) x;

SELECT audit.mk_check('t04', 'sat_sales_line: не более одной активной версии на (ссылку, хеш-дифф)', '0', count(*)::text)
  FROM (SELECT lnk_sales_line_key, hash_diff FROM vault.sat_sales_line
         WHERE active_flag AND valid_to IS NULL
         GROUP BY lnk_sales_line_key, hash_diff HAVING count(*) > 1) x;

-- Интервалы версий не пересекаются
SELECT audit.mk_check('t04', 'sat_location: интервалы версий не пересекаются', '0', count(*)::text)
  FROM vault.sat_location a
  JOIN vault.sat_location b
    ON a.hub_location_key = b.hub_location_key AND a.hash_diff < b.hash_diff
 WHERE a.valid_from < coalesce(b.valid_to, TIMESTAMP '9999-12-31')
   AND b.valid_from < coalesce(a.valid_to, TIMESTAMP '9999-12-31');

-- Эффективные интервалы ссылок
SELECT audit.mk_check('t04', 'efs_location_state: нет пересекающихся интервалов активности', '0', count(*)::text)
  FROM bv.efs_location_state a
  JOIN bv.efs_location_state b
    ON a.lnk_location_state_key = b.lnk_location_state_key AND a.load_dts < b.load_dts
 WHERE a.valid_from < coalesce(b.valid_to, TIMESTAMP '9999-12-31')
   AND b.valid_from < coalesce(a.valid_to, TIMESTAMP '9999-12-31');

-- Множитель дублей
SELECT audit.mk_check('t04', 'sat_sales_line: множитель строк всегда > 0', '0', count(*)::text)
  FROM vault.sat_sales_line WHERE sales_line_count <= 0;

SELECT audit.mk_check('t04', 'sat_sales_line: множитель > 1 встречается (17 дублей источника)', '17',
       (sum(sales_line_count) - count(*))::text)
  FROM vault.sat_sales_line;

-- Служебные поля Data Vault заполнены
SELECT audit.mk_check('t04', 'sat_sales_line: rec_src/valid_from заполнены, valid_to = NULL', '0', count(*)::text)
  FROM vault.sat_sales_line
 WHERE sat_rec_src IS NULL OR valid_from IS NULL OR valid_to IS NOT NULL;

SELECT audit.mk_check('t04', 'хабы: load_dts и rec_src заполнены (все 8 хабов)', '0', count(*)::text)
  FROM (
        SELECT hub_load_dts AS d, hub_rec_src AS s FROM vault.hub_country
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_region
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_state
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_location
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_category
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_sub_category
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_ship_mode
        UNION ALL SELECT hub_load_dts, hub_rec_src FROM vault.hub_segment
       ) x
 WHERE x.d IS NULL OR x.s IS NULL;
