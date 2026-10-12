-- =====================================================================
-- 02_vault/30_ddl_satellites.sql
-- САТЕЛЛИТЫ (Satellites) — описательные атрибуты хаба или ссылки + история.
--
-- Состав сателлита (методология Data Vault 2.0, вебинар 3):
--   <parent>_KEY char(32)  — хеш-ключ родителя (хаба или ссылки), часть PK;
--   HASH_DIFF    char(32)  — md5 от набора атрибутов: определяет, изменилась ли запись;
--   атрибуты               — описательные (неключевые) столбцы;
--   <SAT>_LOAD_DTS / <SAT>_REC_SRC — служебные поля Data Vault (дата и источник);
--   VALID_FROM / VALID_TO  — интервал действия версии (type-2);
--   ACTIVE_FLAG / DELETED_FLAG — метки активности и удаления (по вебинару 3).
--
-- Проектные решения:
--  1) Хранилище — append-only column-oriented (AO/CO) со сжатием zstd: сателлиты
--     только дописываются и часто сканируются «широкими» аналитическими
--     запросами, поэтому колоночная ориентация + компрессия дают выигрыш по I/O.
--  2) PK = (parent_key, HASH_DIFF): уникален по построению (родитель + набор
--     атрибутов) и не мешает повторной загрузке (идемпотентность) — в отличие от
--     PK по (parent_key, LOAD_DTS), который создавал бы дубли при перезапуске.
--  3) ВНЕШНИЕ КЛЮЧИ В САТЕЛЛИТАХ НЕ ОБЪЯВЛЯЮТСЯ — осознанное решение: FK в
--     Greenplum реализуется триггером, а триггеры на AO/CO-таблицах не
--     поддерживаются (проверено на GP 7.0.0: "Trigger is not supported on AOCS yet").
--     Целостность сателлитов обеспечивается загрузкой и тестами t03/t04.
--  4) CHECK-ограничения на меры (в GP они реально enforced, проверено) — дешёвая
--     страховка от «мусорных» значений.
--  5) DISTRIBUTED BY (parent_key) — co-location с родителем: join сателлита и
--     хаба/ссылки выполняется на сегменте без перераспределения данных.
--  6) Один источник — один сателлит; атрибуты разделены по частоте изменения
--     (гео-атрибутика — low-change, меры продаж — high-change), как рекомендует
--     методология Data Vault 2.0.
-- =====================================================================

-- ---------------------------------------------------------------------
-- SAT_LOCATION — описательные атрибуты гео-локации (медленно меняющиеся)
-- Атрибуты: штат, регион и страна, которым принадлежит локация. Позволяет
-- аналитике обращаться к «денормализованной» локации без join'ов, при этом
-- история изменения административной принадлежности сохраняется (type-2).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.sat_location CASCADE;
CREATE TABLE vault.sat_location
(
    hub_location_key char(32)     NOT NULL, -- PK 1/2: хеш-ключ родительского хаба
    hash_diff        char(32)     NOT NULL, -- PK 2/2: md5(state|region|country)
    state_name       varchar(100) NOT NULL,
    region_name      varchar(50)  NOT NULL,
    country_name     varchar(100) NOT NULL,
    sat_load_dts     timestamp(0) NOT NULL,
    sat_rec_src      varchar(20)  NOT NULL,
    valid_from       timestamp(0) NOT NULL,
    valid_to         timestamp(0),
    active_flag      boolean      NOT NULL DEFAULT true,
    deleted_flag     boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_location_pk PRIMARY KEY (hub_location_key, hash_diff)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (hub_location_key);

COMMENT ON TABLE  vault.sat_location                  IS 'Сателлит гео-локации: административная принадлежность (штат/регион/страна) с историей изменений';
COMMENT ON COLUMN vault.sat_location.hub_location_key IS 'Хеш-ключ родительского хаба vault.hub_location';
COMMENT ON COLUMN vault.sat_location.hash_diff        IS 'Хеш-дифф md5(upper(trim(state_name))||''|''||upper(trim(region_name))||''|''||upper(trim(country_name)))';
COMMENT ON COLUMN vault.sat_location.state_name       IS 'Штат локации';
COMMENT ON COLUMN vault.sat_location.region_name      IS 'Регион локации';
COMMENT ON COLUMN vault.sat_location.country_name     IS 'Страна локации';
COMMENT ON COLUMN vault.sat_location.sat_load_dts     IS 'Дата загрузки версии';
COMMENT ON COLUMN vault.sat_location.sat_rec_src      IS 'Источник записи';
COMMENT ON COLUMN vault.sat_location.valid_from       IS 'Начало действия версии атрибутов';
COMMENT ON COLUMN vault.sat_location.valid_to         IS 'Окончание действия версии (NULL — версия активна)';
COMMENT ON COLUMN vault.sat_location.active_flag      IS 'Признак активной версии';
COMMENT ON COLUMN vault.sat_location.deleted_flag     IS 'Признак логического удаления (в источнике удалений нет)';

-- ---------------------------------------------------------------------
-- SAT_SUB_CATEGORY — описательные атрибуты подкатегории товара
-- Атрибут: категория, к которой относится подкатегория (держать категорию
-- атрибутом сателлита дешевле, чем собирать иерархию ссылкой при каждом запросе).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.sat_sub_category CASCADE;
CREATE TABLE vault.sat_sub_category
(
    hub_sub_category_key char(32)     NOT NULL, -- PK 1/2: хеш-ключ родительского хаба
    hash_diff            char(32)     NOT NULL, -- PK 2/2: md5(sub_category|category)
    category_name        varchar(50)  NOT NULL,
    sat_load_dts         timestamp(0) NOT NULL,
    sat_rec_src          varchar(20)  NOT NULL,
    valid_from           timestamp(0) NOT NULL,
    valid_to             timestamp(0),
    active_flag          boolean      NOT NULL DEFAULT true,
    deleted_flag         boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_sub_category_pk PRIMARY KEY (hub_sub_category_key, hash_diff)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (hub_sub_category_key);

COMMENT ON TABLE  vault.sat_sub_category                      IS 'Сателлит подкатегории товара: атрибут «категория» с историей изменений';
COMMENT ON COLUMN vault.sat_sub_category.hub_sub_category_key IS 'Хеш-ключ родительского хаба vault.hub_sub_category';
COMMENT ON COLUMN vault.sat_sub_category.hash_diff            IS 'Хеш-дифф md5(upper(trim(sub_category_name))||''|''||upper(trim(category_name)))';
COMMENT ON COLUMN vault.sat_sub_category.category_name        IS 'Категория, к которой относится подкатегория';
COMMENT ON COLUMN vault.sat_sub_category.sat_load_dts         IS 'Дата загрузки версии';
COMMENT ON COLUMN vault.sat_sub_category.sat_rec_src          IS 'Источник записи';
COMMENT ON COLUMN vault.sat_sub_category.valid_from           IS 'Начало действия версии';
COMMENT ON COLUMN vault.sat_sub_category.valid_to             IS 'Окончание действия версии (NULL — активна)';
COMMENT ON COLUMN vault.sat_sub_category.active_flag          IS 'Признак активной версии';
COMMENT ON COLUMN vault.sat_sub_category.deleted_flag         IS 'Признак логического удаления';

-- ---------------------------------------------------------------------
-- SAT_SHIP_MODE — описательные атрибуты способа доставки
-- Атрибут SHIP_SPEED_RANK — производный (1 = самый быстрый). В источнике ранга
-- нет, он вычисляется на слое DDS как «бизнес-правило источника»: это допустимо
-- для raw vault, т.к. правило простое и не меняет состав ключей. Альтернативный,
-- «академичный» вариант — вынести правило в Business Vault (см. bv.dim_ship_mode).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.sat_ship_mode CASCADE;
CREATE TABLE vault.sat_ship_mode
(
    hub_ship_mode_key char(32)     NOT NULL, -- PK 1/2: хеш-ключ родительского хаба
    hash_diff         char(32)     NOT NULL, -- PK 2/2: md5(ship_mode|speed_rank)
    ship_mode_name    varchar(50)  NOT NULL,
    ship_speed_rank   smallint     NOT NULL, -- 1=Same Day, 2=First Class, 3=Second Class, 4=Standard Class
    sat_load_dts      timestamp(0) NOT NULL,
    sat_rec_src       varchar(20)  NOT NULL,
    valid_from        timestamp(0) NOT NULL,
    valid_to          timestamp(0),
    active_flag       boolean      NOT NULL DEFAULT true,
    deleted_flag      boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_ship_mode_pk PRIMARY KEY (hub_ship_mode_key, hash_diff),
    CONSTRAINT sat_ship_mode_rank_chk CHECK (ship_speed_rank BETWEEN 1 AND 4)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (hub_ship_mode_key);

COMMENT ON TABLE  vault.sat_ship_mode                   IS 'Сателлит способа доставки: наименование и производный ранг скорости';
COMMENT ON COLUMN vault.sat_ship_mode.hub_ship_mode_key IS 'Хеш-ключ родительского хаба vault.hub_ship_mode';
COMMENT ON COLUMN vault.sat_ship_mode.hash_diff         IS 'Хеш-дифф md5(upper(trim(ship_mode_name))||''|''||ship_speed_rank::text)';
COMMENT ON COLUMN vault.sat_ship_mode.ship_mode_name    IS 'Наименование способа доставки';
COMMENT ON COLUMN vault.sat_ship_mode.ship_speed_rank   IS 'Производный ранг скорости доставки: 1 — быстрее всего (Same Day)';
COMMENT ON COLUMN vault.sat_ship_mode.sat_load_dts      IS 'Дата загрузки версии';
COMMENT ON COLUMN vault.sat_ship_mode.sat_rec_src       IS 'Источник записи';
COMMENT ON COLUMN vault.sat_ship_mode.valid_from        IS 'Начало действия версии';
COMMENT ON COLUMN vault.sat_ship_mode.valid_to          IS 'Окончание действия версии (NULL — активна)';
COMMENT ON COLUMN vault.sat_ship_mode.active_flag       IS 'Признак активной версии';
COMMENT ON COLUMN vault.sat_ship_mode.deleted_flag      IS 'Признак логического удаления';

-- ---------------------------------------------------------------------
-- SAT_SEGMENT — описательные атрибуты сегмента покупателя
-- Атрибут SEGMENT_TYPE — производный (Corporate -> B2B, Consumer/Home Office -> B2C).
-- Пример того, что сателлит может хранить и производные атрибуты, если они
-- стабильны и не меняют состав ключей модели.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.sat_segment CASCADE;
CREATE TABLE vault.sat_segment
(
    hub_segment_key char(32)     NOT NULL, -- PK 1/2: хеш-ключ родительского хаба
    hash_diff       char(32)     NOT NULL, -- PK 2/2: md5(segment|segment_type)
    segment_name    varchar(50)  NOT NULL,
    segment_type    varchar(10)  NOT NULL, -- B2B / B2C (производный признак)
    sat_load_dts    timestamp(0) NOT NULL,
    sat_rec_src     varchar(20)  NOT NULL,
    valid_from      timestamp(0) NOT NULL,
    valid_to        timestamp(0),
    active_flag     boolean      NOT NULL DEFAULT true,
    deleted_flag    boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_segment_pk PRIMARY KEY (hub_segment_key, hash_diff),
    CONSTRAINT sat_segment_type_chk CHECK (segment_type IN ('B2B', 'B2C'))
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (hub_segment_key);

COMMENT ON TABLE  vault.sat_segment                 IS 'Сателлит сегмента покупателя: наименование и производный тип сегмента (B2B/B2C)';
COMMENT ON COLUMN vault.sat_segment.hub_segment_key IS 'Хеш-ключ родительского хаба vault.hub_segment';
COMMENT ON COLUMN vault.sat_segment.hash_diff       IS 'Хеш-дифф md5(upper(trim(segment_name))||''|''||upper(trim(segment_type)))';
COMMENT ON COLUMN vault.sat_segment.segment_name    IS 'Наименование сегмента покупателя';
COMMENT ON COLUMN vault.sat_segment.segment_type    IS 'Производный тип: Corporate -> B2B, Consumer/Home Office -> B2C';
COMMENT ON COLUMN vault.sat_segment.sat_load_dts    IS 'Дата загрузки версии';
COMMENT ON COLUMN vault.sat_segment.sat_rec_src     IS 'Источник записи';
COMMENT ON COLUMN vault.sat_segment.valid_from      IS 'Начало действия версии';
COMMENT ON COLUMN vault.sat_segment.valid_to        IS 'Окончание действия версии (NULL — активна)';
COMMENT ON COLUMN vault.sat_segment.active_flag     IS 'Признак активной версии';
COMMENT ON COLUMN vault.sat_segment.deleted_flag    IS 'Признак логического удаления';

-- ---------------------------------------------------------------------
-- SAT_SALES_LINE — САМЫЙ ВАЖНЫЙ САТЕЛЛИТ: меры строки продажи
-- Родитель — транзакционная ссылка vault.lnk_sales_line.
--
-- Особенности решения (следствие того, что в датасете нет дат и идентификаторов):
--  * HASH_DIFF считается по мерам: md5(sales|quantity|discount|profit), поэтому
--    пара (LNK_SALES_LINE_KEY, HASH_DIFF) однозначно идентифицирует строку продажи;
--  * SALES_LINE_COUNT — множитель: сколько одинаковых строк источника «схлопнулось»
--    в эту версию. Благодаря ему модель полностью реконсилится с источником:
--    SUM(SALES_LINE_COUNT) = 9994 и SUM(SALES_LINE_COUNT * SALES) = 2 297 200.8603;
--  * таблица партиционирована по дате загрузки (PARTITION BY RANGE (sat_load_dts)):
--    стандарт для «больших» сателлитов; PK при этом обязан включать ключ партиции
--    (требование Greenplum, проверено экспериментально).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.sat_sales_line CASCADE;
CREATE TABLE vault.sat_sales_line
(
    lnk_sales_line_key char(32)      NOT NULL, -- PK 1/3: хеш-ключ родительской ссылки = ключ дистрибуции
    hash_diff          char(32)      NOT NULL, -- PK 2/3: md5 мер строки
    sat_load_dts       timestamp(0)  NOT NULL, -- PK 3/3: дата загрузки (ключ партиционирования)
    sat_rec_src        varchar(20)   NOT NULL,
    sales_amount       numeric(14,4) NOT NULL, -- Sales
    quantity           smallint      NOT NULL, -- Quantity
    discount_rate      numeric(4,2)  NOT NULL, -- Discount (0..1)
    profit_amount      numeric(14,4) NOT NULL, -- Profit
    sales_line_count   integer       NOT NULL, -- сколько одинаковых строк источника схлопнулось
    valid_from         timestamp(0)  NOT NULL,
    valid_to           timestamp(0),
    active_flag        boolean       NOT NULL DEFAULT true,
    deleted_flag       boolean       NOT NULL DEFAULT false,
    CONSTRAINT sat_sales_line_pk PRIMARY KEY (lnk_sales_line_key, hash_diff, sat_load_dts),
    CONSTRAINT sat_sales_line_qty_chk      CHECK (quantity > 0),
    CONSTRAINT sat_sales_line_discount_chk CHECK (discount_rate >= 0 AND discount_rate <= 1),
    CONSTRAINT sat_sales_line_count_chk    CHECK (sales_line_count > 0)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (lnk_sales_line_key)
PARTITION BY RANGE (sat_load_dts)
(
    START (TIMESTAMP '2026-01-01 00:00:00') INCLUSIVE
    END   (TIMESTAMP '2027-01-01 00:00:00') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION p_other
);

COMMENT ON TABLE  vault.sat_sales_line                   IS 'Сателлит мер строки продажи: Sales, Quantity, Discount, Profit с версионированием по хеш-диффу мер и множителем повторяющихся строк';
COMMENT ON COLUMN vault.sat_sales_line.lnk_sales_line_key IS 'Хеш-ключ родительской ссылки vault.lnk_sales_line (ключ дистрибуции)';
COMMENT ON COLUMN vault.sat_sales_line.hash_diff          IS 'Хеш-дифф md5(sales_amount::text||''|''||quantity::text||''|''||discount_rate::text||''|''||profit_amount::text)';
COMMENT ON COLUMN vault.sat_sales_line.sat_load_dts       IS 'Дата загрузки версии (ключ партиционирования)';
COMMENT ON COLUMN vault.sat_sales_line.sat_rec_src        IS 'Источник записи';
COMMENT ON COLUMN vault.sat_sales_line.sales_amount       IS 'Сумма продажи (Sales)';
COMMENT ON COLUMN vault.sat_sales_line.quantity           IS 'Количество единиц товара (Quantity)';
COMMENT ON COLUMN vault.sat_sales_line.discount_rate      IS 'Ставка скидки (Discount), 0..1';
COMMENT ON COLUMN vault.sat_sales_line.profit_amount      IS 'Прибыль (Profit)';
COMMENT ON COLUMN vault.sat_sales_line.sales_line_count   IS 'Число идентичных строк источника, схлопнутых в эту версию (для точной реконсиляции)';
COMMENT ON COLUMN vault.sat_sales_line.valid_from         IS 'Начало действия версии';
COMMENT ON COLUMN vault.sat_sales_line.valid_to           IS 'Окончание действия версии (NULL — активна)';
COMMENT ON COLUMN vault.sat_sales_line.active_flag        IS 'Признак активной версии';
COMMENT ON COLUMN vault.sat_sales_line.deleted_flag       IS 'Признак логического удаления';



