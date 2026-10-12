-- =====================================================================
-- 99_checks/50_e4_explain_distribution.sql
-- E4. Измеримое доказательство проектного решения «DISTRIBUTED BY (хеш-ключ)».
--
-- Сравниваются два плана одного и того же запроса:
--   A) правильная схема: ссылка и её сателлит дистрибутированы по одному и тому же
--      ключу (lnk_sales_line_key) -> соединение выполняется локально на сегментах;
--   B) антипример: сателлит распределён случайно (DISTRIBUTED RANDOMLY) ->
--      планировщик обязан перераспределять данные (Redistribute Motion).
-- В отчёте приводятся фрагменты планов: наличие Motion — цена ошибки в дистрибуции.
-- =====================================================================

\echo '=== E4-A. Правильная дистрибуция (co-location): Motion отсутствует ==='
EXPLAIN ANALYZE
SELECT l.segment_name,
       count(*)                                  AS measure_versions,
       sum(m.sales_line_count * m.sales_amount)  AS sales_amount
  FROM vault.lnk_sales_line l
  JOIN vault.sat_sales_line m ON m.lnk_sales_line_key = l.lnk_sales_line_key
 GROUP BY l.segment_name
 ORDER BY l.segment_name;

\echo '=== E4-B. Антипример: сателлит распределён случайно ==='
DROP TABLE IF EXISTS vault.tmp_sat_sales_line_random;
CREATE TABLE vault.tmp_sat_sales_line_random
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
AS
SELECT * FROM vault.sat_sales_line DISTRIBUTED RANDOMLY;

EXPLAIN ANALYZE
SELECT l.segment_name,
       count(*)                                  AS measure_versions,
       sum(m.sales_line_count * m.sales_amount)  AS sales_amount
  FROM vault.lnk_sales_line l
  JOIN vault.tmp_sat_sales_line_random m ON m.lnk_sales_line_key = l.lnk_sales_line_key
 GROUP BY l.segment_name
 ORDER BY l.segment_name;

\echo '=== E4-C. Краткие планы: ищем Redistribute/Broadcast Motion ==='
\echo '--- C1) co-location (оба объекта по lnk_sales_line_key) ---'
EXPLAIN
SELECT count(*)
  FROM vault.lnk_sales_line l
  JOIN vault.sat_sales_line m ON m.lnk_sales_line_key = l.lnk_sales_line_key;

\echo '--- C2) случайная дистрибуция сателлита ---'
EXPLAIN
SELECT count(*)
  FROM vault.lnk_sales_line l
  JOIN vault.tmp_sat_sales_line_random m ON m.lnk_sales_line_key = l.lnk_sales_line_key;

DROP TABLE IF EXISTS vault.tmp_sat_sales_line_random;

\echo '=== E4-D. Partition pruning: партиционирование staging по дате загрузки ==='
EXPLAIN
SELECT count(*) FROM staging.stg_superstore_raw
 WHERE load_dts >= TIMESTAMP '2026-10-01 00:00:00'
   AND load_dts <  TIMESTAMP '2026-11-01 00:00:00';
