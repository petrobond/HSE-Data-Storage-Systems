-- =====================================================================
-- tests/sql/t07_data_quality.sql
-- ТЕСТ t07. Качество данных и производные структуры Business Vault:
--   * восстановление ZIP до 5 знаков, отсутствие NULL в бизнес-ключах;
--   * диапазоны мер;
--   * эквивалентность reference-таблиц хабам (E7);
--   * наличие ghost-записей, lineage и пустого карантина;
--   * персистентные метрики качества (E11) без FAIL.
-- =====================================================================

\echo '--- t07: качество данных и Business Vault ---'

SELECT audit.mk_check('t07', 'все ZIP в очищенном слое имеют длину 5', '0',
       (SELECT count(*)::text FROM staging.stg_superstore_clean WHERE length(postal_code) <> 5));

SELECT audit.mk_check('t07', 'в источнике действительно были 4-значные ZIP (проблема качества)', '449',
       (SELECT count(*)::text FROM staging.stg_superstore_raw WHERE length(btrim(postal_code)) = 4));

SELECT audit.mk_check('t07', 'нет NULL в бизнес-ключах очищенного слоя', '0',
       (SELECT count(*)::text FROM staging.stg_superstore_clean
         WHERE ship_mode_name IS NULL OR segment_name IS NULL OR country_name IS NULL
            OR state_name IS NULL OR city_name IS NULL OR postal_code IS NULL
            OR region_name IS NULL OR category_name IS NULL OR sub_category_name IS NULL));

SELECT audit.mk_check('t07', 'нет NULL в мерах', '0',
       (SELECT count(*)::text FROM vault.sat_sales_line
         WHERE sales_amount IS NULL OR quantity IS NULL OR discount_rate IS NULL OR profit_amount IS NULL));

SELECT audit.mk_check('t07', 'discount всегда в диапазоне 0..1', '0',
       (SELECT count(*)::text FROM vault.sat_sales_line WHERE discount_rate < 0 OR discount_rate > 1));

SELECT audit.mk_check('t07', 'quantity всегда > 0', '0',
       (SELECT count(*)::text FROM vault.sat_sales_line WHERE quantity <= 0));

SELECT audit.mk_check('t07', 'гранулярность мер сохранена (4 знака после запятой)', 'true',
       (SELECT (max(sales_amount) = 22638.4800 AND count(*) FILTER (WHERE sales_amount = 261.9600) > 0)::text
          FROM vault.sat_sales_line));

-- E7: эквивалентность reference-таблиц хабам + сателлитам
SELECT audit.mk_check('t07', 'bv.ref_ship_mode эквивалентна hub+sat по способам доставки', '0',
       (SELECT count(*)::text FROM (
            (SELECT ship_mode_name, ship_speed_rank FROM bv.ref_ship_mode
             EXCEPT
             SELECT ship_mode_name, ship_speed_rank FROM vault.sat_ship_mode)
            UNION ALL
            (SELECT ship_mode_name, ship_speed_rank FROM vault.sat_ship_mode
             EXCEPT
             SELECT ship_mode_name, ship_speed_rank FROM bv.ref_ship_mode)) x));

SELECT audit.mk_check('t07', 'bv.ref_segment эквивалентна hub+sat по сегментам', '0',
       (SELECT count(*)::text FROM (
            (SELECT segment_name, segment_type FROM bv.ref_segment
             EXCEPT
             SELECT segment_name, segment_type FROM vault.sat_segment)
            UNION ALL
            (SELECT segment_name, segment_type FROM vault.sat_segment
             EXCEPT
             SELECT segment_name, segment_type FROM bv.ref_segment)) x));

-- E2: RTS покрывает все записи хабов
SELECT audit.mk_check('t07', 'rts_hub_record покрывает все записи восьми хабов', '0',
       ( (SELECT count(*) FROM vault.hub_country) + (SELECT count(*) FROM vault.hub_region)
       + (SELECT count(*) FROM vault.hub_state) + (SELECT count(*) FROM vault.hub_location)
       + (SELECT count(*) FROM vault.hub_category) + (SELECT count(*) FROM vault.hub_sub_category)
       + (SELECT count(*) FROM vault.hub_ship_mode) + (SELECT count(*) FROM vault.hub_segment)
       - (SELECT count(*) FROM bv.rts_hub_record) )::text);

-- E1/E6: PIT и lineage
SELECT audit.mk_check('t07', 'pit_location покрывает все гео-локации (последний снимок)', '632',
       (SELECT count(*)::text FROM bv.pit_location
         WHERE snapshot_dts = (SELECT max(snapshot_dts) FROM bv.pit_location)));

SELECT audit.mk_check('t07', 'lineage содержит строку для каждой строки источника', '9994',
       (SELECT count(*)::text FROM audit.record_lineage));

SELECT audit.mk_check('t07', 'карантин пуст: все 9994 строки прошли валидацию', '0',
       (SELECT count(*)::text FROM audit.rejected_records));

-- E11: персистентные метрики качества
SELECT audit.mk_check('t07', 'все метрики DQ в статусе OK (audit.dq_metrics)', '0',
       (SELECT count(*)::text FROM audit.dq_metrics
         WHERE metric_dts = (SELECT max(metric_dts) FROM audit.dq_metrics) AND status = 'FAIL'));

SELECT audit.mk_check('t07', 'журнал загрузки заполнен (audit.load_run_log)', 'true',
       (SELECT (count(*) > 0)::text FROM audit.load_run_log));
