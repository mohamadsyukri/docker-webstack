#!/usr/bin/env bash
# Run Node/npm in a container, inside a project folder — no Node install needed on the host.
# Shares your host npm cache (~/.npm) and runs as you, so files it writes stay yours.
#
# Usage: bin/node.sh <path-under-projects> <command...>
#   bin/node.sh acme/myapp npm ci
#   bin/node.sh acme/myapp npm run build
#
# For `npm run dev`, use host Node for now: Vite writes its hot-reload URL for the machine it
# runs on, and that address isn't reachable from the browser when Vite runs in here.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

path="${1:-}"
[ -n "$path" ] && [ $# -gt 1 ] || die "usage: bin/node.sh <path-under-projects> <command...>"
shift
path="${path#/}"
[ -d "$(projects_dir)/$path" ] || die "$(projects_dir)/$path doesn't exist"

tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-it)
mkdir -p "$HOME/.npm"

exec docker run --rm "${tty[@]}" \
    -u "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
    -v "$HOME/.npm:/tmp/.npm" \
    -v "$(projects_dir):/var/www/projects" -w "/var/www/projects/$path" \
    --network "$NETWORK" \
    "$(env_get NODE_IMAGE node:22-bookworm-slim)" "$@"
