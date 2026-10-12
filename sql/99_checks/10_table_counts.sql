-- =====================================================================
-- 99_checks/10_table_counts.sql
-- Снимок «что создано и чем заполнено»: перечень объектов хранилища и число
-- строк в каждом. Используется как доказательство выполнения частей 3 задания
-- (таблицы созданы и заполнены данными датасета).
-- =====================================================================

\echo '=== Созданные таблицы и число строк ==='
SELECT n.nspname AS schema_name,
       c.relname AS object_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table'
                      WHEN 'm' THEN 'matview' WHEN 'v' THEN 'view' END AS kind,
       CASE WHEN c.relkind IN ('r', 'p') AND NOT c.relispartition
            THEN (xpath('/row/c/text()',
                        query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
                                     false, true, '')))[1]::text
       END AS rows_
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('staging', 'vault', 'bv', 'dm', 'audit')
   AND c.relkind IN ('r', 'p', 'm', 'v')
   AND NOT c.relispartition
 ORDER BY n.nspname, c.relname;

\echo '=== Итоги по слоям ==='
SELECT 'staging (ODS)' AS layer, count(*) AS tables FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'staging' AND c.relkind IN ('r','p') AND NOT c.relispartition
UNION ALL SELECT 'vault (DDS: hubs+links+sats)', count(*) FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'vault' AND c.relkind IN ('r','p') AND NOT c.relispartition
UNION ALL SELECT 'bv (Business Vault)', count(*) FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'bv' AND c.relkind = 'r'
UNION ALL SELECT 'dm (витрины и представления)', count(*) FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'dm' AND c.relkind IN ('r','m','v')
UNION ALL SELECT 'audit (служебные)', count(*) FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'audit' AND c.relkind = 'r';
