# TransferHub

TransferHub — автоматизированная установка и обслуживание NaiveProxy-сервера на Debian 12/13.

Проект поднимает прокси-сервер с TLS, маскировкой под обычный сайт и простым меню для повседневного управления.

## Что делает проект

- устанавливает и настраивает NaiveProxy-сервер
- получает TLS-сертификат для домена
- поднимает сервис в `systemd`
- настраивает базовый файрвол
- генерирует данные подключения
- показывает URL и QR-код для клиента
- даёт простое меню управления после установки

## Требования

- Debian 12 или 13
- root-доступ
- свободные порты `80` и `443`
- домен, который указывает на IP VPS

## Установка

Рекомендуемая установка с `curl`:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/denash-git/TransferHub/main/bootstrap.sh")
```

Тестовый сертификат Let's Encrypt staging:

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/denash-git/TransferHub/main/bootstrap.sh") --staging
```

Если удобнее, можно использовать `wget`:

```bash
bash <(wget -qO- "https://raw.githubusercontent.com/denash-git/TransferHub/main/bootstrap.sh")
```

```bash
bash <(wget -qO- "https://raw.githubusercontent.com/denash-git/TransferHub/main/bootstrap.sh") --staging
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
- готовый сервер с TLS и маскировкой под обычный сайт

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
- раздел `Бекап`
- тест скорости `VPS → Internet`
- тест скорости `Client ↔ VPS` через временную HTTPS-ссылку
