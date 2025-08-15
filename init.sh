#!/bin/bash
set -e

# Use Let's Encrypt staging environment if set to 1
STAGING=0

SSL_DIR="${SSL_DIR:-ssl}"

# --- Functions ---

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

# === Create required directories ===
create_directories() {
    local dirs=("$@")
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        echo "Created directory: $dir"
    done
}

# === Function to safely load .env files ===

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

# Function to create temporary certificates
create_temp_certs() {
    local rsa_key_size=4096
    local certbot_ssl_path="/etc/letsencrypt/live"
    local host_ssl_path="$SSL_DIR/live/$domain"
    local email="${SSL_EMAIL:-hello@example.com}"

    # Parse domains from environment variable
    local domains=(${CERTBOT_DOMAINS:-example.com})

    for domain in "${domains[@]}"; do
        echo "### Creating dummy certificate for $domain ..."
        mkdir -p "$host_ssl_path/$domain"

        # Generate temporary certificate
        docker compose -f "compose.yaml" run --rm --entrypoint "\
          openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1 \
            -keyout '$certbot_ssl_path/$domain/privkey.pem' \
            -out '$certbot_ssl_path/$domain/fullchain.pem' \
            -subj '/CN=localhost'" certbot

        # Create compatible certificate files
        cp "$host_ssl_path/$domain/fullchain.pem" "$host_ssl_path/$domain/chain.pem"
        cp "$host_ssl_path/$domain/fullchain.pem" "$host_ssl_path/$domain/cert.pem"
    done
}


# --- Preparation ---

load_env

# Check SSL_DIR
# If SSL_DIR is unset, empty, or contains spaces, exit with error
if [[ -z "$SSL_DIR" || "$SSL_DIR" =~ [[:space:]] ]]; then
    echo "Error: SSL_DIR is not set, empty, or contains spaces. Please set SSL_DIR in .env correctly." >&2
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo 'Error: docker compose is not installed.' >&2
    exit 1
fi

# Define the directory where this script is located
SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Validate directory depth (at least 3)
depth=$(echo "$SCRIPT_DIR" | awk -F'/' '{print NF-1}')
if (( depth < 3 )); then
    echo "Error: SCRIPT_DIR must contain at least 3 directories. Current: $SCRIPT_DIR" >&2
    exit 1
fi

# Compute defaults
DEFAULT_STACK_NAME="$(basename "$SCRIPT_DIR")"
DEFAULT_STACKS_DIR="$(dirname "$SCRIPT_DIR")"

# Apply defaults if vars are unset, empty, or contain spaces 
[[ -z "$STACKS_DIR" || "$STACKS_DIR" =~ [[:space:]] ]] && STACKS_DIR="$DEFAULT_STACKS_DIR"
[[ -z "$STACK_NAME" || "$STACK_NAME" =~ [[:space:]] ]] && STACK_NAME="$DEFAULT_STACK_NAME"

echo
echo "SCRIPT_DIR       = $SCRIPT_DIR"
echo "STACKS_DIR       = $STACKS_DIR"
echo "STACK_NAME       = $STACK_NAME"
echo "DEFAULT_STACKS_DIR = $DEFAULT_STACKS_DIR"
echo "DEFAULT_STACK_NAME = $DEFAULT_STACK_NAME"
echo

generate_dhparam 2048

dirs=(
    "${STACKS_DIR}/${STACK_NAME}/conf.d"
    "${STACKS_DIR}/${STACK_NAME}/locations"
    "${STACKS_DIR}/${STACK_NAME}/stream-conf.d"
    "${STACKS_DIR}/${STACK_NAME}/templates"
    "${STACKS_DIR}/${STACK_NAME}/www/certbot"
    "${STACKS_DIR}/${STACK_NAME}/www/html"
    "${STACKS_DIR}/${STACK_NAME}/ssl"
)
create_directories "${dirs[@]}"

create_temp_certs

# Pause here for debugging
read -p "Press Enter to continue..."

echo "### Starting nginx ..."
docker compose -f "compose.yaml" up --force-recreate -d nginx

echo "### Deleting dummy certificate for $domains ..."
docker compose  -f "compose.yaml" run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo

echo "STAGING = $STAGING"

echo "### Requesting Let's Encrypt certificates for ${domains[*]} ..."
domain_args=""
for domain in "${domains[@]}"; do
    domain_args="$domain_args -d $domain"
done

case "$email" in
"") email_arg="--register-unsafely-without-email" ;;
*) email_arg="--email $email" ;;
esac

if [ $STAGING != "0" ]; then staging_arg="--staging"; fi

docker compose -f "compose.yaml" run --rm --entrypoint "\
  certbot -v certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --no-eff-email \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker compose -f "compose.yaml" exec nginx nginx -s reload