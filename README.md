# TransferHub

TransferHub — это автоматизированная установка и обслуживание NaiveProxy-сервера на Debian 12/13.

Проект поднимает прокси-сервер с TLS, маскировкой под обычный сайт и простым runtime-меню для повседневного управления.

## Что делает проект

- устанавливает и настраивает NaiveProxy-сервер
- получает TLS-сертификат для домена
- поднимает сервис в `systemd`
- настраивает базовый файрвол
- генерирует данные подключения
- показывает URL и QR-код для клиента
- даёт простое меню управления после установки
- умеет экспортировать и импортировать настройки инстанса

## Требования

- Debian 12 или 13
- root-доступ
- свободные порты `80` и `443`
- домен, который указывает на IP VPS

## Установка

Боевой сертификат:

```bash
bash <(wget -qO- "https://raw.githubusercontent.com/denash-git/TransferHub/dev/bootstrap.sh")
```

Тестовый сертификат Let's Encrypt staging:

```bash
bash <(wget -qO- "https://raw.githubusercontent.com/denash-git/TransferHub/dev/bootstrap.sh") --staging
```

Можно использовать `curl` вместо `wget`:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/denash-git/TransferHub/dev/bootstrap.sh")
```

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/denash-git/TransferHub/dev/bootstrap.sh") --staging
```

Установка конкретной ветки, например `dev2`:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/denash-git/TransferHub/dev2/bootstrap.sh") --branch dev2
```


## Что спросит установщик

Установщик спрашивает только:

- домен
- email для TLS-сертификата
- включать ли BBR

## Что вы получите после установки

- команду `menu` для управления сервером
- URL подключения в формате `naive+https://user:password@domain:443`
- QR-код для импорта в клиент

## Управление

После установки открой:

```bash
menu
```

В меню доступны:

- управление Caddy и сервисом
- статус TLS и перевыпуск боевого сертификата
- смена логина и пароля
- показ URL и QR-кода
- управление BBR
- тест скорости `VPS → Internet`
- тест скорости `Client ↔ VPS` через временную HTTPS-ссылку
- экспорт и импорт настроек

## Экспорт и импорт настроек

Проект умеет переносить настройки инстанса между установками.

Экспорт сохраняет:

- домен
- email
- логин
- пароль
- режим сертификата
- выбранный шаблон сайта
- настройку BBR

Это удобно для повторного развёртывания на новой машине с теми же данными доступа.
