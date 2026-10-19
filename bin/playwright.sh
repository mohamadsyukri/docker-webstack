#!/usr/bin/env bash
# Run Playwright in the official image that matches the project's installed Playwright version,
# on webstack-network, with every site's *.local name pointing at the nginx container — so the
# browser reaches http://myprojek.local exactly as you do. No Node or browser libraries on the host.
#
# Usage: bin/playwright.sh <path-under-projects> [command...]   (default: npx playwright test)
#   bin/playwright.sh icu/MyProjek2.0
#   bin/playwright.sh icu/MyProjek2.0 npx playwright test e2e/login.spec.ts
#
# PLAYWRIGHT_* variables set in your shell are passed through (e.g. PLAYWRIGHT_BASE_URL);
# PLAYWRIGHT_HEADLESS defaults to 1.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

path="${1:-}"
[ -n "$path" ] || die "usage: bin/playwright.sh <path-under-projects> [command...]"
shift
path="${path#/}"
dir="$(projects_dir)/$path"

pkg="$dir/node_modules/@playwright/test/package.json"
[ -f "$pkg" ] || pkg="$dir/node_modules/playwright/package.json"
[ -f "$pkg" ] || die "no Playwright in $dir/node_modules — install it first: bin/node.sh $path npm ci"
version="$(grep -m1 '"version"' "$pkg" | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
image="mcr.microsoft.com/playwright:v${version}-noble"

nginx_ip="$(docker inspect -f '{{(index .NetworkSettings.Networks "webstack-network").IPAddress}}' nginx 2>/dev/null || true)"
[ -n "$nginx_ip" ] || die "nginx isn't running on $NETWORK — start the stack first (bin/setup.sh)"
hosts=()
for host in $(site_hosts); do
    hosts+=(--add-host "$host:$nginx_ip")
done

envs=(-e "PLAYWRIGHT_HEADLESS=${PLAYWRIGHT_HEADLESS:-1}")
while IFS='=' read -r key _; do
    if [[ "$key" == PLAYWRIGHT_* && "$key" != "PLAYWRIGHT_HEADLESS" ]]; then
        envs+=(-e "$key")
    fi
done < <(env)

[ $# -gt 0 ] || set -- npx playwright test
tty=()
[ -t 0 ] && [ -t 1 ] && tty=(-it)

exec docker run --rm "${tty[@]}" --init --ipc=host \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    "${envs[@]}" "${hosts[@]}" \
    --network "$NETWORK" \
    -v "$(projects_dir):/var/www/projects" -w "/var/www/projects/$path" \
    "$image" "$@"
