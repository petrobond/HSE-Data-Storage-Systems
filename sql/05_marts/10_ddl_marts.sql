-- =====================================================================
-- 05_marts/10_ddl_marts.sql
-- УРОВЕНЬ ПРЕДСТАВЛЕНИЯ (Data marts / information marts).
-- Витрины строятся исключительно из слоя Data Vault (raw vault + Business Vault),
-- т.е. подтверждают, что спроектированное хранилище пригодно для аналитики.
-- =====================================================================

-- ---------------------------------------------------------------------
-- dm.dm_sales_by_region_category — агрегат продаж «регион x категория».
-- Материализованное представление: пересчитывается после загрузки (50_load_marts).
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS dm.dm_sales_by_region_category CASCADE;
CREATE MATERIALIZED VIEW dm.dm_sales_by_region_category AS
SELECT b.region_name,
       b.category_name,
       count(*)                         AS measure_versions,
       sum(b.sales_line_count)          AS sales_lines,
       sum(b.sales_line_count * b.sales_amount)  AS sales_amount,
       sum(b.sales_line_count * b.profit_amount) AS profit_amount,
       sum(b.sales_line_count * b.quantity)      AS quantity,
       round(sum(b.sales_line_count * b.profit_amount)
             / nullif(sum(b.sales_line_count * b.sales_amount), 0) * 100, 2) AS profit_margin_pct
  FROM bv.bridge_sales_line b
 GROUP BY b.region_name, b.category_name;

COMMENT ON MATERIALIZED VIEW dm.dm_sales_by_region_category IS 'Витрина: продажи и прибыль по регионам и категориям (построена из Data Vault через bridge)';

-- ---------------------------------------------------------------------
-- dm.dm_product_hierarchy — товарная иерархия с метриками прибыльности
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS dm.dm_product_hierarchy CASCADE;
CREATE MATERIALIZED VIEW dm.dm_product_hierarchy AS
SELECT b.category_name,
       b.sub_category_name,
       count(*)                        AS measure_versions,
       sum(b.sales_line_count)         AS sales_lines,
       sum(b.sales_line_count * b.sales_amount)  AS sales_amount,
       sum(b.sales_line_count * b.profit_amount) AS profit_amount,
       round(sum(b.sales_line_count * b.profit_amount)
             / nullif(sum(b.sales_line_count * b.sales_amount), 0) * 100, 2) AS profit_margin_pct
  FROM bv.bridge_sales_line b
 GROUP BY b.category_name, b.sub_category_name;

COMMENT ON MATERIALIZED VIEW dm.dm_product_hierarchy IS 'Витрина: метрики по иерархии товаров «категория -> подкатегория»';

-- ---------------------------------------------------------------------
-- dm.dm_dq_source_profile — профиль качества исходных данных
-- (фиксирует проблемы источника, которые пришлось решать при проектировании)
-- ---------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS dm.dm_dq_source_profile CASCADE;
CREATE MATERIALIZED VIEW dm.dm_dq_source_profile AS
SELECT count(*)                                        AS rows_total,
       count(DISTINCT (postal_code, city_name, sub_category_name, ship_mode_name,
                       segment_name, sales_amount, quantity, discount_rate, profit_amount))
                                                       AS unique_sales_lines,
       count(DISTINCT (postal_code, city_name, sub_category_name, ship_mode_name, segment_name))
                                                       AS unique_hub_combinations,
       count(DISTINCT (postal_code, city_name))        AS unique_locations,
       (SELECT count(*)::numeric FROM staging.stg_superstore_raw
         WHERE length(btrim(postal_code)) = 4) AS zip_with_leading_zero_restored,
       count(*) FILTER (WHERE discount_rate > 0)       AS lines_with_discount,
       count(*) FILTER (WHERE profit_amount < 0)       AS loss_lines,
       sum(sales_amount)                               AS sales_amount,
       sum(profit_amount)                              AS profit_amount,
       sum(quantity)                                   AS quantity
  FROM staging.stg_superstore_clean;

COMMENT ON MATERIALIZED VIEW dm.dm_dq_source_profile IS 'Витрина: профиль качества исходного датасета (дубли, восстановленные ZIP, убыточные строки, суммы)';

-- ---------------------------------------------------------------------
-- dm.dm_sales_star — «звезда»: таблица факта с денормализованными измерениями.
-- Заполняется в 50_load_marts.sql; ключ факта — (ссылка + хеш-дифф мер).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dm.dm_sales_star CASCADE;
CREATE TABLE dm.dm_sales_star
(
    lnk_sales_line_key char(32)      NOT NULL,
    hash_diff          char(32)      NOT NULL,
    postal_code        char(5)       NOT NULL,
    city_name          varchar(100)  NOT NULL,
    state_name         varchar(100)  NOT NULL,
    region_name        varchar(50)   NOT NULL,
    country_name       varchar(100)  NOT NULL,
    category_name      varchar(50)   NOT NULL,
    sub_category_name  varchar(100)  NOT NULL,
    ship_mode_name     varchar(50)   NOT NULL,
    ship_speed_rank    smallint,
    segment_name       varchar(50)   NOT NULL,
    segment_type       varchar(10),
    sales_amount       numeric(14,4) NOT NULL,
    quantity           smallint      NOT NULL,
    discount_rate      numeric(4,2)  NOT NULL,
    profit_amount      numeric(14,4) NOT NULL,
    sales_line_count   integer       NOT NULL,
    CONSTRAINT dm_sales_star_pk PRIMARY KEY (lnk_sales_line_key, hash_diff)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (lnk_sales_line_key);

COMMENT ON TABLE dm.dm_sales_star IS 'Витрина-«звезда»: строка продажи с денормализованными измерениями (гео, товар, доставка, сегмент)';
COMMENT ON COLUMN dm.dm_sales_star.sales_line_count IS 'Множитель одинаковых строк источника — обеспечивает точную сходимость с датасетом';

-- ---------------------------------------------------------------------
-- dm.v_sales_line_current — представление «актуальные версии строк продажи»
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dm.v_sales_line_current AS
SELECT s.lnk_sales_line_key, s.hash_diff, s.postal_code, s.city_name, s.state_name,
       s.region_name, s.category_name, s.sub_category_name, s.ship_mode_name,
       s.segment_name, s.sales_amount, s.quantity, s.discount_rate, s.profit_amount,
       s.sales_line_count
  FROM bv.bridge_sales_line s;

COMMENT ON VIEW dm.v_sales_line_current IS 'Представление: актуальные версии строк продажи (источник — Business Vault bridge)';

