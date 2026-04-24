#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="${PROJECT_ROOT}/runtime-images.lock.json"
CADDY_BIN="/usr/local/bin/caddy"
BUILD_TMP_ROOT="/root/tmp"
DEFAULT_GO_VERSION="1.26.2"

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
RESET='\033[0m'

log_ok()   { echo -e "  ${GREEN}✓${RESET} ${1}"; }
log_info() { echo -e "  ${DIM}* ${1}${RESET}"; }
warn()     { echo -e "  ${YELLOW}⚠ ${1}${RESET}"; }
error()    { echo -e "\n${RED}✗ ${1}${RESET}" >&2; exit 1; }

detect_go_version() {
    local version=""
    version=$(curl -fsSL --max-time 10 "https://go.dev/VERSION?m=text" 2>/dev/null | head -n 1 || true)
    if [[ "$version" =~ ^go([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    echo "$DEFAULT_GO_VERSION"
}

main() {
    local arch go_arch tmpdir go_version go_url_primary go_url_fallback caddy_ver digest now
    tmpdir=""

    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        amd64|x86_64) go_arch="amd64" ;;
        arm64|aarch64) go_arch="arm64" ;;
        *) error "Неподдерживаемая архитектура: ${arch}" ;;
    esac

    mkdir -p "$BUILD_TMP_ROOT"
    chmod 700 "$BUILD_TMP_ROOT"
    export TMPDIR="$BUILD_TMP_ROOT"

    log_info "TMPDIR=${TMPDIR}"
    tmpdir=$(mktemp -d -p "$TMPDIR" caddy-build-XXXXXX)
    trap '[[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir"' EXIT

    go_version=$(detect_go_version)
    go_url_primary="https://go.dev/dl/go${go_version}.linux-${go_arch}.tar.gz"
    go_url_fallback="https://dl.google.com/go/go${go_version}.linux-${go_arch}.tar.gz"

    log_info "Скачивание Go ${go_version} для ${go_arch}..."
    if ! curl -fsSL --retry 2 --connect-timeout 15 --progress-bar "$go_url_primary" -o "${tmpdir}/go.tar.gz"; then
        warn "Не удалось скачать Go с ${go_url_primary}, пробую резервный адрес..."
        curl -fsSL --retry 2 --connect-timeout 15 --progress-bar "$go_url_fallback" -o "${tmpdir}/go.tar.gz" \
            || error "Не удалось скачать Go ни с ${go_url_primary}, ни с ${go_url_fallback}"
    fi

    log_info "Распаковка Go..."
    tar -xzf "${tmpdir}/go.tar.gz" -C "$tmpdir" || error "Ошибка распаковки Go"

    export GOROOT="${tmpdir}/go"
    export GOPATH="${tmpdir}/gopath"
    export GOBIN="${tmpdir}/bin"
    export GOCACHE="${tmpdir}/gocache"
    export GOTMPDIR="${tmpdir}/gotmp"
    export PATH="${GOBIN}:${GOROOT}/bin:${PATH}"
    mkdir -p "$GOPATH" "$GOBIN" "$GOCACHE" "$GOTMPDIR"

    log_info "Установка xcaddy..."
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest || error "Не удалось установить xcaddy"

    log_info "Сборка Caddy с github.com/klzgrad/forwardproxy@naive..."
    xcaddy build \
        --output "${tmpdir}/caddy" \
        --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive \
        || error "Не удалось собрать Caddy через xcaddy"

    [[ -f "${tmpdir}/caddy" ]] || error "После сборки не найден бинарник Caddy"

    log_info "Установка бинарника..."
    cp "${tmpdir}/caddy" "$CADDY_BIN"
    chmod 755 "$CADDY_BIN"

    caddy_ver=$("$CADDY_BIN" version 2>/dev/null | head -1)
    log_ok "Caddy собран и установлен: ${caddy_ver}"

    if command -v jq >/dev/null 2>&1 && [[ -f "$LOCK_FILE" ]]; then
        digest=$(sha256sum "$CADDY_BIN" | awk '{print $1}')
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        jq --arg ver "${caddy_ver}" --arg digest "${digest}" --arg ts "${now}" \
            '.locked_at_utc = $ts | .captured_from_host = "'$(hostname)'" |
             .images.CADDY_IMAGE.pinned_ref = ("sha256:" + $digest) |
             .images.CADDY_IMAGE.source_ref = ("xcaddy klzgrad/forwardproxy@naive " + $ver)' \
            "$LOCK_FILE" > "${LOCK_FILE}.tmp" && mv "${LOCK_FILE}.tmp" "$LOCK_FILE"
    fi
}

main "$@"
