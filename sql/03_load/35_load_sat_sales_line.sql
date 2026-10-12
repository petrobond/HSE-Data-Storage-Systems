-- =====================================================================
-- 03_load/35_load_sat_sales_line.sql
-- Загрузка САТЕЛЛИТА МЕР vault.sat_sales_line — ядро модели.
--
-- Почему так:
--  * в источнике НЕТ идентификатора строки продажи и НЕТ даты, поэтому
--    идентичность строки задаётся парой (LNK_SALES_LINE_KEY, HASH_DIFF),
--    где HASH_DIFF = md5(sales|quantity|discount|profit);
--  * 17 строк датасета полностью дублируются, поэтому одинаковые строки
--    «схлопываются» в один HASH_DIFF и учитываются множителем SALES_LINE_COUNT.
--    За счёт этого модель реконсилится с источником:
--        SUM(SALES_LINE_COUNT)              = 9994
--        SUM(SALES_LINE_COUNT * SALES)      = 2 297 200.8603
--        SUM(SALES_LINE_COUNT * PROFIT)     =   286 397.0217
--        SUM(SALES_LINE_COUNT * QUANTITY)   =        37 873
--  * valid_to = NULL и active_flag = true: версии мер — не временные версии
--    (даты в источнике нет). При появлении в источнике даты заказа type-2
--    включится штатно: hash_diff + valid_from/valid_to на дату события.
-- =====================================================================

-- Защита от «тихой» загрузки: если staging пуст, скрипт останавливается с ошибкой.
DO $$
BEGIN
    IF (SELECT count(*) FROM staging.stg_superstore_clean) = 0 THEN
        RAISE EXCEPTION 'staging.stg_superstore_clean пуст — сначала выполните: make stage';
    END IF;
END $$;

\echo '--- vault: сателлит мер строки продажи: агрегация версий мер ---'
BEGIN;
CREATE TEMP TABLE src_agg ON COMMIT DROP AS
SELECT s.lnk_sales_line_key,
       s.hash_diff,
       count(*)              AS sales_line_count,  -- число одинаковых строк источника
       min(s.sales_amount)   AS sales_amount,
       min(s.quantity)       AS quantity,
       min(s.discount_rate)  AS discount_rate,
       min(s.profit_amount)  AS profit_amount,
       max(s.load_dts)       AS load_dts,
       min(s.rec_src)        AS rec_src
  FROM staging.stg_superstore_clean s
 WHERE s.load_dts = (SELECT max(load_dts) FROM staging.stg_superstore_clean)
 GROUP BY s.lnk_sales_line_key, s.hash_diff
DISTRIBUTED BY (lnk_sales_line_key);

\echo '--- vault: вставка новых версий мер в sat_sales_line ---'
INSERT INTO vault.sat_sales_line
      (lnk_sales_line_key, hash_diff, sat_load_dts, sat_rec_src,
       sales_amount, quantity, discount_rate, profit_amount, sales_line_count,
       valid_from, valid_to, active_flag, deleted_flag)
SELECT a.lnk_sales_line_key, a.hash_diff, a.load_dts, a.rec_src,
       a.sales_amount, a.quantity, a.discount_rate, a.profit_amount, a.sales_line_count,
       a.load_dts, NULL, true, false
  FROM src_agg a
  LEFT JOIN vault.sat_sales_line t
         ON t.lnk_sales_line_key = a.lnk_sales_line_key
        AND t.hash_diff = a.hash_diff
 WHERE t.lnk_sales_line_key IS NULL;

\echo '--- vault: реконсиляция сателлита мер с источником ---'
SELECT (SELECT count(*) FROM src_agg)                       AS versions_expected,
       (SELECT count(*) FROM vault.sat_sales_line)          AS versions_loaded,
       (SELECT sum(sales_line_count) FROM vault.sat_sales_line) AS rows_reconciled,
       (SELECT sum(sales_line_count * sales_amount) FROM vault.sat_sales_line) AS sales_reconciled,
       (SELECT sum(sales_line_count * profit_amount) FROM vault.sat_sales_line) AS profit_reconciled,
       (SELECT sum(sales_line_count * quantity) FROM vault.sat_sales_line) AS quantity_reconciled;

INSERT INTO audit.load_run_log (stage, target_table, rows_inserted, load_dts, rec_src, note)
SELECT 'satellite', 'vault.sat_sales_line', count(*), now()::timestamp(0),
       'kaggle_superstore', 'версии мер строк продаж (хеш-дифф + множитель повторяющихся строк)'
  FROM vault.sat_sales_line;
COMMIT;

