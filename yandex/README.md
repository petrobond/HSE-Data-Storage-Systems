# Managed Greenplum в Yandex Cloud (опциональный путь реализации)

Основная реализация домашнего задания выполнена в локальном Greenplum 7 (Docker), потому что
кластеров Managed Greenplum в облаке учётной записи на момент сдачи нет, а создание нового —
платное решение. Все скрипты проекта версионно-нейтральны, поэтому тот же результат
воспроизводится в Yandex Cloud без изменения SQL.

## Шаги

1. **Проверить доступность сервиса и существующие кластеры**

   ```bash
   yc config profile list
   yc managed-greenplum cluster list --folder-id <folder-id>
   ```

   Если сервис недоступен или кластер не нужен, используйте локальный путь (`make up`).

2. **Подготовить группу безопасности** — разрешить входящий TCP `6432` (порт подключения
   Managed Greenplum) со своего адреса:

   ```bash
   yc vpc security-group create --name dv-dds-gp-sg --network-name default
   yc vpc security-group update-rules --name dv-dds-gp-sg \
       --add-rule "direction=ingress,port=6432,protocol=tcp,v4-cidr-blocks=0.0.0.0/0"
   yc vpc security-group list --format json   # взять id группы
   ```

   Для учебного кластера не открывайте порт в интернет без необходимости: лучше добавить
   правило с конкретным IP.

3. **Создать кластер** (минимальная конфигурация: 1 мастер + 2 сегмента, Greenplum 7):

   ```bash
   NETWORK_NAME=default SECURITY_GROUP_ID=<sg-id> GP_PASSWORD='<пароль>' \
       bash yandex/01_create_cluster.sh
   ```

4. **Получить реквизиты и пройти пайплайн**:

   ```bash
   CLUSTER_NAME=dv-dds-gp bash yandex/02_get_conninfo.sh
   # вписать GP_HOST/GP_PORT=6432/GP_USER/GP_PASSWORD/GP_SSLMODE=require в .env
   make ddl && make stage && make load && make test
   ```

   На Greenplum 6 вместо `sql/02_vault/30_ddl_satellites.sql` применяется
   `sql/02_vault_gp6_heap/30_ddl_satellites_gp6.sql` (в GP6 PK на append-optimized таблицах запрещён) —
   цель `make gp6-satellites`.

5. **После проверки — удалить кластер**, чтобы не платить за простой:

   ```bash
   yc managed-greenplum cluster delete dv-dds-gp
   ```

## Что показывать в отчёте

Скриншоты из консоли Yandex Cloud (страница кластера, `gp_segment_configuration`, листинг таблиц)
прикладываются дополнительно к скриншотам локального кластера; SQL-проверки и тесты одинаковы
для обоих вариантов.
