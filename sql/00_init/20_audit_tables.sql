-- =====================================================================
-- 00_init/20_audit_tables.sql
-- Служебные таблицы схемы audit: журнал загрузок, карантин «плохих» строк,
-- метрики качества данных и lineage (прослеживаемость строки источника).
-- Эти таблицы не являются частью модели Data Vault, но делают её
-- «производственной»: видно, что загружалось, что отклонено и какова трасса.
-- =====================================================================

CREATE SEQUENCE IF NOT EXISTS audit.reject_id_seq;
CREATE SEQUENCE IF NOT EXISTS audit.run_id_seq;

-- Журнал запусков загрузки (по одной записи на шаг ELT)
DROP TABLE IF EXISTS audit.load_run_log;
CREATE TABLE audit.load_run_log
(
    run_id        bigint       NOT NULL DEFAULT nextval('audit.run_id_seq'),
    stage         varchar(30)  NOT NULL, -- staging | hub | link | satellite | bv | dm
    target_table  varchar(120) NOT NULL, -- имя целевой таблицы (возможно, группы таблиц)
    rows_inserted integer      NOT NULL,
    load_dts      timestamp(0) NOT NULL,
    file_hash     char(64),
    rec_src       varchar(20)  NOT NULL,
    note          text,
    CONSTRAINT load_run_log_pk PRIMARY KEY (run_id)
)
WITH (appendonly = false)
DISTRIBUTED BY (run_id);

COMMENT ON TABLE  audit.load_run_log             IS 'Журнал загрузок: сколько строк загружено каждым шагом ELT';
COMMENT ON COLUMN audit.load_run_log.stage       IS 'Слой/этап загрузки (staging, hub, link, satellite, bv, dm)';
COMMENT ON COLUMN audit.load_run_log.target_table IS 'Целевая таблица';
COMMENT ON COLUMN audit.load_run_log.rows_inserted IS 'Число вставленных строк';
COMMENT ON COLUMN audit.load_run_log.load_dts    IS 'Время выполнения шага';

-- Карантин: строки источника, не прошедшие правила качества
DROP TABLE IF EXISTS audit.rejected_records;
CREATE TABLE audit.rejected_records
(
    reject_id    bigint       NOT NULL DEFAULT nextval('audit.reject_id_seq'),
    src_row_num  integer      NOT NULL,
    file_hash    char(64)     NOT NULL,
    rule_name    varchar(200) NOT NULL, -- какие правила нарушены
    raw_record   text         NOT NULL, -- исходная строка «как есть»
    detected_dts timestamp(0) NOT NULL,
    rec_src      varchar(20)  NOT NULL,
    CONSTRAINT rejected_records_pk PRIMARY KEY (reject_id)
)
WITH (appendonly = false)
DISTRIBUTED BY (reject_id);

COMMENT ON TABLE  audit.rejected_records             IS 'Карантин: строки источника, отклонённые правилами качества (не попали в staging clean)';
COMMENT ON COLUMN audit.rejected_records.src_row_num IS 'Номер строки исходного CSV';
COMMENT ON COLUMN audit.rejected_records.rule_name   IS 'Перечень нарушенных правил валидации';
COMMENT ON COLUMN audit.rejected_records.raw_record  IS 'Исходная строка целиком (для разбора и повторной загрузки)';

-- Метрики качества данных (накопительный «дашборд» по каждому прогону)
DROP TABLE IF EXISTS audit.dq_metrics;
CREATE TABLE audit.dq_metrics
(
    metric_dts   timestamp(0)  NOT NULL,
    metric_name  varchar(80)   NOT NULL,
    metric_value numeric(20,4),
    expected_value numeric(20,4),
    unit         varchar(20),
    status       varchar(10)   NOT NULL, -- OK / FAIL
    note         text,
    CONSTRAINT dq_metrics_pk PRIMARY KEY (metric_dts, metric_name)
)
WITH (appendonly = false)
DISTRIBUTED BY (metric_dts);

COMMENT ON TABLE  audit.dq_metrics             IS 'Метрики качества данных по каждому прогону загрузки (тренд качества)';
COMMENT ON COLUMN audit.dq_metrics.metric_name IS 'Наименование метрики (например, staging_rows, sales_sum_delta)';
COMMENT ON COLUMN audit.dq_metrics.status      IS 'Результат сравнения с ожидаемым значением: OK/FAIL';

-- Lineage: трассировка «строка источника -> объекты Data Vault»
DROP TABLE IF EXISTS audit.record_lineage;
CREATE TABLE audit.record_lineage
(
    src_row_num          integer      NOT NULL,
    file_hash            char(64)     NOT NULL,
    load_dts             timestamp(0) NOT NULL,
    lnk_sales_line_key   char(32)     NOT NULL,
    hash_diff            char(32)     NOT NULL,
    hub_location_key     char(32)     NOT NULL,
    hub_sub_category_key char(32)     NOT NULL,
    hub_ship_mode_key    char(32)     NOT NULL,
    hub_segment_key      char(32)     NOT NULL,
    CONSTRAINT record_lineage_pk PRIMARY KEY (src_row_num, file_hash)
)
WITH (appendonly = false)
DISTRIBUTED BY (src_row_num);

COMMENT ON TABLE  audit.record_lineage       IS 'Lineage: какие именно строки Data Vault породила конкретная строка исходного файла';
COMMENT ON COLUMN audit.record_lineage.src_row_num IS 'Номер строки исходного CSV';
COMMENT ON COLUMN audit.record_lineage.hash_diff    IS 'Хеш-дифф мер, по которому строка лежит в vault.sat_sales_line';
