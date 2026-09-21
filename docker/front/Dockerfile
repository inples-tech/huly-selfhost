# Фронт со встроенным брендингом.
#
# Файлы брендинга раньше подкладывались bind-монтированием каталога ./branding.
# Это ломалось при каждом деплое, который не пересоздаёт контейнер фронта:
# Dokploy перевыкладывает репозиторий заново, каталог получает новый inode,
# а монтирование контейнера остаётся на старом — удалённом. Внутри каталог
# пустой, /branding/branding.json отдаёт SPA-фолбэк, то есть HTML.
#
# Дальше рвётся весь интерфейс: код загрузки делает
#   (await fetch(BRANDING_URL)).json()
# без обработки ошибки, исключение убивает инициализацию, и пользователь видит
# белый экран. Симптом в консоли — «Unexpected token '<', "<!doctype "... is not
# valid JSON». Ровно те же грабли с inode описаны у нас для nginx.
#
# Поэтому файлы вкладываются в образ на сборке: монтировать больше нечего,
# ломаться нечему. Сборка — только COPY, ничего не компилируется.
ARG HULY_VERSION=v0.7.426
FROM hardcoreeng/front:${HULY_VERSION}

COPY branding /app/dist/branding

RUN test -s /app/dist/branding/branding.json && test -s /app/dist/branding/icon-192.png

# Подключаем таблицу стилей, которая подменяет знак Huly нашим логотипом.
# Почему именно так — в комментарии внутри branding/brand.css.
# Проверка обязательна: если разметка index.html изменится и вставка не
# сработает, сборка должна упасть, а не выкатить фронт без брендинга.
RUN set -eu; \
    sed -i 's|</head>|<link rel="stylesheet" href="/branding/brand.css"></head>|' /app/dist/index.html; \
    grep -q 'branding/brand.css' /app/dist/index.html
