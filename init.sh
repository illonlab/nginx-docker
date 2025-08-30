#!/bin/bash

#set -e
set -euo pipefail

# -------------
# Configuration
# -------------

# Use Let's Encrypt staging environment if set to 1
STAGING=0

# Number of dummy certificate validity days
DUMMY_DAYS=1

# RSA key size in bits
RSA_KEY_SIZE=4096

# dhparam.pem size in bits
DH_PARAM_SIZE=2048

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
    
    echo
    echo "cert_path =$cert_path"

    if [ ! -f "$cert_path" ]; then
        echo "Certificate file does not exist"

        return 0  # Consider non-existent cert as dummy
    fi

    # Check CN for localhost
    local cn
    cn=$(openssl x509 -noout -subject -in "$cert_path" | grep -o 'CN=[^/]*' | cut -d= -f2)
    if [ "$cn" == "localhost" ]; then
        echo "Common Name is localhost"

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
        echo "Certificate expires in less than 7 days ($diff_days days left)"

        return 0
    fi
    
    echo "Certificate is valid and not expiring soon (expires in $diff_days days)"
    return 1  # Real certificate
}

# === Create a temporary dummy certificate ===
# Arguments:
#   $1 - path to certificate directory inside certbot container
create_temp_cert() {
    local cert_dir="$1"

    # Create directory for dummy certificate files
    docker compose -f "compose.yaml" run --rm \
      --entrypoint "mkdir -p $cert_dir" certbot

    # Generate dummy certificate
    docker compose -f "compose.yaml" run --rm --entrypoint "\
      openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE \
          -days $DUMMY_DAYS \
          -keyout '$cert_dir/privkey.pem' \
          -out '$cert_dir/fullchain.pem' \
          -subj '/CN=localhost'" certbot

    # Copy fullchain.pem to chain.pem
    docker compose -f "compose.yaml" run --rm \
      --entrypoint cp \
      certbot \
      "$cert_dir/fullchain.pem" "$cert_dir/chain.pem"
    
    # Copy fullchain.pem to cert.pem
    docker compose -f "compose.yaml" run --rm \
      --entrypoint cp \
      certbot \
      "$cert_dir/fullchain.pem" "$cert_dir/cert.pem"

    echo
    echo "Dummy certificate created at $cert_dir"
}

# === Request a real certificate using Certbot ===
# Arguments:
#   $1 - domain
request_real_cert() {
    local cert_dir="$1"
    local domain="$(basename "$cert_dir")"
    local email="${SSL_EMAIL:-}"
    local staging_arg=""

    if [ $STAGING != "0" ]; then
        staging_arg="--staging";
        echo "STAGING = $STAGING"
    fi

    case "$email" in
        "") email_arg="--register-unsafely-without-email" ;;
        *)  email_arg="--email $email" ;;
    esac

    echo
    echo "Requesting real certificate for $domain..."
    echo
    echo "### Starting nginx ..."
    echo

    docker compose -f "compose.yaml" up --force-recreate -d nginx

    # Wait until nginx is ready
    echo -n "Waiting for nginx to be ready"
    until curl -sSf http://localhost >/dev/null 2>&1; do
        echo -n "."
        sleep 1
    done
    echo " done! Nginx is up and serving HTTP."

    echo
    echo "### Deleting dummy certificate for $domain ..."
    echo

    docker compose -f "compose.yaml" run --rm --entrypoint "\
      rm -rf $cert_dir && \
      rm -rf $cert_dir && \
      rm -rf $cert_dir" certbot

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
    echo

    docker compose -f "compose.yaml" exec nginx nginx -s reload

    docker compose -f "compose.yaml" up -d certbot
}

# === Print usage information and available options ===
arg_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Options:
    --staging           Enable staging mode
    --test              Enable testing mode (pauses before action + staging)
    --clean             Clean up directories ()
    -h, --help          Show this help message
    
EOF
}

# === Parse command-line arguments ===
arg_parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --staging)
                STAGING=1
                ;;
            --test)
                TESTING=1
                STAGING=1
                ;;
            --clean)
                CLEANUP=1
                ;;
            -h|--help)
                arg_usage
                exit 0
                ;;
            *)
                echo "Error: Unknown parameter '$1'" >&2
                arg_usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

# === Main entry point for argument handling ===
arg_main() {
    arg_parse_arguments "$@"
    
    echo
    # Status summary
    echo "Certificates: $([[ ${STAGING:-0} -eq 1 ]] && echo "STAGING" || echo "PROD")"
    echo "Mode:         $([[ ${TESTING:-0} -eq 1 ]] && echo "TESTING" || echo "PROD")"
    echo "Cleanup:      $([[ ${CLEANUP:-0} -eq 1 ]] && echo "ON" || echo "OFF")"
    echo
}

# === Function to pause if testing mode is enabled ===
testing() {
    if [[ ${TESTING:-0} -eq 1 ]]; then
        echo
        echo "TESTING mode active. Ready to proceed."
        read -p "Press Enter to continue..."
        echo
    fi
}

# === Function to clean up directories if CLEANUP is enabled ===
# Example usage: cleanup ./dir1 ./dir2
cleanup() {
    local dirs=("$@")  # accept multiple directories

    if [[ ${CLEANUP:-0} -eq 1 ]]; then
        echo
        echo "CLEANUP is enabled."
        echo "WARNING: the following directories will be removed:"
        for dir in "${dirs[@]}"; do
            echo "  $dir"
        done
        read -p "Press Enter to continue or Ctrl+C to abort..."
        sudo rm -rf "${dirs[@]}"
        echo "Cleanup complete."
        echo
    fi
}

# -----------
# Preparation
# -----------

load_env

# Handle command-line arguments
arg_main "$@"

# Absolute path to the script's directory
readonly SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

# Define the name of this script
readonly SCRIPT_NAME=$(basename "$0")

# SSL directory inside the docker containers
DOCKER_SSL_DIR="${DOCKER_SSL_DIR:-/etc/letsencrypt/live}"

# SSL directory on this host
HOST_SSL_DIR="${HOST_SSL_DIR:-./ssl/live}"

# Validate DOCKER_SSL_DIR: must be set, non-empty, and without spaces
if [[ -z "$DOCKER_SSL_DIR" || "$DOCKER_SSL_DIR" =~ [[:space:]] ]]; then
    echo "Error: Invalid DOCKER_SSL_DIR. Check .env." >&2
    exit 1
fi

# Validate HOST_SSL_DIR: must be set, non-empty, and without spaces
if [[ -z "$HOST_SSL_DIR" || "$HOST_SSL_DIR" =~ [[:space:]] ]]; then
    echo "Error: Invalid HOST_SSL_DIR. Check .env." >&2
    exit 1
fi

# Check if Docker Compose is installed
if ! docker compose version &>/dev/null; then
    echo 'Error: docker compose is not installed.' >&2
    exit 1
fi

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
[[ -z "${STACKS_DIR:-}" || "${STACKS_DIR}" =~ [[:space:]] ]] \
    && STACKS_DIR="$DEFAULT_STACKS_DIR"

# Use default stack name if STACK_NAME is unset or contains spaces
[[ -z "${STACK_NAME:-}" || "${STACK_NAME}" =~ [[:space:]] ]] \
    && STACK_NAME="$DEFAULT_STACK_NAME"

echo
echo "SCRIPT_DIR       = $SCRIPT_DIR"
echo "STACKS_DIR       = $STACKS_DIR"
echo "STACK_NAME       = $STACK_NAME"
echo "DEFAULT_STACKS_DIR = $DEFAULT_STACKS_DIR"
echo "DEFAULT_STACK_NAME = $DEFAULT_STACK_NAME"
echo

# Cleanup dirs (runs only with --clean)
cleanup ./ssl ./conf.d ./stream-conf.d ./locations

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
generate_dhparam $DH_PARAM_SIZE

# Split comma-separated domains into an array
IFS=',' read -r -a CERTBOT_DOMAINS_ARRAY <<< "${CERTBOT_DOMAINS:-}"

# ----------
# Main logic
# ----------

docker compose -f "compose.yaml" run --rm --entrypoint "\
  mkdir -p $DOCKER_SSL_DIR && \
  touch $CERTBOT_LOCK_FILE" certbot

# First loop: create temporary (dummy) certificates for all domains
# This ensures Nginx can start even if multiple domains are configured
for domain in "${CERTBOT_DOMAINS_ARRAY[@]}"; do
    docker_cert_dir="$DOCKER_SSL_DIR/$domain"
    host_cert_dir="$HOST_SSL_DIR/$domain"

    # If certificate is missing or dummy, create temporary cert
    if is_dummy_cert "$host_cert_dir"; then
        echo
        echo "$domain: creating dummy certificate..."
        echo
        create_temp_cert "$docker_cert_dir"
    fi
done

# Second loop: request real certificates
# Run after all temporary certs exist so Nginx can start safely
for domain in "${CERTBOT_DOMAINS_ARRAY[@]}"; do
    docker_cert_dir="$DOCKER_SSL_DIR/$domain"
    host_cert_dir="$HOST_SSL_DIR/$domain"

    # Skip if the domain already has a valid certificate
    if ! is_dummy_cert "$host_cert_dir"; then
        echo
        echo "$domain already has a real certificate"
        echo
        continue
    fi

    testing

    # Try to get real certificate
    request_real_cert "$docker_cert_dir"
done

docker compose -f "compose.yaml" run --rm --entrypoint "\
  rm -f $CERTBOT_LOCK_FILE" certbot
