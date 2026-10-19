#!/bin/bash
# Remote tester access for MyProjek2.0 through a Cloudflare quick tunnel.
#
# The tunnel reaches nginx on internal port 8081 (nginx/sites/myprojek-tunnel.conf),
# which asks for a password and turns APP_DEBUG and Debugbar off for tunnel requests only.
# Port 8081 is never published, so only the tunnel container can reach it.
#
# Usage:
#   bin/tester-tunnel.sh start [--no-build]   prepare the app, start the tunnel, print the link
#   bin/tester-tunnel.sh stop                 stop the tunnel (the link stops working)
#   bin/tester-tunnel.sh status               show whether it is running, and its link
#   bin/tester-tunnel.sh password             set a new tester password
#
# Optional: TESTER_PASSWORD=... skips the password prompt for the final check.

set -eo pipefail

WEBSTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# PROJECTS_DIR from .env (relative paths are relative to the webstack folder).
PROJECTS_DIR="$(grep -E '^PROJECTS_DIR=' "$WEBSTACK_DIR/.env" 2>/dev/null | cut -d= -f2- || true)"
case "${PROJECTS_DIR:=./projects}" in /*) ;; *) PROJECTS_DIR="$WEBSTACK_DIR/${PROJECTS_DIR#./}" ;; esac
APP_DIR="$PROJECTS_DIR/icu/MyProjek2.0"
APP_DIR_IN_PHP="/var/www/projects/icu/MyProjek2.0"
CONF_FILE="$WEBSTACK_DIR/nginx/sites/myprojek-tunnel.conf"
PASS_FILE="$WEBSTACK_DIR/nginx/sites/myprojek-tunnel.htpasswd"
TUNNEL_NAME="${TUNNEL_NAME:-myprojek-tunnel}"
NETWORK="webstack-network"
TESTER_USER="tester"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR: $1${NC}" >&2
}

die() {
    error "$1"
    exit 1
}

tunnel_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$TUNNEL_NAME" 2>/dev/null)" = "true" ]
}

tunnel_link() {
    docker logs "$TUNNEL_NAME" 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1 || true
}

# HTTP status of a path on the tunnel entry, asked from inside webstack-network.
internal_status() {
    docker run --rm --network "$NETWORK" curlimages/curl -s -o /dev/null -w '%{http_code}' "http://nginx:8081$1"
}

# Cloudflare edge IP for trycloudflare.com. Checks connect to it directly instead of looking up
# the new link in DNS: asking before the link is published makes the office DNS cache
# "not found" for up to ~15 minutes.
edge_ip() {
    getent ahostsv4 trycloudflare.com | awk 'NR==1 {print $1}'
}

public_status() {
    local url="$1" host
    shift
    host="${url#https://}"
    host="${host%%/*}"
    curl -s -o /dev/null --max-time 15 -w '%{http_code}' --resolve "$host:443:$EDGE_IP" "$@" "$url" || true
}

vite_dev_running() {
    pgrep -f "$APP_DIR/node_modules/.bin/vite" >/dev/null 2>&1
}

write_conf_if_missing() {
    [ -f "$CONF_FILE" ] && return 0
    log "Tunnel nginx entry missing — recreating $CONF_FILE"
    cat > "$CONF_FILE" <<'EOF'
# Cloudflare quick-tunnel entry for remote testers. Port 8081 is not published,
# so only the cloudflared container on webstack-network can reach it.
server {
    listen 8081 default_server;
    server_name _;
    root /var/www/projects/icu/MyProjek2.0/public;
    index index.php index.html;

    auth_basic "MyProjek test";
    auth_basic_user_file /etc/nginx/conf.d/myprojek-tunnel.htpasswd;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include /etc/nginx/fastcgi_params;
        fastcgi_pass php83:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTPS on;
        fastcgi_param APP_DEBUG false;
        fastcgi_param DEBUGBAR_ENABLED false;
        fastcgi_param DEBUGBAR_OPEN_STORAGE false;
        fastcgi_index index.php;
    }
}
EOF
}

set_password() {
    [ -t 0 ] || die "Run this in a terminal — it asks you to type the password."
    echo "Type the tester password twice (use 12+ characters; nothing shows while typing)."
    local hash
    hash="$(openssl passwd -apr1)" || die "Passwords did not match — nothing changed."
    [[ "$hash" == '$apr1$'* ]] || die "Could not create the password — nothing changed."
    printf '%s:%s\n' "$TESTER_USER" "$hash" > "$PASS_FILE"
    chmod 644 "$PASS_FILE"
    log "Password saved. It takes effect immediately."
}

# Fail if the nginx entry lost any of the settings that keep the tunnel safe.
check_conf_settings() {
    local setting
    for setting in 'auth_basic_user_file' 'HTTPS on' 'APP_DEBUG false' 'DEBUGBAR_ENABLED false' 'DEBUGBAR_OPEN_STORAGE false'; do
        grep -q "$setting" "$CONF_FILE" || die "$CONF_FILE is missing '$setting' — fix it or delete the file so it is recreated."
    done
}

check_code_state() {
    local branch unmerged changed
    branch="$(git -C "$APP_DIR" branch --show-current)"
    log "Branch: $branch — the tester sees exactly what is on disk."
    if git -C "$APP_DIR" rev-parse -q --verify MERGE_HEAD >/dev/null; then
        unmerged="$(git -C "$APP_DIR" diff --name-only --diff-filter=U | wc -l)"
        if [ "$unmerged" -gt 0 ]; then
            warn "A merge is in progress ($unmerged unmerged files). Finish it if that code is not ready to test."
        else
            warn "A merge is in progress (conflicts resolved, not committed yet)."
        fi
    fi
    changed="$(git -C "$APP_DIR" status --porcelain | wc -l)"
    [ "$changed" -gt 0 ] && log "$changed uncommitted file(s) will be part of the test."
    return 0
}

prepare_frontend() {
    local skip_build="$1"
    if vite_dev_running; then
        log "Stopping npm run dev (it points the tester's browser at their own localhost)..."
        pkill -INT -f "$APP_DIR/node_modules/.bin/vite" || true
        sleep 2
        vite_dev_running && die "npm run dev is still running — stop it with Ctrl+C and run this again."
    fi
    rm -f "$APP_DIR/public/hot"

    if [ "$skip_build" = "1" ]; then
        log "Skipping npm run build (--no-build)."
        return 0
    fi
    log "Building the frontend (about 1 minute)..."
    (cd "$APP_DIR" && npm run build 2>&1 | tail -1)
}

# The tunnel entry switches debug off through fastcgi params, which a cached config ignores.
clear_config_cache() {
    if [ -f "$APP_DIR/bootstrap/cache/config.php" ]; then
        log "Config is cached — clearing it so the tunnel can hide debug output..."
        docker exec php83 php "$APP_DIR_IN_PHP/artisan" config:clear >/dev/null
    fi
}

ensure_nginx_gate() {
    local code
    code="$(internal_status /)"
    if [ "$code" != "401" ]; then
        log "Reloading nginx to load the tunnel entry..."
        docker exec nginx nginx -t >/dev/null 2>&1 || die "nginx config test failed — run: docker exec nginx nginx -t"
        docker exec nginx nginx -s reload >/dev/null 2>&1
        sleep 1
        code="$(internal_status /)"
    fi
    [ "$code" = "401" ] || die "Tunnel entry answered $code instead of 401 (password prompt)."
    log "Password gate is on."
}

start_tunnel() {
    if tunnel_running; then
        log "Tunnel already running — keeping the same link."
        return 0
    fi
    docker rm -f "$TUNNEL_NAME" >/dev/null 2>&1 || true
    log "Starting the Cloudflare tunnel..."
    docker run -d --name "$TUNNEL_NAME" --network "$NETWORK" cloudflare/cloudflared:latest \
        tunnel --no-autoupdate --url http://nginx:8081 >/dev/null
}

wait_for_link() {
    local link="" i
    for i in $(seq 1 30); do
        link="$(tunnel_link)"
        [ -n "$link" ] && break
        sleep 2
    done
    [ -n "$link" ] || die "No link after 60 s — check: docker logs $TUNNEL_NAME"
    echo "$link"
}

verify_public() {
    local link="$1" code="000" i password
    EDGE_IP="$(edge_ip)"
    [ -n "$EDGE_IP" ] || die "Cannot reach Cloudflare (trycloudflare.com does not resolve)."
    for i in $(seq 1 30); do
        code="$(public_status "$link/")"
        [ "$code" = "401" ] && break
        sleep 3
    done
    [ "$code" = "401" ] || die "Public link answered $code instead of 401 (password prompt)."
    log "Public link asks for the password."

    password="${TESTER_PASSWORD:-}"
    if [ -z "$password" ] && [ -t 0 ]; then
        read -rsp "Tester password for the final check (Enter to skip): " password
        echo
    fi
    if [ -z "$password" ]; then
        warn "Final check skipped — open the link yourself and make sure there is no Debugbar strip."
        return 0
    fi

    code="$(public_status "$link/" -u "$TESTER_USER:$password")"
    [ "$code" = "401" ] && die "That password was rejected."
    [ "$(public_status "$link/_ignition/health-check" -u "$TESTER_USER:$password")" = "404" ] \
        || die "Error details are exposed on the tunnel — do not send the link."
    [ "$(public_status "$link/_debugbar/open" -u "$TESTER_USER:$password")" = "404" ] \
        || die "Debugbar is exposed on the tunnel — do not send the link."
    log "Password works; error details and Debugbar are hidden."
}

cmd_start() {
    local skip_build=0 link container
    [ "$1" = "--no-build" ] && skip_build=1

    docker info >/dev/null 2>&1 || die "Docker is not running — start Docker Desktop first."
    for container in nginx php83; do
        [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ] \
            || die "Container '$container' is not running."
    done

    write_conf_if_missing
    check_conf_settings
    if [ ! -s "$PASS_FILE" ]; then
        log "No tester password yet — set one now."
        set_password
    fi

    check_code_state
    prepare_frontend "$skip_build"
    clear_config_cache
    ensure_nginx_gate
    start_tunnel
    link="$(wait_for_link)"
    verify_public "$link"

    echo
    echo -e "${GREEN}=== Ready. Send your tester: ===${NC}"
    echo "  Link:      $link/login-as/id/<ID>"
    echo "  Username:  $TESTER_USER"
    echo "  Password:  (the one you set)"
    echo "  Plus the persona IDs they should use."
    echo
    echo "While they test:"
    echo "  - Keep the laptop awake (Windows Sleep = Never)."
    echo "  - Do not run npm run dev. JS/CSS edits need: npm run build. PHP/Blade edits show instantly."
    echo "  - Queue jobs need a worker: docker exec -it php83 php $APP_DIR_IN_PHP/artisan queue:work"
    echo "  - If the link says 'site can't be reached' on YOUR PC, your office DNS is still caching it"
    echo "    as not found (up to ~15 min). Try your phone on mobile data. The tester is not affected."
    echo "When done:  bin/tester-tunnel.sh stop   (then npm run dev again)"
}

cmd_stop() {
    if docker inspect "$TUNNEL_NAME" >/dev/null 2>&1; then
        docker rm -f "$TUNNEL_NAME" >/dev/null
        log "Tunnel stopped — the link no longer works."
    else
        log "No tunnel was running."
    fi
    echo "Resume your own work with: npm run dev"
}

cmd_status() {
    local link
    if tunnel_running; then
        link="$(tunnel_link)"
        log "Tunnel is running: $link"
        EDGE_IP="$(edge_ip)"
        if [ -n "$link" ] && [ "$(public_status "$link/")" = "401" ]; then
            log "Link answers with the password prompt."
        else
            warn "Link is not answering yet — run status again in a minute."
        fi
    else
        log "Tunnel is not running."
    fi
    if vite_dev_running || [ -f "$APP_DIR/public/hot" ]; then
        warn "npm run dev is on (or public/hot exists) — the tester's pages will be unstyled."
    fi
    return 0
}

case "$1" in
    start)
        shift
        cmd_start "$@"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    password)
        set_password
        ;;
    *)
        echo "Usage: $0 {start [--no-build]|stop|status|password}"
        exit 1
        ;;
esac
