#!/bin/bash
set -euo pipefail

# ============================================= Configuration =============================================
# Définition des variables de configuration du déploiement
BASENAME="projet-docker"             # Base name pour tous les ressources
ADMIN_USER="devopsadmin"             # Nom d'utilisateur administrateur pour le VM
VM_SIZE="Standard_B2s"               # Taille de la machine virtuelle

# Noms des ressources Azure
RG_NAME="${BASENAME}-rg"             # Resource Group
VNET_NAME="${BASENAME}-vnet01"       # Virtual Network
SUBNET_NAME="${BASENAME}-subnet01"   # Subnet
NSG_NAME="${BASENAME}-nsg01"         # Network Security Group
PUBLIC_IP_NAME="${BASENAME}-ip01"    # Adresse IP Publique
NIC_NAME="${BASENAME}-nic01"         # Interface réseau (NIC)
VM_NAME="${BASENAME}-vm01"           # Nom de la VM

FORCE_CLEANUP=0                      # Flag pour forcer le nettoyage sans confirmation

# ============================================= Fonction de nettoyage =============================================
cleanup_resources() {
  echo ""
  echo "=========================================="
  echo "⚠️  SUPPRESSION DES RESSOURCES"
  echo "=========================================="
  echo ""

  if ! az group show --name "$RG_NAME" --output none 2>/dev/null; then
    echo "❌ Le Resource Group '$RG_NAME' n'existe pas ou a déjà été supprimé"
    exit 0
  fi

  echo "Cette action va supprimer :"
  echo "  • Resource Group : $RG_NAME"
  echo "  • VM et tous ses disques"
  echo "  • Réseau (VNet, Subnet, NSG, NIC)"
  echo "  • IP publique"
  echo "  • Toutes les ressources associées"
  echo "  • Clé SSH locale générée : ~/.ssh/azure_n8n et ~/.ssh/azure_n8n.pub"
  echo ""

  echo "Ressources actuelles :"
  az resource list --resource-group "$RG_NAME" --query "[].{Nom:name, Type:type}" -o table

  echo ""
  echo "⏱ Temps estimé : 10-20 minutes"
  echo ""

  if [ $FORCE_CLEANUP -eq 0 ]; then
    read -r -p "Êtes-vous sûr de vouloir tout supprimer ? (oui/non) : " confirm
    if [ "$confirm" != "oui" ] && [ "$confirm" != "OUI" ]; then
      echo "❌ Suppression annulée"
      exit 1
    fi
  else
    echo "⚡ Confirmation forcée activée : suppression sans prompt."
  fi

  echo ""
  echo "==> Suppression du Resource Group en cours..."
  az group delete --name "$RG_NAME" --yes --no-wait

  echo "⏱ Attente de la suppression complète du Resource Group..."
  while az group show --name "$RG_NAME" --output none 2>/dev/null; do
    echo "Suppression en cours..."
    sleep 10
  done
  echo "✓ Resource Group supprimé."

  SSH_PRIV_KEY="${HOME:-${USERPROFILE}}/.ssh/azure_n8n"
  SSH_PUB_KEY="${SSH_PRIV_KEY}.pub"

  if [ -f "$SSH_PRIV_KEY" ] && [ -f "$SSH_PUB_KEY" ]; then
    echo "==> Suppression des clés SSH locales : $SSH_PRIV_KEY et $SSH_PUB_KEY"
    rm -f "$SSH_PRIV_KEY" "$SSH_PUB_KEY"
    echo "✓ Clés SSH supprimées"
  else
    echo "ℹ️ Pas de clés SSH locales à supprimer."
  fi

  echo ""
  echo "Suppression terminée."
  exit 0
}

# ============================================= Fonction pour stopper la VM =============================================
stop_vm() {
  echo ""
  echo "=========================================="
  echo "⏸️  Arrêt de la VM Azure : $VM_NAME"
  echo "=========================================="
  if ! az vm stop --resource-group "$RG_NAME" --name "$VM_NAME"; then
    echo "❌ Impossible d'arrêter la VM : $VM_NAME"
    exit 1
  fi
  echo "✓ VM arrêtée."
  exit 0
}

# ============================================= Fonction pour démarrer la VM =============================================
start_vm() {
  echo ""
  echo "=========================================="
  echo "▶️  Démarrage de la VM Azure : $VM_NAME"
  echo "=========================================="
  if ! az vm start --resource-group "$RG_NAME" --name "$VM_NAME"; then
    echo "❌ Impossible de démarrer la VM : $VM_NAME"
    exit 1
  fi
  echo "✓ VM démarrée."
  exit 0
}

# ============================================= Argument parsing =============================================
for arg in "$@"; do
  case $arg in
    --cleanup)
      cleanup_resources
      ;;
    --force)
      FORCE_CLEANUP=1
      ;;
    --stop)
      stop_vm
      ;;
    --start)
      start_vm
      ;;
    *)
      ;;
  esac
done

# ============================================= Détection OS =============================================
detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macOS"
  elif [[ "${OS:-}" =~ (Windows_NT) ]]; then
    echo "Windows"
  elif [[ "$(uname -o 2>/dev/null)" == "Msys" ]] || [[ "$(uname -o 2>/dev/null)" == "Cygwin" ]]; then
    echo "Windows"
  elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
      ubuntu) echo "ubuntu" ;;
      debian) echo "debian" ;;
      fedora) echo "fedora" ;;
      centos) echo "centos" ;;
      arch) echo "arch" ;;
      *) echo "unsupported" ;;
    esac
  else
    echo "unsupported"
  fi
}

os=$(detect_os)

if [ "$os" = "unsupported" ]; then
  echo "ERREUR : Votre OS n'est pas inclus dans les distributions prises en charge."
  echo "Merci de voir avec le professeur pour une assistance adaptée."
  exit 1
fi

# ============================================= Installation Azure CLI =============================================
install_azure_cli() {
  case "$os" in
    macOS)
      if ! command -v az &>/dev/null; then
        echo "Installation Azure CLI sur macOS..."
        brew update && brew install azure-cli
      else
        echo "Azure CLI déjà installée."
      fi
      ;;
    ubuntu|debian)
      if ! command -v az &>/dev/null; then
        echo "Installation Azure CLI sur $os..."
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
      else
        echo "Azure CLI déjà installée."
      fi
      ;;
    fedora)
      if ! command -v az &>/dev/null; then
        echo "Installation Azure CLI sur Fedora..."
        sudo dnf install -y azure-cli
      else
        echo "Azure CLI déjà installée."
      fi
      ;;
    centos)
      if ! command -v az &>/dev/null; then
        echo "Installation Azure CLI sur CentOS..."
        sudo yum install -y https://packages.microsoft.com/config/centos/7/packages-microsoft-prod.rpm
        sudo yum install -y azure-cli
      else
        echo "Azure CLI déjà installée."
      fi
      ;;
    arch)
      if ! command -v az &>/dev/null; then
        echo "Installation Azure CLI sur Arch Linux..."
        sudo pacman -Sy azure-cli
      else
        echo "Azure CLI déjà installée."
      fi
      ;;
    Windows)
      if ! command -v az &>/dev/null; then
        echo "Azure CLI non trouvée."
        echo "Merci d'installer manuellement Azure CLI sous Windows via PowerShell avec :"
        echo "  winget install -e --id Microsoft.AzureCLI"
        echo "Le script va maintenant s'arrêter. Relancez-le après installation."
        exit 1
      else
        echo "Azure CLI déjà installée."
      fi
      ;;
  esac
}

install_azure_cli

echo "==> Mise à jour Azure CLI..."
az upgrade --yes 2>/dev/null || true

az login

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "ERREUR : Impossible de récupérer l'ID de subscription Azure."
  exit 1
fi

echo ""
echo "==> Vérification des régions autorisées..."
ALLOWED_REGIONS=$(az policy assignment list \
  --query "[?displayName=='Allowed resource deployment regions'].parameters.listOfAllowedLocations.value[]" \
  -o tsv 2>/dev/null || echo "")

POLICY_REGIONS=()
if [ -n "$ALLOWED_REGIONS" ]; then
  while IFS=$'\n' read -r line; do
    [ -n "$line" ] && POLICY_REGIONS+=("$line")
  done <<< "$ALLOWED_REGIONS"
fi

if [ ${#POLICY_REGIONS[@]} -eq 0 ]; then
  echo "ERREUR : Impossible de récupérer les régions autorisées depuis Azure Policy"
  echo "  Vérifiez vos permissions et la présence d'une policy de localisation"
  exit 1
fi

echo "Régions autorisées par Azure :"
printf '  ✓ %s\n' "${POLICY_REGIONS[@]}"

if [ "$os" = "Windows" ]; then
  LOCATION=$(echo "${POLICY_REGIONS[0]}" | tr -d '\r')
else
  LOCATION="${POLICY_REGIONS[0]}"
fi

echo ""
echo "Région sélectionnée automatiquement : $LOCATION"

DISK_SKU="Standard_LRS"

echo ""
echo "=========================================="
echo "Configuration de déploiement :"
echo "  Région      : $LOCATION"
echo "  Stockage    : $DISK_SKU"
echo "  Abonnement  : $(az account show --query name -o tsv)"
echo "  Subscription: $SUBSCRIPTION_ID"
echo "=========================================="
echo ""
echo "⏱ Pause 5 secondes avant déploiement..."
sleep 5

generate_ssh_key() {
  SSH_KEY_PATH="${HOME:-${USERPROFILE}}/.ssh/azure_n8n"
  if [[ -f "$SSH_KEY_PATH" || -f "${SSH_KEY_PATH}.pub" ]]; then
    echo "⏳ Clé SSH $SSH_KEY_PATH déjà existante. Suppression des anciennes clés."
    rm -f "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub"
  fi
  echo "🗝 Génération d'une nouvelle paire de clés SSH : $SSH_KEY_PATH"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" -q
  echo "✓ Clé SSH générée."
}

generate_ssh_key

echo "==> Vérification du groupe de ressources : $RG_NAME"

if az group show --name "$RG_NAME" --output none 2>/dev/null; then
  EXISTING_LOC=$(az group show --name "$RG_NAME" --query location -o tsv)
  echo "✓ RG existant trouvé en région : $EXISTING_LOC"
  if [ "$EXISTING_LOC" != "$LOCATION" ]; then
    echo "❌ Conflit de région détecté ! Suppression du RG..."
    az group delete --name "$RG_NAME" --yes --no-wait
    echo "⏱ Attente suppression complète du RG..."
    while az group show --name "$RG_NAME" --output none 2>/dev/null; do
      echo "Suppression en cours..."
      sleep 10
    done
    echo "==> Création du groupe de ressources : $RG_NAME ($LOCATION)"
    az group create --name "$RG_NAME" --location "$LOCATION" --output none
  else
    echo "✓ RG en bonne région, on continue"
  fi
else
  echo "==> Création du groupe de ressources : $RG_NAME ($LOCATION)"
  az group create --name "$RG_NAME" --location "$LOCATION" --output none
fi

echo "✓ Resource Group prêt"

CLOUD_INIT_YAML=$(cat << 'CLOUDEOF'
#cloud-config
package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - gnupg

write_files:
  - path: /tmp/setup-docker.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euxo pipefail
      exec > /tmp/docker-install.log 2>&1

      echo "Starting Docker installation..."

      mkdir -p /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg

      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bullseye stable" > /etc/apt/sources.list.d/docker.list

      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

      systemctl enable docker
      systemctl start docker

      usermod -aG docker devopsadmin

      sleep 5

      docker run -d --name n8n -p 5678:5678 \
        -e N8N_SECURE_COOKIE=false \
        -v n8n_/home/node/.n8n \
        --restart unless-stopped \
        n8nio/n8n

      echo "Installation completed successfully"

runcmd:
  - /tmp/setup-docker.sh

CLOUDEOF
)

echo ""
echo "==> Création VNet/Subnet"
if ! az network vnet create \
  --resource-group "$RG_NAME" \
  --name "$VNET_NAME" \
  --location "$LOCATION" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_NAME" \
  --subnet-prefix 10.0.0.0/24 \
  -o none; then
  echo "Erreur lors de la création du VNet/Subnet"
  exit 1
fi

echo "==> Création NSG"
if ! az network nsg create \
  --resource-group "$RG_NAME" \
  --name "$NSG_NAME" \
  --location "$LOCATION" \
  -o none; then
  echo "Erreur lors de la création du NSG"
  exit 1
fi

echo "==> Création règles NSG (SSH 22, n8n 5678)"
az network nsg rule create \
  --resource-group "$RG_NAME" \
  --nsg-name "$NSG_NAME" \
  --name AllowSSH \
  --priority 1000 \
  --source-address-prefixes '*' \
  --destination-port-ranges 22  \
  --protocol Tcp \
  --access Allow \
  -o none || { echo "Erreur création règle AllowSSH"; exit 1; }

az network nsg rule create \
  --resource-group "$RG_NAME" \
  --nsg-name "$NSG_NAME" \
  --name AllowN8N \
  --priority 1010 \
  --source-address-prefixes '*' \
  --destination-port-ranges 5678 \
  --protocol Tcp \
  --access Allow \
  -o none || { echo "Erreur création règle AllowN8N"; exit 1; }

echo "==> Création IP publique (Standard/Statique)"
if ! az network public-ip create \
  --resource-group "$RG_NAME" \
  --name "$PUBLIC_IP_NAME" \
  --location "$LOCATION" \
  --sku Standard \
  --allocation-method Static \
  -o none; then
  echo "Erreur création IP publique"
  exit 1
fi

echo "==> Création NIC (attachement NSG + IP publique)"
if ! az network nic create \
  --resource-group "$RG_NAME" \
  --name "$NIC_NAME" \
  --location "$LOCATION" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SUBNET_NAME" \
  --public-ip-address "$PUBLIC_IP_NAME" \
  --network-security-group "$NSG_NAME" \
  -o none; then
  echo "Erreur création NIC"
  exit 1
fi

case "$os" in
  macOS)
    echo ""
    echo "==> Création VM : $VM_NAME (Debian 11 Gen2)"
    if ! az vm create \
      --resource-group "$RG_NAME" \
      --name "$VM_NAME" \
      --location "$LOCATION" \
      --nics "$NIC_NAME" \
      --image Debian11 \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" \
      --ssh-key-values "${HOME:-${USERPROFILE}}/.ssh/azure_n8n.pub" \
      --storage-sku "$DISK_SKU" \
      --custom-data <(echo "$CLOUD_INIT_YAML") \
      -o none; then
      echo "Erreur lors de la création de la VM sur macOS"
      exit 1
    fi
    ;;
  Windows)
    echo ""
    echo "==> Création VM : $VM_NAME (Debian 11 Gen2)"
    az vm create \
      --resource-group "$RG_NAME" \
      --name "$VM_NAME" \
      --location "$LOCATION" \
      --nics "$NIC_NAME" \
      --image "Debian:debian-11:11-gen2:latest" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" \
      --ssh-key-values "${HOME:-${USERPROFILE}}/.ssh/n8n_azure.pub" \
      --storage-sku "$DISK_SKU" \
      --custom-data "$CLOUD_INIT_FILE" \
      -o none
    ;;
  *)
    echo "OS non supporté pour la création automatique de VM."
    exit 1
    ;;
esac

PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RG_NAME" \
  --name "$PUBLIC_IP_NAME" \
  --query ipAddress -o tsv)

echo ""
echo "=========================================="
echo "✅ Déploiement terminé avec succès !"
echo "=========================================="
echo ""
echo "📦 Ressources créées :"
echo "  Resource Group : $RG_NAME"
echo "  VM             : $VM_NAME ($VM_SIZE)"
echo "  Région         : $LOCATION"
echo "  IP Publique    : $PUBLIC_IP"
echo ""

echo "⏳ Attente de la disponibilité de n8n..."
MAX_RETRIES=180
RETRY_COUNT=0
while true; do
  if curl -s --fail --connect-timeout 5 "http://$PUBLIC_IP:5678" >/dev/null; then
    echo "✓ Le service est prêt pour utilisation."
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "⚠️ Timeout : n8n n'a pas répondu."
    break
  fi
  echo "En attente..."
  sleep 20
done

# ============================================= Affichage des commandes d'usage =============================================
echo ""
echo "📢 Commandes utiles :"
echo "  Pour supprimer toutes les ressources :"
echo "    $0 --cleanup [--force]"
echo "  Pour arrêter la VM sans supprimer l'infrastructure :"
echo "    $0 --stop"
echo "  Pour redémarrer la VM arrêtée :"
echo "    $0 --start"
echo ""
echo "🔗 Accès :"
echo "  n8n Interface : http://$PUBLIC_IP:5678"
echo "  SSH (port 22) : ssh -i ~/.ssh/azure_n8n $ADMIN_USER@$PUBLIC_IP"
echo ""
echo "  Suivi des logs : ssh -i ~/.ssh/azure_n8n $ADMIN_USER@$PUBLIC_IP 'sudo tail -f /var/log/cloud-init-output.log'"
echo ""
echo "🔒 Sécurité :"
echo "  ⚠ NSG ouvert à tous (*) - À restreindre en production !"
echo "  ⚠ Credentials en clair - À changer immédiatement !"
echo "  ⚠ Pas de HTTPS - À configurer avec reverse proxy + Let's Encrypt"
echo ""
