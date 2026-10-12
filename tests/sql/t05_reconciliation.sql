-- =====================================================================
-- tests/sql/t05_reconciliation.sql
-- ТЕСТ t05. Сходимость модели с источником (главный критерий корректности
-- хранилища): количества, контрольные суммы, кардинальности хабов и ссылок,
-- совпадение агрегатов по независимым разрезам.
--
-- Ожидаемые значения получены профилированием датасета (src/profile_dataset.py):
--   строк 9994, Sales 2 297 200.8603, Profit 286 397.0217, Quantity 37 873,
--   полных дублей 17, комбинаций 4 хабов 6868, версий мер 9977.
-- =====================================================================

\echo '--- t05: сходимость с источником ---'

SELECT audit.mk_check_num('t05', 'строк в staging = строк в источнике', 9994,
       (SELECT count(*) FROM staging.stg_superstore_clean));

SELECT audit.mk_check_num('t05', 'восстановленных строк источника из DDS (сумма SALES_LINE_COUNT)', 9994,
       (SELECT sum(sales_line_count) FROM vault.sat_sales_line));

SELECT audit.mk_check_num('t05', 'сумма Sales в DDS = сумме в источнике', 2297200.8603,
       (SELECT sum(sales_line_count * sales_amount) FROM vault.sat_sales_line));

SELECT audit.mk_check_num('t05', 'сумма Profit в DDS = сумме в источнике', 286397.0217,
       (SELECT sum(sales_line_count * profit_amount) FROM vault.sat_sales_line));

SELECT audit.mk_check_num('t05', 'сумма Quantity в DDS = сумме в источнике', 37873,
       (SELECT sum(sales_line_count * quantity) FROM vault.sat_sales_line));

-- Кардинальности хабов (без ghost-записей)
SELECT audit.mk_check_num('t05', 'hub_country: стран', 1,
       (SELECT count(*) FROM vault.hub_country WHERE hub_country_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_region: регионов', 4,
       (SELECT count(*) FROM vault.hub_region WHERE hub_region_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_state: штатов', 49,
       (SELECT count(*) FROM vault.hub_state WHERE hub_state_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_location: гео-локаций', 632,
       (SELECT count(*) FROM vault.hub_location WHERE hub_location_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_category: категорий', 3,
       (SELECT count(*) FROM vault.hub_category WHERE hub_category_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_sub_category: подкатегорий', 17,
       (SELECT count(*) FROM vault.hub_sub_category WHERE hub_sub_category_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_ship_mode: способов доставки', 4,
       (SELECT count(*) FROM vault.hub_ship_mode WHERE hub_ship_mode_key <> repeat('0',32)));
SELECT audit.mk_check_num('t05', 'hub_segment: сегментов покупателя', 3,
       (SELECT count(*) FROM vault.hub_segment WHERE hub_segment_key <> repeat('0',32)));

-- Кардинальности ссылок и сателлитов
SELECT audit.mk_check_num('t05', 'lnk_location_state: связей локация-штат', 632,
       (SELECT count(*) FROM vault.lnk_location_state));
SELECT audit.mk_check_num('t05', 'lnk_state_region: связей штат-регион', 49,
       (SELECT count(*) FROM vault.lnk_state_region));
SELECT audit.mk_check_num('t05', 'lnk_region_country: связей регион-страна', 4,
       (SELECT count(*) FROM vault.lnk_region_country));
SELECT audit.mk_check_num('t05', 'lnk_category_sub_category: связей категория-подкатегория', 17,
       (SELECT count(*) FROM vault.lnk_category_sub_category));
SELECT audit.mk_check_num('t05', 'lnk_sales_line: уникальных комбинаций 4 хабов', 6868,
       (SELECT count(*) FROM vault.lnk_sales_line));
SELECT audit.mk_check_num('t05', 'sat_sales_line: версий мер', 9977,
       (SELECT count(*) FROM vault.sat_sales_line));
SELECT audit.mk_check_num('t05', 'sat_location: версий гео-атрибутов', 632,
       (SELECT count(*) FROM vault.sat_location));
SELECT audit.mk_check_num('t05', 'bv.bridge_sales_line: строк (расплющенная модель)', 9977,
       (SELECT count(*) FROM bv.bridge_sales_line));
SELECT audit.mk_check_num('t05', 'dm.dm_sales_star: строк витрины-звезды', 9977,
       (SELECT count(*) FROM dm.dm_sales_star));

-- Совпадение агрегатов по независимым разрезам: staging vs витрина
SELECT audit.mk_check_num('t05', 'сумма Sales по регионам: staging vs витрина', 0,
       (SELECT sum(abs(delta)) FROM (
            SELECT coalesce(s.sales, 0) - coalesce(d.sales, 0) AS delta
              FROM (SELECT region_name, sum(sales_amount) AS sales
                      FROM staging.stg_superstore_clean GROUP BY region_name) s
              FULL JOIN (SELECT region_name, sum(sales_line_count * sales_amount) AS sales
                           FROM dm.dm_sales_star GROUP BY region_name) d
                ON d.region_name = s.region_name) x));

SELECT audit.mk_check_num('t05', 'сумма Profit по категориям: staging vs bridge', 0,
       (SELECT sum(abs(delta)) FROM (
            SELECT coalesce(s.profit, 0) - coalesce(d.profit, 0) AS delta
              FROM (SELECT category_name, sum(profit_amount) AS profit
                      FROM staging.stg_superstore_clean GROUP BY category_name) s
              FULL JOIN (SELECT category_name, sum(sales_line_count * profit_amount) AS profit
                           FROM bv.bridge_sales_line GROUP BY category_name) d
                ON d.category_name = s.category_name) x));

-- Проверка гранулярности строк источника
SELECT audit.mk_check('t05', 'первая строка файла (src_row_num = 1) соответствует началу датасета', '1',
       (SELECT count(*)::text FROM staging.stg_superstore_raw
         WHERE src_row_num = 1 AND ship_mode = 'Second Class' AND city = 'Henderson'
           AND postal_code = '42420'));
