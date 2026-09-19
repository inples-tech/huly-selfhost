# Бэкап Huly (HLY-7)

Ставится на хост `159.194.210.202` (erp.inples.ru). **Вне git ничего не живёт**:
при пересоздании VPS всё разворачивается отсюда.

## Что и куда

| Артефакт | Что внутри | Когда |
|---|---|---|
| `cockroach-<ts>.tar.gz` | полный логический бэкап кластера (`BACKUP INTO`): ядро всех воркспейсов + `global_account` с реестром и пользователями | ежедневно |
| `minio-<ts>.tar.gz` | том MinIO целиком: вложения, аватары, записи созвонов | ежедневно |
| `workspaces-<ts>.tar.gz` | логический бэкап каждого воркспейса штатным `tool backup` — переносимый формат, разворачивается в другую инсталляцию Huly | по воскресеньям |
| `env-<ts>.tar.gz.age` | конфигурация развёртывания под шифром: `huly_v7.conf` (env компоуза Dokploy) и `/etc/huly-secrets/` | ежедневно |
| `manifest-<ts>.txt` | версия Huly, состав, sha256 каждого архива | с каждым прогоном |

**Почему конфигурация обязательна.** Данные без неё мертвы: `SECRET` из `huly_v7.conf`
подписывает все токены, без него в восстановленный воркспейс не войти. Приватный ключ
GitHub App из `/etc/huly-secrets/github.env` вообще не воспроизводится из репозитория —
при потере надо заводить App заново.

Хранилище: `s3://da52bb93d7ea-edlegal-s3/huly-backup/{daily,weekly,monthly}/<дата>/`
(Beget S3, тот же бакет, что у RAG-реплики edlegal, отдельный префикс).
Ротация: 7 ежедневных, 4 еженедельных, 3 ежемесячных.

Расписание: `huly-backup.timer`, 02:30 UTC (05:30 МСК), `Persistent=true` —
пропущенный из-за выключенного хоста прогон догоняется при старте.

## Установка на чистом хосте

```bash
mkdir -p /opt/huly-backup
python3 -m venv /opt/huly-backup/venv
/opt/huly-backup/venv/bin/pip install awscli      # v1: у v2 ломается контрольная сумма на Beget
install -m 700 ops/backup/backup.sh /opt/huly-backup/backup.sh
install -m 644 ops/backup/huly-backup.{service,timer} /etc/systemd/system/
install -m 644 ops/backup/logrotate.huly-backup /etc/logrotate.d/huly-backup
systemctl daemon-reload && systemctl enable --now huly-backup.timer
```

Плюс `~/.aws/{credentials,config}` (0600) с ключом к бакету. В `config` обязательны
`addressing_style = path` и `request_checksum_calculation = when_required` — иначе
Beget отвергает запросы.

И `age` с файлом получателей:

```bash
apt-get install -y age
echo "<публичный ключ age>" > /opt/huly-backup/recipients.txt
```

Если имя стека поменялось (Dokploy генерирует его сам), поправить `STACK=` в начале
скрипта: `docker ps --format '{{.Names}}' | head -1`.

## Проверка

```bash
systemctl start huly-backup.service          # разовый прогон
tail -40 /var/log/huly-backup.log
systemctl list-timers huly-backup.timer
```

Читаемость архива CockroachDB без восстановления:

```bash
EXT=/var/lib/docker/volumes/<стек>_cr_data/_data/extern
tar xzf cockroach-<ts>.tar.gz -C $EXT
U=$(docker exec <стек>-account-1 printenv DB_URL)"?sslmode=disable"
docker exec -e U="$U" <стек>-cockroach-1 \
  cockroach sql --url "$U" --execute "SHOW BACKUP FROM LATEST IN 'nodelocal://1/run-<ts>';"
```

## Шифрование конфигурации

Асимметричное, `age`. На хосте лежит **только публичный ключ** (`recipients.txt`):
сервер умеет зашифровать, но не расшифровать, поэтому его компрометация не раскрывает
ни прошлые бэкапы, ни чужие копии в S3.

Приватный ключ создаётся на машине администратора и на сервер не попадает:

```bash
age-keygen -o ~/.config/huly/backup-age-key.txt   # 0600
```

Расшифровка:

```bash
age -d -i ~/.config/huly/backup-age-key.txt env-<ts>.tar.gz.age | tar xzf - -C /куда
```

### Две вещи, которые обязаны лежать вне этого бэкапа

Обе нужны, чтобы до бэкапа вообще добраться, поэтому внутри него бесполезны — им
место в менеджере паролей:

1. **приватный ключ age** — потерян, и вся конфигурация во всех копиях нечитаема;
2. **ключ доступа к бакету Beget** — без него не скачать ни один архив.

## Оповещения

Ошибка на любом шаге — сообщение в группу «Huly оповещения» через `@inpleshulybot`.
По воскресеньям туда же приходит сводка об успехе: молчание должно что-то значить,
поэтому тишина всю неделю + сводка в воскресенье = всё в порядке.

Токен и chat_id берутся из окружения контейнера meetscribe, отдельной копии секрета нет.

## Грабли, на которые уже наступили

- **`trap ERR` не наследуется функциями без `set -E`.** Первая версия падала внутри
  ротации и завершалась с кодом 1 молча: ни строки в логе, ни сообщения в Telegram.
  Ровно тот сценарий, ради которого бэкап и заводили.
- **`aws s3 ls` по несуществующему префиксу возвращает 1.** Пустой ярус ротации (ещё
  не было ни одного weekly) роняет скрипт под `set -e`.
- **`--data-urlencode` не раскрывает `%0A`** — в сообщение уезжает литерал. Переносы
  строк подавать настоящими символами.
- **logrotate отказывается ротировать в `/var/log`** без директивы `su`: каталог
  принадлежит `root:syslog`.
- Каталог даты в S3 очищается перед выгрузкой: иначе повторный прогон (ретрай после
  сбоя) копит архивы внутри одного дня, а ротация удаляет каталоги целиком и их не видит.
- **Первая версия бэкапа была полна по данным и пуста по развёртыванию.** CockroachDB,
  MinIO и воркспейсы выгружались, а `SECRET` и ключ GitHub App — нет, то есть
  восстановить на чистом сервере было нечем. Вскрылось при проектировании учений
  HLY-8, а не при настоящей аварии.
