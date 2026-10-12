#!/usr/bin/env bash
# =====================================================================
# ОПЦИОНАЛЬНО. Получение параметров подключения к Managed Greenplum YC
# и подсказка, что вписать в .env для прогона тех же скриптов.
#
# Использование: CLUSTER_NAME=dv-dds-gp bash yandex/02_get_conninfo.sh
# =====================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-dv-dds-gp}"

echo "=== Кластеры Managed Greenplum ==="
yc managed-greenplum cluster list

echo
echo "=== Хосты кластера ${CLUSTER_NAME} ==="
yc managed-greenplum cluster list-hosts "${CLUSTER_NAME}"

echo
echo "=== Реквизиты подключения ==="
HOST=$(yc managed-greenplum cluster list-hosts "${CLUSTER_NAME}" \
        --format json | python3 -c "
import json,sys
hosts = json.load(sys.stdin)
for h in hosts:
    if h.get('role') == 'MASTER':
        print(h['name'])
        break
")
echo "GP_HOST=${HOST}"
echo "GP_PORT=6432            # Managed Greenplum слушает 6432 (Odyssey)"
echo "GP_USER=gpadmin         # пользователь, заданный при создании кластера"
echo "GP_DATABASE=vault_dv"
echo "GP_SSLMODE=require"
echo
echo "Впишите эти значения в .env и выполните: make ddl && make stage && make load && make test"
echo "Для Greenplum 6 дополнительно: make gp6-satellites (PK на AO/column там запрещён)."
