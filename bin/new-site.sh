#!/usr/bin/env bash
# Add a site: <name>.local -> projects/<path>, served by php83 (default) or php84.
# Uses <path>/public as the web root when it exists (Laravel), otherwise <path> itself.
#
# Usage: bin/new-site.sh <name> <path-under-projects> [php83|php84]
#   bin/new-site.sh myapp acme/myapp

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

name="${1:-}"
path="${2:-}"
php="${3:-php83}"

[ -n "$name" ] && [ -n "$path" ] || die "usage: bin/new-site.sh <name> <path-under-projects> [php83|php84]"
[[ "$name" =~ ^[a-z0-9-]+$ ]] || die "name must be lowercase letters, digits or dashes"
case "$php" in
    php83 | php84) ;;
    *) die "php must be php83 or php84" ;;
esac

path="${path#/}"
path="${path%/}"
conf="$ROOT/nginx/sites/$name.conf"
dir="$(projects_dir)/$path"
[ -e "$conf" ] && die "$conf already exists — edit it instead"
[ -d "$dir" ] || die "$dir doesn't exist — clone or create the project first"

root="$path"
[ -d "$dir/public" ] && root="$path/public"

sed -e "s|{{NAME}}|$name|g" -e "s|{{PATH}}|$path|g" -e "s|{{ROOT}}|$root|g" -e "s|{{PHP}}|$php|g" \
    "$ROOT/nginx/site.conf.template" >"$conf"
say created "nginx/sites/$name.conf (root /var/www/projects/$root, $php)"

if [ "$php" = "php84" ]; then
    profiles="$(env_get COMPOSE_PROFILES)"
    if [[ ",$profiles," != *",php84,"* ]]; then
        env_set COMPOSE_PROFILES "${profiles:+$profiles,}php84"
        say updated ".env COMPOSE_PROFILES now includes php84"
    fi
    (cd "$ROOT" && docker compose up -d --wait php84 >/dev/null)
    say started "php84"
fi

if [ "$(docker inspect -f '{{.State.Running}}' nginx 2>/dev/null)" = "true" ]; then
    if docker exec nginx nginx -t >/dev/null 2>&1; then
        docker exec nginx nginx -s reload >/dev/null
        say reloaded "nginx"
    else
        rm -f "$conf"
        docker exec nginx nginx -t || true
        die "nginx rejected the new site, so nginx/sites/$name.conf was removed again"
    fi
else
    say note "nginx isn't running — the site loads when the stack starts (bin/setup.sh)"
fi

if host_mapped "$name.local"; then
    say ok "$name.local is in your hosts file"
else
    echo "  Add to C:\\Windows\\System32\\drivers\\etc\\hosts (Notepad, run as Administrator):"
    echo "    127.0.0.1 $name.local"
fi
echo "Open: http://$name.local"
