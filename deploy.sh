#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
DOCKER_PLUGIN_CONFIG="$SCRIPT_DIR/zabbix/agent2.d/plugins.d/docker.conf"

fail() {
    printf 'Erreur : %s\n' "$*" >&2
    exit 1
}

if (($#)); then
    case "$1" in
        --help|-h)
            printf 'Usage : bash ./deploy.sh\n'
            printf 'Déploie WordPress, n8n et Zabbix sur cette VM Linux.\n'
            exit 0
            ;;
        *)
            fail "Aucune option n'est nécessaire. Lancez simplement : bash ./deploy.sh"
            ;;
    esac
fi

for file in "$COMPOSE_FILE" "$ENV_FILE" "$SCRIPT_DIR/Caddyfile" "$DOCKER_PLUGIN_CONFIG"; do
    [[ -f "$file" ]] || fail "Fichier requis introuvable : $file. Copiez .env.example vers .env avant de relancer."
done

env_value() {
    local name="$1"
    local value
    value="$(awk -v name="$name" '
        index($0, name "=") == 1 {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$ENV_FILE")"
    value="${value%$'\r'}"
    printf '%s' "$value"
}

required_variables=(
    MYSQL_ROOT_PASSWORD WORDPRESS_DB_NAME WORDPRESS_DB_USER WORDPRESS_DB_PASSWORD
    N8N_DB_NAME N8N_DB_USER N8N_DB_PASSWORD N8N_ENCRYPTION_KEY
    ZABBIX_DB_NAME ZABBIX_DB_USER ZABBIX_DB_PASSWORD ZABBIX_DB_ROOT_PASSWORD
)
for name in "${required_variables[@]}"; do
    value="$(env_value "$name")"
    [[ -n "$value" ]] || fail "La variable $name est manquante ou vide dans .env."
done

secret_variables=(
    MYSQL_ROOT_PASSWORD WORDPRESS_DB_PASSWORD N8N_DB_PASSWORD
    ZABBIX_DB_PASSWORD ZABBIX_DB_ROOT_PASSWORD
)
for name in "${secret_variables[@]}"; do
    value="$(env_value "$name")"
    [[ "$value" != replace-with-* && ${#value} -ge 24 ]] ||
        fail "Remplacez $name par un mot de passe d'au moins 24 caractères."
done

encryption_key="$(env_value N8N_ENCRYPTION_KEY)"
[[ "$encryption_key" != replace-with-* && ${#encryption_key} -ge 32 ]] ||
    fail "N8N_ENCRYPTION_KEY doit compter au moins 32 caractères."

command -v docker >/dev/null 2>&1 || fail "Docker est requis. Installez Docker Engine avec Docker Compose v2."
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 est requis. Vérifiez l'installation de Docker."

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    if ((EUID == 0)); then
        ufw allow 80/tcp comment 'WordPress via Caddy' ||
            fail "Impossible d'ouvrir TCP 80 dans UFW."
    elif command -v sudo >/dev/null 2>&1; then
        sudo ufw allow 80/tcp comment 'WordPress via Caddy' ||
            fail "Impossible d'ouvrir TCP 80 dans UFW avec sudo."
    else
        fail "UFW est actif. Exécutez le script en root ou ajoutez manuellement la règle : ufw allow 80/tcp."
    fi
fi

chmod 600 "$ENV_FILE"

printf 'Validation de la configuration Docker Compose...\n'
docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" config --quiet ||
    fail "La configuration Compose est invalide. Vérifiez le fichier .env."

printf 'Démarrage de WordPress, n8n et Zabbix...\n'
docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" up -d --build ||
    fail "Le déploiement Compose a échoué. Consultez les journaux avec docker compose logs."

if command -v curl >/dev/null 2>&1; then
    http_status="000"
    for attempt in {1..12}; do
        if http_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
            --max-time 10 http://127.0.0.1/)"; then
            case "$http_status" in
                2*|3*) break ;;
            esac
        else
            http_status="000"
        fi
        sleep 5
    done
    case "$http_status" in
        2*|3*) printf 'Vérification locale réussie : Caddy/WordPress répond avec HTTP %s.\n' "$http_status" ;;
        *)
            if ! docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
                -f "$COMPOSE_FILE" logs --tail=30 reverse-proxy wordpress >&2; then
                printf 'Impossible de récupérer les journaux Docker du proxy et de WordPress.\n' >&2
            fi
            fail "Caddy/WordPress ne répond pas correctement en local (dernier code HTTP : $http_status)."
            ;;
    esac
else
    printf "curl n'est pas installé; vérification HTTP locale ignorée.\n" >&2
fi

printf 'Dans le portail Azure, vérifiez que cette VM possède une IP publique et que son NSG autorise le trafic entrant TCP 80.\n'
