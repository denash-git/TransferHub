#!/usr/bin/env bash
# =============================================================================
# TransferHub — Export / Import config
# =============================================================================
# Использование:
#   backup.sh backup          — экспортировать настройки
#   backup.sh restore         — импортировать из последнего файла
#   backup.sh restore <файл>  — импортировать из конкретного файла
# =============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${PROJECT_ROOT}/backup"
CADDY_SERVICE="transferhub-caddy"
INSTANCE_ENV="${PROJECT_ROOT}/instance.env"
USERS_DB="${PROJECT_ROOT}/users.db"
RENDER_CADDY_SCRIPT="${PROJECT_ROOT}/runtime/render-caddy.sh"

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; DIM='\033[2m'; RESET='\033[0m'
log_ok()   { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_info() { echo -e "  ${DIM}• ${1}${RESET}"; }
warn()     { echo -e "  ${YELLOW}⚠ ${1}${RESET}"; }
error()    { echo -e "  ${RED}✗ ${1}${RESET}" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Экспорт конфигурации
# -----------------------------------------------------------------------------
cmd_backup() {
    mkdir -p "$BACKUP_DIR"
    [[ -f "$INSTANCE_ENV" ]] || error "instance.env не найден: ${INSTANCE_ENV}"
    [[ -f "$USERS_DB" ]] || error "users.db не найден: ${USERS_DB}"

    local ts
    ts=$(date -u '+%Y%m%d-%H%M%S')
    local bundle="${BACKUP_DIR}/config-${ts}.tar.gz"

    log_info "Экспорт настроек: $(basename "$bundle")"
    tar -czf "$bundle" -C "$PROJECT_ROOT" instance.env users.db
    log_ok "Настройки экспортированы: ${bundle}"
}

# -----------------------------------------------------------------------------
# Импорт конфигурации
# -----------------------------------------------------------------------------
cmd_restore() {
    local bundle="${1:-}"
    mkdir -p "$BACKUP_DIR"

    if [[ -z "$bundle" ]]; then
        bundle=$(ls -t "${BACKUP_DIR}"/config-[0-9]*.tar.gz 2>/dev/null | head -1 || echo "")
        if [[ -z "$bundle" ]]; then
            error "Экспортов не найдено в ${BACKUP_DIR}"
        fi
        log_info "Последний экспорт: $(basename "$bundle")"
    elif [[ ! -f "$bundle" ]]; then
        error "Файл не найден: ${bundle}"
    fi

    warn "Будут импортированы настройки из: $(basename "$bundle")"
    warn "Текущие настройки будут перезаписаны!"
    echo
    read -rp "  Продолжить? [y/N]: " ans
    [[ "$ans" == "00" ]] && exit 0
    [[ "${ans,,}" != "y" ]] && { echo "  Отменено."; return 0; }

    if [[ -f "$INSTANCE_ENV" ]]; then
        local rollback
        rollback="${BACKUP_DIR}/config-rollback-$(date -u '+%Y%m%d-%H%M%S').tar.gz"
        if [[ -f "$USERS_DB" ]]; then
            tar -czf "$rollback" -C "$PROJECT_ROOT" instance.env users.db
        else
            tar -czf "$rollback" -C "$PROJECT_ROOT" instance.env
        fi
        log_ok "Rollback настроек создан: $(basename "$rollback")"
    fi

    tar -xzf "$bundle" -C "$PROJECT_ROOT"
    chmod 600 "$INSTANCE_ENV" "$USERS_DB"
    log_ok "Настройки восстановлены"

    if [[ -f "$RENDER_CADDY_SCRIPT" ]]; then
        log_info "Пересобираем Caddyfile..."
        bash "$RENDER_CADDY_SCRIPT"
    fi

    if command -v systemctl &>/dev/null && systemctl list-unit-files | grep -q "^${CADDY_SERVICE}"; then
        log_info "Перезапускаем Caddy..."
        systemctl restart "${CADDY_SERVICE}" 2>/dev/null || true
    fi

    log_ok "Импорт настроек завершён"
}

# -----------------------------------------------------------------------------
# Точка входа
# -----------------------------------------------------------------------------
case "${1:-backup}" in
    backup)  cmd_backup;;
    restore) cmd_restore "${2:-}";;
    *)       echo "Использование: $0 {backup|restore [файл]}"; exit 1;;
esac
