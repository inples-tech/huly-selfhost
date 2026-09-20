#!/usr/bin/env bash
#
# HLY-8 — учения по восстановлению. Проверяют не «лежит ли файл в S3», а
# «поднимаются ли из него данные и совпадают ли с продом».
#
# Два режима:
#
#   ./restore-drill.sh quick
#       Ежемесячный. Поднимает одноразовый CockroachDB рядом (~1,5 ГБ, портов
#       наружу нет), тянет последний бэкап ИЗ S3, делает полный RESTORE и сверяет
#       контрольные числа с манифестом того же прогона. Около полуминуты. Ловит то, что ломается чаще
#       всего: битый архив, несовместимость версий, потерю global_account.
#       НЕ проверяет: поднимется ли поверх этих данных сам Huly.
#
#   ./restore-drill.sh full
#       Ежеквартальный, на ОТДЕЛЬНОМ одноразовом сервере. Разворачивает стек
#       целиком и проверяет вход в UI. Печатает чеклист — шаги, которые нельзя
#       автоматизировать вслепую.
#
# Запускать на хосте Huly (нужны docker, ключ к S3 и образ CockroachDB той же версии).
#
set -Eeuo pipefail

MODE="${1:-quick}"
STACK="${STACK:-compose-reboot-digital-port-j1flk6}"
WORK=/opt/huly-backup
AWS="$WORK/venv/bin/aws --endpoint-url https://s3.ru1.storage.beget.cloud"
BUCKET=da52bb93d7ea-edlegal-s3
PREFIX=huly-backup
DRILL=drill-cr
TMP=/tmp/drill-$$

log() { echo "[$(date -u '+%F %T') UTC] $*"; }

cleanup() {
  docker rm -f "$DRILL" >/dev/null 2>&1 || true
  docker volume rm "${DRILL}-data" >/dev/null 2>&1 || true
  docker network rm drill-net >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ "$MODE" = "full" ]; then
  cat <<'CHECKLIST'
УЧЕНИЯ, ПОЛНЫЙ РЕЖИМ — чеклист для отдельного одноразового сервера

Ни один существующий хост не подходит: у huly-inples свободно ~4 ГБ из 11, у
bnlegal-vps ~1 ГБ из 7. Второй стек рядом с продом — это сценарий 05.09.2026,
когда сборка на общем хосте вызвала OOM и granai.ru лёг на 15 минут.

 1. Поднять временный VPS: 4 ядра, 8 ГБ, 50 ГБ диска. Docker, docker compose, age.
 2. Скачать из S3 последний daily: cockroach, minio, env (.age), manifest.
    Сверить sha256 с манифестом.
 3. Расшифровать конфигурацию приватным ключом age (он у администратора, НЕ на сервере):
       age -d -i ~/.config/huly/backup-age-key.txt env-<ts>.tar.gz.age | tar xzf -
 4. !!! САНИТАРНЫЙ ENV — без этого стенд начнёт вести себя как прод.
    Из huly_v7.conf вырезать или подменить:
      GITHUB_*            иначе пойдёт синхронизировать в живые репозитории inples-tech
      TELEGRAM_BOT_TOKEN  иначе getUpdates выбьет прод-бота с 409, и он НЕ поднимется сам
      SMTP_*              иначе полетят письма живым людям от huly@inples.ru
      DEEPGRAM_API_KEY, AIBOT_*, MEETSCRIBE_*, LIVEKIT_*
    SECRET оставить как есть — на нём подписаны токены, без него не войти.
 5. Клонировать форк inples-tech/huly-selfhost на ту же версию, что в манифесте.
    Поднять только ядро: cockroach minio redpanda elastic account transactor front
    workspace fulltext collaborator kvs rekoni. Остальное не нужно и съест память.
 6. Восстановить CockroachDB: распаковать в extern узла, RESTORE FROM LATEST IN ...
 7. Восстановить MinIO: распаковать архив в том files.
 8. Прогнать сверку из quick-режима против прода.
 9. Открыть UI, войти, открыть произвольную задачу, скачать вложение.
10. Засечь общее время от пустого сервера до рабочего UI — это и есть RTO.
11. Удалить VPS. Записать итог комментарием в HLY-8.

Известно на 19.09.2026 (проверено): полный кластерный RESTORE в core-версии
CockroachDB работает, лицензия не нужна, 48 МБ восстанавливаются за 9 секунд.
Не проверено: поднимается ли поверх восстановленных данных сам Huly — ровно
это и есть предмет полного режима.
CHECKLIST
  exit 0
fi

# ── быстрый режим ────────────────────────────────────────────────────────
log "Учения, быстрый режим: RESTORE из S3 + сверка с продом"
mkdir -p "$TMP"

DAY=$($AWS s3 ls "s3://$BUCKET/$PREFIX/daily/" | awk '/PRE/ {print $2}' | sed 's#/$##' | sort | tail -1)
KEY=$($AWS s3 ls "s3://$BUCKET/$PREFIX/daily/$DAY/" | awk '/cockroach-/ {print $4}' | tail -1)
if [ -z "${KEY:-}" ]; then log "в S3 нет бэкапа CockroachDB — учения провалены"; exit 1; fi
log "берём $DAY / $KEY"
$AWS s3 cp "s3://$BUCKET/$PREFIX/daily/$DAY/$KEY" "$TMP/" --only-show-errors
tar xzf "$TMP/$KEY" -C "$TMP"
RUN=$(basename "$(ls -d "$TMP"/run-*)")

log "поднимаем одноразовый узел (память ограничена — рядом прод)"
docker network create drill-net >/dev/null 2>&1 || true
docker run -d --name "$DRILL" --network drill-net --memory 1500m --cpus 1.5 \
  -v "${DRILL}-data:/cockroach/cockroach-data" \
  "$(docker inspect --format '{{.Config.Image}}' "${STACK}-cockroach-1")" \
  start-single-node --insecure --cache=192MiB --max-sql-memory=192MiB >/dev/null
for i in $(seq 30); do
  docker exec "$DRILL" cockroach sql --insecure --execute "SELECT 1;" >/dev/null 2>&1 && break
  sleep 2
done

docker exec "$DRILL" mkdir -p /cockroach/cockroach-data/extern
docker cp "$TMP/$RUN" "$DRILL:/cockroach/cockroach-data/extern/$RUN"

log "RESTORE"
START=$(date +%s)
docker exec "$DRILL" cockroach sql --insecure \
  --execute "RESTORE FROM LATEST IN 'nodelocal://1/$RUN';" --format=table | tail -3
log "восстановление заняло $(( $(date +%s) - START )) с"

drill() { docker exec "$DRILL" cockroach sql --insecure --execute "$1" --format=csv 2>/dev/null | tail -n +2 | tr -d '\r'; }

# Сверяемся с манифестом, а не с живым продом. Прод продолжает работать, пока идут
# учения, поэтому сверка с ним показывает расхождение ВСЕГДА — и через полгода на
# него перестают смотреть. Манифест фиксирует числа на момент снятия бэкапа, значит
# совпадение должно быть точным, а любое расхождение — настоящий сигнал.
MKEY=$($AWS s3 ls "s3://$BUCKET/$PREFIX/daily/$DAY/" | awk '/manifest-/ {print $4}' | tail -1)
$AWS s3 cp "s3://$BUCKET/$PREFIX/daily/$DAY/$MKEY" "$TMP/manifest.txt" --only-show-errors
if ! grep -q '^count\.' "$TMP/manifest.txt"; then
  log "в манифесте нет контрольных чисел — бэкап снят старой версией скрипта, сверить не с чем"
  exit 1
fi

log "сверяем с манифестом ($MKEY)"
FAILED=0
while IFS='|' read -r name sql; do
  [ -z "$name" ] && continue
  want="$(grep "^count\.$name=" "$TMP/manifest.txt" | cut -d= -f2)"
  got="$(drill "$sql")"
  if [ "$want" = "$got" ]; then
    echo "  сходится    $name: $got"
  else
    echo "  РАСХОЖДЕНИЕ $name: в манифесте $want, восстановлено $got"
    FAILED=1
  fi
done <<'CHECKS'
workspace|SELECT count(*) FROM global_account.workspace;
account|SELECT count(*) FROM global_account.account;
tx|SELECT count(*) FROM defaultdb.tx;
task|SELECT count(*) FROM defaultdb.task;
github_sync|SELECT count(*) FROM defaultdb.github_sync;
collaborator|SELECT count(*) FROM defaultdb.collaborator;
CHECKS

# Расхождение на живом проде возможно: пока шло восстановление, кто-то работал.
# Значимо не само расхождение, а его размер — на десятки строк это норма,
# на порядки означает, что восстановился не тот бэкап.
if [ "$FAILED" = 0 ]; then
  log "УЧЕНИЯ ПРОЙДЕНЫ: бэкап восстанавливается, числа совпадают с манифестом"
else
  log "УЧЕНИЯ ПРОВАЛЕНЫ: восстановленное не совпало с манифестом — разбираться"
  exit 1
fi
