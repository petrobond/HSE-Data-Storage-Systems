-- =====================================================================
-- 02_vault_gp6_heap/30_ddl_satellites_gp6.sql
-- ВАРИАНТ САТЕЛЛИТОВ ДЛЯ GREENPLUM 6 (ветка совместимости).
--
-- Зачем: в Greenplum 6 запрещено объявлять PRIMARY KEY/UNIQUE на
-- append-optimized таблицах («UNIQUE and PRIMARY KEY constraints are not
-- allowed on append-optimized tables»), а именно так сателлиты создаются в
-- основном варианте (sql/02_vault/30_ddl_satellites.sql, GP7).
-- В GP7 это ограничение снято — проверено на живом сервере.
--
-- Чем отличается этот скрипт:
--   * сателлиты создаются как heap-таблицы (appendonly = false) без сжатия;
--   * состав колонок, ключей, CHECK-ограничений и DISTRIBUTED BY — идентичен;
--   * у сателлита sat_sales_line сохраняется партиционирование по дате загрузки.
-- Применение: psql -f sql/02_vault_gp6_heap/30_ddl_satellites_gp6.sql
-- (используется вместо sql/02_vault/30_ddl_satellites.sql на кластере GP 6).
-- =====================================================================

DROP TABLE IF EXISTS vault.sat_location CASCADE;
CREATE TABLE vault.sat_location
(
    hub_location_key char(32)     NOT NULL,
    hash_diff        char(32)     NOT NULL,
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
WITH (appendonly = false)
DISTRIBUTED BY (hub_location_key);

COMMENT ON TABLE vault.sat_location IS 'Сателлит гео-локации (вариант для GP6: heap вместо AO/column)';

DROP TABLE IF EXISTS vault.sat_sub_category CASCADE;
CREATE TABLE vault.sat_sub_category
(
    hub_sub_category_key char(32)     NOT NULL,
    hash_diff            char(32)     NOT NULL,
    category_name        varchar(50)  NOT NULL,
    sat_load_dts         timestamp(0) NOT NULL,
    sat_rec_src          varchar(20)  NOT NULL,
    valid_from           timestamp(0) NOT NULL,
    valid_to             timestamp(0),
    active_flag          boolean      NOT NULL DEFAULT true,
    deleted_flag         boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_sub_category_pk PRIMARY KEY (hub_sub_category_key, hash_diff)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_sub_category_key);

COMMENT ON TABLE vault.sat_sub_category IS 'Сателлит подкатегории (вариант для GP6: heap вместо AO/column)';

DROP TABLE IF EXISTS vault.sat_ship_mode CASCADE;
CREATE TABLE vault.sat_ship_mode
(
    hub_ship_mode_key char(32)     NOT NULL,
    hash_diff         char(32)     NOT NULL,
    ship_mode_name    varchar(50)  NOT NULL,
    ship_speed_rank   smallint     NOT NULL,
    sat_load_dts      timestamp(0) NOT NULL,
    sat_rec_src       varchar(20)  NOT NULL,
    valid_from        timestamp(0) NOT NULL,
    valid_to          timestamp(0),
    active_flag       boolean      NOT NULL DEFAULT true,
    deleted_flag      boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_ship_mode_pk PRIMARY KEY (hub_ship_mode_key, hash_diff),
    CONSTRAINT sat_ship_mode_rank_chk CHECK (ship_speed_rank BETWEEN 1 AND 4)
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_ship_mode_key);

COMMENT ON TABLE vault.sat_ship_mode IS 'Сателлит способа доставки (вариант для GP6: heap вместо AO/column)';

DROP TABLE IF EXISTS vault.sat_segment CASCADE;
CREATE TABLE vault.sat_segment
(
    hub_segment_key char(32)     NOT NULL,
    hash_diff       char(32)     NOT NULL,
    segment_name    varchar(50)  NOT NULL,
    segment_type    varchar(10)  NOT NULL,
    sat_load_dts    timestamp(0) NOT NULL,
    sat_rec_src     varchar(20)  NOT NULL,
    valid_from      timestamp(0) NOT NULL,
    valid_to        timestamp(0),
    active_flag     boolean      NOT NULL DEFAULT true,
    deleted_flag    boolean      NOT NULL DEFAULT false,
    CONSTRAINT sat_segment_pk PRIMARY KEY (hub_segment_key, hash_diff),
    CONSTRAINT sat_segment_type_chk CHECK (segment_type IN ('B2B', 'B2C'))
)
WITH (appendonly = false)
DISTRIBUTED BY (hub_segment_key);

COMMENT ON TABLE vault.sat_segment IS 'Сателлит сегмента покупателя (вариант для GP6: heap вместо AO/column)';

DROP TABLE IF EXISTS vault.sat_sales_line CASCADE;
CREATE TABLE vault.sat_sales_line
(
    lnk_sales_line_key char(32)      NOT NULL,
    hash_diff          char(32)      NOT NULL,
    sat_load_dts       timestamp(0)  NOT NULL,
    sat_rec_src        varchar(20)   NOT NULL,
    sales_amount       numeric(14,4) NOT NULL,
    quantity           smallint      NOT NULL,
    discount_rate      numeric(4,2)  NOT NULL,
    profit_amount      numeric(14,4) NOT NULL,
    sales_line_count   integer       NOT NULL,
    valid_from         timestamp(0)  NOT NULL,
    valid_to           timestamp(0),
    active_flag        boolean       NOT NULL DEFAULT true,
    deleted_flag       boolean       NOT NULL DEFAULT false,
    CONSTRAINT sat_sales_line_pk PRIMARY KEY (lnk_sales_line_key, hash_diff, sat_load_dts),
    CONSTRAINT sat_sales_line_qty_chk      CHECK (quantity > 0),
    CONSTRAINT sat_sales_line_discount_chk CHECK (discount_rate >= 0 AND discount_rate <= 1),
    CONSTRAINT sat_sales_line_count_chk    CHECK (sales_line_count > 0)
)
WITH (appendonly = false)
DISTRIBUTED BY (lnk_sales_line_key)
PARTITION BY RANGE (sat_load_dts)
(
    START (TIMESTAMP '2026-01-01 00:00:00') INCLUSIVE
    END   (TIMESTAMP '2027-01-01 00:00:00') EXCLUSIVE
    EVERY (INTERVAL '1 month'),
    DEFAULT PARTITION p_other
);

COMMENT ON TABLE vault.sat_sales_line IS 'Сателлит мер строки продажи (вариант для GP6: heap вместо AO/column)';
