-- =====================================================================
-- 99_checks/60_audit_metrics.sql
-- Служебная аналитика хранилища: журнал загрузок, метрики качества (E11),
-- карантин (E3) и размеры объектов.
-- =====================================================================

\echo '=== Журнал загрузок (audit.load_run_log) ==='
SELECT run_id, stage, target_table, rows_inserted, load_dts, rec_src, note
  FROM audit.load_run_log
 ORDER BY run_id;

\echo '=== Метрики качества данных последнего прогона (E11) ==='
SELECT metric_name, metric_value, expected_value, unit, status, note
  FROM audit.dq_metrics
 WHERE metric_dts = (SELECT max(metric_dts) FROM audit.dq_metrics)
 ORDER BY status, metric_name;

\echo '=== Тренд качества: число FAIL по прогонам (история накапливается) ==='
SELECT metric_dts, count(*) AS metrics, count(*) FILTER (WHERE status = 'FAIL') AS failed
  FROM audit.dq_metrics
 GROUP BY metric_dts
 ORDER BY metric_dts;

\echo '=== Карантин отклонённых записей (E3) ==='
SELECT count(*) AS rejected_total FROM audit.rejected_records;

\echo '=== Размеры объектов хранилища ==='
SELECT n.nspname AS schema_name, c.relname AS object_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('staging', 'vault', 'bv', 'dm', 'audit')
   AND c.relkind IN ('r', 'm')
 ORDER BY pg_total_relation_size(c.oid) DESC
 LIMIT 15;

\echo '=== Общий объём хранилища по слоям ==='
SELECT n.nspname AS schema_name,
       pg_size_pretty(sum(pg_total_relation_size(c.oid))) AS total_size
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('staging', 'vault', 'bv', 'dm', 'audit')
   AND c.relkind IN ('r', 'm')
 GROUP BY n.nspname
 ORDER BY sum(pg_total_relation_size(c.oid)) DESC;
