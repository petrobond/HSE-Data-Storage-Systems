-- =====================================================================
-- tests/sql/t08_quarantine.sql
-- ТЕСТ t08. Проверка механизма карантина (E3): в staging подкладывается
-- заведомо «плохая» строка (quantity = -5, скидка = 1.5), после чего
-- запускается РЕАЛЬНЫЙ загрузчик очищенного слоя (30_transform_staging.sql)
-- с отдельным file_hash. Ожидание: строка попадает в audit.rejected_records
-- и НЕ попадает в staging.stg_superstore_clean.
-- Запускается с параметрами: -v file_hash=test_hash_bad_row -v rec_src=test
-- (см. tests/run_tests.py), в конце тест убирает за собой.
-- =====================================================================

\echo '--- t08: механизм карантина «плохих» строк ---'

SELECT audit.mk_check('t08', 'строка с нарушением правил отклонена в карантин', '1',
       (SELECT count(*)::text FROM audit.rejected_records WHERE file_hash = 'test_hash_bad_row'));

SELECT audit.mk_check('t08', 'в очищенный слой «плохая» строка не попала', '0',
       (SELECT count(*)::text FROM staging.stg_superstore_clean WHERE file_hash = 'test_hash_bad_row'));

SELECT audit.mk_check('t08', 'в карантине указаны конкретные нарушенные правила', 'true',
       (SELECT (rule_name LIKE '%R3%' AND rule_name LIKE '%R4%')::text
          FROM audit.rejected_records WHERE file_hash = 'test_hash_bad_row' LIMIT 1));

-- Уборка тестовых данных (после сбора результатов теста)
DELETE FROM audit.rejected_records WHERE file_hash = 'test_hash_bad_row';
DELETE FROM audit.record_lineage   WHERE file_hash = 'test_hash_bad_row';
DELETE FROM staging.stg_superstore_clean WHERE file_hash = 'test_hash_bad_row';
DELETE FROM staging.stg_superstore_raw   WHERE file_hash = 'test_hash_bad_row';
DELETE FROM audit.load_run_log WHERE file_hash = 'test_hash_bad_row';
