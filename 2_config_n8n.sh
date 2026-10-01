#!/bin/bash
set -euo pipefail

CONFIG_FILE="$HOME/.n8n_api_key.conf"

# Fonction pour sauvegarder la config
save_config() {
    echo "N8N_IP=$1" > "$CONFIG_FILE"
    echo "N8N_API_KEY=$2" >> "$CONFIG_FILE"
    echo "✓ Configuration sauvegardée dans $CONFIG_FILE"
}

# Fonction pour charger la config
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

# Fonction pour supprimer la config
delete_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo "✓ Ancienne configuration supprimée."
    else
        echo "ℹ️ Pas de configuration existante à supprimer."
    fi
}

# Fonction de validation IP
validate_ip() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0 || return 1
}

# Fonction pour valider email
validate_email() {
    [[ $1 =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && return 0 || return 1
}

# Menu de vérification si le service est prêt via curl
wait_service_ready() {
    echo "⏳ Vérification de la disponibilité du service n8n..."
    MAX_RETRIES=120
    COUNT=0
    while true; do
        if curl -s --fail --connect-timeout 5 "http://$PUBLIC_IP:5678" >/dev/null; then
            echo "✓ Le service est prêt pour utilisation."
            break
        fi
        COUNT=$((COUNT +1))
        if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
            echo "⚠️ Timeout : n8n n'a pas répondu après 10 min."
            break
        fi
        echo "En attente..."
        sleep 5
    done
}

# Fonction pour créer un utilisateur manuellement (avec info et pause)
create_user() {
    echo "=== Création d'un utilisateur n8n ==="
    # Supprime ancienne config si existante
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        echo "⚠️ Ancienne configuration supprimée."
    fi

    while true; do
        read -p "Adresse IP: " IP
        validate_ip "$IP" && break || echo "IP invalide."
    done
    while true; do
        read -p "Email: " EMAIL
        validate_email "$EMAIL" && break || echo "Email invalide."
    done
    while true; do
        read -p "Prénom: " FIRSTNAME
        [[ -n "$FIRSTNAME" ]] && break || echo "Prénom vide."
    done
    while true; do
        read -p "Nom: " LASTNAME
        [[ -n "$LASTNAME" ]] && break || echo "Nom vide."
    done
    while true; do
        read -sp "Mot de passe (min 8, maj, chif): " PASSWORD
        echo
        if [[ ${#PASSWORD} -lt 8 || ! "$PASSWORD" =~ [0-9] || ! "$PASSWORD" =~ [A-Z] ]]; then
            echo "Mot de passe non valide."
        else
            break
        fi
    done
    echo "Création en cours..."
    RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/n8n_response.json -X POST "http://${IP}:5678/rest/owner/setup" \
      -H "Content-Type: application/json" \
      -d '{
        "email": "'"$EMAIL"'",
        "firstName": "'"$FIRSTNAME"'",
        "lastName": "'"$LASTNAME"'",
        "password": "'"$PASSWORD"'"
      }')
    if [[ "$RESPONSE" == "200" ]]; then
        echo "✓ Utilisateur créé!"
        echo "Pause 3 min pour config API..."
        sleep 180
        read -p "Clé API: " API_KEY
        save_config "$IP" "$API_KEY"
        export N8N_IP="$IP"
        export N8N_API_KEY="$API_KEY"
    else
        echo "Erreur: $RESPONSE"
        cat /tmp/n8n_response.json
        exit 1
    fi
}

# Fonctions pour charger workflow, nouvelle clé, etc.
load_workflow() {
    echo "=== Chargement workflow ==="
    load_config
    if [[ -n "$N8N_API_KEY" && -n "$N8N_IP" ]]; then
        echo "Configuration:"
        echo "  IP: $N8N_IP"
        echo "  Clé: ${N8N_API_KEY:0:10}..."
        read -p "Utiliser cette config? (o/n): " RESP
        if ! [[ "$RESP" =~ ^[oOyY]$ ]]; then
            while true; do
                read -p "IP: " IP
                validate_ip "$IP" && break || echo "IP invalide."
            done
            read -p "Clé API: " API_KEY
            save_config "$IP" "$API_KEY"
            IP="$IP"
            API_KEY="$API_KEY"
        else
            IP="$N8N_IP"
            API_KEY="$N8N_API_KEY"
        fi
    else
        while true; do
            read -p "IP: " IP
            validate_ip "$IP" && break || echo "IP invalide."
        done
        read -p "Clé API: " API_KEY
        save_config "$IP" "$API_KEY"
    fi

    read -p "Fichier workflow: " WORKFLOW_FILE
    if [[ ! -f "$WORKFLOW_FILE" ]]; then
        echo "Fichier absent!"
        exit 1
    fi

    RESPONSE=$(curl -s -w "%{http_code}" -o /tmp/workflow_response.json -X POST "http://${IP}:5678/api/v1/workflows" \
      -H "Content-Type: application/json" \
      -H "X-N8N-API-KEY: ${API_KEY}" \
      -d @"${WORKFLOW_FILE}")

    if [[ "$RESPONSE" == "200" || "$RESPONSE" == "201" ]]; then
        echo "✓ Workflow chargé!"
    else
        echo "Erreur HTTP: $RESPONSE"
        cat /tmp/workflow_response.json
        exit 1
    fi
}

# Fonction pour charger une nouvelle clé API
load_new_api_key() {
    echo "=== Chargement nouvelle clé API ==="
    load_config
    if [[ -f "$CONFIG_FILE" ]]; then
        read -p "Supprimer ancienne clé ? (o/n): " del
        if [[ "$del" =~ ^[oOyY]$ ]]; then
            delete_config
        fi
    fi
    while true; do
        read -p "IP: " IP
        validate_ip "$IP" && break || echo "IP invalide"
    done
    read -p "Clé API: " API_KEY
    save_config "$IP" "$API_KEY"
    export N8N_IP="$IP"
    export N8N_API_KEY="$API_KEY"
}

# Menu
export COLUMNS=1
PS3="Choisissez une option: "
options=("Créer un utilisateur" "Charger un workflow" "Charger une nouvelle clé" "Quitter")
while true; do
    select opt in "${options[@]}"; do
        case "$REPLY" in
            1) create_user; break ;;
            2) load_workflow; break ;;
            3) load_new_api_key; break ;;
            4) echo "Au revoir!"; exit 0 ;;
            *) echo "Option invalide";;
        esac
    done
done
