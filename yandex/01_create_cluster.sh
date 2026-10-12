#!/usr/bin/env bash
# =====================================================================
# ОПЦИОНАЛЬНО. Создание кластера Managed Greenplum в Yandex Cloud.
#
# ВНИМАНИЕ: сервис платный. Минимальная конфигурация — 1 хост-мастер и 2 хоста
# сегментов. Все параметры ниже задаются переменными окружения, значения по
# умолчанию выбраны экономными. Скрипт ничего не делает без явного запуска.
#
# Требуется авторизованный yc CLI (yc init) и права на облако/каталог.
#
# Использование:
#   NETWORK_NAME=default SECURITY_GROUP_ID=<id> GP_PASSWORD='...' bash yandex/01_create_cluster.sh
# =====================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-dv-dds-gp}"
NETWORK_NAME="${NETWORK_NAME:-default}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
GP_USER="${GP_USER:-gpadmin}"
GP_PASSWORD="${GP_PASSWORD:-ChangeMe12345}"
GP_VERSION="${GP_VERSION:-7}"
MASTER_PRESET="${MASTER_PRESET:-s3-c2-m8}"
SEGMENT_PRESET="${SEGMENT_PRESET:-s3-c2-m8}"
SEGMENT_COUNT="${SEGMENT_COUNT:-2}"
DISK_SIZE="${DISK_SIZE:-20}"

if [ -z "${SECURITY_GROUP_ID}" ]; then
    echo "Не задан SECURITY_GROUP_ID. Создайте группу безопасности, разрешающую входящий TCP 6432" >&2
    echo "и повторите запуск. Примеры команд — в yandex/README.md" >&2
    exit 2
fi

echo "=== Создание кластера ${CLUSTER_NAME} (Greenplum ${GP_VERSION}) ==="
echo "Учетная запись БД: ${GP_USER}; пароль: ${GP_PASSWORD}"
yc managed-greenplum cluster create "${CLUSTER_NAME}" \
    --environment production \
    --network-name "${NETWORK_NAME}" \
    --security-group-ids "${SECURITY_GROUP_ID}" \
    --master-host-count 1 \
    --segment-host-count "${SEGMENT_COUNT}" \
    --version "${GP_VERSION}" \
    --user-name "${GP_USER}" \
    --user-password "${GP_PASSWORD}" \
    --master-config resource-id="${MASTER_PRESET}",disk-size="${DISK_SIZE}",disk-type=network-ssd \
    --segment-config resource-id="${SEGMENT_PRESET}",disk-size="${DISK_SIZE}",disk-type=network-ssd

echo
echo "Кластер создаётся (10-15 минут). Параметры подключения: bash yandex/02_get_conninfo.sh"
