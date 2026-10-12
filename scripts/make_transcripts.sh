#!/usr/bin/env bash
# =====================================================================
# Генерация текстовых транскриптов и плана скриншотов.
#
# Что делает:
#   1) подключается к Greenplum параметрами из .env;
#   2) прогоняет SQL-скрипты из sql/99_checks/ и сохраняет результат
#      (команда + вывод) в docs/tmp/transcripts/*.txt — это «текстовые
#      транскрипты» доказательств, которые не зависят от ручных скриншотов;
#   3) формирует docs/tmp/screenshots_plan.md — пошаговую инструкцию
#      с точными командами и тем, что должно быть видно на каждом скриншоте.
#
# Запуск: bash scripts/make_transcripts.sh   (или make screenshots)
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
. ./.env
set +a
export PGHOST="${GP_HOST}" PGPORT="${GP_PORT}" PGUSER="${GP_USER}" \
       PGPASSWORD="${GP_PASSWORD:-}" PGDATABASE="${GP_DATABASE}" \
       PGSSLMODE="${GP_SSLMODE:-prefer}"

OUT=docs/tmp/transcripts
mkdir -p "$OUT"

PSQL=(psql -X -q --pset pager=off)

run_file() {                        # run_file <sql-файл> <заголовок>
    local file="$1" title="$2"
    local out="$OUT/$(basename "$file" .sql).txt"
    {
        echo "### ${title}"
        echo "### Сформировано: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "### Подключение: ${PGHOST}:${PGPORT} / ${PGDATABASE} / пользователь ${PGUSER}"
        echo "### Команда:"
        echo "\$ psql -h ${PGHOST} -p ${PGPORT} -U ${PGUSER} -d ${PGDATABASE} -f ${file}"
        echo
    } > "$out"
    "${PSQL[@]}" -f "$file" >> "$out" 2>&1 || true
    echo "  создан $(basename "$out")"
}

run_cmd() {                         # run_cmd <имя файла> <заголовок> <SQL/метакоманды через \n>
    local name="$1" title="$2" body="$3"
    local out="$OUT/${name}.txt"
    {
        echo "### ${title}"
        echo "### Сформировано: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "### Подключение: ${PGHOST}:${PGPORT} / ${PGDATABASE} / пользователь ${PGUSER}"
        echo
        echo "$body"
        echo
        echo "--- вывод ---"
    } > "$out"
    printf '%s\n' "$body" | "${PSQL[@]}" -f - >> "$out" 2>&1 || true
    echo "  создан $(basename "$out")"
}

echo "=== Генерация транскриптов в ${OUT} ==="

run_cmd "00_environment" "Окружение Greenplum: версия и MPP-топология" \
"\\echo '=== Версия СУБД ==='
SELECT version();
\\echo '=== Инстансы кластера (координатор + сегменты) ==='
SELECT dbid, content, role, hostname, port, status FROM gp_segment_configuration ORDER BY content, role;
\\echo '=== База данных хранилища ==='
SELECT current_database(), current_user, current_setting('gp_role') AS gp_role;"

run_cmd "05_ddl_objects" "Созданные объекты хранилища (\\dt / \\d)" \
"\\echo '=== Схемы ==='
\\dn staging.* vault.* bv.* dm.* audit.*
\\echo '=== ХАБЫ (vault) ==='
\\dt vault.hub_*
\\echo '=== ССЫЛКИ (vault) ==='
\\dt vault.lnk_*
\\echo '=== САТЕЛЛИТЫ (vault) ==='
\\dt vault.sat_*
\\echo '=== Business Vault ==='
\\dt bv.*
\\echo '=== Витрины и представления ==='
\\dt dm.*
\\echo '=== DDL транзакционной ссылки ==='
\\d+ vault.lnk_sales_line
\\echo '=== DDL сателлита мер (AO/column, партиции, комментарии) ==='
\\d+ vault.sat_sales_line"

run_file sql/99_checks/10_table_counts.sql      "Созданные таблицы и число строк"
run_file sql/99_checks/20_reconciliation.sql    "Сходимость источник -> DDS -> Business Vault -> витрина"
run_file sql/99_checks/30_storage_distribution.sql "Хранение, дистрибуция, ограничения, партиции"
run_file sql/99_checks/40_lineage_trace.sql     "E6: прослеживаемость строки источника"
run_file sql/99_checks/50_e4_explain_distribution.sql "E4: EXPLAIN ANALYZE — co-location против случайной дистрибуции"
run_file sql/99_checks/60_audit_metrics.sql     "Журнал загрузок, метрики качества, карантин, размеры"

# ---------------------------------------------------------------------
# План скриншотов для итогового документа
# ---------------------------------------------------------------------
PLAN=docs/tmp/screenshots_plan.md
cat > "$PLAN" <<EOF
# План скриншотов для итогового документа в Google Docs

Хранилище: локальный Greenplum 7 (Docker-контейнер \`gp7\`, ${GP_HOST}:${GP_PORT}).
Скриншоты сохраняйте в \`docs/report/img/\` с именами из таблицы — отчёт
(\`docs/report/report.md\`) ссылается именно на них.

Подготовка окружения перед съёмкой (терминал №1 — держите открытым вывод psql):

\`\`\`bash
cd <каталог репозитория>
make ps                     # контейнер gp7 должен быть Up (healthy)
psql -h ${GP_HOST} -p ${GP_PORT} -U ${GP_USER} -d ${GP_DATABASE}
\`\`\`

## Обязательные скриншоты (покрывают все критерии задания)

| № | Файл | Что показать | Команда для подготовки |
|---|------|--------------|------------------------|
| 1 | \`01_greenplum_running.png\` | Контейнер с Greenplum запущен | \`docker ps --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'\` |
| 2 | \`02_version.png\` | Версия СУБД: Greenplum Database 7.0.0 | \`psql -h ${GP_HOST} -p ${GP_PORT} -U ${GP_USER} -d ${GP_DATABASE} -c 'SELECT version();'\` |
| 3 | \`03_mpp_topology.png\` | MPP: координатор + 4 сегмента | \`psql ... -c 'SELECT dbid, content, role, hostname, port FROM gp_segment_configuration ORDER BY content, role;'\` |
| 4 | \`04_tables_vault.png\` | Все таблицы vault: \`hub_*\`, \`lnk_*\`, \`sat_*\` | \`psql ... -c '\\dt vault.*'\` |
| 5 | \`05_ddl_link.png\` | DDL ссылки: PK, FK, DISTRIBUTED BY, комментарии | \`psql ... -c '\\d+ vault.lnk_sales_line'\` |
| 6 | \`06_ddl_satellite.png\` | DDL сателлита: AO/column, zstd, PK, CHECK, партиции | \`psql ... -c '\\d+ vault.sat_sales_line'\` |
| 7 | \`07_load_staging.png\` | Загрузка CSV: 9994 строки в staging | \`make stage\` (обрезать до строк «staging: итог») |
| 8 | \`08_load_dds.png\` | Загрузка хабов/ссылок/сателлитов и реконсиляция | \`make load 2>&1 | grep -v NOTICE\` (или открыть расходный лог загрузки) |
| 9 | \`09_table_counts.png\` | Число строк в каждой таблице (таблицы заполнены) | \`psql ... -f sql/99_checks/10_table_counts.sql\` |
| 10 | \`10_reconciliation.png\` | Источник = DDS = Business Vault = витрина (суммы совпадают) | \`psql ... -f sql/99_checks/20_reconciliation.sql\` |
| 11 | \`11_tests_all_pass.png\` | Итог автотестов: 118 проверок, 0 провалено | \`make test\` (или открыть \`docs/tmp/transcripts/tests_report.txt\`) |
| 12 | \`12_e4_explain.png\` | E4: план с Motion (антипример) vs без Motion (co-location) | \`psql ... -f sql/99_checks/50_e4_explain_distribution.sql\` |
| 13 | \`13_dq_metrics.png\` | Метрики качества (E11) и карантин (E3) | \`psql ... -f sql/99_checks/60_audit_metrics.sql\` |
| 14 | \`14_lineage.png\` | E6: трассировка строки CSV до строк Data Vault | \`psql ... -f sql/99_checks/40_lineage_trace.sql\` |

## Дополнительные (для «пятёрки с плюсами»)

| № | Файл | Что показать | Команда |
|---|------|--------------|---------|
| 15 | \`15_diagram.png\` | Диаграмма модели Data Vault (хабы/ссылки/сателлиты + Business Vault) | \`python3 scripts/make_diagram.py\` (PNG в \`docs/report/diagrams/\`) |
| 16 | \`16_marts.png\` | Витрины: продажи по регионам и категориям, топ-10 подкатегорий | \`psql ... -c 'SELECT * FROM dm.dm_sales_by_region_category ORDER BY region_name, category_name;'\` и \`SELECT * FROM dm.dm_product_hierarchy ORDER BY profit_amount DESC LIMIT 10;\` |
| 17 | \`17_dq_profile.png\` | Профиль качества источника: 17 дублей, 449 восстановленных ZIP, 6868 комбинаций | \`psql ... -c 'SELECT * FROM dm.dm_dq_source_profile;'\` |
| 18 | \`18_explain_partitions.png\` | Partition pruning по дате загрузки | \`psql ... -c \"EXPLAIN SELECT count(*) FROM staging.stg_superstore_raw WHERE load_dts >= TIMESTAMP '2026-10-01' AND load_dts < TIMESTAMP '2026-11-01';\"\` |
| 19 | \`19_vscode_ddl.png\` | Скрипт DDL с комментариями в VS Code | открыть \`sql/02_vault/10_ddl_hubs.sql\` |
| 20 | \`20_console_google_doc.png\` | Готовый документ в Google Docs (диаграмма + таблицы + скриншоты) | после загрузки DOCX |

## Как быстро всё воспроизвести с нуля

\`\`\`bash
make up            # поднять локальный Greenplum 7 (Docker)
make wait          # дождаться готовности
make ddl           # создать схемы и все таблицы
make download      # скачать датасет с Kaggle (data/raw)
make profile       # профилирование датасета (EDA)
make stage         # загрузка CSV в staging
make load          # ELT: хабы -> ссылки -> сателлиты -> Business Vault -> витрины
make test          # 118 автотестов корректности
make screenshots   # транскрипты + этот план скриншотов
make report        # сборка DOCX и PDF для Google Docs
make teardown      # в конце: снести все следы Greenplum
\`\`\`

Текстовые транскрипты всех проверок лежат в \`docs/tmp/transcripts/\` — их можно
использовать как текстовые доказательства вместо скриншотов (или в дополнение к ним).
EOF
echo "  создан ${PLAN}"
echo "=== Готово: транскрипты в ${OUT}, план скриншотов — ${PLAN} ==="

