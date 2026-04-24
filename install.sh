#!/usr/bin/env bash
# =============================================================================
# TransferHub — Установщик NaiveProxy
# =============================================================================
# Поддерживаемые ОС: Debian 12, Debian 13
# Запуск: sudo bash install.sh
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Цвета и форматирование
# -----------------------------------------------------------------------------
BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# Пути
# -----------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ENV="$PROJECT_ROOT/instance.env"
CADDY_BIN="/usr/local/bin/caddy"
CADDY_SERVICE="/etc/systemd/system/transferhub-caddy.service"
MENU_BIN="/usr/local/bin/menu"
CADDY_CONFIG_DIR="$PROJECT_ROOT/caddy"
FAKESITE_DIR="$CADDY_CONFIG_DIR/fakesite"
INSTALL_LOG="$PROJECT_ROOT/.install.log"
RENDER_CADDY_SCRIPT="${PROJECT_ROOT}/runtime/render-caddy.sh"
USERS_DB="${PROJECT_ROOT}/users.db"
BACKUP_DIR="${PROJECT_ROOT}/backup"
SPEEDTEST_SERVICE="/etc/systemd/system/transferhub-speedtest.service"
CERT_MODE="prod"
DOMAIN_DISPLAY=""

# Версия Go для сборки xcaddy (обновляй при необходимости)
DEFAULT_GO_VERSION="1.26.2"
TOTAL_STEPS=10
BUILD_TMP_ROOT="/root/tmp"

# -----------------------------------------------------------------------------
# Вспомогательные функции вывода
# -----------------------------------------------------------------------------
step()    { echo -e "\n${BLUE}[${1}/${TOTAL_STEPS}] ${2}${RESET}"; }
log_ok()  { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_info(){ echo -e "  ${DIM}* ${1}${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠ ${1}${RESET}"; }
error()   { fail_current_step; echo -e "\n${RED}✗ ОШИБКА: ${1}${RESET}" >&2; exit 1; }
clear_screen() { printf '\033c'; }

cert_mode_label() {
    case "${CERT_MODE}" in
        staging) echo "Let's Encrypt staging (тестовый)" ;;
        *)       echo "Let's Encrypt production (боевой)" ;;
    esac
}

init_progress_steps() { :; }
complete_current_step() { :; }
fail_current_step() { :; }

run_logged() {
    local title="$1"
    shift
    if "$@" >>"$INSTALL_LOG" 2>&1; then
        return 0
    fi
    fail_current_step
    warn "Подробности сохранены в ${INSTALL_LOG}"
    tail -n 20 "$INSTALL_LOG" | sed 's/^/    /' >&2 || true
    error "${title}"
}

generate_safe_password() {
    openssl rand -hex 12
}

generate_safe_login() {
    openssl rand -hex 8 | cut -c1-9
}

generate_speedtest_prefix() {
    openssl rand -hex 4
}

detect_go_version() {
    local version=""
    version=$(curl -fsSL --max-time 10 "https://go.dev/VERSION?m=text" 2>/dev/null | head -n 1 || true)
    if [[ "$version" =~ ^go([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$DEFAULT_GO_VERSION"
}

pick_fake_site_template() {
    case $(( RANDOM % 3 )) in
        1) echo "meridian" ;;
        2) echo "northcraft" ;;
        *) echo "techvision" ;;
    esac
}

validate_credential() {
    local label="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        error "${label} не может быть пустым"
    fi
    if [[ ! "$value" =~ ^[A-Za-z0-9._~-]+$ ]]; then
        error "${label} содержит недопустимые символы. Разрешены только A-Z, a-z, 0-9, ., _, ~ и -"
    fi
}

validate_nickname() {
    local nickname="$1"
    if [[ -z "$nickname" ]]; then
        error "Ник пользователя не может быть пустым"
    fi
    if [[ "$nickname" == *$'\t'* || "$nickname" == *$'\n'* || "$nickname" == *$'\r'* ]]; then
        error "Ник пользователя не должен содержать табы и переводы строки"
    fi
}

normalize_link_label() {
    local value="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY'
import re
import sys

value = sys.argv[1]
mapping = {
    'А': 'A', 'а': 'a', 'Б': 'B', 'б': 'b', 'В': 'V', 'в': 'v',
    'Г': 'G', 'г': 'g', 'Д': 'D', 'д': 'd', 'Е': 'E', 'е': 'e',
    'Ё': 'Yo', 'ё': 'yo', 'Ж': 'Zh', 'ж': 'zh', 'З': 'Z', 'з': 'z',
    'И': 'I', 'и': 'i', 'Й': 'Y', 'й': 'y', 'К': 'K', 'к': 'k',
    'Л': 'L', 'л': 'l', 'М': 'M', 'м': 'm', 'Н': 'N', 'н': 'n',
    'О': 'O', 'о': 'o', 'П': 'P', 'п': 'p', 'Р': 'R', 'р': 'r',
    'С': 'S', 'с': 's', 'Т': 'T', 'т': 't', 'У': 'U', 'у': 'u',
    'Ф': 'F', 'ф': 'f', 'Х': 'Kh', 'х': 'kh', 'Ц': 'Ts', 'ц': 'ts',
    'Ч': 'Ch', 'ч': 'ch', 'Ш': 'Sh', 'ш': 'sh', 'Щ': 'Sch', 'щ': 'sch',
    'Ъ': '', 'ъ': '', 'Ы': 'Y', 'ы': 'y', 'Ь': '', 'ь': '',
    'Э': 'E', 'э': 'e', 'Ю': 'Yu', 'ю': 'yu', 'Я': 'Ya', 'я': 'ya',
}

result = ''.join(mapping.get(ch, ch) for ch in value)
result = re.sub(r'\s+', '_', result)
result = re.sub(r'[^A-Za-z0-9._-]', '', result)
result = re.sub(r'_+', '_', result)
result = result.strip('._-')
print(result)
PY
        return 0
    fi
    printf '%s' "$value" | LC_ALL=C sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9._-]//g; s/__*/_/g; s/^[._-]*//; s/[._-]*$//'
}

build_naive_url() {
    local login="$1"
    local password="$2"
    local nickname="${3:-}"
    local url="naive+https://${login}:${password}@${DOMAIN}:443"
    local label=""

    if [[ -n "$nickname" ]]; then
        label=$(normalize_link_label "$nickname")
    fi
    if [[ -z "$label" ]]; then
        label=$(normalize_link_label "$login")
    fi
    if [[ -n "$label" ]]; then
        url+="#${label}"
    fi

    printf '%s' "$url"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --staging) CERT_MODE="staging" ;;
            --prod)    CERT_MODE="prod" ;;
            *)         error "Неизвестный аргумент: $1" ;;
        esac
        shift
    done
}

banner() {
    local width=60
    echo -e "\n${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    printf "${BLUE}%-${width}s${RESET}\n" "  TransferHub — Установщик NaiveProxy"
    printf "${DIM}%-${width}s${RESET}\n" "  Проект: github.com/denash-git/TransferHub"
    printf "${DIM}%-${width}s${RESET}\n" "  Сертификат: ${CERT_MODE} — $(cert_mode_label)"
    if [[ -n "${DOMAIN_DISPLAY:-}" ]]; then
        printf "${DIM}%-${width}s${RESET}\n" "  Домен: ${DOMAIN_DISPLAY}"
    fi
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}\n"
}

has_complete_instance_env() {
    [[ -f "$INSTANCE_ENV" ]] || return 1
    grep -q '^DOMAIN=' "$INSTANCE_ENV" || return 1
    grep -q '^FAKE_SITE_TEMPLATE=' "$INSTANCE_ENV" || return 1
    grep -q '^SPEEDTEST_PREFIX=' "$INSTANCE_ENV" || return 1
    [[ -f "$USERS_DB" ]] || return 1
}

sync_cert_mode_to_instance_env() {
    if grep -q '^CERT_MODE=' "$INSTANCE_ENV" 2>/dev/null; then
        sed -i "s/^CERT_MODE=.*/CERT_MODE=${CERT_MODE}/" "$INSTANCE_ENV"
    else
        printf '\n# Режим сертификата\nCERT_MODE=%s\n' "$CERT_MODE" >> "$INSTANCE_ENV"
    fi
    chmod 600 "$INSTANCE_ENV"
}

ensure_speedtest_prefix_in_instance_env() {
    local prefix=""
    prefix=$(awk -F '=' '/^SPEEDTEST_PREFIX=/{print $2; exit}' "$INSTANCE_ENV" 2>/dev/null || true)
    if [[ "$prefix" =~ ^[a-f0-9]{8}$ ]]; then
        return 0
    fi

    prefix=$(generate_speedtest_prefix)
    if grep -q '^SPEEDTEST_PREFIX=' "$INSTANCE_ENV" 2>/dev/null; then
        sed -i "s/^SPEEDTEST_PREFIX=.*/SPEEDTEST_PREFIX=${prefix}/" "$INSTANCE_ENV"
    else
        printf '\n# Префикс speedtest-ссылок\nSPEEDTEST_PREFIX=%s\n' "$prefix" >> "$INSTANCE_ENV"
    fi
    chmod 600 "$INSTANCE_ENV"
}

# -----------------------------------------------------------------------------
# Preflight проверки
# -----------------------------------------------------------------------------
check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "Установщик должен запускаться от root. Используй: sudo bash install.sh"
    fi
    log_ok "Запуск от root"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Файл /etc/os-release не найден. Поддерживается только Debian 12/13"
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        error "Неподдерживаемая ОС: ${PRETTY_NAME:-unknown}. Требуется Debian 12 или 13"
    fi
    local ver="${VERSION_ID:-0}"
    if [[ "$ver" -lt 12 ]]; then
        error "Требуется Debian версии 12 или выше. Текущая: ${ver}"
    fi
    log_ok "ОС: ${PRETTY_NAME}"
}

check_ports() {
    local port
    for port in 80 443; do
        if ss -tlnp "( sport = :${port} )" 2>/dev/null | grep -q LISTEN; then
            if systemctl is-active transferhub-caddy --quiet 2>/dev/null; then
                log_info "Порт ${port} уже занят сервисом TransferHub — продолжаю доустановку"
                continue
            fi
            error "Порт ${port} уже занят сторонним процессом. Освободи его перед установкой"
        fi
        log_ok "Порт ${port} свободен"
    done
}

check_domain() {
    local domain="$1"
    if [[ -z "$domain" || "$domain" == "example.com" ]]; then
        return 0
    fi
    log_info "Проверяем DNS для домена ${domain}..."
    if ! getent hosts "$domain" &>/dev/null; then
        error "Домен ${domain} не резолвится. Настрой DNS A-запись на IP этого сервера"
    fi
    local resolved_ip
    resolved_ip=$(getent hosts "$domain" | awk '{print $1}' | head -1)
    # Получаем наш внешний IP
    local server_ip
    server_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || ip route get 1 | awk '{print $7}' | head -1)
    if [[ -n "$server_ip" && "$resolved_ip" != "$server_ip" ]]; then
        warn "Домен ${domain} указывает на ${resolved_ip}, а IP сервера: ${server_ip}"
        warn "TLS сертификат может не выдаться. Продолжаем..."
    else
        log_ok "Домен ${domain} → ${resolved_ip}"
    fi
}

# -----------------------------------------------------------------------------
# Wizard — интерактивный ввод настроек
# -----------------------------------------------------------------------------
run_wizard() {
    echo -e "${YELLOW}Настройка TransferHub${RESET}\n"

    # Домен
    local domain=""
    while [[ -z "$domain" ]]; do
        read -rp "  Домен (например: proxy.example.com): " domain
        domain="${domain// /}"
        if [[ -z "$domain" ]]; then
            echo -e "  ${RED}Домен не может быть пустым${RESET}"
        fi
    done

    # Email для Let's Encrypt
    local email=""
    read -rp "  Email для Let's Encrypt (можно пустой): " email
    email="${email// /}"

    # Логин
    local naive_user
    naive_user=$(generate_safe_login)
    validate_credential "Логин" "$naive_user"
    log_info "Логин NaiveProxy сгенерирован автоматически: ${naive_user}"

    # Пароль (генерируем случайный)
    local naive_pass
    naive_pass=$(generate_safe_password)
    log_info "Пароль сгенерирован автоматически (можно сменить в меню)"
    validate_credential "Пароль" "$naive_pass"
    local naive_nick="main"
    validate_nickname "$naive_nick"

    # Фейковый сайт
    FAKE_SITE_TEMPLATE=$(pick_fake_site_template)
    log_info "Шаблон фейкового сайта выбран автоматически: ${FAKE_SITE_TEMPLATE}"

    # BBR
    local enable_bbr="true"
    read -rp "  Включить BBR (TCP оптимизация трафика)? [Y/n]: " bbr_input
    [[ "${bbr_input,,}" == "n" ]] && enable_bbr="false"

    # Запись instance.env
    cat > "$INSTANCE_ENV" <<EOF
# TransferHub — конфиг инстанса
# Создан: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Домен и TLS
DOMAIN=${domain}
ADMIN_EMAIL=${email}

# Режим сертификата: prod | staging
CERT_MODE=${CERT_MODE}

# Шаблон фейкового сайта
FAKE_SITE_TEMPLATE=${FAKE_SITE_TEMPLATE}

# BBR TCP оптимизация
ENABLE_BBR=${enable_bbr}

# Префикс speedtest-ссылок
SPEEDTEST_PREFIX=$(generate_speedtest_prefix)

# Дата установки
INSTALL_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    chmod 600 "$INSTANCE_ENV"
    printf '%s\t%s\t%s\t%s\n' "$naive_nick" "$naive_user" "$naive_pass" "1" > "$USERS_DB"
    chmod 600 "$USERS_DB"
    log_ok "Конфиг сохранён в instance.env"
    log_ok "Стартовый пользователь создан"
}

ensure_instance_env() {
    if has_complete_instance_env; then
        sync_cert_mode_to_instance_env
        ensure_speedtest_prefix_in_instance_env
        log_ok "Найден существующий instance.env — использую сохранённые настройки"
        return 0
    fi

    if [[ -f "$INSTANCE_ENV" ]]; then
        warn "Найден неполный instance.env — он будет перезаписан"
    fi

    run_wizard
    sync_cert_mode_to_instance_env
    ensure_speedtest_prefix_in_instance_env
}

# -----------------------------------------------------------------------------
# Системные пакеты
# -----------------------------------------------------------------------------
install_packages() {
    export DEBIAN_FRONTEND=noninteractive

    log_info "Обновление списка пакетов..."
    run_logged "Не удалось выполнить apt-get update" \
        apt-get update -qq -o Dpkg::Use-Pty=0 -o APT::Color=0

    log_info "Обновление установленных пакетов..."
    run_logged "Не удалось выполнить apt-get upgrade" \
        apt-get upgrade -y -qq -o Dpkg::Use-Pty=0 -o APT::Color=0

    log_info "Установка базовых пакетов..."
    run_logged "Не удалось установить системные пакеты" \
        apt-get install -y -qq -o Dpkg::Use-Pty=0 -o APT::Color=0 \
        build-essential \
        curl wget git ca-certificates \
        python3 \
        ufw openssl \
        qrencode jq \
        gettext-base \
        speedtest-cli \
        net-tools iproute2

    log_ok "Системные пакеты установлены"
}

# -----------------------------------------------------------------------------
# Настройка UFW
# -----------------------------------------------------------------------------
setup_ufw() {
    log_info "Настройка правил UFW..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp comment 'SSH' >/dev/null
    ufw allow 80/tcp comment 'HTTP (ACME challenge)' >/dev/null
    ufw allow 443/tcp comment 'HTTPS NaiveProxy' >/dev/null
    ufw --force enable >/dev/null
    log_ok "UFW настроен: входящий трафик разрешён только для 22, 80, 443"
}

# -----------------------------------------------------------------------------
# BBR TCP оптимизация
# -----------------------------------------------------------------------------
apply_bbr() {
    # Проверяем поддержку ядра
    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "Модуль tcp_bbr недоступен в данном ядре, BBR пропускается"
        return 0
    fi

    # Применяем настройки
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    # Делаем постоянными
    local sysctl_file="/etc/sysctl.d/99-transferhub-bbr.conf"
    cat > "$sysctl_file" <<'EOF'
# TransferHub — BBR TCP оптимизация
# BBR (Bottleneck Bandwidth and RTT) — алгоритм управления перегрузкой от Google
# Заметно улучшает пропускную способность на высоколатентных каналах
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p "$sysctl_file" >/dev/null 2>&1 || true

    local active_cc
    active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    log_ok "BBR активирован (текущий алгоритм: ${active_cc})"
}

# Отключение BBR
disable_bbr() {
    rm -f /etc/sysctl.d/99-transferhub-bbr.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    # Обновляем instance.env
    sed -i 's/^ENABLE_BBR=.*/ENABLE_BBR=false/' "$INSTANCE_ENV"
    log_ok "BBR отключён, используется cubic"
}

# -----------------------------------------------------------------------------
# Сборка Caddy с naive forwardproxy через xcaddy
# -----------------------------------------------------------------------------
build_caddy() {
    # Определяем архитектуру
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    local go_arch
    case "$arch" in
        amd64|x86_64) go_arch="amd64";;
        arm64|aarch64) go_arch="arm64";;
        *) error "Неподдерживаемая архитектура: ${arch}";;
    esac

    # Если Caddy уже собран и версия совпадает — пропускаем
    if [[ -x "$CADDY_BIN" ]]; then
        local existing_ver
        existing_ver=$("$CADDY_BIN" version 2>/dev/null | head -1 || echo "")
        if [[ -n "$existing_ver" ]]; then
            log_ok "Caddy уже установлен: ${existing_ver}"
            # Проверяем наличие naive плагина
            if "$CADDY_BIN" list-modules 2>/dev/null | grep "http.handlers.forward_proxy" >/dev/null; then
                log_ok "Плагин naive forwardproxy присутствует"
                return 0
            fi
            warn "Плагин naive не найден в существующем Caddy — пересобираем"
        fi
    fi

    log_info "Подготовка временного каталога для сборки..."
    mkdir -p "$BUILD_TMP_ROOT"
    chmod 700 "$BUILD_TMP_ROOT"
    export TMPDIR="$BUILD_TMP_ROOT"
    log_info "TMPDIR=${TMPDIR}"

    log_info "Создание временной рабочей директории..."
    local tmpdir
    tmpdir=$(mktemp -d -p "$TMPDIR" caddy-build-XXXXXX)
    local go_version
    go_version=$(detect_go_version)
    local go_url_primary="https://go.dev/dl/go${go_version}.linux-${go_arch}.tar.gz"
    local go_url_fallback="https://dl.google.com/go/go${go_version}.linux-${go_arch}.tar.gz"
    log_info "Скачивание Go ${go_version} для ${go_arch}..."
    if ! curl -fsSL --retry 2 --connect-timeout 15 --progress-bar \
        "$go_url_primary" -o "${tmpdir}/go.tar.gz" 2>>"$INSTALL_LOG"; then
        warn "Не удалось скачать Go с ${go_url_primary}, пробую резервный адрес..."
        if ! curl -fsSL --retry 2 --connect-timeout 15 --progress-bar \
            "$go_url_fallback" -o "${tmpdir}/go.tar.gz" 2>>"$INSTALL_LOG"; then
            error "Не удалось скачать Go ни с ${go_url_primary}, ни с ${go_url_fallback}"
        fi
    fi

    log_info "Распаковка Go..."
    if ! tar -xzf "${tmpdir}/go.tar.gz" -C "$tmpdir"; then
        error "Ошибка распаковки Go"
    fi

    export GOROOT="${tmpdir}/go"
    export GOPATH="${tmpdir}/gopath"
    export GOBIN="${tmpdir}/bin"
    export GOCACHE="${tmpdir}/gocache"
    export GOTMPDIR="${tmpdir}/gotmp"
    export PATH="${GOBIN}:${GOROOT}/bin:${PATH}"
    mkdir -p "$GOPATH" "$GOBIN" "$GOCACHE" "$GOTMPDIR"

    log_info "Установка xcaddy..."
    run_logged "Не удалось установить xcaddy" \
        go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

    log_info "Сборка Caddy с github.com/klzgrad/forwardproxy@naive..."
    run_logged "Не удалось собрать Caddy через xcaddy" \
        xcaddy build \
        --output "${tmpdir}/caddy" \
        --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive

    if [[ ! -f "${tmpdir}/caddy" ]]; then
        error "После сборки не найден бинарник Caddy"
    fi

    log_info "Установка бинарника..."
    cp "${tmpdir}/caddy" "$CADDY_BIN"
    chmod 755 "$CADDY_BIN"

    local caddy_ver
    caddy_ver=$("$CADDY_BIN" version 2>/dev/null | head -1)
    log_ok "Caddy собран и установлен: ${caddy_ver}"

    rm -rf "$tmpdir"
    log_ok "Временные файлы Go удалены"
}

# -----------------------------------------------------------------------------
# Рендер Caddyfile из шаблона
# -----------------------------------------------------------------------------
render_configs() {
    # Загружаем переменные из instance.env
    # shellcheck source=/dev/null
    set -a; source "$INSTANCE_ENV"; set +a

    if [[ ! -f "$RENDER_CADDY_SCRIPT" ]]; then
        error "Скрипт рендера Caddyfile не найден: ${RENDER_CADDY_SCRIPT}"
    fi
    bash "$RENDER_CADDY_SCRIPT"
    log_ok "Caddyfile создан: ${CADDY_CONFIG_DIR}/Caddyfile"

    # Копируем фейковый сайт
    local fake_src="${PROJECT_ROOT}/templates/fakesite/${FAKE_SITE_TEMPLATE}"
    if [[ ! -d "$fake_src" ]]; then
        warn "Шаблон фейкового сайта '${FAKE_SITE_TEMPLATE}' не найден, использую 'techvision'"
        fake_src="${PROJECT_ROOT}/templates/fakesite/techvision"
    fi

    if [[ -d "$fake_src" ]]; then
        mkdir -p "$FAKESITE_DIR"
        cp -r "${fake_src}/." "$FAKESITE_DIR/"
        log_ok "Фейковый сайт скопирован: ${FAKE_SITE_TEMPLATE}"
    else
        error "Ни один шаблон фейкового сайта не найден в ${PROJECT_ROOT}/templates/fakesite/"
    fi
}

# -----------------------------------------------------------------------------
# systemd сервис для Caddy
# -----------------------------------------------------------------------------
install_caddy_service() {
    cat > "$CADDY_SERVICE" <<EOF
[Unit]
Description=TransferHub — Caddy NaiveProxy
Documentation=https://github.com/denash-git/TransferHub
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=${CADDY_BIN} run --config ${CADDY_CONFIG_DIR}/Caddyfile --environ
ExecReload=${CADDY_BIN} reload --config ${CADDY_CONFIG_DIR}/Caddyfile --force
ExecStop=${CADDY_BIN} stop
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable transferhub-caddy >/dev/null 2>&1
    systemctl start transferhub-caddy

    log_ok "Сервис transferhub-caddy запущен и добавлен в автозагрузку"
}

install_speedtest_service() {
    cat > "$SPEEDTEST_SERVICE" <<EOF
[Unit]
Description=TransferHub LibreSpeed backend
Documentation=https://github.com/denash-git/TransferHub
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=simple
WorkingDirectory=${PROJECT_ROOT}
ExecStart=/usr/bin/env python3 ${PROJECT_ROOT}/runtime/librespeed_server.py
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable transferhub-speedtest >/dev/null 2>&1
    systemctl restart transferhub-speedtest

    log_ok "Сервис transferhub-speedtest запущен и добавлен в автозагрузку"
}

# -----------------------------------------------------------------------------
# Ожидание TLS сертификата
# -----------------------------------------------------------------------------
wait_for_tls() {
    # shellcheck source=/dev/null
    set -a; source "$INSTANCE_ENV"; set +a

    log_info "Ожидание выдачи TLS сертификата для ${DOMAIN}..."
    log_info "(Caddy автоматически запрашивает сертификат у Let's Encrypt)"

    local attempts=0
    local max_attempts=60  # 5 минут (60 × 5 сек)
    while (( attempts < max_attempts )); do
        if curl -kfsSL --max-time 5 -o /dev/null \
            -w "%{http_code}" "https://${DOMAIN}" 2>/dev/null | grep -qE '^(200|407|4[0-9][0-9])'; then
            log_ok "HTTPS активен на ${DOMAIN}"
            return 0
        fi
        # Проверяем не упал ли сервис
        if ! systemctl is-active transferhub-caddy --quiet; then
            echo
            error "Сервис Caddy упал. Логи:\n$(journalctl -u transferhub-caddy --no-pager -n 20)"
        fi
        attempts=$((attempts + 1))
        printf "."
        sleep 5
    done
    echo
    warn "TLS сертификат ещё не готов. Проверь: systemctl status transferhub-caddy"
    warn "Домен ${DOMAIN} должен резолвиться на IP этого сервера"
}

# -----------------------------------------------------------------------------
# Установка команды menu
# -----------------------------------------------------------------------------
install_menu() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    chmod +x "${PROJECT_ROOT}/runtime/menu.sh" "${PROJECT_ROOT}/runtime/backup.sh" "$RENDER_CADDY_SCRIPT"
    cat > "$MENU_BIN" <<EOF
#!/usr/bin/env bash
exec bash "${PROJECT_ROOT}/runtime/menu.sh" "\$@"
EOF
    chmod +x "$MENU_BIN"
    log_ok "Команда 'menu' установлена → ${MENU_BIN}"
}

# -----------------------------------------------------------------------------
# Самоудаление installer-файлов
# -----------------------------------------------------------------------------
prune_installer() {
    log_info "Удаление установочных файлов..."
    local to_remove=(
        "${PROJECT_ROOT}/install.sh"
        "${PROJECT_ROOT}/bootstrap.sh"
        "${PROJECT_ROOT}/instance.env.example"
        "${PROJECT_ROOT}/templates"
        "${PROJECT_ROOT}/naive"
        "${PROJECT_ROOT}/requirements.txt"
        "${PROJECT_ROOT}/README.md"
        "${PROJECT_ROOT}/runtime-images.lock.json"
        "${PROJECT_ROOT}/SPEEDTEST_PLAN.md"
    )
    for item in "${to_remove[@]}"; do
        if [[ -e "$item" ]]; then
            rm -rf "$item"
        fi
    done
    rm -f "$INSTALL_LOG"
    log_ok "Установочные файлы удалены"
}

# -----------------------------------------------------------------------------
# Итоговый вывод
# -----------------------------------------------------------------------------
print_summary() {
    # shellcheck source=/dev/null
    set -a; source "$INSTANCE_ENV"; set +a
    local first_nick first_user first_pass
    first_nick=$(awk -F '\t' 'NF >= 4 && $4 == "1" {print $1; exit}' "$USERS_DB" 2>/dev/null || true)
    first_user=$(awk -F '\t' 'NF >= 4 && $4 == "1" {print $2; exit}' "$USERS_DB" 2>/dev/null || true)
    first_pass=$(awk -F '\t' 'NF >= 4 && $4 == "1" {print $3; exit}' "$USERS_DB" 2>/dev/null || true)
    local url
    url=$(build_naive_url "$first_user" "$first_pass" "$first_nick")
    local width=64

    echo
    echo -e "${GREEN}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    echo -e "${GREEN}  ✓ TransferHub успешно установлен!${RESET}"
    echo -e "${GREEN}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    echo
    echo -e "  ${YELLOW}Домен:${RESET}    ${DOMAIN}"
    echo -e "  ${YELLOW}Логин:${RESET}    ${first_user}"
    echo -e "  ${YELLOW}Пароль:${RESET}   ${first_pass}"
    echo
    echo -e "  ${YELLOW}URL подключения:${RESET}"
    echo -e "  ${BLUE}${url}${RESET}"
    echo -e "  ${YELLOW}Certificate:${RESET}  ${CERT_MODE}"
    echo
    echo -e "  ${YELLOW}Управление:${RESET}  menu"
    echo
    echo -e "${GREEN}$(printf '═%.0s' $(seq 1 $width))${RESET}"

    # QR-код если доступен qrencode
    if command -v qrencode &>/dev/null; then
        echo
        echo -e "  ${DIM}QR-код для подключения:${RESET}"
        qrencode -t ANSIUTF8 -o - "$url" 2>/dev/null | sed 's/^/  /'
    fi
}

# =============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# =============================================================================
main() {
    parse_args "$@"
    : > "$INSTALL_LOG"
    if [[ "${TRANSFERHUB_HEADER_ALREADY_PRINTED:-0}" != "1" ]]; then
        clear_screen
        banner
    fi

    # --- Preflight ---
    check_root
    check_os

    # --- Wizard / resume (создаёт instance.env только при первом запуске) ---
    ensure_instance_env

    # Загружаем настройки
    # shellcheck source=/dev/null
    set -a; source "$INSTANCE_ENV"; set +a
    DOMAIN_DISPLAY="${DOMAIN:-}"
    log_info "Домен: ${DOMAIN_DISPLAY}"
    log_info "Certificate mode: ${CERT_MODE} - $(cert_mode_label)"

    # --- Проверки портов и домена ---
    check_ports
    check_domain "$DOMAIN"

    # --- Шаг 1: Системные пакеты и обновление ОС ---
    step 1 "Подготовка системы и установка пакетов"
    install_packages
    complete_current_step

    # --- Шаг 2: UFW ---
    step 2 "Настройка брандмауэра UFW"
    setup_ufw
    complete_current_step

    # --- Шаг 3: BBR (если включён) ---
    step 3 "Сетевые оптимизации"
    if [[ "${ENABLE_BBR:-true}" == "true" ]]; then
        apply_bbr
    else
        log_info "BBR пропущен (отключён в настройках)"
    fi
    complete_current_step

    # --- Шаг 4: Сборка Caddy ---
    step 4 "Сборка Caddy с naive forwardproxy"
    build_caddy
    complete_current_step

    # --- Шаг 5: Рендер конфигов ---
    step 5 "Создание конфигурации"
    render_configs
    complete_current_step

    # --- Шаг 6: Запуск сервиса ---
    step 6 "Запуск Caddy"
    install_speedtest_service
    install_caddy_service
    complete_current_step

    # --- Шаг 7: Ожидание TLS ---
    step 7 "Получение TLS сертификата"
    wait_for_tls
    complete_current_step

    # --- Шаг 8: Установка menu ---
    step 8 "Установка команды menu"
    install_menu
    complete_current_step

    # --- Шаг 9: Проверка итоговой конфигурации ---
    step 9 "Проверка конфигурации Caddy"
    run_logged "Проверка конфигурации Caddy завершилась ошибкой" \
        "$CADDY_BIN" validate --config "${CADDY_CONFIG_DIR}/Caddyfile"
    log_ok "Конфигурация Caddy валидна"
    complete_current_step

    # --- Шаг 10: Очистка ---
    step 10 "Финализация"
    prune_installer
    complete_current_step

    # --- Готово ---
    print_summary
}

main "$@"
