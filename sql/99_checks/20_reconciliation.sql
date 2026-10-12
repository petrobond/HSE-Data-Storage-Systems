-- =====================================================================
-- 99_checks/20_reconciliation.sql
-- Главное доказательство корректности части 3: данные источника доехали до
-- витрин без потерь и искажений. Сравниваются:
--   staging (источник) -> vault.sat_sales_line (DDS) -> bv.bridge -> dm_sales_star.
-- Ключевая особенность модели: множитель SALES_LINE_COUNT восстанавливает
-- количество строк источника (в том числе 17 полных дублей).
-- =====================================================================

\echo '=== Сходимость: источник -> Data Vault -> Business Vault -> витрина ==='
SELECT 'staging.stg_superstore_clean (источник)' AS object,
       count(*)                                   AS lines,
       sum(sales_amount)                          AS sales,
       sum(profit_amount)                         AS profit,
       sum(quantity)                              AS quantity
  FROM staging.stg_superstore_clean
UNION ALL
SELECT 'vault.sat_sales_line (DDS)', sum(sales_line_count),
       sum(sales_line_count * sales_amount), sum(sales_line_count * profit_amount),
       sum(sales_line_count * quantity)
  FROM vault.sat_sales_line
UNION ALL
SELECT 'bv.bridge_sales_line', sum(sales_line_count),
       sum(sales_line_count * sales_amount), sum(sales_line_count * profit_amount),
       sum(sales_line_count * quantity)
  FROM bv.bridge_sales_line
UNION ALL
SELECT 'dm.dm_sales_star (витрина)', sum(sales_line_count),
       sum(sales_line_count * sales_amount), sum(sales_line_count * profit_amount),
       sum(sales_line_count * quantity)
  FROM dm.dm_sales_star;

\echo '=== Профиль исходных данных и решённые проблемы качества ==='
SELECT * FROM dm.dm_dq_source_profile;

\echo '=== Продажи по регионам и категориям (витрина из Data Vault) ==='
SELECT region_name, category_name, sales_lines, sales_amount, profit_amount, profit_margin_pct
  FROM dm.dm_sales_by_region_category
 ORDER BY region_name, category_name;
