-- =====================================================================
-- tests/sql/99_report.sql
-- Сводный отчёт автотестов: итог по группам, детализация по каждой проверке
-- и общий вердикт. Этот отчёт используется как доказательство корректности
-- в итоговом документе (скриншот «все тесты PASS»).
-- =====================================================================

\echo ''
\echo '================= СВОДНЫЙ ОТЧЁТ АВТОТЕСТОВ ================='
\echo ''

\echo '--- Итог по группам проверок ---'
SELECT test_id,
       CASE test_id
            WHEN 't01' THEN 'структура DDL (таблицы, PK/FK/CHECK, комментарии, дистрибуция, AO/CO, партиции)'
            WHEN 't02' THEN 'хеш-ключи (детерминизм, уникальность, нормализация, ghost-записи)'
            WHEN 't03' THEN 'ссылочная целостность (анти-join по всем связям)'
            WHEN 't04' THEN 'логика сателлитов (хеш-дифф, версии, интервалы, множитель дублей)'
            WHEN 't05' THEN 'сходимость с источником (количества, суммы, кардинальности, разрезы)'
            WHEN 't06' THEN 'идемпотентность повторной загрузки'
            WHEN 't07' THEN 'качество данных, Business Vault, метрики DQ'
            WHEN 't08' THEN 'карантин некорректных строк'
       END AS group_name,
       count(*) AS checks,
       count(*) FILTER (WHERE result = 'PASS') AS passed,
       count(*) FILTER (WHERE result = 'FAIL') AS failed
  FROM audit.test_results
 GROUP BY test_id
 ORDER BY test_id;

\echo '--- Детализация по каждой проверке ---'
SELECT test_id, test_name, expected, actual, result
  FROM audit.test_results
 ORDER BY result DESC, test_id, test_name;

\echo '--- ИТОГ ---'
SELECT count(*) AS checks_total,
       count(*) FILTER (WHERE result = 'PASS') AS passed,
       count(*) FILTER (WHERE result = 'FAIL') AS failed,
       CASE WHEN count(*) FILTER (WHERE result = 'FAIL') = 0
            THEN 'ВСЕ ТЕСТЫ ПРОЙДЕНЫ — модель Data Vault корректна и сходится с источником'
            ELSE 'ЕСТЬ ОШИБКИ — см. строки со статусом FAIL' END AS verdict
  FROM audit.test_results;

\echo ''
\echo '============================================================'
