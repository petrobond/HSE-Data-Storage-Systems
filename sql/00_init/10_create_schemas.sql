-- =====================================================================
-- 00_init/10_create_schemas.sql
-- Схемы хранилища. Разделение по слоям архитектуры Data Vault 2.0:
--   staging — область подготовки данных (ODS, «сырые» данные источников);
--   vault   — уровень корпоративного хранилища (DDS, модель Data Vault 2.0);
--   bv      — Business Vault (производные структуры: PIT, Bridge, EFS, RTS, ref);
--   dm      — уровень представления (витрины, information marts);
--   audit   — служебные таблицы: лог загрузок, карантин, метрики качества, lineage.
-- Схемы создаются идемпотентно, к каждой прикладывается комментарий.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS vault;
CREATE SCHEMA IF NOT EXISTS bv;
CREATE SCHEMA IF NOT EXISTS dm;
CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA staging IS 'Область подготовки данных (Staging/ODS): сырые данные источника и очищенный типизированный слой с хеш-ключами';
COMMENT ON SCHEMA vault   IS 'Уровень корпоративного хранилища (DDS): модель Data Vault 2.0 — хабы, ссылки, сателлиты (raw vault)';
COMMENT ON SCHEMA bv      IS 'Business Vault: производные структуры Data Vault 2.0 — PIT, Bridge, Effectivity Satellite, Record Tracking Satellite, reference-таблицы';
COMMENT ON SCHEMA dm      IS 'Уровень представления: витрины данных и information marts, построенные поверх Data Vault';
COMMENT ON SCHEMA audit   IS 'Служебные данные: лог загрузок, карантин отклонённых записей, метрики качества данных, lineage';
