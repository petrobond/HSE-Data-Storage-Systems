-- =====================================================================
-- 02_vault/10_ddl_hubs.sql
-- ХАБЫ (Hubs) — центральные бизнес-сущности модели Data Vault 2.0.
--
-- Состав хаба (методология Data Vault 2.0, вебинар 3):
--   <HUB>_KEY      char(32) PK  — суррогатный хеш-ключ = md5(нормализованный бизнес-ключ);
--   бизнес-ключ(и)              — натуральный ключ источника (устойчивый, уникальный);
--   <HUB>_LOAD_DTS timestamp(0) — дата появления записи с этим бизнес-ключом;
--   <HUB>_REC_SRC  varchar(20)  — источник записи (record source).
--
-- Проектные решения и их обоснование:
--  1) Перед хешированием бизнес-ключи нормализуются: upper(trim(coalesce(x,''))).
--     Это защищает от «дублей» вида 'Consumer' и ' Consumer ', а coalesce — от
--     NULL-семантики склейки (NULL || 'x' = NULL в SQL).
--  2) Хеш-функция md5 -> char(32): выбрана в методологии Data Vault 2.0 (вебинар 3);
--     128 бит с запасом покрывают объёмы поствавтомобильного учёта, ключ имеет
--     фиксированную длину и не требует обмена с sequence-генераторами.
--  3) Хабы — heap-таблицы (WITH (appendonly = false)): они малы, читаются
--     точечно при загрузке, а на heap можно объявить внешние ключи из ссылок
--     (на append-optimized таблицах GP FK невозможен — проверено: "Trigger is
--     not supported on AOCS yet").
--  4) DISTRIBUTED BY (<HUB>_KEY): линки и сателлиты дистрибутируются по тем же
--     ключам, поэтому соединения выполняются локально, без Motion (см. E4).
--  5) Ограничение PK в GP обязано включать столбцы ключа дистрибуции — здесь
--     это один и тот же <HUB>_KEY, поэтому PK (хеш-ключ) корректен.
--     Следствие: UNIQUE по одному бизнес-ключу объявить нельзя (он не содержит
--     ключ дистрибуции), поэтому уникальность бизнес-ключей обеспечивается
--     конструкцией модели (хеш-ключ) и проверяется автотестами (t02).
--  6) Zero-key (ghost) запись '000...0' = «неизвестный член» — стандарт DV 2.0:
--     загружается всегда, чтобы ссылки на несуществующего члена не «ломались».
-- =====================================================================

-- ---------------------------------------------------------------------
-- HUB_COUNTRY — страна
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_country CASCADE;
CREATE TABLE vault.hub_country
(
    hub_country_key char(32)     NOT NULL, -- PK: md5(upper(trim(country_name)))
    country_name    varchar(100) NOT NULL, -- бизнес-ключ
    hub_load_dts    timestamp(0) NOT NULL,
    hub_rec_src     varchar(20)  NOT NULL,
    CONSTRAINT hub_country_pk PRIMARY KEY (hub_country_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_country_key);

COMMENT ON TABLE  vault.hub_country                IS 'Хаб «Страна»; в датасете одна страна (United States) — хаб сохранён для расширяемости модели';
COMMENT ON COLUMN vault.hub_country.hub_country_key IS 'Хеш-ключ = md5(upper(trim(country_name)))';
COMMENT ON COLUMN vault.hub_country.country_name    IS 'Бизнес-ключ: наименование страны';
COMMENT ON COLUMN vault.hub_country.hub_load_dts    IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_country.hub_rec_src     IS 'Источник записи (record source)';


-- ---------------------------------------------------------------------
-- HUB_REGION — регион
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_region CASCADE;
CREATE TABLE vault.hub_region
(
    hub_region_key char(32)     NOT NULL, -- PK: md5(upper(trim(region_name)))
    region_name    varchar(50)  NOT NULL, -- бизнес-ключ
    hub_load_dts   timestamp(0) NOT NULL,
    hub_rec_src    varchar(20)  NOT NULL,
    CONSTRAINT hub_region_pk PRIMARY KEY (hub_region_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_region_key);

COMMENT ON TABLE  vault.hub_region               IS 'Хаб «Регион»; иерархия «регион -> страна» моделируется ссылкой lnk_region_country';
COMMENT ON COLUMN vault.hub_region.hub_region_key IS 'Хеш-ключ = md5(upper(trim(region_name)))';
COMMENT ON COLUMN vault.hub_region.region_name    IS 'Бизнес-ключ: наименование региона (South/West/Central/East)';
COMMENT ON COLUMN vault.hub_region.hub_load_dts   IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_region.hub_rec_src    IS 'Источник записи (record source)';

-- ---------------------------------------------------------------------
-- HUB_STATE — штат
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_state CASCADE;
CREATE TABLE vault.hub_state
(
    hub_state_key char(32)     NOT NULL, -- PK: md5(upper(trim(state_name)))
    state_name    varchar(100) NOT NULL, -- бизнес-ключ
    hub_load_dts  timestamp(0) NOT NULL,
    hub_rec_src   varchar(20)  NOT NULL,
    CONSTRAINT hub_state_pk PRIMARY KEY (hub_state_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_state_key);

COMMENT ON TABLE  vault.hub_state               IS 'Хаб «Штат» (49 штатов); иерархия «штат -> регион» моделируется ссылкой lnk_state_region';
COMMENT ON COLUMN vault.hub_state.hub_state_key IS 'Хеш-ключ = md5(upper(trim(state_name)))';
COMMENT ON COLUMN vault.hub_state.state_name    IS 'Бизнес-ключ: наименование штата (аббревиатуры в источнике нет)';
COMMENT ON COLUMN vault.hub_state.hub_load_dts  IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_state.hub_rec_src   IS 'Источник записи (record source)';

-- ---------------------------------------------------------------------
-- HUB_LOCATION — гео-локация (почтовый индекс + город)
-- Бизнес-ключ составной: POSTAL_CODE + CITY_NAME.
-- Проверено на датасете: (postal, city) даёт 632 уникальные комбинации и
-- однозначно определяет штат, поэтому штат вынесен в отдельный хаб и связан
-- ссылкой lnk_location_state (нормализация вместо дублирования атрибутов).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_location CASCADE;
CREATE TABLE vault.hub_location
(
    hub_location_key char(32)     NOT NULL, -- PK: md5(upper(trim(postal_code)) || '|' || upper(trim(city_name)))
    postal_code      char(5)      NOT NULL, -- бизнес-ключ 1/2
    city_name        varchar(100) NOT NULL, -- бизнес-ключ 2/2
    hub_load_dts     timestamp(0) NOT NULL,
    hub_rec_src      varchar(20)  NOT NULL,
    CONSTRAINT hub_location_pk PRIMARY KEY (hub_location_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_location_key);

COMMENT ON TABLE  vault.hub_location                  IS 'Хаб «Гео-локация» (ZIP + город); 632 уникальные комбинации в датасете';
COMMENT ON COLUMN vault.hub_location.hub_location_key IS 'Хеш-ключ = md5(upper(trim(postal_code)) || ''|'' || upper(trim(city_name)))';
COMMENT ON COLUMN vault.hub_location.postal_code      IS 'Бизнес-ключ 1/2: почтовый индекс, 5 знаков (в исходном CSV терялся ведущий ноль)';
COMMENT ON COLUMN vault.hub_location.city_name        IS 'Бизнес-ключ 2/2: город';
COMMENT ON COLUMN vault.hub_location.hub_load_dts     IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_location.hub_rec_src      IS 'Источник записи (record source)';

-- ---------------------------------------------------------------------
-- HUB_CATEGORY — категория товара
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_category CASCADE;
CREATE TABLE vault.hub_category
(
    hub_category_key char(32)     NOT NULL, -- PK: md5(upper(trim(category_name)))
    category_name    varchar(50)  NOT NULL, -- бизнес-ключ
    hub_load_dts     timestamp(0) NOT NULL,
    hub_rec_src      varchar(20)  NOT NULL,
    CONSTRAINT hub_category_pk PRIMARY KEY (hub_category_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_category_key);

COMMENT ON TABLE  vault.hub_category                   IS 'Хаб «Категория товара» (Furniture / Office Supplies / Technology)';
COMMENT ON COLUMN vault.hub_category.hub_category_key  IS 'Хеш-ключ = md5(upper(trim(category_name)))';
COMMENT ON COLUMN vault.hub_category.category_name     IS 'Бизнес-ключ: наименование категории товара';
COMMENT ON COLUMN vault.hub_category.hub_load_dts      IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_category.hub_rec_src       IS 'Источник записи (record source)';


-- ---------------------------------------------------------------------
-- HUB_SUB_CATEGORY — подкатегория товара
-- В датасете только 17 подкатегорий и они однозначно определяют категорию,
-- поэтому категория вынесена в отдельный хаб, а связь — в ссылку
-- lnk_category_sub_category (иерархия моделируется ссылкой, а не атрибутом).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_sub_category CASCADE;
CREATE TABLE vault.hub_sub_category
(
    hub_sub_category_key char(32)     NOT NULL, -- PK: md5(upper(trim(sub_category_name)))
    sub_category_name    varchar(100) NOT NULL, -- бизнес-ключ
    hub_load_dts         timestamp(0) NOT NULL,
    hub_rec_src          varchar(20)  NOT NULL,
    CONSTRAINT hub_sub_category_pk PRIMARY KEY (hub_sub_category_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_sub_category_key);

COMMENT ON TABLE  vault.hub_sub_category                      IS 'Хаб «Подкатегория товара» (17 значений в датасете)';
COMMENT ON COLUMN vault.hub_sub_category.hub_sub_category_key IS 'Хеш-ключ = md5(upper(trim(sub_category_name)))';
COMMENT ON COLUMN vault.hub_sub_category.sub_category_name    IS 'Бизнес-ключ: наименование подкатегории';
COMMENT ON COLUMN vault.hub_sub_category.hub_load_dts         IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_sub_category.hub_rec_src          IS 'Источник записи (record source)';

-- ---------------------------------------------------------------------
-- HUB_SHIP_MODE — способ доставки
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_ship_mode CASCADE;
CREATE TABLE vault.hub_ship_mode
(
    hub_ship_mode_key char(32)    NOT NULL, -- PK: md5(upper(trim(ship_mode_name)))
    ship_mode_name    varchar(50) NOT NULL, -- бизнес-ключ
    hub_load_dts      timestamp(0) NOT NULL,
    hub_rec_src       varchar(20)  NOT NULL,
    CONSTRAINT hub_ship_mode_pk PRIMARY KEY (hub_ship_mode_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_ship_mode_key);

COMMENT ON TABLE  vault.hub_ship_mode                   IS 'Хаб «Способ доставки» (Same Day / First Class / Second Class / Standard Class)';
COMMENT ON COLUMN vault.hub_ship_mode.hub_ship_mode_key IS 'Хеш-ключ = md5(upper(trim(ship_mode_name)))';
COMMENT ON COLUMN vault.hub_ship_mode.ship_mode_name    IS 'Бизнес-ключ: способ доставки';
COMMENT ON COLUMN vault.hub_ship_mode.hub_load_dts      IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_ship_mode.hub_rec_src       IS 'Источник записи (record source)';

-- ---------------------------------------------------------------------
-- HUB_SEGMENT — сегмент потребителя (по сути «класс покупателя»)
-- В датасете нет идентификаторов клиентов, поэтому единственная доступная
-- сущность клиента — его сегмент. При появлении источника с Customer ID
-- добавляются hub_customer + link hub_customer — hub_segment БЕЗ изменения
-- существующих таблиц (главное свойство методологии).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vault.hub_segment CASCADE;
CREATE TABLE vault.hub_segment
(
    hub_segment_key char(32)    NOT NULL, -- PK: md5(upper(trim(segment_name)))
    segment_name    varchar(50) NOT NULL, -- бизнес-ключ
    hub_load_dts    timestamp(0) NOT NULL,
    hub_rec_src     varchar(20)  NOT NULL,
    CONSTRAINT hub_segment_pk PRIMARY KEY (hub_segment_key)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_segment_key);

COMMENT ON TABLE  vault.hub_segment               IS 'Хаб «Сегмент потребителя» (Consumer / Corporate / Home Office)';
COMMENT ON COLUMN vault.hub_segment.hub_segment_key IS 'Хеш-ключ = md5(upper(trim(segment_name)))';
COMMENT ON COLUMN vault.hub_segment.segment_name    IS 'Бизнес-ключ: наименование сегмента';
COMMENT ON COLUMN vault.hub_segment.hub_load_dts    IS 'Дата первого появления бизнес-ключа в источнике';
COMMENT ON COLUMN vault.hub_segment.hub_rec_src     IS 'Источник записи (record source)';
