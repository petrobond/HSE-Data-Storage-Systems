-- =====================================================================
-- 01_staging/10_ddl_staging.sql
-- STAGING-СЛОЙ (ODS). Две таблицы:
--   1) stg_superstore_raw   — данные «как есть» из CSV (все поля TEXT),
--                             append-only, column-oriented, сжатие zstd,
--                             партиционирование по дате загрузки;
--   2) stg_superstore_clean — типизированный и очищенный слой с уже посчитанными
--                             хеш-ключами хабов и ссылок (в Data Vault 2.0
--                             хеши вычисляются именно на этапе staging).
--
-- Почему staging не входит в модель Data Vault: слой предназначен для загрузки
-- «как есть» и перезагрузки, он не хранит историю изменений (историю хранит vault).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Сырой слой
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_superstore_raw CASCADE;
CREATE TABLE staging.stg_superstore_raw
(
    src_row_num   integer       NOT NULL, -- номер строки в исходном CSV (для lineage и разбора карантина)
    ship_mode     text,                   -- все прикладные поля — TEXT: в staging не приводим типы,
    segment       text,                   -- чтобы любая «грязная» строка физически загрузилась
    country       text,                   -- и могла быть проверена/отклонена на следующем шаге
    city          text,
    state         text,
    postal_code   text,
    region        text,
    category      text,
    sub_category  text,
    sales         text,
    quantity      text,
    discount      text,
    profit        text,
    file_name     varchar(255)  NOT NULL, -- имя исходного файла (прослеживаемость)
    file_hash     char(64)      NOT NULL, -- sha256 файла: фиксирует версию датасета
    load_dts      timestamp(0)  NOT NULL, -- время загрузки файла
    rec_src       varchar(20)   NOT NULL  -- код системы-источника (record source)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED RANDOMLY
PARTITION BY RANGE (load_dts)
(
    START (TIMESTAMP '2026-01-01 00:00:00') INCLUSIVE
    END   (TIMESTAMP '2027-01-01 00:00:00') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION p_other
);

COMMENT ON TABLE staging.stg_superstore_raw IS
  'Staging: сырые данные датасета superstore 1:1 с CSV (все поля TEXT), append-only, партиционирование по load_dts';
COMMENT ON COLUMN staging.stg_superstore_raw.src_row_num IS 'Номер строки в исходном файле (lineage)';
COMMENT ON COLUMN staging.stg_superstore_raw.file_hash IS 'sha256 исходного файла — версия загруженного датасета';
COMMENT ON COLUMN staging.stg_superstore_raw.rec_src IS 'Источник записи (record source) для трассировки происхождения данных';

-- ---------------------------------------------------------------------
-- 2. Очищенный слой (типы + хеш-ключи)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_superstore_clean CASCADE;
CREATE TABLE staging.stg_superstore_clean
(
    src_row_num        integer       NOT NULL,
    file_hash          char(64)      NOT NULL,
    -- ---- бизнес-ключи (нормализованные) ----
    ship_mode_name     varchar(50)   NOT NULL,
    segment_name       varchar(50)   NOT NULL,
    country_name       varchar(100)  NOT NULL,
    state_name         varchar(100)  NOT NULL,
    city_name          varchar(100)  NOT NULL,
    postal_code        char(5)       NOT NULL,
    region_name        varchar(50)   NOT NULL,
    category_name      varchar(50)   NOT NULL,
    sub_category_name  varchar(100)  NOT NULL,
    -- ---- меры ----
    sales_amount       numeric(14,4) NOT NULL,
    quantity           smallint      NOT NULL,
    discount_rate      numeric(4,2)  NOT NULL,
    profit_amount      numeric(14,4) NOT NULL,
    -- ---- хеш-ключи хабов ----
    hub_country_key       char(32)   NOT NULL,
    hub_region_key        char(32)   NOT NULL,
    hub_state_key         char(32)   NOT NULL,
    hub_location_key      char(32)   NOT NULL,
    hub_category_key      char(32)   NOT NULL,
    hub_sub_category_key  char(32)   NOT NULL,
    hub_ship_mode_key     char(32)   NOT NULL,
    hub_segment_key       char(32)   NOT NULL,
    -- ---- хеш-ключи ссылок ----
    lnk_location_state_key       char(32) NOT NULL,
    lnk_state_region_key         char(32) NOT NULL,
    lnk_region_country_key       char(32) NOT NULL,
    lnk_category_sub_category_key char(32) NOT NULL,
    lnk_sales_line_key           char(32) NOT NULL,
    -- ---- хеш-диффа для сателлита мер ----
    hash_diff          char(32)      NOT NULL,
    load_dts           timestamp(0)  NOT NULL,
    rec_src            varchar(20)   NOT NULL
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED RANDOMLY;

COMMENT ON TABLE staging.stg_superstore_clean IS
  'Staging: типизированный и очищенный слой (lpad ZIP до 5 знаков, trim/upper, приведение мер) + все хеш-ключи DV';
COMMENT ON COLUMN staging.stg_superstore_clean.postal_code IS 'ZIP, восстановленный до 5 знаков (в исходном CSV ведущий ноль был потерян)';
COMMENT ON COLUMN staging.stg_superstore_clean.hash_diff IS 'md5 от мер строки: (sales|quantity|discount|profit) — определяет версию в sat_sales_line';
