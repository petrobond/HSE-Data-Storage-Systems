#!/usr/bin/env bash
# =====================================================================
# Полный снос следов Greenplum после сдачи работы.
#
# Что удаляется:
#   1) контейнер gp7 и Docker-образ andruche/greenplum:7-4seg;
#   2) вспомогательные образы, скачанные при разведке (alpine:latest);
#   3) тома/сети, созданные compose-проектом (томов у нас нет — «нет следов»);
#   4) локальные данные: data/raw (CSV) и data/tmp (подготовленный CSV, профиль).
#
# Что НЕ удаляется: исходный код, SQL-скрипты, тесты, отчёт и транскрипты —
# всё это лежит в git, а хранилище поднимается заново командами
#   make up && make wait && make ddl && make stage && make load && make test
#
# Запуск: bash scripts/teardown_greenplum.sh   (или make teardown)
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="andruche/greenplum:7-4seg"
CONTAINER="gp7"

echo "=== 1. Остановка и удаление контейнера ${CONTAINER} ==="
docker compose -f docker/docker-compose.yml down --remove-orphans 2>/dev/null || true
docker rm -f "${CONTAINER}" 2>/dev/null && echo "  контейнер удалён" || echo "  контейнера нет"

echo "=== 2. Удаление образов Greenplum и вспомогательных ==="
docker rmi -f "${IMAGE}" 2>/dev/null && echo "  образ ${IMAGE} удалён" || echo "  образа нет"
docker rmi -f alpine:latest 2>/dev/null && echo "  образ alpine:latest удалён" || echo "  образа нет"

echo "=== 3. Удаление томов и сетей проекта ==="
docker volume prune -f >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1 || true

echo "=== 4. Удаление локальных данных ==="
rm -rf data/raw/* data/tmp/* 2>/dev/null || true
echo "  очищены data/raw и data/tmp"

echo "=== 5. Контроль: следов Greenplum не осталось ==="
echo "--- контейнеры ---"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' | (grep -i greenplum || echo "  Greenplum-контейнеров нет")
echo "--- образы ---"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | (grep -i greenplum || echo "  Greenplum-образов нет")
echo "--- локальные данные ---"
ls -la data/raw data/tmp 2>/dev/null | (grep -E '\.csv|\.json' || echo "  файлов данных нет")
