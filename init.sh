#!/bin/bash

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

generate_dhparam 2048

if [ -f .env ]; then
  eval "$(grep -v '^#' .env | sed 's/^/export /')"
fi

if ! docker compose version &>/dev/null; then
    echo 'Error: docker compose is not installed.' >&2
    exit 1
fi

IFS=' ' read -r -a domains <<< "${CERTBOT_DOMAINS:-example.com}"
rsa_key_size=4096
data_path="./certbot/ssl/"
email="${SSL_EMAIL:-hello@example.com}"
staging=0

if [ "$(find "$data_path" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    read -p "SSL directory not empty. Overwrite? (y/N) " decision
    if [ "$decision" != "y" ] && [ "$decision" != "Y" ]; then
        exit
    fi
fi

create_temp_certs() {
    local domain=$1
    echo "### Creating dummy certificate for $domain ..."
    local path="/etc/letsencrypt/live/$domain"
    mkdir -p "$data_path/live/$domain"
    
    docker compose -f "compose.yaml" run --rm --entrypoint "\
      openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1 \
        -keyout '$path/privkey.pem' \
        -out '$path/fullchain.pem' \
        -subj '/CN=localhost'" certbot
    
    cp "$data_path/live/$domain/fullchain.pem" "$data_path/live/$domain/chain.pem"
    cp "$data_path/live/$domain/fullchain.pem" "$data_path/live/$domain/cert.pem"
}

for domain in "${domains[@]}"; do
    create_temp_certs "$domain"
done

echo "### Starting nginx ..."
docker compose -f "compose.yaml" up --force-recreate -d nginx


echo "### Deleting dummy certificate for $domains ..."
docker compose  -f "compose.yaml" run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo

echo "staging = $staging"

echo "### Requesting Let's Encrypt certificates for ${domains[*]} ..."
domain_args=""
for domain in "${domains[@]}"; do
    domain_args="$domain_args -d $domain"
done

case "$email" in
"") email_arg="--register-unsafely-without-email" ;;
*) email_arg="--email $email" ;;
esac

if [ $staging != "0" ]; then staging_arg="--staging"; fi

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