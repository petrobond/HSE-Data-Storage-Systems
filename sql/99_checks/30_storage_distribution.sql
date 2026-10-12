-- =====================================================================
-- 99_checks/30_storage_distribution.sql
-- Доказательство «зелёной» части критериев по Greenplum: как именно созданы
-- таблицы (модель хранения, сжатие, ключ дистрибуции, партиционирование,
-- ограничения, комментарии).
-- =====================================================================

\echo '=== Модель хранения, сжатие и ключ дистрибуции (схема vault) ==='
SELECT c.relname AS object_name,
       am.amname AS storage_am,
       array_to_string(c.reloptions, ', ') AS storage_options,
       (SELECT string_agg(a.attname, ', ' ORDER BY a.attname)
          FROM pg_attribute a
         WHERE a.attrelid = c.oid AND a.attnum = ANY (p.distkey)) AS distribution_key
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_am am ON am.oid = c.relam
  LEFT JOIN gp_distribution_policy p ON p.localoid = c.oid
 WHERE n.nspname = 'vault' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
 ORDER BY c.relname;

\echo '=== Ограничения целостности (PK / FK / CHECK) ==='
SELECT c.relname AS object_name, con.contype AS type, con.conname AS constraint_name
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'vault' AND NOT c.relispartition
 ORDER BY c.relname, con.contype DESC, con.conname;

\echo '=== Партиционирование (sat_sales_line и staging raw) ==='
SELECT parent.relname AS partitioned_table, count(*) AS partitions
  FROM pg_inherits i
  JOIN pg_class parent ON parent.oid = i.inhparent
  JOIN pg_namespace n ON n.oid = parent.relnamespace
 WHERE n.nspname IN ('vault', 'staging')
 GROUP BY parent.relname
 ORDER BY parent.relname;

\echo '=== MPP-топология локального кластера ==='
SELECT dbid, content, role, hostname, port, datadir, status
  FROM gp_segment_configuration
 ORDER BY content, role;
