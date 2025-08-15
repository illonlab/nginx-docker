#!/bin/bash
set -e

# -------------
# Configuration
# -------------

# Directory where certificates are stored
SSL_DIR="${SSL_DIR:-ssl}"

# Use Let's Encrypt staging environment if set to 1
STAGING=0

# Number of dummy certificate validity days
DUMMY_DAYS=1

# RSA key size in bits
RSA_KEY_SIZE=4096

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

# === Create required directories ===
create_directories() {
    local dirs=("$@")
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        echo "Created directory: $dir"
    done
}

# === Generate dhparam.pem ===
generate_dhparam() {
    local key_length="$1"
    if [[ ! -f "dhparam.pem" ]]; then
        echo "Generating dhparam.pem with ${key_length} bits..."
        openssl dhparam -out dhparam.pem "$key_length"
    else
        echo "dhparam.pem already exists, skipping."
    fi
}

# === Check if a certificate is dummy ===

# Arguments:
#   $1 - path to certificate directory
# Returns:
#   0 if dummy, 1 if real

is_dummy_cert() {
    local cert_path="$1/fullchain.pem"
    if [ ! -f "$cert_path" ]; then
        return 0  # Consider non-existent cert as dummy
    fi

    # Check CN for localhost
    local cn
    cn=$(openssl x509 -noout -subject -in "$cert_path" | grep -o 'CN=[^/]*' | cut -d= -f2)
    if [ "$cn" == "localhost" ]; then
        return 0
    fi

    # Check expiration date (less than 7 days)
    local end_date
    end_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)
    local end_epoch
    end_epoch=$(date -d "$end_date" +%s)
    local now_epoch
    now_epoch=$(date +%s)
    local diff_days=$(( (end_epoch - now_epoch) / 86400 ))
    if [ "$diff_days" -lt 7 ]; then
        return 0
    fi

    return 1  # Real certificate
}

# === Create a temporary dummy certificate ===

# Arguments:
#   $1 - path to certificate directory

create_temp_cert() {
    local cert_dir="$1"
    mkdir -p "$cert_dir"
    
    # Generate dummy certificate
    docker compose -f "compose.yaml" run --rm --entrypoint "\
      openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE \
          -days '$DUMMY_DAYS' \
          -keyout '$cert_dir/privkey.pem' \
          -out '$cert_dir/fullchain.pem' \
          -subj '/CN=localhost'"

    # Copy fullchain.pem to chain.pem
    docker compose -f "compose.yaml" run --rm \
      --entrypoint "cp" \
      "$cert_dir/fullchain.pem" "$cert_dir/chain.pem"
    
    # Copy fullchain.pem to cert.pem
    docker compose -f "compose.yaml" run --rm \
      --entrypoint "cp" \
      "$cert_dir/fullchain.pem" "$cert_dir/cert.pem"

    echo "Dummy certificate created at $cert_dir"
}

# === Request a real certificate using Certbot ===

# Arguments:
#   $1 - domain

request_real_cert() {
    local domain="$1"
    cert_path="$SSL_DIR/live/$domain"

    # Use dummy cert if no cert exists yet
    if ! is_dummy_cert "$cert_path"; then
        echo "$domain already has a real certificate"
        return
    fi

    if [ $STAGING != "0" ]; then
        staging_arg="--staging";
        echo "STAGING = $STAGING"
    fi

    case "$email" in
        "") email_arg="--register-unsafely-without-email" ;;
        *)  email_arg="--email $email" ;;
    esac

    echo "Requesting real certificate for $domain..."
    mkdir -p "$cert_path"

    echo "### Starting nginx ..."
    docker compose  -f "compose.yaml" up --force-recreate -d nginx
    echo

    echo "### Deleting dummy certificate for $domains ..."
    docker compose  -f "compose.yaml" run --rm --entrypoint "\
      rm -Rf /etc/letsencrypt/live/$domains && \
      rm -Rf /etc/letsencrypt/archive/$domains && \
      rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot

    docker compose -f "compose.yaml" run --rm --entrypoint "\
      certbot -v certonly --webroot -w /var/www/certbot \
        $staging_arg \
        $email_arg \
        -d "$domain" \
        --rsa-key-size $RSA_KEY_SIZE \
        --agree-tos \
        --no-eff-email \
        --force-renewal" certbot
    
    echo
    echo "Real certificate obtained for $domain"
    echo
    echo "### Reloading nginx ..."
    docker compose -f "compose.yaml" exec nginx nginx -s reload
}

# -----------
# Preparation
# -----------

load_env

# Validate SSL_DIR: must be set, non-empty, and without spaces
if [[ -z "$SSL_DIR" || "$SSL_DIR" =~ [[:space:]] ]]; then
    echo "Error: Invalid SSL_DIR. Check .env." >&2
    exit 1
fi

# Check if Docker Compose is installed
if ! docker compose version &>/dev/null; then
    echo 'Error: docker compose is not installed.' >&2
    exit 1
fi

# Absolute path to the script's directory
SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Ensure SCRIPT_DIR path has at least 3 directory levels
depth=$(echo "$SCRIPT_DIR" | awk -F'/' '{print NF-1}')
if (( depth < 3 )); then
    echo "Error: SCRIPT_DIR must contain at least 3 directories. Current: $SCRIPT_DIR" >&2
    exit 1
fi

# Default stack name is the script's directory name
DEFAULT_STACK_NAME="$(basename "$SCRIPT_DIR")"
# Default stacks directory is the parent of the script's directory
DEFAULT_STACKS_DIR="$(dirname "$SCRIPT_DIR")"

# Use default stacks directory if STACKS_DIR is unset or contains spaces
[[ -z "$STACKS_DIR" || "$STACKS_DIR" =~ [[:space:]] ]] \
    && STACKS_DIR="$DEFAULT_STACKS_DIR"

# Use default stack name if STACK_NAME is unset or contains spaces
[[ -z "$STACK_NAME" || "$STACK_NAME" =~ [[:space:]] ]] \
    && STACK_NAME="$DEFAULT_STACK_NAME"

echo
echo "SCRIPT_DIR       = $SCRIPT_DIR"
echo "STACKS_DIR       = $STACKS_DIR"
echo "STACK_NAME       = $STACK_NAME"
echo "DEFAULT_STACKS_DIR = $DEFAULT_STACKS_DIR"
echo "DEFAULT_STACK_NAME = $DEFAULT_STACK_NAME"
echo

# Required directories for configs, templates, web content, and SSL
dirs=(
    "${STACKS_DIR}/${STACK_NAME}/conf.d"         # Nginx HTTP configs
    "${STACKS_DIR}/${STACK_NAME}/locations"      # Extra location blocks
    "${STACKS_DIR}/${STACK_NAME}/stream-conf.d"  # Nginx stream (TCP/UDP) configs
    "${STACKS_DIR}/${STACK_NAME}/templates"      # Config templates (envsubst)
    "${STACKS_DIR}/${STACK_NAME}/www/certbot"    # Certbot challenge files
    "${STACKS_DIR}/${STACK_NAME}/www/html"       # Web root
    "${STACKS_DIR}/${STACK_NAME}/ssl"            # SSL certs and keys
)
create_directories "${dirs[@]}"

# Create dhparam.pem if need
generate_dhparam 2048

# ----------
# Main logic
# ----------

for domain in "${CERTBOT_DOMAINS[@]}"; do
    cert_path="$SSL_DIR/live/$domain"

    # If certificate is missing or dummy, create temporary cert
    if is_dummy_cert "$cert_path"; then
        echo "$domain: creating dummy certificate..."
        create_temp_cert "$cert_path"
    fi

    # Try to get real certificate
    request_real_cert "$domain"
done

