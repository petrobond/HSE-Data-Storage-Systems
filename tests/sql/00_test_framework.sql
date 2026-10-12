-- =====================================================================
-- tests/sql/00_test_framework.sql
-- Каркас автотестов корректности хранилища.
--
-- ВАЖНО про архитектуру тестов: проверка НЕ пишет в таблицу напрямую, а
-- возвращает строку результата (текст с разделителем chr(31)). Причина —
-- ограничение Greenplum: нельзя в одном плане одновременно сканировать
-- распределённую таблицу и выполнять вложенную запись из функции
-- (ошибка "query plan with multiple segworker groups is not supported").
-- Поэтому SQL-файлы тестов — это чистые SELECT (по одной строке на проверку),
-- а накопление результатов в audit.test_results выполняет tests/run_tests.py.
--
-- Формат строки результата: test_id \x1f test_name \x1f expected \x1f actual \x1f PASS|FAIL
-- =====================================================================

DROP TABLE IF EXISTS audit.test_results CASCADE;
CREATE TABLE audit.test_results
(
    test_id   varchar(10) NOT NULL, -- идентификатор группы тестов (t01..t08)
    test_name text        NOT NULL, -- что именно проверяется
    expected  text,                 -- ожидаемое значение
    actual    text,                 -- фактическое значение
    result    varchar(4)  NOT NULL  -- PASS / FAIL
)
WITH (appendonly = false)
DISTRIBUTED BY (test_id);

COMMENT ON TABLE audit.test_results IS 'Результаты автотестов корректности Data Vault-хранилища (PASS/FAIL)';

-- Строка результата для точного сравнения текстовых значений.
CREATE OR REPLACE FUNCTION audit.mk_check(p_id varchar, p_name text, p_expected text, p_actual text)
RETURNS text AS $$
    SELECT p_id || chr(31) || p_name || chr(31)
         || coalesce(p_expected, 'NULL') || chr(31) || coalesce(p_actual, 'NULL') || chr(31)
         || CASE WHEN p_expected IS NOT DISTINCT FROM p_actual THEN 'PASS' ELSE 'FAIL' END;
$$ LANGUAGE sql IMMUTABLE;

-- Строка результата для числовых сравнений (допуск 1e-4).
CREATE OR REPLACE FUNCTION audit.mk_check_num(p_id varchar, p_name text,
                                             p_expected numeric, p_actual numeric)
RETURNS text AS $$
    SELECT p_id || chr(31) || p_name || chr(31)
         || round(p_expected, 4)::text || chr(31) || round(p_actual, 4)::text || chr(31)
         || CASE WHEN abs(coalesce(p_expected, 0) - coalesce(p_actual, 0)) < 0.0001
                 THEN 'PASS' ELSE 'FAIL' END;
$$ LANGUAGE sql IMMUTABLE;

