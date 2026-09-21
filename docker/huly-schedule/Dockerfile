# Публичная страница записи на встречу с одной заплаткой.
#
# Проблема: в hardcoreeng/huly-schedule клиент транзактора берёт автора
# транзакции как account.socialIds[0]. Бронирование ходит в транзактор под
# системным аккаунтом, а у него в нашей инсталляции socialIds пустой —
# /api/v1/account отдаёт {"socialIds":[], "primarySocialId":"core:account:System"}.
# В результате транзакция уходит без modifiedBy, NormalizeTxMiddleware отбивает
# её как BadRequest, и бронь падает на создании персоны гостя. В интерфейсе это
# видно как «An error occurred while booking the meeting», в логе сервиса —
# Internal Server Error без подробностей.
#
# Заплатка подставляет primarySocialId, когда список пуст. Транзактор такой
# modifiedBy принимает — проверено отдельным запросом. Строка одинаковая и в
# v0.7.426, и в свежем s0.7.437, так что само обновление образа не поможет:
# в облаке у системного аккаунта, судя по всему, соц-идентификатор есть.
#
# Сборка ничего не компилирует — это FROM плюс sed, поэтому её не страшно
# делать на боевом хосте (запрет на сборку на проде касается тяжёлых сборок
# приложений, из-за которых 05.09.2026 хост ушёл в OOM).
ARG HULY_VERSION=v0.7.426
FROM hardcoreeng/huly-schedule:${HULY_VERSION}

RUN set -eu; \
    target=$(grep -rl 'account.socialIds\[0\]' /app/dist/server/chunks); \
    test -n "$target"; \
    sed -i 's/account\.socialIds\[0\]/(account.socialIds[0] ?? account.primarySocialId)/g' $target; \
    grep -q 'account.primarySocialId)' $target
