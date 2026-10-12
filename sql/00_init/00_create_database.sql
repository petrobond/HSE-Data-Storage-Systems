-- =====================================================================
-- 00_init/00_create_database.sql
-- Идемпотентное создание базы данных хранилища.
-- Запускается в служебной БД (по умолчанию postgres), см. Makefile: make init.
-- =====================================================================
SELECT 'CREATE DATABASE vault_dv'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'vault_dv')\gexec

COMMENT ON DATABASE vault_dv IS
  'Итоговое ДЗ модуль 1: хранилище данных, спроектированное методом Data Vault 2.0 (датасет Kaggle: roopacalistus/superstore)';
