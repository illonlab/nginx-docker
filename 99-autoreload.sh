#!/bin/bash
set -eu

WATCHER_ENV_FILE="/etc/nginx/.env" # .env from host
WATCHER_WATCH_PATHS="/etc/nginx/templates /etc/nginx/nginx.conf /etc/letsencrypt/"
WATCHER_DEBOUNCE_TIME="2" # seconds to wait after last change
CERTBOT_LOCK_FILE="/etc/letsencrypt/renewal.lock"

# ---------
# Functions
# ---------

# === Safely load .env files ===
# Usage: load_env          # loads default .env
#        load_env my.env   # loads a custom file
load_env() {
    local env_file="${1:-.env}"  # default to .env if no argument is given

    # Check if the file exists
    [ ! -f "$env_file" ] && return

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Multiline support: join lines ending with \
        while [[ "$line" =~ \\$ ]]; do
            line="${line%\\}"  # remove trailing backslash
            IFS= read -r next || break
            line="$line$next"
        done

        # Split key and value
        local key="${line%%=*}"
        local value="${line#*=}"

        # Trim spaces around key and value
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"

        # Check if the variable name is valid
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "Skipping invalid key: $key" >&2; continue; }

        # Export the variable
        export "$key=$value"
    done < "$env_file"
}

# === Reload nginx safely ===
reload_nginx() {
    echo "[$(date)] [watcher] Loading env and generating configs..."

    set -a
    load_env "$WATCHER_ENV_FILE"
    set +a

    /docker-entrypoint.d/20-envsubst-on-templates.sh

    echo "[$(date)] [watcher] Testing nginx config..."
    if nginx -t; then
        echo "[$(date)] [watcher] Reloading nginx..."
        nginx -s reload
    else
        echo "[$(date)] [watcher] Config test failed, reload skipped"
    fi
}

# -----------
# Preparation
# -----------

# Ensure inotify-tools installed
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "[$(date)] [watcher] Installing inotify-tools..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y inotify-tools
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache inotify-tools
    else
        echo "[$(date)] [watcher] Unsupported package manager. Install inotify-tools manually." >&2
        exit 1
    fi
fi

echo "[$(date)] [watcher] Watching paths: $WATCHER_WATCH_PATHS"

# ----------
# Main logic
# ----------

while true; do
    # Wait for file change with timeout
    if inotifywait -r -e modify,create,delete,move --timeout $WATCHER_DEBOUNCE_TIME --quiet $WATCHER_WATCH_PATHS >/dev/null 2>&1; then
        if [ ! -f "$CERTBOT_LOCK_FILE" ]; then
            reload_nginx
        fi
    fi
done &
