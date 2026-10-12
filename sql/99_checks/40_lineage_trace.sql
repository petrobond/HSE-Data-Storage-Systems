-- =====================================================================
-- 99_checks/40_lineage_trace.sql
-- E6. Прослеживаемость: от строки исходного CSV до строк Data Vault и обратно.
-- Демонстрируется на конкретной строке файла (src_row_num = 1).
-- =====================================================================

\echo '=== 1. Строка источника (src_row_num = 1) ==='
SELECT src_row_num, ship_mode, segment, country, city, state, postal_code, region,
       category, sub_category, sales, quantity, discount, profit, file_name, file_hash
  FROM staging.stg_superstore_raw
 WHERE src_row_num = 1;

\echo '=== 2. Порождённые строки Data Vault (lineage) ==='
SELECT r.src_row_num,
       r.lnk_sales_line_key,
       r.hash_diff,
       l.postal_code, l.city_name, l.sub_category_name, l.ship_mode_name, l.segment_name,
       m.sales_amount, m.quantity, m.discount_rate, m.profit_amount, m.sales_line_count
  FROM audit.record_lineage r
  JOIN vault.lnk_sales_line l ON l.lnk_sales_line_key = r.lnk_sales_line_key
  JOIN vault.sat_sales_line m ON m.lnk_sales_line_key = r.lnk_sales_line_key
                             AND m.hash_diff = r.hash_diff
 WHERE r.src_row_num = 1;

\echo '=== 3. Обратная трассировка: какие строки файла дали эту строку хранилища ==='
SELECT r.src_row_num, r.file_hash, r.load_dts
  FROM audit.record_lineage r
 WHERE r.lnk_sales_line_key = (SELECT lnk_sales_line_key FROM audit.record_lineage WHERE src_row_num = 1)
   AND r.hash_diff = (SELECT hash_diff FROM audit.record_lineage WHERE src_row_num = 1)
 ORDER BY r.src_row_num;

\echo '=== 4. Полнота lineage ==='
SELECT (SELECT count(*) FROM audit.record_lineage) AS lineage_rows,
       (SELECT count(*) FROM staging.stg_superstore_clean) AS source_rows,
       (SELECT count(*) FROM audit.record_lineage r
          LEFT JOIN vault.sat_sales_line s
            ON s.lnk_sales_line_key = r.lnk_sales_line_key AND s.hash_diff = r.hash_diff
         WHERE s.lnk_sales_line_key IS NULL) AS without_target;
