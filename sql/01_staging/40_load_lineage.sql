-- =====================================================================
-- 01_staging/40_load_lineage.sql
-- Lineage (прослеживаемость) и журнал загрузки staging:
--   audit.record_lineage — какая строка исходного файла породила какую строку
--   Data Vault (ссылка продажи + её хеш-дифф + ключи хабов);
--   audit.load_run_log   — журнал: сколько строк загружено на каждом шаге.
-- Позволяет по номеру строки CSV (или по её sha256) найти все порождённые
-- объекты хранилища и наоборот — от строки хранилища дойти до источника.
-- =====================================================================

\if :{?file_hash}
\else
  \set file_hash '0000000000000000000000000000000000000000000000000000000000000000'
\endif
\if :{?rec_src}
\else
  \set rec_src 'kaggle_superstore'
\endif

\echo '--- staging: lineage и журнал загрузки ---'

BEGIN;

DELETE FROM audit.record_lineage WHERE file_hash = :'file_hash';

INSERT INTO audit.record_lineage
      (src_row_num, file_hash, load_dts, lnk_sales_line_key, hash_diff,
       hub_location_key, hub_sub_category_key, hub_ship_mode_key, hub_segment_key)
SELECT src_row_num, file_hash, load_dts, lnk_sales_line_key, hash_diff,
       hub_location_key, hub_sub_category_key, hub_ship_mode_key, hub_segment_key
  FROM staging.stg_superstore_clean
 WHERE file_hash = :'file_hash';

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, file_hash, rec_src, note)
SELECT 'staging', 'staging.stg_superstore_clean', count(*), now()::timestamp(0), :'file_hash', :'rec_src',
       'очищенный слой staging с хеш-ключами и lineage'
  FROM staging.stg_superstore_clean
 WHERE file_hash = :'file_hash';

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, file_hash, rec_src, note)
SELECT 'staging', 'audit.record_lineage', count(*), now()::timestamp(0), :'file_hash', :'rec_src',
       'lineage строк источника'
  FROM audit.record_lineage
 WHERE file_hash = :'file_hash';

COMMIT;

\echo '--- staging: контрольные суммы (для сверки с источником) ---'
SELECT count(*)          AS rows_,
       sum(sales_amount) AS sales_sum,
       sum(profit_amount) AS profit_sum,
       sum(quantity)     AS quantity_sum,
       count(DISTINCT lnk_sales_line_key) AS sales_line_combos,
       count(DISTINCT hash_diff)          AS measure_versions
  FROM staging.stg_superstore_clean
 WHERE file_hash = :'file_hash';
