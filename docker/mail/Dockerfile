# Шлюз исходящей почты с одной заплаткой.
#
# Проблема: hardcoreeng/mail сверяет ключ только с полем apiKey в теле запроса,
# а account (приглашения в workspace, коды входа, сброс пароля) шлёт тот же
# MAIL_AUTH_TOKEN заголовком Authorization: Bearer, поля apiKey в теле у него
# нет. Транзактор в части вызовов кладёт ключ в тело, поэтому уведомления
# доходят, а все письма account с 18.09.2026 отбиваются 401 «Unauthorized
# access attempt to send email». В логе account при этом рядом стоит
# «Invite has been sent», и в интерфейсе приглашение выглядит отправленным.
#
# Заплатка: если apiKey в теле нет, ключ берётся из заголовка Authorization
# (без префикса «Bearer »). Сравнение с API_KEY остаётся строгим: без ключа и
# с неверным ключом по-прежнему 401. Проверено на v0.7.426 одноразовым
# контейнером: Bearer верный и apiKey верный проходят проверку, Bearer
# неверный и пустой запрос получают 401.
#
# Сборка — FROM плюс sed, ничего не компилирует (как docker/huly-schedule).
ARG HULY_VERSION=v0.7.426
FROM hardcoreeng/mail:${HULY_VERSION}

RUN set -eu; \
    f=/usr/src/app/bundle.js; \
    test "$(grep -c 'process.env.API_KEY !== apiKey)' $f)" = 1; \
    sed -i 's|process.env.API_KEY !== apiKey)|process.env.API_KEY !== (apiKey ?? String(req.headers.authorization ?? "").replace("Bearer ", "")))|' $f; \
    grep -q 'req.headers.authorization ?? "").replace("Bearer ", "")' $f; \
    node --check $f
