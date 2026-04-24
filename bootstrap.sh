#!/usr/bin/env bash
# =============================================================================
# TransferHub - Bootstrap
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/denash-git/TransferHub.git"
BRANCH="${TRANSFERHUB_BRANCH:-dev}"
INSTALL_DIR="/root/TransferHub"
CERT_MODE="prod"

BLUE='\033[1;34m'
GREEN='\033[1;32m'
RED='\033[1;31m'
DIM='\033[2m'
RESET='\033[0m'

error() { echo -e "\n${RED}x ${1}${RESET}" >&2; exit 1; }
info()  { echo -e "  ${GREEN}✓${RESET} ${1}"; }
warn()  { echo -e "  ${RED}!${RESET} ${1}"; }
clear_screen() { printf '\033c'; }

detect_local_branch() {
    local script_dir current_branch
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! command -v git >/dev/null 2>&1; then
        return 0
    fi
    if ! git -C "$script_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi
    current_branch=$(git -C "$script_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
        BRANCH="$current_branch"
    fi
}

parse_args() {
    BOOTSTRAP_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --staging)
                CERT_MODE="staging"
                BOOTSTRAP_ARGS+=("$1")
                ;;
            --prod)
                CERT_MODE="prod"
                BOOTSTRAP_ARGS+=("$1")
                ;;
            --branch)
                [[ $# -lt 2 ]] && error "Option --branch requires a value"
                BRANCH="$2"
                shift
                ;;
            --branch=*)
                BRANCH="${1#--branch=}"
                ;;
            *)
                BOOTSTRAP_ARGS+=("$1")
                ;;
        esac
        shift
    done
}

cert_mode_label() {
    case "${CERT_MODE}" in
        staging) echo "Let's Encrypt staging (test)" ;;
        *)       echo "Let's Encrypt production (live)" ;;
    esac
}

installer_cert_mode_label() {
    case "${CERT_MODE}" in
        staging) echo "Let's Encrypt staging (тестовый)" ;;
        *)       echo "Let's Encrypt production (боевой)" ;;
    esac
}

print_bootstrap_header() {
    clear_screen
    local width=60
    echo -e "\n${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}"
    printf "${BLUE}%-${width}s${RESET}\n" "  TransferHub — Установщик NaiveProxy"
    printf "${DIM}%-${width}s${RESET}\n" "  Проект: github.com/denash-git/TransferHub"
    printf "${DIM}%-${width}s${RESET}\n" "  Сертификат: ${CERT_MODE} — $(installer_cert_mode_label)"
    echo -e "${BLUE}$(printf '═%.0s' $(seq 1 $width))${RESET}\n"
}

ensure_base_tools() {
    if command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
        return 0
    fi

    info "Installing base tools..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq -o Dpkg::Use-Pty=0 -o APT::Color=0 >/dev/null 2>&1
    apt-get install -y -qq -o Dpkg::Use-Pty=0 -o APT::Color=0 git ca-certificates curl >/dev/null 2>&1
}

run_bootstrap() {
    info "Certificate mode: ${CERT_MODE} - $(cert_mode_label)"
    info "Source branch: ${BRANCH}"
    ensure_base_tools
    cd /root

    if [[ -d "$INSTALL_DIR" ]]; then
        info "Directory ${INSTALL_DIR} already exists - trying to reuse it safely..."
        cd "$INSTALL_DIR"
        if [[ -d .git ]]; then
            git fetch origin "$BRANCH" --quiet || warn "Could not fetch updates, continuing with local copy"
            git checkout "$BRANCH" --quiet 2>/dev/null || true
            git pull --ff-only origin "$BRANCH" --quiet 2>/dev/null || \
                warn "Fast-forward pull failed, continuing with current files"
        else
            warn "Directory exists but is not a git repository. Using it as-is."
        fi
    else
        info "Cloning repository..."
        git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR" --quiet
        cd "$INSTALL_DIR"
    fi

    info "Starting installer..."
    chmod +x install.sh
    export TRANSFERHUB_HEADER_ALREADY_PRINTED=1
    exec bash install.sh "${BOOTSTRAP_ARGS[@]}"
}

detect_local_branch
parse_args "$@"

print_bootstrap_header

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    error "Root is required. Run with sudo or as root."
fi

run_bootstrap
