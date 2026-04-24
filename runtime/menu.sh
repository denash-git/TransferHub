#!/usr/bin/env bash
# =============================================================================
# TransferHub — Runtime меню управления
# =============================================================================
# Запуск: menu  (или /root/TransferHub/runtime/menu.sh напрямую)
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Пути
# -----------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCE_ENV="${PROJECT_ROOT}/instance.env"
USERS_DB="${PROJECT_ROOT}/users.db"
CADDY_BIN="/usr/local/bin/caddy"
CADDY_CONFIG="${PROJECT_ROOT}/caddy/Caddyfile"
CADDY_SERVICE="transferhub-caddy"
SPEEDTEST_SERVICE="transferhub-speedtest"
BACKUP_DIR="${PROJECT_ROOT}/backup"
RENDER_CADDY_SCRIPT="${PROJECT_ROOT}/runtime/render-caddy.sh"
RUNTIME_BUILD_CADDY_SCRIPT="${PROJECT_ROOT}/runtime/build-caddy.sh"
LE_STAGING_CA="https://acme-staging-v02.api.letsencrypt.org/directory"
SPEEDTEST_LINKS_DB="${PROJECT_ROOT}/runtime/speedtest-links.tsv"

# -----------------------------------------------------------------------------
# Цвета
# -----------------------------------------------------------------------------
BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# Загрузка переменных
# -----------------------------------------------------------------------------
load_env() {
    if [[ -f "$INSTANCE_ENV" ]]; then
        # shellcheck source=/dev/null
        set -a; source "$INSTANCE_ENV"; set +a
    fi
}

# -----------------------------------------------------------------------------
# Вспомогательные функции
# -----------------------------------------------------------------------------
clear_screen() { printf '\033[2J\033[H'; }
pause()        { echo; read -rp "  Нажми Enter для продолжения..."; }
exit_program() { echo -e "\n  ${DIM}До свидания!${RESET}\n"; exit 0; }
read_menu_input() {
    local __var="$1"
    local prompt="${2:-  Выбор: }"
    local value=""
    read -rp "$prompt" value
    [[ "$value" == "00" ]] && exit_program
    printf -v "$__var" '%s' "$value"
}
confirm()      {
    local msg="${1:-Ты уверен?}"
    local ans=""
    read -rp "  ${msg} [y/N]: " ans
    [[ "$ans" == "00" ]] && exit_program
    [[ "${ans,,}" == "y" ]]
}
log_ok()   { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_err()  { echo -e "  ${RED}✗ ${1}${RESET}"; }
log_info() { echo -e "  ${DIM}* ${1}${RESET}"; }
warn()     { echo -e "  ${YELLOW}⚠ ${1}${RESET}"; }
menu_back_exit_hint() {
    echo
    echo -e "  ${DIM}0) Назад${RESET}"
    echo -e "  ${DIM}00) Выход${RESET}"
    echo
}
menu_exit_hint() {
    echo
    echo -e "  ${DIM}00) Выход${RESET}"
    echo
}

ensure_runtime_package() {
    local package="$1"
    local bin="${2:-$1}"

    if command -v "$bin" >/dev/null 2>&1; then
        return 0
    fi

    log_info "Устанавливаю пакет ${package}..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -o Dpkg::Use-Pty=0 -o APT::Color=0 >/dev/null 2>&1 || {
        log_err "Не удалось выполнить apt-get update"
        return 1
    }
    apt-get install -y -qq -o Dpkg::Use-Pty=0 -o APT::Color=0 "$package" >/dev/null 2>&1 || {
        log_err "Не удалось установить пакет ${package}"
        return 1
    }

    if ! command -v "$bin" >/dev/null 2>&1; then
        log_err "Пакет ${package} установлен, но команда ${bin} не найдена"
        return 1
    fi

    log_ok "Пакет ${package} установлен"
}

run_speedtest_vps_internet() {
    load_env
    print_section_header "Speed Test" \
        "Направление" "VPS → Internet" \
        "Префикс" "${SPEEDTEST_PREFIX:-не задан}"
    echo -e "  ${BOLD}Скорость VPS → Internet${RESET}\n"
    echo -e "  Тест выполняется прямо на сервере через ближайший speedtest-узел."
    echo -e "  Это показывает качество канала самого VPS, без участия клиента.\n"

    ensure_runtime_package speedtest-cli speedtest-cli || { pause; return; }

    echo -e "  ${DIM}Запуск speedtest-cli --secure --simple ...${RESET}\n"
    if ! speedtest-cli --secure --simple 2>&1 | sed 's/^/  /'; then
        echo
        warn "Тест не выполнился. Проверь исходящее соединение VPS и доступность speedtest-серверов."
        pause
        return
    fi
    echo
    echo -e "  ${DIM}Сравнивай этот тест с браузерным Client ↔ VPS. Если VPS быстрый, а клиентский тест слабый, узкое место обычно вне сервера.${RESET}"
    pause
}

run_speedtest_client_vps() {
    load_env
    print_section_header "Speed Test" \
        "Направление" "Client ↔ VPS" \
        "Префикс" "${SPEEDTEST_PREFIX:-не задан}"
    echo -e "  ${BOLD}Замер скорости: Client <-> VPS${RESET}\n"
    echo -e "  Temporary HTTPS link for 10 minutes opens the speed test page."
    echo -e "  Клиент открывает её в браузере и запускает тест как обычный веб-трафик по 443.\n"

    ensure_speedtest_prefix
    cleanup_speedtest_links

    if ! systemctl is-active "${SPEEDTEST_SERVICE}" --quiet 2>/dev/null; then
        systemctl restart "${SPEEDTEST_SERVICE}" >/dev/null 2>&1 || {
            log_err "Не удалось запустить backend speedtest"
            pause
            return
        }
    fi

    local token expires_at expires_human url
    token=$(generate_speedtest_token)
    expires_at=$(( $(date +%s) + 600 ))
    expires_human=$(date -d "@${expires_at}" '+%Y-%m-%d %H:%M:%S %Z')

    mkdir -p "$(dirname "$SPEEDTEST_LINKS_DB")"
    touch "$SPEEDTEST_LINKS_DB"
    printf '%s\t%s\t%s\n' "$token" "$expires_at" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$SPEEDTEST_LINKS_DB"
    chmod 600 "$SPEEDTEST_LINKS_DB"

    url=$(build_speedtest_link "$token")

    echo -e "  ${YELLOW}Префикс:${RESET} ${CYAN}${SPEEDTEST_PREFIX}${RESET}"
    echo -e "  ${YELLOW}Живёт до:${RESET} ${CYAN}${expires_human}${RESET}"
    echo
    echo -e "  ${YELLOW}Ссылка:${RESET}"
    echo -e "  ${CYAN}${url}${RESET}"
    echo
    echo -e "  ${DIM}Пока TTL не истёк, по этой ссылке можно запускать тест повторно сколько угодно раз.${RESET}"
    echo -e "  ${DIM}После истечения срока ссылка исчезает, а запросы снова выглядят как обычный вход на фейк-сайт.${RESET}"
    pause
}

menu_speed() {
    while true; do
        load_env
        print_section_header "Speed Test" \
            "Префикс" "${SPEEDTEST_PREFIX:-не задан}" \
            "Backend" "$(systemctl is-active "${SPEEDTEST_SERVICE}" 2>/dev/null || echo unknown)"
        echo -e "  ${CYAN}1)${RESET} VPS → Internet"
        echo -e "  ${CYAN}2)${RESET} Замер скорости: Client <-> VPS"
        echo -e "  ${CYAN}3)${RESET} Показать текущий префикс"
        echo -e "  ${CYAN}4)${RESET} Перегенерировать префикс"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1) run_speedtest_vps_internet;;
            2) run_speedtest_client_vps;;
            3)
                ensure_speedtest_prefix
                echo
                echo -e "  ${YELLOW}Текущий префикс:${RESET} ${CYAN}${SPEEDTEST_PREFIX}${RESET}"
                pause
                ;;
            4)
                warn "Все уже выданные speedtest-ссылки перестанут работать."
                confirm "Перегенерировать префикс?" || continue
                regenerate_speedtest_prefix
                pause
                ;;
            0) return;;
            *) ;;
        esac
    done
}

validate_credential() {
    local label="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        log_err "${label} не может быть пустым"
        return 1
    fi
    if [[ ! "$value" =~ ^[A-Za-z0-9._~-]+$ ]]; then
        log_err "${label} содержит недопустимые символы. Разрешены только A-Z, a-z, 0-9, ., _, ~ и -"
        return 1
    fi
}

validate_nickname() {
    local value="$1"
    if [[ -z "$value" ]]; then
        log_err "Ник пользователя не может быть пустым"
        return 1
    fi
    if [[ "$value" == *$'\t'* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        log_err "Ник пользователя не должен содержать табы и переводы строки"
        return 1
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

generate_safe_login() {
    openssl rand -hex 8 | cut -c1-9
}

generate_safe_password() {
    openssl rand -hex 12
}

generate_speedtest_prefix() {
    openssl rand -hex 4
}

generate_speedtest_token() {
    openssl rand -hex 12
}

set_instance_env_key() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$INSTANCE_ENV" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=${value}/" "$INSTANCE_ENV"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$INSTANCE_ENV"
    fi
    chmod 600 "$INSTANCE_ENV"
}

ensure_speedtest_prefix() {
    load_env
    if [[ "${SPEEDTEST_PREFIX:-}" =~ ^[a-f0-9]{8}$ ]]; then
        return 0
    fi

    local prefix
    prefix=$(generate_speedtest_prefix)
    set_instance_env_key SPEEDTEST_PREFIX "$prefix"
    load_env
}

cleanup_speedtest_links() {
    mkdir -p "$(dirname "$SPEEDTEST_LINKS_DB")"
    touch "$SPEEDTEST_LINKS_DB"

    local now tmp
    now=$(date +%s)
    tmp="${SPEEDTEST_LINKS_DB}.tmp"
    awk -F '\t' -v now="$now" 'NF >= 2 && $2 > now {print $0}' "$SPEEDTEST_LINKS_DB" > "$tmp"
    mv "$tmp" "$SPEEDTEST_LINKS_DB"
}

build_speedtest_link() {
    load_env
    ensure_speedtest_prefix
    local token="$1"
    printf 'https://%s/%s%s/' "${DOMAIN}" "${SPEEDTEST_PREFIX}" "${token}"
}

regenerate_speedtest_prefix() {
    local new_prefix
    new_prefix=$(generate_speedtest_prefix)

    set_instance_env_key SPEEDTEST_PREFIX "$new_prefix"
    : > "$SPEEDTEST_LINKS_DB"
    chmod 600 "$SPEEDTEST_LINKS_DB"
    load_env

    if [[ ! -f "$RENDER_CADDY_SCRIPT" ]]; then
        log_err "Скрипт рендера Caddyfile не найден: ${RENDER_CADDY_SCRIPT}"
        return 1
    fi

    bash "$RENDER_CADDY_SCRIPT"
    systemctl restart "${SPEEDTEST_SERVICE}" >/dev/null 2>&1 || true
    systemctl reload "${CADDY_SERVICE}" >/dev/null 2>&1 || systemctl restart "${CADDY_SERVICE}" >/dev/null 2>&1 || true
    log_ok "Префикс speedtest обновлён: ${new_prefix}"
}

ensure_users_db() {
    if [[ ! -f "$USERS_DB" ]]; then
        log_err "Файл пользователей не найден: ${USERS_DB}"
        return 1
    fi
}

users_total_count() {
    ensure_users_db || return 1
    awk -F '\t' 'NF >= 4 {count++} END {print count+0}' "$USERS_DB"
}

users_enabled_count() {
    ensure_users_db || return 1
    awk -F '\t' 'NF >= 4 && $4 == "1" {count++} END {print count+0}' "$USERS_DB"
}

user_exists_by_nick() {
    local nick="$1"
    awk -F '\t' -v target="$nick" 'NF >= 4 && $1 == target {found=1} END {exit(found ? 0 : 1)}' "$USERS_DB"
}

user_get_by_index() {
    local index="$1"
    awk -F '\t' -v idx="$index" 'NF >= 4 {count++; if (count == idx) {print $0; exit}}' "$USERS_DB"
}

user_find_index_by_login() {
    local login="$1"
    awk -F '\t' -v target="$login" 'NF >= 4 {count++; if ($2 == target) {print count; exit}}' "$USERS_DB"
}

user_exists_by_login() {
    local login="$1"
    [[ -n "$(user_find_index_by_login "$login")" ]]
}

list_users_compact() {
    ensure_users_db || return 1
    local index=0
    while IFS=$'\t' read -r nick login password enabled; do
        [[ -z "${nick:-}" || -z "${login:-}" || -z "${password:-}" || -z "${enabled:-}" ]] && continue
        index=$((index + 1))
        if [[ "$enabled" == "1" ]]; then
            printf "  - %s [%s] active\n" "$nick" "$login"
        else
            printf "  - %s [%s] disabled\n" "$nick" "$login"
        fi
    done < "$USERS_DB"
}

list_users_numbered() {
    ensure_users_db || return 1
    local index=0
    while IFS=$'\t' read -r nick login password enabled; do
        [[ -z "${nick:-}" || -z "${login:-}" || -z "${password:-}" || -z "${enabled:-}" ]] && continue
        index=$((index + 1))
        if [[ "$enabled" == "1" ]]; then
            printf "  %d) %s [%s] active\n" "$index" "$nick" "$login"
        else
            printf "  %d) %s [%s] disabled\n" "$index" "$nick" "$login"
        fi
    done < "$USERS_DB"
}

update_user_record() {
    local target_index="$1"
    local new_nick="$2"
    local new_login="$3"
    local new_password="$4"
    local new_enabled="$5"
    local tmp="${USERS_DB}.tmp"
    local index=0
    : > "$tmp"
    while IFS=$'\t' read -r nick login password enabled; do
        [[ -z "${nick:-}" || -z "${login:-}" || -z "${password:-}" || -z "${enabled:-}" ]] && continue
        index=$((index + 1))
        if [[ "$index" == "$target_index" ]]; then
            printf '%s\t%s\t%s\t%s\n' "$new_nick" "$new_login" "$new_password" "$new_enabled" >> "$tmp"
        else
            printf '%s\t%s\t%s\t%s\n' "$nick" "$login" "$password" "$enabled" >> "$tmp"
        fi
    done < "$USERS_DB"
    mv "$tmp" "$USERS_DB"
    chmod 600 "$USERS_DB"
}

delete_user_record() {
    local target_index="$1"
    local tmp="${USERS_DB}.tmp"
    local index=0
    : > "$tmp"
    while IFS=$'\t' read -r nick login password enabled; do
        [[ -z "${nick:-}" || -z "${login:-}" || -z "${password:-}" || -z "${enabled:-}" ]] && continue
        index=$((index + 1))
        [[ "$index" == "$target_index" ]] && continue
        printf '%s\t%s\t%s\t%s\n' "$nick" "$login" "$password" "$enabled" >> "$tmp"
    done < "$USERS_DB"
    mv "$tmp" "$USERS_DB"
    chmod 600 "$USERS_DB"
}

# -----------------------------------------------------------------------------
# Статус сервиса
# -----------------------------------------------------------------------------
caddy_status_str() {
    if systemctl is-active "${CADDY_SERVICE}" --quiet 2>/dev/null; then
        echo -e "${GREEN}● работает${RESET}"
    else
        echo -e "${RED}● остановлен${RESET}"
    fi
}

tls_status_str() {
    load_env
    local domain="${DOMAIN:-}"
    if [[ -z "$domain" ]]; then
        echo -e "${DIM}неизвестно${RESET}"
        return
    fi
    # Получаем expiry через openssl
    local expiry
    expiry=$(echo | timeout 5 openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
    if [[ -n "$expiry" ]]; then
        local days_left
        days_left=$(( ( $(date -d "$expiry" '+%s') - $(date '+%s') ) / 86400 ))
        if (( days_left > 30 )); then
            echo -e "${GREEN}● активен (осталось: ${days_left} дн.)${RESET}"
        elif (( days_left > 0 )); then
            echo -e "${YELLOW}⚠ скоро истекает (осталось: ${days_left} дн.)${RESET}"
        else
            echo -e "${RED}✗ истёк${RESET}"
        fi
    else
        echo -e "${DIM}недоступен (HTTPS не отвечает)${RESET}"
    fi
}

bbr_status_str() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        echo -e "${GREEN}● bbr${RESET}"
    else
        echo -e "${DIM}● ${cc}${RESET}"
    fi
}

caddy_version_str() {
    "$CADDY_BIN" version 2>/dev/null | head -1 || echo "не установлен"
}

cert_mode_status_str() {
    echo -e "${GREEN}✓${RESET} ${CERT_MODE:-prod}"
}

tls_expiry_str() {
    load_env
    local domain="${DOMAIN:-}"
    [[ -n "$domain" ]] || { echo "—"; return; }
    echo | timeout 5 openssl s_client -connect "${domain}:443" -servername "${domain}" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "—"
}

# -----------------------------------------------------------------------------
# Шапка меню
# -----------------------------------------------------------------------------
print_header() {
    load_env
    local width=58
    clear_screen
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    printf "${BOLD}  %-$((width-4))s${RESET}\n" "TransferHub — Управление"
    echo -e "${BLUE}$(printf '─%.0s' $(seq 1 $width))${RESET}"
    printf "  %-20s %s\n" "Домен:"  "${DOMAIN:-не задан}"
    printf "  %-20s " "Caddy:"; echo -e "$(caddy_status_str)"
    printf "  %-20s " "TLS:"; echo -e "$(tls_status_str)"
    printf "  %-20s " "Cert mode:"; echo -e "$(cert_mode_status_str)"
    printf "  %-20s " "BBR:"; echo -e "$(bbr_status_str)"
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    echo
}

print_section_header() {
    load_env
    local title="$1"
    shift
    local width=58
    local label_width=12
    local indent="      "
    clear_screen
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    printf "${BOLD}  %-$((width-4))s${RESET}\n" "$title"
    echo -e "${BLUE}$(printf '─%.0s' $(seq 1 $width))${RESET}"
    while (( "$#" >= 2 )); do
        local label="$1"
        local value="$2"
        shift 2
        printf "%s%-${label_width}s " "$indent" "${label}:"
        echo -e "${value}"
    done
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    echo
}

# =============================================================================
# РАЗДЕЛЫ МЕНЮ
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Управление Caddy
# -----------------------------------------------------------------------------
menu_caddy() {
    while true; do
        load_env
        print_section_header "Caddy" \
            "Статус" "$(caddy_status_str)" \
            "Версия" "$(caddy_version_str)"
        echo -e "  ${CYAN}1)${RESET} Запустить"
        echo -e "  ${CYAN}2)${RESET} Остановить"
        echo -e "  ${CYAN}3)${RESET} Перезапустить"
        echo -e "  ${CYAN}4)${RESET} Перезагрузить конфиг"
        echo -e "  ${CYAN}5)${RESET} Показать логи"
        echo -e "  ${CYAN}6)${RESET} Следить за логами"
        echo -e "  ${CYAN}7)${RESET} Обновить Caddy"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1) systemctl start "${CADDY_SERVICE}" && log_ok "Caddy запущен" || log_err "Ошибка запуска"; pause;;
            2) confirm "Остановить Caddy (прокси перестанет работать)?" && \
               systemctl stop "${CADDY_SERVICE}" && log_ok "Caddy остановлен" || log_err "Ошибка"; pause;;
            3) systemctl restart "${CADDY_SERVICE}" && log_ok "Caddy перезапущен" || log_err "Ошибка"; pause;;
            4) "$CADDY_BIN" reload --config "$CADDY_CONFIG" --force 2>/dev/null && \
               log_ok "Конфиг перезагружен" || log_err "Ошибка перезагрузки"; pause;;
            5) echo; journalctl -u "${CADDY_SERVICE}" --no-pager -n 50; pause;;
            6) journalctl -u "${CADDY_SERVICE}" -f;;
            7) menu_update_caddy;;
            0) return;;
            *) ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# 2. TLS сертификат
# -----------------------------------------------------------------------------
menu_tls() {
    while true; do
        load_env
        print_section_header "TLS" \
            "Домен" "${DOMAIN:-не задан}" \
            "Статус" "$(tls_status_str)" \
            "Valid until" "$(tls_expiry_str)" \
            "Режим" "$(cert_mode_status_str)"
        echo -e "  ${CYAN}1)${RESET} Перевыпустить боевой сертификат"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1)
                warn "Будет включён боевой режим сертификата и перезапущен Caddy."
                warn "Используй это после тестового staging-сертификата или для повторной инициализации боевого выпуска."
                confirm "Продолжить?" || continue
                _set_cert_mode prod
                pause
                ;;
            0) return;;
            *) ;;
        esac
    done
}

# Перерендер auth-строк в Caddyfile и перезагрузка конфига
reload_users_config() {
    if [[ ! -f "$RENDER_CADDY_SCRIPT" ]]; then
        warn "Скрипт рендера Caddyfile не найден: ${RENDER_CADDY_SCRIPT}"
        return 1
    fi
    bash "$RENDER_CADDY_SCRIPT"
    "$CADDY_BIN" reload --config "$CADDY_CONFIG" --force 2>/dev/null && \
        log_ok "Конфиг Caddy перезагружен" || warn "Не удалось перезагрузить конфиг. Перезапусти вручную: systemctl restart ${CADDY_SERVICE}"
}

_set_cert_mode() {
    local mode="$1"
    case "$mode" in
        prod|staging) ;;
        *) log_err "Неизвестный режим сертификата: ${mode}"; return 1 ;;
    esac

    if grep -q '^CERT_MODE=' "$INSTANCE_ENV" 2>/dev/null; then
        sed -i "s/^CERT_MODE=.*/CERT_MODE=${mode}/" "$INSTANCE_ENV"
    else
        printf '\nCERT_MODE=%s\n' "$mode" >> "$INSTANCE_ENV"
    fi

    if [[ ! -f "$RENDER_CADDY_SCRIPT" ]]; then
        log_err "Скрипт рендера Caddyfile не найден: ${RENDER_CADDY_SCRIPT}"
        return 1
    fi

    bash "$RENDER_CADDY_SCRIPT"
    systemctl restart "${CADDY_SERVICE}" && \
        log_ok "Caddy перезапущен. Режим сертификата: ${mode}" || \
        log_err "Ошибка перезапуска Caddy"
}

# -----------------------------------------------------------------------------
# 3. Пользователи
# -----------------------------------------------------------------------------
show_user_url() {
    local nick="$1"
    local login="$2"
    local password="$3"

    load_env
    local url
    url=$(build_naive_url "$login" "$password" "$nick")
    print_section_header "Пользователь" \
        "Ник" "$nick" \
        "Логин" "$login"
    echo -e "  ${YELLOW}Логин:${RESET} ${CYAN}${login}${RESET}"
    echo -e "  ${YELLOW}Пароль:${RESET} ${CYAN}${password}${RESET}"
    echo
    echo -e "  ${YELLOW}Протокол naive+HTTPS:${RESET}"
    echo -e "  ${CYAN}${url}${RESET}"
    echo

    if command -v qrencode &>/dev/null; then
        echo -e "  ${YELLOW}QR-код:${RESET}"
        qrencode -t ANSIUTF8 -o - "$url" 2>/dev/null | sed 's/^/  /'
    else
        echo -e "  ${DIM}(qrencode не установлен — установи командой: apt install qrencode)${RESET}"
    fi

    pause
}

menu_user_actions() {
    local user_index="$1"
    while true; do
        load_env
        local user_line
        user_line=$(user_get_by_index "$user_index")
        [[ -z "$user_line" ]] && { warn "Пользователь не найден"; pause; return; }

        local nick login password enabled
        IFS=$'\t' read -r nick login password enabled <<< "$user_line"

        print_section_header "Пользователь" \
            "Ник" "$nick" \
            "Логин" "$login" \
            "Статус" "$([[ "$enabled" == "1" ]] && echo "${GREEN}active${RESET}" || echo "${YELLOW}disabled${RESET}")"
        echo -e "  ${CYAN}1)${RESET} Показать URL / QR"
        echo -e "  ${CYAN}2)${RESET} Сменить пароль"
        echo -e "  ${CYAN}3)${RESET} Сменить логин"
        echo -e "  ${CYAN}4)${RESET} Переименовать"
        echo -e "  ${CYAN}5)${RESET} Отключить"
        echo -e "  ${CYAN}6)${RESET} Включить"
        echo -e "  ${CYAN}7)${RESET} Удалить"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1)
                show_user_url "$nick" "$login" "$password"
                ;;
            2)
                local new_password suggested_password
                suggested_password=$(generate_safe_password)
                read_menu_input new_password "  Новый пароль [${suggested_password}]: "
                [[ -z "$new_password" ]] && new_password="$suggested_password"
                if validate_credential "Пароль" "$new_password"; then
                    update_user_record "$user_index" "$nick" "$login" "$new_password" "$enabled"
                    reload_users_config
                    log_ok "Новый пароль: ${new_password}"
                fi
                pause
                ;;
            3)
                local new_login suggested_login
                suggested_login=$(generate_safe_login)
                while [[ "$suggested_login" != "$login" ]] && user_exists_by_login "$suggested_login"; do
                    suggested_login=$(generate_safe_login)
                done
                read_menu_input new_login "  Новый логин [${suggested_login}]: "
                [[ -z "$new_login" ]] && new_login="$suggested_login"
                if validate_credential "Логин" "$new_login"; then
                    if [[ "$new_login" != "$login" ]] && user_exists_by_login "$new_login"; then
                        log_err "Пользователь с таким логином уже существует"
                    else
                        update_user_record "$user_index" "$nick" "$new_login" "$password" "$enabled"
                        reload_users_config
                        log_ok "Логин обновлён → ${new_login}"
                    fi
                fi
                pause
                ;;
            4)
                local new_nick
                read_menu_input new_nick "  Новый ник: "
                if validate_nickname "$new_nick"; then
                    if [[ "$new_nick" != "$nick" ]] && user_exists_by_nick "$new_nick"; then
                        log_err "Пользователь с таким ником уже существует"
                    else
                        update_user_record "$user_index" "$new_nick" "$login" "$password" "$enabled"
                        log_ok "Ник обновлён → ${new_nick}"
                    fi
                fi
                pause
                ;;
            5)
                if [[ "$enabled" != "1" ]]; then
                    log_err "Пользователь уже отключён"
                elif [[ "$(users_enabled_count)" -le 1 ]]; then
                    log_err "Нельзя отключить последнего активного пользователя"
                else
                    update_user_record "$user_index" "$nick" "$login" "$password" "0"
                    reload_users_config
                    log_ok "Пользователь отключён"
                fi
                pause
                ;;
            6)
                if [[ "$enabled" == "1" ]]; then
                    log_err "Пользователь уже включён"
                else
                    update_user_record "$user_index" "$nick" "$login" "$password" "1"
                    reload_users_config
                    log_ok "Пользователь включён"
                fi
                pause
                ;;
            7)
                if [[ "$enabled" == "1" ]] && [[ "$(users_enabled_count)" -le 1 ]]; then
                    log_err "Нельзя удалить последнего активного пользователя"
                    pause
                    continue
                fi
                confirm "Удалить пользователя ${nick}?" || continue
                delete_user_record "$user_index"
                reload_users_config
                log_ok "Пользователь удалён"
                pause
                return
                ;;
            0) return;;
            *) ;;
        esac
    done
}

menu_users() {
    while true; do
        load_env
        print_section_header "Пользователи" \
            "Всего" "$(users_total_count)" \
            "Активных" "$(users_enabled_count)"
        if [[ "$(users_total_count)" -eq 0 ]]; then
            echo -e "  ${DIM}Пользователей пока нет${RESET}"
        else
            list_users_compact
        fi
        echo
        echo -e "  ${CYAN}1)${RESET} Добавить пользователя"
        echo -e "  ${CYAN}2)${RESET} Редактировать пользователя"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1)
                local nickname login password
                read_menu_input nickname "  Ник пользователя: "
                if validate_nickname "$nickname"; then
                    if user_exists_by_nick "$nickname"; then
                        log_err "Пользователь с таким ником уже существует"
                        pause
                        continue
                    fi
                    login=$(generate_safe_login)
                    password=$(generate_safe_password)
                    printf '%s\t%s\t%s\t1\n' "$nickname" "$login" "$password" >> "$USERS_DB"
                    chmod 600 "$USERS_DB"
                    reload_users_config
                    log_ok "Пользователь добавлен"
                    show_user_url "$nickname" "$login" "$password"
                else
                    pause
                fi
                ;;
            2)
                echo
                if [[ "$(users_total_count)" -eq 0 ]]; then
                    echo -e "  ${DIM}Пользователей нет${RESET}"
                    pause
                    continue
                fi
                list_users_numbered
                echo
                read_menu_input selected "  Номер пользователя: "
                if [[ "$selected" =~ ^[0-9]+$ ]] && [[ "$selected" -ge 1 ]] && [[ "$selected" -le "$(users_total_count)" ]]; then
                    menu_user_actions "$selected"
                else
                    log_err "Некорректный номер пользователя"
                    pause
                fi
                ;;
            0) return;;
            *) ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# 5. Оптимизация сети (BBR)
# -----------------------------------------------------------------------------
menu_bbr() {
    while true; do
        load_env
        local cc
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        print_section_header "BBR" \
            "Текущий алгоритм" "${CYAN}${cc}${RESET}" \
            "Состояние" "$(bbr_status_str)"
        echo -e "  BBR (Bottleneck Bandwidth and RTT) — алгоритм TCP от Google."
        echo -e "  Улучшает пропускную способность и снижает задержки.\n"
        if [[ "$cc" == "bbr" ]]; then
            echo -e "  ${CYAN}1)${RESET} Отключить BBR (переключить на cubic)"
        else
            echo -e "  ${CYAN}1)${RESET} Включить BBR"
        fi
        echo -e "  ${CYAN}2)${RESET} Показать доступные алгоритмы"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1)
                if [[ "$cc" == "bbr" ]]; then
                    confirm "Отключить BBR?" || continue
                    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
                    rm -f /etc/sysctl.d/99-transferhub-bbr.conf
                    sed -i 's/^ENABLE_BBR=.*/ENABLE_BBR=false/' "$INSTANCE_ENV"
                    log_ok "BBR отключён. Используется cubic."
                else
                    if modprobe tcp_bbr 2>/dev/null; then
                        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
                        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
                        cat > /etc/sysctl.d/99-transferhub-bbr.conf <<'EOF'
# TransferHub BBR оптимизация
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
                        sed -i 's/^ENABLE_BBR=.*/ENABLE_BBR=true/' "$INSTANCE_ENV"
                        log_ok "BBR включён"
                    else
                        log_err "Модуль tcp_bbr недоступен в данном ядре"
                    fi
                fi
                pause
                ;;
            2)
                echo; sysctl net.ipv4.tcp_available_congestion_control; pause;;
            0) return;;
            *) ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# 6. Speed Test
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 7. Backup / Restore
# -----------------------------------------------------------------------------
menu_services() {
    while true; do
        load_env
        print_section_header "Бекап" \
            "Каталог backup" "${BACKUP_DIR}"
        echo -e "  ${CYAN}1)${RESET} Экспортировать настройки"
        echo -e "  ${CYAN}2)${RESET} Импортировать настройки"
        echo -e "  ${CYAN}3)${RESET} Список экспортов"
        menu_back_exit_hint
        read_menu_input choice
        case "$choice" in
            1) echo; bash "${PROJECT_ROOT}/runtime/backup.sh" backup; pause;;
            2) echo; bash "${PROJECT_ROOT}/runtime/backup.sh" restore; pause;;
            3)
                echo
                mkdir -p "$BACKUP_DIR"
                local files
                files=$(ls -lh "${BACKUP_DIR}/"config-*.tar.gz 2>/dev/null || echo "")
                if [[ -n "$files" ]]; then
                    echo "$files" | awk '{print "  " $5 "\t" $9}' | sed "s|${BACKUP_DIR}/||"
                else
                    echo -e "  ${DIM}Экспортов нет${RESET}"
                fi
                pause
                ;;
            0) return;;
            *) ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# 7. Обновить Caddy (пересборка)
# -----------------------------------------------------------------------------
menu_update_caddy() {
    load_env
    print_section_header "Обновить Caddy" \
        "Статус" "$(caddy_status_str)" \
        "Текущая версия" "$(caddy_version_str)"
    warn "Caddy будет остановлен на время сборки (~5–7 минут)!"
    echo
    confirm "Запустить обновление?" || return

    log_info "Остановка Caddy..."
    systemctl stop "${CADDY_SERVICE}" || true

    log_info "Сборка новой версии..."
    if [[ ! -f "${RUNTIME_BUILD_CADDY_SCRIPT}" ]]; then
        log_err "Скрипт сборки не найден: ${RUNTIME_BUILD_CADDY_SCRIPT}"
        log_info "Пробую вернуть Caddy в работу..."
        systemctl start "${CADDY_SERVICE}" >/dev/null 2>&1 || true
        pause
        return
    fi
    if ! bash "${RUNTIME_BUILD_CADDY_SCRIPT}"; then
        log_err "Сборка Caddy завершилась ошибкой"
        log_info "Пробую вернуть Caddy в работу..."
        systemctl start "${CADDY_SERVICE}" >/dev/null 2>&1 || true
        pause
        return
    fi

    log_info "Запуск Caddy..."
    systemctl start "${CADDY_SERVICE}" || {
        log_err "Не удалось запустить Caddy после обновления"
        pause
        return
    }
    log_ok "Обновление завершено: $("${CADDY_BIN}" version 2>/dev/null | head -1)"
    pause
}

# =============================================================================
# ГЛАВНОЕ МЕНЮ
# =============================================================================
main_menu() {
    while true; do
        print_header
        echo -e "  ${CYAN}1)${RESET} Caddy"
        echo -e "  ${CYAN}2)${RESET} TLS сертификат"
        echo -e "  ${CYAN}3)${RESET} Пользователи"
        echo -e "  ${CYAN}4)${RESET} Показать URL / QR"
        echo -e "  ${CYAN}5)${RESET} Оптимизация сети (BBR)"
        echo -e "  ${CYAN}6)${RESET} Замер скорости"
        echo -e "  ${CYAN}7)${RESET} Бекап"
        menu_exit_hint
        read_menu_input choice
        case "$choice" in
            1) menu_caddy;;
            2) menu_tls;;
            3) menu_users;;
            4)
                if [[ "$(users_total_count)" -eq 1 ]]; then
                    local only_line only_nick only_login only_password only_enabled
                    only_line=$(user_get_by_index 1)
                    IFS=$'\t' read -r only_nick only_login only_password only_enabled <<< "$only_line"
                    show_user_url "$only_nick" "$only_login" "$only_password"
                else
                    menu_users
                fi
                ;;
            5) menu_bbr;;
            6) menu_speed;;
            7) menu_services;;
            *) ;;
        esac
    done
}

# Проверка root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "\n${RED}✗ Требуется root. Используй: sudo menu${RESET}\n" >&2
    exit 1
fi

load_env
main_menu
