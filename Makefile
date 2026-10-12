# Итоговое ДЗ модуль 1 — Data Vault в Greenplum.
# Все цели завязаны на переменные из .env (см. .env.example).
# Подключение к Greenplum выполняется клиентом psql через переменные libpq.

SHELL := /bin/bash

# --- .env -> libpq ---
ENV_FILE := .env
include $(ENV_FILE)
export PGHOST     := $(GP_HOST)
export PGPORT     := $(GP_PORT)
export PGUSER     := $(GP_USER)
export PGPASSWORD := $(GP_PASSWORD)
export PGDATABASE := $(GP_DATABASE)
export PGSSLMODE  := $(GP_SSLMODE)

COMPOSE := docker compose -f docker/docker-compose.yml
PSQL    := psql -v ON_ERROR_STOP=1 -X -q
DATA_CSV := data/raw/SampleSuperstore.csv
SCREENSHOTS := docs/tmp/screenshots_plan.md
TRANSCRIPTS := docs/tmp/transcripts

.PHONY: help up down ps wait init download profile ddl stage load bv marts test report screenshots all teardown clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Поднять локальный Greenplum (Docker)
	$(COMPOSE) up -d
	@echo "Greenplum поднимается. Проверка: make wait"

wait: ## Дождаться готовности координатора (обычный режим, не admin)
	@for i in $$(seq 1 60); do \
	  if $(PSQL) -d $(GP_MAINT_DB) -Atc 'select 1' >/dev/null 2>&1; then echo "Greenplum готов ($$i попыток)"; exit 0; fi; \
	done; echo "Greenplum не ответил"; exit 1

ps: ## Состояние контейнера
	$(COMPOSE) ps

down: ## Остановить контейнеры
	$(COMPOSE) down

init: ## Создать БД vault_dv (идемпотентно)
	$(PSQL) -d $(GP_MAINT_DB) -f sql/00_init/00_create_database.sql

download: ## Скачать датасет с Kaggle в data/raw/ (+ sha256)
	python3 src/download_dataset.py

profile: ## EDA: профиль датасета (кардинальности, иерархии, контрольные суммы)
	python3 src/profile_dataset.py

ddl: init ## Создать схемы и все таблицы (staging, vault, bv, dm, audit)
	$(PSQL) -f sql/00_init/10_create_schemas.sql
	$(PSQL) -f sql/00_init/20_audit_tables.sql
	$(PSQL) -f sql/01_staging/10_ddl_staging.sql
	$(PSQL) -f sql/02_vault/10_ddl_hubs.sql
	$(PSQL) -f sql/02_vault/20_ddl_links.sql
	$(PSQL) -f sql/02_vault/30_ddl_satellites.sql
	$(PSQL) -f sql/04_bv/10_ddl_business_vault.sql
	$(PSQL) -f sql/05_marts/10_ddl_marts.sql

stage: ## Загрузить CSV в staging (raw -> clean, с карантином плохих строк)
	python3 src/load_staging.py

load: ## ELT: хабы -> линки -> сателлиты -> Business Vault -> витрины
	$(PSQL) -f sql/03_load/10_load_hubs.sql
	$(PSQL) -f sql/03_load/20_load_links.sql
	$(PSQL) -f sql/03_load/30_load_satellites.sql
	$(PSQL) -f sql/03_load/35_load_sat_sales_line.sql
	$(PSQL) -f sql/03_load/40_load_business_vault.sql
	$(PSQL) -f sql/03_load/50_load_marts.sql
	$(PSQL) -f sql/03_load/90_refresh_dq_metrics.sql
	$(PSQL) -f sql/03_load/99_analyze.sql

test: ## Тесты корректности DV-модели (t01..t08) + сводный отчёт PASS/FAIL
	python3 tests/run_tests.py

all: up wait ddl download stage load test report ## Полный цикл

report: ## Собрать отчёт DOCX + PDF
	bash scripts/build_report.sh

diagram: ## Сгенерировать диаграмму модели (PNG/SVG из DOT)
	python3 scripts/make_diagram.py

screenshots: ## Сгенерировать план скриншотов и текстовые транскрипты
	bash scripts/make_transcripts.sh

yc-create: ## (Опционально) создать Managed Greenplum в Yandex Cloud
	bash yandex/01_create_cluster.sh

yc-conninfo: ## (Опционально) получить параметры подключения к кластеру YC
	bash yandex/02_get_conninfo.sh

gp6-satellites: ## Пересоздать сателлиты в GP6-совместимом виде (heap вместо AO/column)
	$(PSQL) -f sql/02_vault_gp6_heap/30_ddl_satellites_gp6.sql

teardown: ## Снести все следы Greenplum (контейнеры, образы, данные)
	bash scripts/teardown_greenplum.sh
