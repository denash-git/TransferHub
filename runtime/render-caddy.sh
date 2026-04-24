#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCE_ENV="${PROJECT_ROOT}/instance.env"
USERS_DB="${PROJECT_ROOT}/users.db"
CADDY_CONFIG_DIR="${PROJECT_ROOT}/caddy"
CADDY_CONFIG="${CADDY_CONFIG_DIR}/Caddyfile"

error() {
    echo "render-caddy.sh: $1" >&2
    exit 1
}

[[ -f "$INSTANCE_ENV" ]] || error "instance.env не найден: ${INSTANCE_ENV}"
[[ -f "$USERS_DB" ]] || error "users.db не найден: ${USERS_DB}"

# shellcheck source=/dev/null
set -a; source "$INSTANCE_ENV"; set +a

: "${DOMAIN:?DOMAIN не задан}"
: "${SPEEDTEST_PREFIX:?SPEEDTEST_PREFIX не задан}"

CERT_MODE="${CERT_MODE:-prod}"
case "$CERT_MODE" in
    prod)    ACME_GLOBAL_OPTIONS="" ;;
    staging) ACME_GLOBAL_OPTIONS="    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory" ;;
    *)       error "неподдерживаемый CERT_MODE: ${CERT_MODE}" ;;
esac

USERS_BLOCK=""
while IFS=$'\t' read -r nick username password enabled; do
    [[ -z "${nick:-}" || -z "${username:-}" || -z "${password:-}" || -z "${enabled:-}" ]] && continue
    [[ "$enabled" != "1" ]] && continue
    USERS_BLOCK+="        basic_auth ${username} ${password}"$'\n'
done < "$USERS_DB"

[[ -n "$USERS_BLOCK" ]] || error "нет ни одного активного пользователя в users.db"

mkdir -p "$CADDY_CONFIG_DIR"

cat > "$CADDY_CONFIG" <<EOF
{
${ACME_GLOBAL_OPTIONS}
    order forward_proxy before file_server
}

:80 {
    redir https://{host}{uri} permanent
}

:443, ${DOMAIN} {
    tls ${ADMIN_EMAIL:-}

    @speedtest path_regexp speedtest ^/${SPEEDTEST_PREFIX}[A-Za-z0-9]{24}(/.*)?$
    handle @speedtest {
        reverse_proxy 127.0.0.1:9080 {
            header_down -Server
        }
    }

    route {
        forward_proxy {
${USERS_BLOCK}            hide_ip
            hide_via
            probe_resistance
        }

        root * /root/TransferHub/caddy/fakesite
        file_server
    }

    log {
        output stderr
        level ERROR
    }
}
EOF

sed -i '/^[[:space:]]*tls[[:space:]]*$/d' "$CADDY_CONFIG"
