-- =====================================================================
-- tests/sql/t01_ddl_structure.sql
-- ТЕСТ t01. Проверка структуры DDL: состав таблиц, ограничения целостности,
-- комментарии (по критерию «комментарии в коде/БД»), политика дистрибуции,
-- модель хранения (heap vs append-only column-oriented), партиционирование.
-- =====================================================================

\echo '--- t01: структура DDL ---'

-- 1. Состав таблиц
SELECT audit.mk_check('t01', 'таблиц в схеме vault (без партиций)', '18', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'vault' AND c.relkind IN ('r', 'p') AND NOT c.relispartition;

SELECT audit.mk_check('t01', 'таблиц в схеме staging', '2', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'staging' AND c.relkind IN ('r', 'p') AND NOT c.relispartition;

SELECT audit.mk_check('t01', 'таблиц в схеме bv (Business Vault)', '7', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'bv' AND c.relkind = 'r';

SELECT audit.mk_check('t01', 'материализованных представлений в схеме dm', '3', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'dm' AND c.relkind = 'm';

-- 2. Ограничения целостности
SELECT audit.mk_check('t01', 'PRIMARY KEY у всех 18 таблиц vault', '18', count(DISTINCT con.conrelid)::text)
  FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE con.contype = 'p' AND n.nspname = 'vault' AND NOT c.relispartition;

SELECT audit.mk_check('t01', 'FOREIGN KEY в ссылках vault (по одному на хаб-участник)', '12', count(*)::text)
  FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE con.contype = 'f' AND n.nspname = 'vault';

SELECT audit.mk_check('t01', 'CHECK-ограничения на меры и справочные значения', '5', count(*)::text)
  FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE con.contype = 'c' AND n.nspname = 'vault' AND NOT c.relispartition;

SELECT audit.mk_check('t01', 'UNIQUE/PRIMARY KEY в reference-таблицах Business Vault', '2', count(*)::text)
  FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE con.contype = 'p' AND n.nspname = 'bv' AND c.relname IN ('ref_ship_mode', 'ref_segment');

-- 3. Комментарии (таблицы и колонки схемы vault)
SELECT audit.mk_check('t01', 'у всех таблиц vault есть комментарии', '0', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'vault' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
   AND obj_description(c.oid, 'pg_class') IS NULL;

SELECT audit.mk_check('t01', 'у всех колонок vault есть комментарии', '0', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
 WHERE n.nspname = 'vault' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
   AND col_description(c.oid, a.attnum) IS NULL;

-- 4. Модель хранения и дистрибуция
SELECT audit.mk_check('t01', 'сателлиты хранятся как append-only column-oriented', '5', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_am am ON am.oid = c.relam
 WHERE n.nspname = 'vault' AND c.relname LIKE 'sat\_%' AND c.relkind IN ('r', 'p')
   AND NOT c.relispartition AND am.amname = 'ao_column';

SELECT audit.mk_check('t01', 'сателлиты сжаты (compresstype=zstd в reloptions)', '5', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'vault' AND c.relname LIKE 'sat\_%' AND c.relkind IN ('r', 'p')
   AND NOT c.relispartition AND array_to_string(c.reloptions, ',') LIKE '%compresstype=zstd%';

SELECT audit.mk_check('t01', 'хабы и ссылки хранятся как heap (поддержка PK/FK)', '13', count(*)::text)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_am am ON am.oid = c.relam
 WHERE n.nspname = 'vault' AND (c.relname LIKE 'hub\_%' OR c.relname LIKE 'lnk\_%')
   AND c.relkind = 'r' AND am.amname = 'heap';

SELECT audit.mk_check('t01', 'ключ дистрибуции каждой таблицы vault совпадает с её хеш-ключом', '0', count(*)::text)
  FROM (
        SELECT c.relname,
               array_agg(a.attname::text ORDER BY a.attname::text) AS distkeys
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN gp_distribution_policy p ON p.localoid = c.oid
          LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (p.distkey)
         WHERE n.nspname = 'vault' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
         GROUP BY c.relname
       ) t
 WHERE t.distkeys IS DISTINCT FROM
       ARRAY[CASE WHEN t.relname = 'sat_sales_line' THEN 'lnk_sales_line_key'
                  WHEN t.relname LIKE 'sat\_%' THEN 'hub_' || substr(t.relname, 5) || '_key'
                  ELSE t.relname || '_key' END];

-- 5. Партиционирование
SELECT audit.mk_check('t01', 'партиций у sat_sales_line (12 месяцев + DEFAULT)', '13', count(*)::text)
  FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent
 WHERE p.relname = 'sat_sales_line';

SELECT audit.mk_check('t01', 'партиций у staging.stg_superstore_raw', '13', count(*)::text)
  FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent
 WHERE p.relname = 'stg_superstore_raw';
