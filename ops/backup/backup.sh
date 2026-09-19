#!/usr/bin/env bash
#
# HLY-7 — ночной бэкап Huly (erp.inples.ru).
#
# Что кладём:
#   1. Полный логический бэкап кластера CockroachDB (BACKUP INTO nodelocal) —
#      это и ядро всех воркспейсов, и global_account с реестром и пользователями.
#   2. Том MinIO целиком — вложения, аватары, записи созвонов. Блобы неизменяемые,
#      так что tar на живом сервисе безопасен.
#   3. По воскресеньям — логический бэкап каждого воркспейса штатным tool backup.
#      Он переносим: разворачивается в другую инсталляцию Huly и служит страховкой
#      на случай, если формат кластерного бэкапа окажется нечитаемым (HLY-25).
#
# Куда: s3://<bucket>/huly-backup/{daily,weekly,monthly}/<дата>/
# Ротация: 7 ежедневных, 4 еженедельных, 3 ежемесячных.
# При любой ошибке — сообщение в Telegram. Молчащий бэкап незаметно умирает,
# поэтому раз в неделю приходит и сводка об успехе.
#
set -Eeuo pipefail

STACK="compose-reboot-digital-port-j1flk6"
WORK="/opt/huly-backup"
OUT="$WORK/out"
STATE="$WORK/state"
LOG="/var/log/huly-backup.log"

S3_ENDPOINT="https://s3.ru1.storage.beget.cloud"
S3_BUCKET="da52bb93d7ea-edlegal-s3"
S3_PREFIX="huly-backup"
AWS="$WORK/venv/bin/aws"

WORKSPACES=(inpleslts bnlegal danilaq)

# Нижние границы размера: если архив меньше, бэкап считается провалившимся.
MIN_CR_BYTES=$((5 * 1024 * 1024))
MIN_MINIO_BYTES=$((10 * 1024 * 1024))

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DATE="$(date -u +%F)"
DOW="$(date -u +%u)"   # 7 = воскресенье
DOM="$(date -u +%d)"

CR_CONTAINER="${STACK}-cockroach-1"
CR_EXTERN="/var/lib/docker/volumes/${STACK}_cr_data/_data/extern"
MINIO_DATA="/var/lib/docker/volumes/${STACK}_files/_data"
NETWORK="${STACK}_huly_net"

mkdir -p "$OUT" "$STATE"

log() { echo "[$(date -u '+%F %T') UTC] $*" | tee -a "$LOG"; }

notify() {
  local text="$1"
  local token chat
  token="$(docker exec "${STACK}-meetscribe-1" printenv TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  chat="$(docker exec "${STACK}-meetscribe-1" printenv TELEGRAM_CHAT_ID 2>/dev/null || true)"
  if [ -z "$token" ]; then return 0; fi
  curl -sS -m 20 -o /dev/null \
    "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" || true
}

FAILED_STEP="запуск"
on_error() {
  local code=$?
  log "ОШИБКА на шаге: $FAILED_STEP (код $code)"
  notify "$(printf '%s\n' \
    "🔴 <b>Бэкап Huly не прошёл</b>" \
    "Шаг: ${FAILED_STEP}" \
    "Код выхода: ${code}" \
    "Хост: erp.inples.ru" \
    "Лог: ${LOG}")"
  # не оставляем мусор в extern — он лежит внутри тома cockroach
  rm -rf "${CR_EXTERN:?}/run-$TS" 2>/dev/null || true
  exit "$code"
}
trap on_error ERR

# Один экземпляр за раз: прошлый прогон мог зависнуть на выгрузке.
exec 9>"$WORK/.lock"
flock -n 9 || { log "предыдущий прогон ещё идёт, выходим"; exit 0; }

log "=== старт $TS ==="
rm -f "$OUT"/*.tar.gz "$OUT"/manifest-*.txt 2>/dev/null || true

# ── 1. CockroachDB ───────────────────────────────────────────────────────
FAILED_STEP="полный бэкап CockroachDB"
log "CockroachDB: BACKUP INTO nodelocal://1/run-$TS"
CR_URL="$(docker exec "${STACK}-account-1" printenv DB_URL)?sslmode=disable"
docker exec -e U="$CR_URL" "$CR_CONTAINER" bash -lc \
  "cockroach sql --url \"\$U\" --execute \"BACKUP INTO 'nodelocal://1/run-$TS' AS OF SYSTEM TIME '-10s';\"" \
  >>"$LOG" 2>&1

FAILED_STEP="упаковка бэкапа CockroachDB"
tar czf "$OUT/cockroach-$TS.tar.gz" -C "$CR_EXTERN" "run-$TS"
rm -rf "${CR_EXTERN:?}/run-$TS"
CR_SIZE=$(stat -c %s "$OUT/cockroach-$TS.tar.gz")
log "CockroachDB: $((CR_SIZE / 1024 / 1024)) МБ"
[ "$CR_SIZE" -ge "$MIN_CR_BYTES" ] || { FAILED_STEP="бэкап CockroachDB подозрительно мал ($CR_SIZE байт)"; false; }

# ── 2. MinIO ─────────────────────────────────────────────────────────────
FAILED_STEP="упаковка тома MinIO"
log "MinIO: упаковываем $MINIO_DATA"
tar czf "$OUT/minio-$TS.tar.gz" -C "$MINIO_DATA" .
MINIO_SIZE=$(stat -c %s "$OUT/minio-$TS.tar.gz")
log "MinIO: $((MINIO_SIZE / 1024 / 1024)) МБ"
[ "$MINIO_SIZE" -ge "$MIN_MINIO_BYTES" ] || { FAILED_STEP="архив MinIO подозрительно мал ($MINIO_SIZE байт)"; false; }

# ── 3. Логические бэкапы воркспейсов (по воскресеньям) ───────────────────
WS_NOTE="—"
if [ "$DOW" = "7" ]; then
  FAILED_STEP="логический бэкап воркспейсов"
  log "Воркспейсы: логический бэкап (переносимый формат)"
  SECRET="$(docker exec "${STACK}-account-1" printenv SERVER_SECRET)"
  DBU="$(docker exec "${STACK}-account-1" printenv DB_URL)"
  HV="$(docker inspect --format '{{index .Config.Image}}' "${STACK}-account-1" | sed 's/.*://')"
  mkdir -p "$STATE/ws"
  for ws in "${WORKSPACES[@]}"; do
    log "  воркспейс $ws"
    docker run --rm --network "$NETWORK" \
      -e SERVER_SECRET="$SECRET" -e DB_URL="$DBU" -e ACCOUNT_DB_URL="$DBU" \
      -e STORAGE_CONFIG="minio|minio?accessKey=minioadmin&secretKey=minioadmin" \
      -e ACCOUNTS_URL="http://account:3000" -e TRANSACTOR_URL="ws://transactor:3333" \
      -e QUEUE_CONFIG="redpanda:9092" -e STATS_URL="http://stats:4900" \
      -v "$STATE/ws:/backup" \
      "hardcoreeng/tool:${HV}" bundle.js backup "/backup/$ws" "$ws" \
      --blobLimit 200 --keepSnapshots 8 >>"$LOG" 2>&1
  done
  tar czf "$OUT/workspaces-$TS.tar.gz" -C "$STATE" ws
  WS_SIZE=$(stat -c %s "$OUT/workspaces-$TS.tar.gz")
  WS_NOTE="$((WS_SIZE / 1024 / 1024)) МБ"
  log "Воркспейсы: $WS_NOTE"
fi

# ── 4. Манифест ──────────────────────────────────────────────────────────
FAILED_STEP="запись манифеста"
MANIFEST="$OUT/manifest-$TS.txt"
{
  echo "прогон:        $TS"
  echo "хост:          $(hostname) / erp.inples.ru"
  echo "версия Huly:   $(docker inspect --format '{{.Config.Image}}' "${STACK}-account-1")"
  echo "воркспейсы:    ${WORKSPACES[*]}"
  echo ""
  echo "содержимое:"
  ( cd "$OUT" && sha256sum ./*.tar.gz )
} > "$MANIFEST"

# ── 5. Выгрузка ──────────────────────────────────────────────────────────
FAILED_STEP="выгрузка в S3"
DEST="s3://$S3_BUCKET/$S3_PREFIX/daily/$DATE"
log "S3: выгружаем в $DEST"
# Каталог даты должен содержать ровно один прогон: повторный запуск (ретрай после
# сбоя) иначе накапливает архивы, а ротация удаляет каталоги целиком и их не видит.
"$AWS" --endpoint-url "$S3_ENDPOINT" s3 rm "$DEST" --recursive --only-show-errors || true
for f in "$OUT"/*; do
  "$AWS" --endpoint-url "$S3_ENDPOINT" s3 cp "$f" "$DEST/$(basename "$f")" --only-show-errors
done

copy_to() {
  local tier="$1"
  log "S3: копия в $tier/$DATE"
  "$AWS" --endpoint-url "$S3_ENDPOINT" s3 rm "s3://$S3_BUCKET/$S3_PREFIX/$tier/$DATE" \
    --recursive --only-show-errors || true
  "$AWS" --endpoint-url "$S3_ENDPOINT" s3 cp "$DEST" \
    "s3://$S3_BUCKET/$S3_PREFIX/$tier/$DATE" --recursive --only-show-errors
}
if [ "$DOW" = "7" ]; then copy_to weekly; fi
if [ "$DOM" = "01" ]; then copy_to monthly; fi

# ── 6. Ротация ───────────────────────────────────────────────────────────
FAILED_STEP="ротация"
prune() {
  local tier="$1" keep="$2"
  local dirs
  # Пустой ярус — это не ошибка: s3 ls по несуществующему префиксу возвращает 1.
  dirs="$({ "$AWS" --endpoint-url "$S3_ENDPOINT" s3 ls "s3://$S3_BUCKET/$S3_PREFIX/$tier/" || true; } \
    | awk '/PRE/ {print $2}' | sed 's#/$##' | sort)"
  local total
  total="$(echo "$dirs" | grep -c . || true)"
  if [ "$total" -le "$keep" ]; then return 0; fi
  echo "$dirs" | head -n $((total - keep)) | while read -r d; do
    [ -z "$d" ] && continue
    log "  удаляем $tier/$d"
    "$AWS" --endpoint-url "$S3_ENDPOINT" s3 rm "s3://$S3_BUCKET/$S3_PREFIX/$tier/$d" --recursive --only-show-errors
  done
}
prune daily 7
prune weekly 4
prune monthly 3

# Локально держим только последний прогон — S3 основное хранилище.
find "$OUT" -type f -mtime +1 -delete 2>/dev/null || true

log "=== готово: cockroach $((CR_SIZE/1024/1024)) МБ, minio $((MINIO_SIZE/1024/1024)) МБ, воркспейсы $WS_NOTE ==="

if [ "$DOW" = "7" ]; then
  notify "$(printf '%s\n' \
    "🟢 <b>Недельная сводка бэкапов Huly</b>" \
    "CockroachDB: $((CR_SIZE/1024/1024)) МБ" \
    "MinIO: $((MINIO_SIZE/1024/1024)) МБ" \
    "Воркспейсы: ${WS_NOTE}" \
    "Хранится: ${S3_PREFIX}/{daily,weekly,monthly} в ${S3_BUCKET}")"
fi
