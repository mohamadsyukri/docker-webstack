#!/usr/bin/env bash
# Set up — or repair — the webstack on this machine. Safe to re-run: every step checks first and
# only does what is missing. Never removes a container, volume or database.
#
# Usage: bin/setup.sh [--dry-run]

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# In a dry run, commands are skipped and the say() lines describe what would happen.
run() {
    [ "$DRY" = 1 ] || "$@"
}

command -v docker >/dev/null || die "docker not found — install Docker Desktop and turn on WSL integration"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found"

echo "webstack: $ROOT"
[ "$DRY" = 1 ] && echo "(dry run — nothing changes; the lines below are what a real run would do)"

echo "1. .env"
if [ -f "$ROOT/.env" ]; then
    say ok ".env exists"
else
    run cp "$ROOT/.env.example" "$ROOT/.env"
    say created ".env from .env.example"
fi
for key in REDIS_PASSWORD MYSQL_ROOT_PASSWORD; do
    if [ -n "$(env_get "$key")" ]; then
        say ok "$key is set"
    else
        run env_set "$key" "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
        say generated "$key (random, stored in .env)"
    fi
done

echo "2. folders"
for dir in logs/nginx logs/php83 logs/php84 db/redis; do
    if [ -d "$ROOT/$dir" ]; then
        say ok "$dir"
    else
        run mkdir -p "$ROOT/$dir"
        say created "$dir"
    fi
done
projects="$(projects_dir)"
if [ -d "$projects" ]; then
    say ok "projects: $projects"
else
    run mkdir -p "$projects"
    say created "projects: $projects"
fi

echo "3. network"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    say ok "$NETWORK"
else
    run docker network create "$NETWORK" >/dev/null
    say created "$NETWORK"
fi

echo "4. mysql-local (separate container, not in compose.yaml)"
if docker container inspect mysql-local >/dev/null 2>&1; then
    if docker inspect -f '{{json .NetworkSettings.Networks}}' mysql-local | grep -q "\"$NETWORK\""; then
        say ok "on $NETWORK"
    else
        run docker network connect "$NETWORK" mysql-local
        say connected "mysql-local to $NETWORK"
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' mysql-local)" = "true" ]; then
        say ok "running"
    else
        run docker start mysql-local >/dev/null
        say started "mysql-local"
    fi
    if [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' mysql-local)" = "no" ]; then
        say note "restart policy is 'no', so it stays down after a reboot. To change that: docker update --restart unless-stopped mysql-local"
    fi
else
    run docker run -d --name mysql-local --restart unless-stopped \
        --network "$NETWORK" -p "$(env_get MYSQL_PORT 3306):3306" \
        -e MYSQL_ROOT_PASSWORD="$(env_get MYSQL_ROOT_PASSWORD)" -e MYSQL_ROOT_HOST=% \
        -v mysql-local-data:/var/lib/mysql \
        "$(env_get MYSQL_IMAGE mysql:8.4.10)" --mysql-native-password=ON >/dev/null
    say created "mysql-local ($(env_get MYSQL_IMAGE mysql:8.4.10), data in volume mysql-local-data, root password in .env)"
fi

echo "5. stack"
# Another stack using the same container names (e.g. the old docker-webstack) must be stopped first.
for name in nginx php83 php84 redis mailpit; do
    project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)"
    if [ -n "$project" ] && [ "$project" != "webstack" ]; then
        dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name")"
        if [ "$DRY" = 1 ]; then
            say blocked "'$name' belongs to compose project '$project' ($dir) — a real run stops here until you run: cd $dir && docker compose down"
            blocked=1
            break
        fi
        die "container '$name' belongs to compose project '$project' ($dir). Stop that stack first: cd $dir && docker compose down"
    fi
done
if [ -z "${blocked:-}" ]; then
    (cd "$ROOT" && run docker compose build --quiet)
    say built "PHP images"
    (cd "$ROOT" && run docker compose up -d --wait)
    profiles="$(env_get COMPOSE_PROFILES)"
    say started "nginx, php83, redis, mailpit${profiles:+ + $profiles}"
fi

echo "6. hosts file"
missing=()
for host in $(site_hosts); do
    if host_mapped "$host"; then
        say ok "$host"
    else
        missing+=("$host")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "  Add these to C:\\Windows\\System32\\drivers\\etc\\hosts (Notepad, run as Administrator):"
    for host in "${missing[@]}"; do
        echo "    127.0.0.1 $host"
    done
fi

echo "Done. Sites: $(site_hosts | sed 's#^#http://#' | tr '\n' ' ')— mail: http://localhost:8025"
