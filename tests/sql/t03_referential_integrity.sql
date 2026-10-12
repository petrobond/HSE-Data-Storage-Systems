-- =====================================================================
-- tests/sql/t03_referential_integrity.sql
-- ТЕСТ t03. Ссылочная целостность фактическая.
-- ВАЖНО: Greenplum объявляет внешние ключи, но НЕ проверяет их
-- («referential integrity (FOREIGN KEY) constraints are not supported in
-- Greenplum Database, will not be enforced»), поэтому целостность проверяется
-- явными анти-join'ами. Дополнительно: FK нельзя объявить на append-optimized
-- таблицах (проверено: "Trigger is not supported on AOCS yet"), поэтому
-- целостность сателлитов — ответственность загрузки и этих тестов.
-- =====================================================================

\echo '--- t03: ссылочная целостность (анти-join по всем связям) ---'

SELECT audit.mk_check('t03', 'lnk_location_state -> hub_location (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_location_state l LEFT JOIN vault.hub_location h
    ON h.hub_location_key = l.hub_location_key WHERE h.hub_location_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_location_state -> hub_state (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_location_state l LEFT JOIN vault.hub_state h
    ON h.hub_state_key = l.hub_state_key WHERE h.hub_state_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_state_region -> hub_state (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_state_region l LEFT JOIN vault.hub_state h
    ON h.hub_state_key = l.hub_state_key WHERE h.hub_state_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_state_region -> hub_region (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_state_region l LEFT JOIN vault.hub_region h
    ON h.hub_region_key = l.hub_region_key WHERE h.hub_region_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_region_country -> hub_region (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_region_country l LEFT JOIN vault.hub_region h
    ON h.hub_region_key = l.hub_region_key WHERE h.hub_region_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_region_country -> hub_country (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_region_country l LEFT JOIN vault.hub_country h
    ON h.hub_country_key = l.hub_country_key WHERE h.hub_country_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_category_sub_category -> hub_category (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_category_sub_category l LEFT JOIN vault.hub_category h
    ON h.hub_category_key = l.hub_category_key WHERE h.hub_category_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_category_sub_category -> hub_sub_category (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_category_sub_category l LEFT JOIN vault.hub_sub_category h
    ON h.hub_sub_category_key = l.hub_sub_category_key WHERE h.hub_sub_category_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_sales_line -> hub_location (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_sales_line l LEFT JOIN vault.hub_location h
    ON h.hub_location_key = l.hub_location_key WHERE h.hub_location_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_sales_line -> hub_sub_category (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_sales_line l LEFT JOIN vault.hub_sub_category h
    ON h.hub_sub_category_key = l.hub_sub_category_key WHERE h.hub_sub_category_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_sales_line -> hub_ship_mode (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_sales_line l LEFT JOIN vault.hub_ship_mode h
    ON h.hub_ship_mode_key = l.hub_ship_mode_key WHERE h.hub_ship_mode_key IS NULL;

SELECT audit.mk_check('t03', 'lnk_sales_line -> hub_segment (осиротевших нет)', '0', count(*)::text)
  FROM vault.lnk_sales_line l LEFT JOIN vault.hub_segment h
    ON h.hub_segment_key = l.hub_segment_key WHERE h.hub_segment_key IS NULL;

-- Сателлиты -> родители
SELECT audit.mk_check('t03', 'sat_location -> hub_location (осиротевших нет)', '0', count(*)::text)
  FROM vault.sat_location s LEFT JOIN vault.hub_location h
    ON h.hub_location_key = s.hub_location_key WHERE h.hub_location_key IS NULL;

SELECT audit.mk_check('t03', 'sat_sub_category -> hub_sub_category (осиротевших нет)', '0', count(*)::text)
  FROM vault.sat_sub_category s LEFT JOIN vault.hub_sub_category h
    ON h.hub_sub_category_key = s.hub_sub_category_key WHERE h.hub_sub_category_key IS NULL;

SELECT audit.mk_check('t03', 'sat_ship_mode -> hub_ship_mode (осиротевших нет)', '0', count(*)::text)
  FROM vault.sat_ship_mode s LEFT JOIN vault.hub_ship_mode h
    ON h.hub_ship_mode_key = s.hub_ship_mode_key WHERE h.hub_ship_mode_key IS NULL;

SELECT audit.mk_check('t03', 'sat_segment -> hub_segment (осиротевших нет)', '0', count(*)::text)
  FROM vault.sat_segment s LEFT JOIN vault.hub_segment h
    ON h.hub_segment_key = s.hub_segment_key WHERE h.hub_segment_key IS NULL;

SELECT audit.mk_check('t03', 'sat_sales_line -> lnk_sales_line (осиротевших нет)', '0', count(*)::text)
  FROM vault.sat_sales_line s LEFT JOIN vault.lnk_sales_line l
    ON l.lnk_sales_line_key = s.lnk_sales_line_key WHERE l.lnk_sales_line_key IS NULL;

-- Business Vault -> raw vault
SELECT audit.mk_check('t03', 'bridge_sales_line -> lnk_sales_line (осиротевших нет)', '0', count(*)::text)
  FROM bv.bridge_sales_line b LEFT JOIN vault.lnk_sales_line l
    ON l.lnk_sales_line_key = b.lnk_sales_line_key WHERE l.lnk_sales_line_key IS NULL;

SELECT audit.mk_check('t03', 'pit_location -> hub_location (осиротевших нет)', '0', count(*)::text)
  FROM bv.pit_location p LEFT JOIN vault.hub_location h
    ON h.hub_location_key = p.hub_location_key WHERE h.hub_location_key IS NULL;

SELECT audit.mk_check('t03', 'efs_location_state -> lnk_location_state (осиротевших нет)', '0', count(*)::text)
  FROM bv.efs_location_state e LEFT JOIN vault.lnk_location_state l
    ON l.lnk_location_state_key = e.lnk_location_state_key WHERE l.lnk_location_state_key IS NULL;

SELECT audit.mk_check('t03', 'dm_sales_star -> bv.bridge_sales_line (осиротевших нет)', '0', count(*)::text)
  FROM dm.dm_sales_star d LEFT JOIN bv.bridge_sales_line b
    ON b.lnk_sales_line_key = d.lnk_sales_line_key AND b.hash_diff = d.hash_diff
 WHERE b.lnk_sales_line_key IS NULL;

SELECT audit.mk_check('t03', 'audit.record_lineage -> sat_sales_line (все строки трассируются)', '0', count(*)::text)
  FROM audit.record_lineage r LEFT JOIN vault.sat_sales_line s
    ON s.lnk_sales_line_key = r.lnk_sales_line_key AND s.hash_diff = r.hash_diff
 WHERE s.lnk_sales_line_key IS NULL;

