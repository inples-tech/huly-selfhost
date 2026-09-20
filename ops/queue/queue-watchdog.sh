#!/usr/bin/env bash
#
# HLY-5 — сторож очереди.
#
# Ожидание брокера в команде запуска (d47c4e8) закрывает причину: после
# перезагрузки сервис не стартует, пока redpanda не ответит. Но не закрывает все
# пути в то же состояние — брокер может упасть и подняться уже после того, как
# потребитель подключился.
#
# Беда этого отказа в том, что он молчит: kafkajs сдаётся после пяти попыток
# навсегда, а сервис продолжает работать и выглядит здоровым — порт слушает,
# healthcheck зелёный. 18.09.2026 так неделями молчал telegram-bot.
#
# Признак берём из rpk, а не из логов. Две первые версии сторожа искали в логе
# "ENOTFOUND redpanda" и дважды дали ложную тревогу по fulltext: сервис
# спотыкается на старте, переподключается и про это НЕ пишет. Состояние группы
# потребителей — это факт на брокере, а не то, что сервис решил залогировать.
#
# Сам ничего не чинит: лечение — docker restart, решение о перезапуске боевого
# сервиса остаётся за человеком.
#
set -Eeuo pipefail

STACK="${STACK:-compose-reboot-digital-port-j1flk6}"
BASELINE=/opt/huly-backup/queue-baseline.txt
LOG=/var/log/huly-queue-watchdog.log

log() { echo "[$(date -u '+%F %T') UTC] $*" | tee -a "$LOG"; }

notify() {
  local token chat
  token="$(docker exec "${STACK}-meetscribe-1" printenv TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  chat="$(docker exec "${STACK}-meetscribe-1" printenv TELEGRAM_CHAT_ID 2>/dev/null || true)"
  if [ -z "$token" ]; then return 0; fi
  curl -sS -m 20 -o /dev/null "https://api.telegram.org/bot${token}/sendMessage" \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" \
    --data-urlencode "parse_mode=HTML" || true
}

# Huly заводит временные группы под конкретные воркспейсы (workspace-<24 hex>).
# Они законно появляются и исчезают, следить за ними — значит получать шум.
# Постоянные группы сервисов такого вида не имеют.
is_permanent() { ! [[ "$1" =~ ^workspace-[0-9a-f]{24}$ ]]; }

RPK="$(docker exec "${STACK}-redpanda-1" rpk group list 2>/dev/null | tail -n +2 || true)"
if [ -z "$RPK" ]; then
  log "БРОКЕР НЕ ОТВЕЧАЕТ: rpk не отдал список групп"
  notify "$(printf '%s\n' "🔴 <b>Huly: брокер очереди не отвечает</b>" "" \
    "<code>rpk group list</code> на redpanda не вернул ничего." \
    "Без очереди встанут индексация, уведомления и синхронизация с GitHub.")"
  exit 1
fi

declare -A STATE
while read -r _broker group state; do
  [ -z "${group:-}" ] && continue
  STATE["$group"]="$state"
done <<< "$RPK"

touch "$BASELINE"
MISSING=(); EMPTY=()
while read -r g; do
  [ -z "$g" ] && continue
  case "${STATE[$g]:-ОТСУТСТВУЕТ}" in
    Stable) ;;
    ОТСУТСТВУЕТ) MISSING+=("$g") ;;
    *)           EMPTY+=("$g (${STATE[$g]})") ;;
  esac
done < "$BASELINE"

# Новые постоянные группы запоминаем: сегодняшняя норма — завтрашний эталон.
ADDED=0
for g in "${!STATE[@]}"; do
  if [ "${STATE[$g]}" = "Stable" ] && is_permanent "$g" && ! grep -qxF "$g" "$BASELINE"; then
    echo "$g" >> "$BASELINE"; log "  запомнили группу: $g"; ADDED=$((ADDED+1))
  fi
done

log "групп в эталоне: $(grep -c . "$BASELINE"), новых: $ADDED, пропало: ${#MISSING[@]}, без потребителей: ${#EMPTY[@]}"

if [ ${#MISSING[@]} -eq 0 ] && [ ${#EMPTY[@]} -eq 0 ]; then
  log "очередь в порядке"
  exit 0
fi

log "ПРОБЛЕМА: пропали [${MISSING[*]-}] без потребителей [${EMPTY[*]-}]"
notify "$(printf '%s\n' \
  "🔴 <b>Huly: сервисы отвалились от очереди</b>" "" \
  "Группы без потребителей: <b>${EMPTY[*]-—}</b>" \
  "Группы пропали совсем: <b>${MISSING[*]-—}</b>" "" \
  "Сервисы при этом работают и выглядят здоровыми, но события не обрабатывают." \
  "Лечится перезапуском затронутого контейнера, например:" \
  "<code>docker restart ${STACK}-fulltext-1</code>" "" \
  "Состояние групп сейчас:" "<pre>${RPK}</pre>")"
exit 1
