-- =====================================================================
-- 03_load/90_refresh_dq_metrics.sql
-- E11. Персистентные метрики качества данных: после каждой загрузки метрики
-- сохраняются в audit.dq_metrics, что даёт «тренд» качества, а не только
-- одноразовую проверку. Метрика считается OK, если значение совпало с ожидаемым.
-- =====================================================================

\echo '--- audit: обновление метрик качества данных ---'
INSERT INTO audit.dq_metrics (metric_dts, metric_name, metric_value, expected_value, unit, status, note)
SELECT now()::timestamp(0), m.metric_name, m.metric_value, m.expected_value, m.unit,
       CASE WHEN m.metric_value IS NOT DISTINCT FROM m.expected_value THEN 'OK' ELSE 'FAIL' END,
       m.note
  FROM (
        SELECT 'staging_rows' AS metric_name,
               (SELECT count(*)::numeric FROM staging.stg_superstore_clean) AS metric_value,
               9994::numeric AS expected_value, 'rows' AS unit,
               'строк исходного датасета, прошедших валидацию' AS note
  UNION ALL SELECT 'staging_rejected_rows',
               (SELECT count(*)::numeric FROM audit.rejected_records), 0, 'rows',
               'строки, отклонённые правилами качества (ожидается 0)'
  UNION ALL SELECT 'sales_lines_reconciled',
               (SELECT sum(sales_line_count)::numeric FROM vault.sat_sales_line), 9994, 'rows',
               'строк источника, восстановленных из Data Vault (множитель SALES_LINE_COUNT)'
  UNION ALL SELECT 'sales_sum_delta',
               (SELECT sum(sales_line_count * sales_amount)::numeric - 2297200.8603 FROM vault.sat_sales_line), 0, 'currency',
               'расхождение суммы Sales между источником и vault'
  UNION ALL SELECT 'profit_sum_delta',
               (SELECT sum(sales_line_count * profit_amount)::numeric - 286397.0217 FROM vault.sat_sales_line), 0, 'currency',
               'расхождение суммы Profit между источником и vault'
  UNION ALL SELECT 'quantity_sum_delta',
               (SELECT sum(sales_line_count * quantity)::numeric - 37873 FROM vault.sat_sales_line), 0, 'units',
               'расхождение суммы Quantity между источником и vault'
  UNION ALL SELECT 'sat_sales_line_versions',
               (SELECT count(*)::numeric FROM vault.sat_sales_line), 9977, 'rows',
               'версии мер (ключ линка + хеш-дифф мер)'
  UNION ALL SELECT 'sales_line_combinations',
               (SELECT count(*)::numeric FROM vault.lnk_sales_line), 6868, 'rows',
               'уникальные комбинации четырёх хабов (гранулярность транзакционной ссылки)'
  UNION ALL SELECT 'ghost_records',
               (SELECT count(*)::numeric FROM vault.hub_location WHERE hub_location_key = repeat('0',32)), 1, 'rows',
               'zero-key (ghost) запись в хабах (стандарт Data Vault 2.0)'
  UNION ALL SELECT 'zip_leading_zeros_restored',
               (SELECT count(*)::numeric FROM staging.stg_superstore_raw
                 WHERE length(btrim(postal_code)) = 4), 449, 'rows',
               'ZIP, у которых в источнике потерян ведущий ноль (восстановлены lpad до 5 знаков)'
  UNION ALL SELECT 'duplicate_rows_folded',
               (SELECT count(*)::numeric FROM staging.stg_superstore_clean)
               - (SELECT count(*)::numeric FROM vault.sat_sales_line), 17, 'rows',
               'полностью дублирующиеся строки, «схлопнутые» множителем SALES_LINE_COUNT'
  UNION ALL SELECT 'lineage_rows',
               (SELECT count(*)::numeric FROM audit.record_lineage),
               (SELECT count(*)::numeric FROM staging.stg_superstore_clean), 'rows',
               'трассировка «строка источника -> строка Data Vault»'
        ) m;

\echo '--- audit: метрики качества (последний прогон) ---'
SELECT metric_name, metric_value, expected_value, unit, status
  FROM audit.dq_metrics
 WHERE metric_dts = (SELECT max(metric_dts) FROM audit.dq_metrics)
 ORDER BY status, metric_name;

SELECT count(*) FILTER (WHERE status = 'OK')   AS metrics_ok,
       count(*) FILTER (WHERE status = 'FAIL') AS metrics_failed
  FROM audit.dq_metrics
 WHERE metric_dts = (SELECT max(metric_dts) FROM audit.dq_metrics);
