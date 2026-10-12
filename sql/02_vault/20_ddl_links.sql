-- =====================================================================
-- 02_vault/20_ddl_links.sql
-- ССЫЛКИ (Links) — связи между хабами: транзакции, ассоциации, иерархии.
--
-- Состав ссылки (по методологии и вебинару 3):
--   <LNK>_KEY  char(32) PK — хеш от бизнес-ключей связанных хабов;
--   <HUB>_KEY  char(32) FK — хеш-ключи связанных хабов (по одному столбцу на хаб);
--   бизнес-ключи хабов      — дублируются внутри ссылки (как в примере вебинара
--                             LNK_REGION_COUNTRY: COUNTRY_ABBRV + REGION_NAME),
--                             это позволяет профилировать данные без join'ов;
--   <LNK>_LOAD_DTS, <LNK>_REC_SRC — служебные поля Data Vault.
--
-- Проектные решения:
--  1) Хеш-ключ ссылки считается от бизнес-ключей хабов (а не от их хеш-ключей) —
--     так же, как в примере вебинара: md5(upper(trim(bk1)) || '|' || upper(trim(bk2))).
--     Порядок хабов в формуле фиксирован и задокументирован.
--  2) Ссылки — heap-таблицы: на heap работают объявленные внешние ключи
--     (на append-optimized таблицах GP констрейнт FK невозможен, проверено
--     экспериментально: "Trigger is not supported on AOCS yet").
--  3) ВАЖНО: Greenplum объявляет FK, но НЕ проверяет их при вставке
--     ("referential integrity (FOREIGN KEY) constraints are not supported
--     in Greenplum Database, will not be enforced"). Поэтому целостность
--     данных обеспечивается процессом загрузки + автотестами (t03).
--  4) DISTRIBUTED BY (<LNK>_KEY): каждая строка ссылки лежит на том же сегменте,
--     что и соответствующий центр (хаб), что устраняет Motion при join'ах.
-- =====================================================================

-- ---------------------------------------------------------------------
-- LNK_LOCATION_STATE — иерархия «гео-локация -> штат» (632 строки)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.lnk_location_state CASCADE;
CREATE TABLE vault.lnk_location_state
(
    lnk_location_state_key char(32)     NOT NULL, -- PK: md5(postal|city|state)
    hub_location_key       char(32)     NOT NULL, -- FK -> hub_location
    hub_state_key          char(32)     NOT NULL, -- FK -> hub_state
    postal_code            char(5)      NOT NULL, -- бизнес-ключ хаб-локации 1/2
    city_name              varchar(100) NOT NULL, -- бизнес-ключ хаб-локации 2/2
    state_name             varchar(100) NOT NULL, -- бизнес-ключ хаб-штата
    lnk_load_dts           timestamp(0) NOT NULL,
    lnk_rec_src            varchar(20)  NOT NULL,
    CONSTRAINT lnk_location_state_pk PRIMARY KEY (lnk_location_state_key),
    CONSTRAINT lnk_location_state_fk_location FOREIGN KEY (hub_location_key) REFERENCES vault.hub_location (hub_location_key),
    CONSTRAINT lnk_location_state_fk_state    FOREIGN KEY (hub_state_key)    REFERENCES vault.hub_state    (hub_state_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (lnk_location_state_key);

COMMENT ON TABLE  vault.lnk_location_state      IS 'Ссылка «гео-локация -> штат»: в какой штат входит каждая локация (ZIP+город)';
COMMENT ON COLUMN vault.lnk_location_state.lnk_location_state_key IS 'Хеш-ключ ссылки = md5(upper(trim(postal_code)) || ''|'' || upper(trim(city_name)) || ''|'' || upper(trim(state_name)))';
COMMENT ON COLUMN vault.lnk_location_state.hub_location_key IS 'FK на хаб гео-локаций';
COMMENT ON COLUMN vault.lnk_location_state.hub_state_key    IS 'FK на хаб штатов';
COMMENT ON COLUMN vault.lnk_location_state.state_name       IS 'Бизнес-ключ штата (денормализован в ссылку для профилирования без join)';
COMMENT ON COLUMN vault.lnk_location_state.lnk_load_dts     IS 'Дата загрузки связи';
COMMENT ON COLUMN vault.lnk_location_state.lnk_rec_src      IS 'Источник записи';

-- ---------------------------------------------------------------------
-- LNK_STATE_REGION — иерархия «штат -> регион» (49 строк)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.lnk_state_region CASCADE;
CREATE TABLE vault.lnk_state_region
(
    lnk_state_region_key char(32)     NOT NULL, -- PK: md5(state|region)
    hub_state_key        char(32)     NOT NULL, -- FK -> hub_state
    hub_region_key       char(32)     NOT NULL, -- FK -> hub_region
    state_name           varchar(100) NOT NULL,
    region_name          varchar(50)  NOT NULL,
    lnk_load_dts         timestamp(0) NOT NULL,
    lnk_rec_src          varchar(20)  NOT NULL,
    CONSTRAINT lnk_state_region_pk PRIMARY KEY (lnk_state_region_key),
    CONSTRAINT lnk_state_region_fk_state  FOREIGN KEY (hub_state_key)  REFERENCES vault.hub_state  (hub_state_key),
    CONSTRAINT lnk_state_region_fk_region FOREIGN KEY (hub_region_key) REFERENCES vault.hub_region (hub_region_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (lnk_state_region_key);

COMMENT ON TABLE  vault.lnk_state_region      IS 'Ссылка «штат -> регион» (в источнике связь 1:1, но моделируется иерархической ссылкой)';
COMMENT ON COLUMN vault.lnk_state_region.lnk_state_region_key IS 'Хеш-ключ ссылки = md5(upper(trim(state_name)) || ''|'' || upper(trim(region_name)))';
COMMENT ON COLUMN vault.lnk_state_region.hub_state_key  IS 'FK на хаб штатов';
COMMENT ON COLUMN vault.lnk_state_region.hub_region_key IS 'FK на хаб регионов';
COMMENT ON COLUMN vault.lnk_state_region.lnk_load_dts   IS 'Дата загрузки связи';
COMMENT ON COLUMN vault.lnk_state_region.lnk_rec_src    IS 'Источник записи';

-- ---------------------------------------------------------------------
-- LNK_REGION_COUNTRY — иерархия «регион -> страна» (4 строки)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.lnk_region_country CASCADE;
CREATE TABLE vault.lnk_region_country
(
    lnk_region_country_key char(32)     NOT NULL, -- PK: md5(region|country)
    hub_region_key         char(32)     NOT NULL, -- FK -> hub_region
    hub_country_key        char(32)     NOT NULL, -- FK -> hub_country
    region_name            varchar(50)  NOT NULL,
    country_name           varchar(100) NOT NULL,
    lnk_load_dts           timestamp(0) NOT NULL,
    lnk_rec_src            varchar(20)  NOT NULL,
    CONSTRAINT lnk_region_country_pk PRIMARY KEY (lnk_region_country_key),
    CONSTRAINT lnk_region_country_fk_region  FOREIGN KEY (hub_region_key)  REFERENCES vault.hub_region  (hub_region_key),
    CONSTRAINT lnk_region_country_fk_country FOREIGN KEY (hub_country_key) REFERENCES vault.hub_country (hub_country_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (lnk_region_country_key);

COMMENT ON TABLE  vault.lnk_region_country      IS 'Ссылка «регион -> страна» (4 региона США)';
COMMENT ON COLUMN vault.lnk_region_country.lnk_region_country_key IS 'Хеш-ключ ссылки = md5(upper(trim(region_name)) || ''|'' || upper(trim(country_name)))';
COMMENT ON COLUMN vault.lnk_region_country.hub_region_key  IS 'FK на хаб регионов';
COMMENT ON COLUMN vault.lnk_region_country.hub_country_key IS 'FK на хаб стран';
COMMENT ON COLUMN vault.lnk_region_country.lnk_load_dts    IS 'Дата загрузки связи';
COMMENT ON COLUMN vault.lnk_region_country.lnk_rec_src     IS 'Источник записи';

-- ---------------------------------------------------------------------
-- LNK_CATEGORY_SUB_CATEGORY — иерархия «категория -> подкатегория» (17 строк)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.lnk_category_sub_category CASCADE;
CREATE TABLE vault.lnk_category_sub_category
(
    lnk_category_sub_category_key char(32)     NOT NULL, -- PK: md5(category|sub_category)
    hub_category_key              char(32)     NOT NULL, -- FK -> hub_category
    hub_sub_category_key          char(32)     NOT NULL, -- FK -> hub_sub_category
    category_name                 varchar(50)  NOT NULL,
    sub_category_name             varchar(100) NOT NULL,
    lnk_load_dts                  timestamp(0) NOT NULL,
    lnk_rec_src                   varchar(20)  NOT NULL,
    CONSTRAINT lnk_category_sub_category_pk PRIMARY KEY (lnk_category_sub_category_key),
    CONSTRAINT lnk_category_sub_category_fk_category     FOREIGN KEY (hub_category_key)     REFERENCES vault.hub_category     (hub_category_key),
    CONSTRAINT lnk_category_sub_category_fk_sub_category FOREIGN KEY (hub_sub_category_key) REFERENCES vault.hub_sub_category (hub_sub_category_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (lnk_category_sub_category_key);

COMMENT ON TABLE  vault.lnk_category_sub_category      IS 'Ссылка-иерархия товаров «категория -> подкатегория» (17 подкатегорий)';
COMMENT ON COLUMN vault.lnk_category_sub_category.lnk_category_sub_category_key IS 'Хеш-ключ ссылки = md5(upper(trim(category_name)) || ''|'' || upper(trim(sub_category_name)))';
COMMENT ON COLUMN vault.lnk_category_sub_category.hub_category_key     IS 'FK на хаб категорий';
COMMENT ON COLUMN vault.lnk_category_sub_category.hub_sub_category_key IS 'FK на хаб подкатегорий';
COMMENT ON COLUMN vault.lnk_category_sub_category.lnk_load_dts         IS 'Дата загрузки связи';
COMMENT ON COLUMN vault.lnk_category_sub_category.lnk_rec_src          IS 'Источник записи';

-- ---------------------------------------------------------------------
-- LNK_SALES_LINE — транзакционная ссылка «строка продажи» (6868 строк)
-- Самый важный объект модели: в датасете нет ни Order ID, ни Customer ID,
-- ни Order Date, поэтому гранулярность «строка продажи» описывается как
-- комбинация четырёх хабов (гео-локация + подкатегория + способ доставки +
-- сегмент покупателя), а меры (Sales/Quantity/Discount/Profit) хранятся
-- в сателлите ссылки vault.sat_sales_line с хеш-диффом по мерам.
-- Итог: 9994 строки источника -> 6868 уникальных комбинаций (ссылка) и
-- 9977 версий мер (сателлит) + множитель SALES_LINE_COUNT (17 полных дублей).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.lnk_sales_line CASCADE;
CREATE TABLE vault.lnk_sales_line
(
    lnk_sales_line_key   char(32)     NOT NULL, -- PK: md5(postal|city|sub_category|ship_mode|segment)
    hub_location_key     char(32)     NOT NULL, -- FK -> hub_location
    hub_sub_category_key char(32)     NOT NULL, -- FK -> hub_sub_category
    hub_ship_mode_key    char(32)     NOT NULL, -- FK -> hub_ship_mode
    hub_segment_key      char(32)     NOT NULL, -- FK -> hub_segment
    postal_code          char(5)      NOT NULL,
    city_name            varchar(100) NOT NULL,
    sub_category_name    varchar(100) NOT NULL,
    ship_mode_name       varchar(50)  NOT NULL,
    segment_name         varchar(50)  NOT NULL,
    lnk_load_dts         timestamp(0) NOT NULL,
    lnk_rec_src          varchar(20)  NOT NULL,
    CONSTRAINT lnk_sales_line_pk PRIMARY KEY (lnk_sales_line_key),
    CONSTRAINT lnk_sales_line_fk_location     FOREIGN KEY (hub_location_key)     REFERENCES vault.hub_location     (hub_location_key),
    CONSTRAINT lnk_sales_line_fk_sub_category FOREIGN KEY (hub_sub_category_key) REFERENCES vault.hub_sub_category (hub_sub_category_key),
    CONSTRAINT lnk_sales_line_fk_ship_mode    FOREIGN KEY (hub_ship_mode_key)    REFERENCES vault.hub_ship_mode    (hub_ship_mode_key),
    CONSTRAINT lnk_sales_line_fk_segment      FOREIGN KEY (hub_segment_key)      REFERENCES vault.hub_segment      (hub_segment_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (lnk_sales_line_key);

COMMENT ON TABLE  vault.lnk_sales_line      IS 'Транзакционная ссылка «строка продажи»: комбинация локации, подкатегории, способа доставки и сегмента покупателя (6868 комбинаций)';
COMMENT ON COLUMN vault.lnk_sales_line.lnk_sales_line_key IS 'Хеш-ключ ссылки = md5(upper(trim(postal_code)) || ''|'' || upper(trim(city_name)) || ''|'' || upper(trim(sub_category_name)) || ''|'' || upper(trim(ship_mode_name)) || ''|'' || upper(trim(segment_name)))';
COMMENT ON COLUMN vault.lnk_sales_line.hub_location_key     IS 'FK на хаб гео-локаций';
COMMENT ON COLUMN vault.lnk_sales_line.hub_sub_category_key IS 'FK на хаб подкатегорий товаров';
COMMENT ON COLUMN vault.lnk_sales_line.hub_ship_mode_key    IS 'FK на хаб способов доставки';
COMMENT ON COLUMN vault.lnk_sales_line.hub_segment_key      IS 'FK на хаб сегментов покупателей';
COMMENT ON COLUMN vault.lnk_sales_line.postal_code          IS 'Бизнес-ключ локации (денормализован для профилирования без join)';
COMMENT ON COLUMN vault.lnk_sales_line.city_name            IS 'Бизнес-ключ локации (денормализован)';
COMMENT ON COLUMN vault.lnk_sales_line.sub_category_name     IS 'Бизнес-ключ подкатегории (денормализован)';
COMMENT ON COLUMN vault.lnk_sales_line.ship_mode_name        IS 'Бизнес-ключ способа доставки (денормализован)';
COMMENT ON COLUMN vault.lnk_sales_line.segment_name          IS 'Бизнес-ключ сегмента покупателя (денормализован)';
COMMENT ON COLUMN vault.lnk_sales_line.lnk_load_dts         IS 'Дата загрузки строки продажи';
COMMENT ON COLUMN vault.lnk_sales_line.lnk_rec_src          IS 'Источник записи';

-- ---------------------------------------------------------------------
-- Уточняющие комментарии к денормализованным бизнес-ключам ссылок
-- (бизнес-ключи хранятся внутри ссылки для профилирования данных без join'ов —
-- приём из вебинара 3 на примере LNK_REGION_COUNTRY).
-- ---------------------------------------------------------------------
COMMENT ON COLUMN vault.lnk_location_state.postal_code  IS 'Бизнес-ключ локации: ZIP (денормализован)';
COMMENT ON COLUMN vault.lnk_location_state.city_name    IS 'Бизнес-ключ локации: город (денормализован)';
COMMENT ON COLUMN vault.lnk_state_region.state_name     IS 'Бизнес-ключ штата (денормализован)';
COMMENT ON COLUMN vault.lnk_state_region.region_name    IS 'Бизнес-ключ региона (денормализован)';
COMMENT ON COLUMN vault.lnk_region_country.region_name  IS 'Бизнес-ключ региона (денормализован)';
COMMENT ON COLUMN vault.lnk_region_country.country_name IS 'Бизнес-ключ страны (денормализован)';
COMMENT ON COLUMN vault.lnk_category_sub_category.category_name     IS 'Бизнес-ключ категории (денормализован)';
COMMENT ON COLUMN vault.lnk_category_sub_category.sub_category_name IS 'Бизнес-ключ подкатегории (денормализован)';



