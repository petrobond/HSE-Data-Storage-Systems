-- =====================================================================
-- 04_bv/10_ddl_business_vault.sql
-- BUSINESS VAULT — производный слой Data Vault 2.0 (над raw vault).
-- Здесь живут структуры, которых нет в источнике, но которые нужны аналитике
-- и/или ускоряют доступ:
--   * reference-таблицы (ref_*) — справочники низкой кардинальности;
--   * Effectivity Satellites (efs_*) — активность связей во времени;
--   * Record Tracking Satellite (rts_*) — единая трассировка загрузок хабов;
--   * Point-In-Time (pit_*) — предрасчитанные срезы «хаб + актуальный сателлит»;
--   * Bridge (bridge_*) — «расплющенная» модель для быстрых запросов.
-- Слой отделён от raw vault: правила и агрегаты можно менять без пересборки DDS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- E7. Reference-таблица способов доставки.
-- Особенность Greenplum: таблица распределена ПО БИЗНЕС-КЛЮЧУ, поэтому
-- естественный UNIQUE/PRIMARY KEY по нему разрешён и реально enforced
-- (в хабах так сделать нельзя: там ключ дистрибуции — хеш-ключ).
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.ref_ship_mode CASCADE;
CREATE TABLE bv.ref_ship_mode
(
    ship_mode_name  varchar(50) NOT NULL,
    ship_speed_rank smallint    NOT NULL,
    effective_from  timestamp(0) NOT NULL,
    CONSTRAINT ref_ship_mode_pk PRIMARY KEY (ship_mode_name),
    CONSTRAINT ref_ship_mode_rank_chk CHECK (ship_speed_rank BETWEEN 1 AND 4)
)
WITH (appendonly = false)
DISTRIBUTED BY (ship_mode_name);

COMMENT ON TABLE  bv.ref_ship_mode               IS 'Reference-таблица способов доставки: справочник низкой кардинальности (альтернатива хабу + сателлиту)';
COMMENT ON COLUMN bv.ref_ship_mode.ship_mode_name IS 'Бизнес-ключ и ключ дистрибуции: наименование способа доставки';
COMMENT ON COLUMN bv.ref_ship_mode.ship_speed_rank IS 'Ранг скорости доставки (1 — быстрее всего)';

-- ---------------------------------------------------------------------
-- E7. Reference-таблица сегментов покупателей
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.ref_segment CASCADE;
CREATE TABLE bv.ref_segment
(
    segment_name   varchar(50) NOT NULL,
    segment_type   varchar(10) NOT NULL,
    effective_from timestamp(0) NOT NULL,
    CONSTRAINT ref_segment_pk PRIMARY KEY (segment_name),
    CONSTRAINT ref_segment_type_chk CHECK (segment_type IN ('B2B', 'B2C'))
)
WITH (appendonly = false)
DISTRIBUTED BY (segment_name);

COMMENT ON TABLE  bv.ref_segment              IS 'Reference-таблица сегментов покупателей: справочник низкой кардинальности (альтернатива хабу + сателлиту)';
COMMENT ON COLUMN bv.ref_segment.segment_name IS 'Бизнес-ключ и ключ дистрибуции: наименование сегмента';
COMMENT ON COLUMN bv.ref_segment.segment_type IS 'Тип сегмента: B2B (Corporate) / B2C (Consumer, Home Office)';

-- ---------------------------------------------------------------------
-- E2. Effectivity Satellite для связи «локация -> штат».
-- Хранит интервалы действия связи и метки active_flag/deleted_flag: если
-- источник перестанет сообщать о связи, она будет закрыта (valid_to) без
-- изменения самой ссылки в raw vault.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.efs_location_state CASCADE;
CREATE TABLE bv.efs_location_state
(
    lnk_location_state_key char(32)     NOT NULL, -- родительская ссылка
    load_dts               timestamp(0) NOT NULL, -- PK 2/2: дата загрузки версии
    valid_from             timestamp(0) NOT NULL,
    valid_to               timestamp(0),
    active_flag            boolean      NOT NULL DEFAULT true,
    deleted_flag           boolean      NOT NULL DEFAULT false,
    CONSTRAINT efs_location_state_pk PRIMARY KEY (lnk_location_state_key, load_dts)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (lnk_location_state_key);

COMMENT ON TABLE  bv.efs_location_state                    IS 'Effectivity Satellite связи «локация -> штат»: интервалы активности связи';
COMMENT ON COLUMN bv.efs_location_state.lnk_location_state_key IS 'Хеш-ключ родительской ссылки vault.lnk_location_state';

-- ---------------------------------------------------------------------
-- E2. Effectivity Satellite для связи «штат -> регион»
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.efs_state_region CASCADE;
CREATE TABLE bv.efs_state_region
(
    lnk_state_region_key char(32)     NOT NULL,
    load_dts             timestamp(0) NOT NULL,
    valid_from           timestamp(0) NOT NULL,
    valid_to             timestamp(0),
    active_flag          boolean      NOT NULL DEFAULT true,
    deleted_flag         boolean      NOT NULL DEFAULT false,
    CONSTRAINT efs_state_region_pk PRIMARY KEY (lnk_state_region_key, load_dts)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (lnk_state_region_key);

COMMENT ON TABLE  bv.efs_state_region                      IS 'Effectivity Satellite связи «штат -> регион»: интервалы активности связи';
COMMENT ON COLUMN bv.efs_state_region.lnk_state_region_key IS 'Хеш-ключ родительской ссылки vault.lnk_state_region';

-- ---------------------------------------------------------------------
-- E2. Record Tracking Satellite (RTS): единая «лента» появления записей
-- во всех хабах. Позволяет ответить на вопрос «что и когда пришло» без
-- сканирования служебных полей каждого хаба.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.rts_hub_record CASCADE;
CREATE TABLE bv.rts_hub_record
(
    hub_name varchar(30)  NOT NULL, -- какой хаб (hub_country, hub_state, ...)
    hub_key  char(32)     NOT NULL, -- хеш-ключ записи хаба
    load_dts timestamp(0) NOT NULL, -- когда запись загружена
    rec_src  varchar(20)  NOT NULL,
    CONSTRAINT rts_hub_record_pk PRIMARY KEY (hub_name, hub_key, load_dts)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 1)
DISTRIBUTED BY (hub_key);

COMMENT ON TABLE  bv.rts_hub_record          IS 'Record Tracking Satellite: единая лента загрузок по всем хабам (имя хаба, хеш-ключ, дата, источник)';
COMMENT ON COLUMN bv.rts_hub_record.hub_name IS 'Имя хаба-источника (hub_country, hub_region, ...)';
COMMENT ON COLUMN bv.rts_hub_record.hub_key  IS 'Хеш-ключ записи хаба';

-- ---------------------------------------------------------------------
-- E1. Point-In-Time (PIT) по гео-локациям.
-- Для каждого снимка (snapshot_dts) и локации хранит ссылку на актуальную
-- версию сателлита и на текущие связи иерархии. Избавляет аналитику от
-- дорогих временных join'ов «сателлит + линки» при каждом запросе.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.pit_location CASCADE;
CREATE TABLE bv.pit_location
(
    snapshot_dts           timestamp(0) NOT NULL, -- дата снимка (ключ партиции в будущем при необходимости)
    hub_location_key       char(32)     NOT NULL, -- ключ дистрибуции и часть PK
    sat_location_hash_diff char(32)     NOT NULL, -- версия атрибутивного сателлита
    hub_state_key          char(32)     NOT NULL,
    hub_region_key         char(32)     NOT NULL,
    hub_country_key        char(32)     NOT NULL,
    CONSTRAINT pit_location_pk PRIMARY KEY (snapshot_dts, hub_location_key, sat_location_hash_diff)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_location_key);

COMMENT ON TABLE  bv.pit_location                        IS 'Point-In-Time по гео-локациям: снимок «хаб + актуальный сателлит + текущие связи иерархии»';
COMMENT ON COLUMN bv.pit_location.snapshot_dts           IS 'Дата снимка (момент загрузки, на который зафиксировано состояние)';
COMMENT ON COLUMN bv.pit_location.sat_location_hash_diff IS 'Ссылка на версию vault.sat_location, актуальную на снимок';

-- ---------------------------------------------------------------------
-- E1. Bridge (мост) продаж: «расплющенная» модель «ссылка + все атрибуты
-- сателлитов + меры». Один раз материализует соединения Data Vault, после чего
-- витрины и BI считают данные без повторных join'ов и Motion.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bv.bridge_sales_line CASCADE;
CREATE TABLE bv.bridge_sales_line
(
    lnk_sales_line_key char(32)      NOT NULL, -- PK 1/2, ключ дистрибуции
    hash_diff          char(32)      NOT NULL, -- PK 2/2: версия мер
    postal_code        char(5)       NOT NULL,
    city_name          varchar(100)  NOT NULL,
    state_name         varchar(100)  NOT NULL,
    region_name        varchar(50)   NOT NULL,
    country_name       varchar(100)  NOT NULL,
    sub_category_name  varchar(100)  NOT NULL,
    category_name      varchar(50)   NOT NULL,
    ship_mode_name     varchar(50)   NOT NULL,
    ship_speed_rank    smallint,
    segment_name       varchar(50)   NOT NULL,
    segment_type       varchar(10),
    sales_amount       numeric(14,4) NOT NULL,
    quantity           smallint      NOT NULL,
    discount_rate      numeric(4,2)  NOT NULL,
    profit_amount      numeric(14,4) NOT NULL,
    sales_line_count   integer       NOT NULL,
    CONSTRAINT bridge_sales_line_pk PRIMARY KEY (lnk_sales_line_key, hash_diff)
)
WITH (appendonly = true, orientation = column, compresstype = zstd, compresslevel = 3)
DISTRIBUTED BY (lnk_sales_line_key);

COMMENT ON TABLE  bv.bridge_sales_line                  IS 'Bridge: «расплющенная» строка продажи (все атрибуты измерений и меры) для быстрых аналитических запросов';
COMMENT ON COLUMN bv.bridge_sales_line.sales_line_count IS 'Множитель одинаковых строк источника (точная сходимость с датасетом)';

