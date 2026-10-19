# Shared helpers for bin/*.sh — source it, don't run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK="webstack-network"
WIN_HOSTS="/mnt/c/Windows/System32/drivers/etc/hosts"

say() { printf '  %-9s %s\n' "$1" "$2"; }
die() { echo "error: $*" >&2; exit 1; }

# env_get KEY [default]: a value from .env, read without sourcing (passwords may hold $ or spaces).
env_get() {
    local value=""
    if [ -f "$ROOT/.env" ]; then
        value="$(grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2-)"
    fi
    printf '%s' "${value:-${2:-}}"
}

# env_set KEY VALUE: set a key in .env (VALUE must be sed-safe: letters, digits, commas).
env_set() {
    if grep -qE "^$1=" "$ROOT/.env"; then
        sed -i "s|^$1=.*|$1=$2|" "$ROOT/.env"
    else
        printf '%s=%s\n' "$1" "$2" >>"$ROOT/.env"
    fi
}

# projects_dir: PROJECTS_DIR from .env as an absolute path.
projects_dir() {
    local dir
    dir="$(env_get PROJECTS_DIR ./projects)"
    case "$dir" in
        /*) ;;
        *) dir="$ROOT/${dir#./}" ;;
    esac
    printf '%s' "${dir%/}"
}

# site_hosts: every server_name in nginx/sites/*.conf, minus the catch-all.
site_hosts() {
    grep -hoE '^\s*server_name\s+[^;]+' "$ROOT"/nginx/sites/*.conf \
        | sed -E 's/^\s*server_name\s+//' | tr ' ' '\n' | grep -vE '^(_)?$' | sort -u
}

# host_mapped NAME: true when the Windows or WSL hosts file already points NAME somewhere.
host_mapped() {
    grep -qsE "^\s*[0-9.:]+\s+([^#]*\s)?$1(\s|$)" "$WIN_HOSTS" /etc/hosts
}
