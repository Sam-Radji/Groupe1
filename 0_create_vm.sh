#!/bin/bash
set -euo pipefail

# ============================================= Configuration =============================================
# Définition des variables de configuration du déploiement
BASENAME="projet-docker"             # Base name pour tous les ressources
ADMIN_USER="devopsadmin"             # Nom d'utilisateur administrateur pour le VM
VM_SIZE=""                           # Taille de la VM (sélectionnée interactivement selon la région)
DISK_SKU=""                          # SKU disque (sélectionné interactivement)

# Noms des ressources Azure
RG_NAME="${BASENAME}-rg"             # Resource Group
VNET_NAME="${BASENAME}-vnet01"       # Virtual Network
SUBNET_NAME="${BASENAME}-subnet01"   # Subnet
NSG_NAME="${BASENAME}-nsg01"         # Network Security Group
PUBLIC_IP_NAME="${BASENAME}-ip01"    # Adresse IP Publique
NIC_NAME="${BASENAME}-nic01"         # Interface réseau (NIC)
VM_NAME="${BASENAME}-vm01"           # Nom de la VM

FORCE_CLEANUP=0                      # Flag pour forcer le nettoyage sans confirmation
REGENERATE_SSH_KEY=0                 # Régénère explicitement la clé SSH locale
SSH_KEY_PATH="${HOME:-${USERPROFILE}}/.ssh/azure_n8n"
SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"

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
  echo "  • Clé SSH locale générée : $SSH_KEY_PATH et $SSH_PUB_KEY_PATH"
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

  SSH_PRIV_KEY="$SSH_KEY_PATH"
  SSH_PUB_KEY="$SSH_PUB_KEY_PATH"

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

# ============================================= Aide =============================================
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --help      Affiche cette aide puis quitte
  --cleanup   Supprime toutes les ressources du déploiement
  --force     Force la suppression sans confirmation (avec --cleanup)
  --regenerate-ssh-key  Régénère la paire de clés $SSH_KEY_PATH
  --start     Démarre la VM existante
  --stop      Arrête la VM existante
EOF
}

# ============================================= Argument parsing =============================================
SHOW_HELP=0
REQUESTED_ACTION=""

# Passe 1 : enregistrement des options
for arg in "$@"; do
  case "$arg" in
    --help)
      SHOW_HELP=1
      ;;
    --force)
      FORCE_CLEANUP=1
      ;;
    --regenerate-ssh-key)
      REGENERATE_SSH_KEY=1
      ;;
    --cleanup|--start|--stop)
      if [ -n "$REQUESTED_ACTION" ] && [ "$REQUESTED_ACTION" != "$arg" ]; then
        echo "❌ Options incompatibles : '$REQUESTED_ACTION' et '$arg'."
        echo "Utilisez une seule action à la fois."
        exit 1
      fi
      REQUESTED_ACTION="$arg"
      ;;
    *)
      echo "❌ Option inconnue : $arg"
      echo "Utilisez --help pour voir les options disponibles."
      exit 1
      ;;
  esac
done

# Passe 2 : exécution des options
if [ "$SHOW_HELP" -eq 1 ]; then
  show_help
  exit 0
fi

case "$REQUESTED_ACTION" in
  --cleanup)
    cleanup_resources
    ;;
  --start)
    start_vm
    ;;
  --stop)
    stop_vm
    ;;
esac

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

az login --allow-no-subscriptions # --use-device-code

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
if [ -z "$SUBSCRIPTION_ID" ]; then
  echo "ERREUR : Impossible de récupérer l'ID de subscription Azure."
  exit 1
fi

# Un abonnement neuf (typiquement Azure for Students) n'a pas encore activé
# Compute, Network et Storage. Sans ça, `az vm list-usage` renvoie une liste
# vide pour toutes les régions, et la création de VM échoue ensuite.
ensure_resource_providers() {
  local namespaces=("Microsoft.Compute" "Microsoft.Network" "Microsoft.Storage")
  local ns state

  echo ""
  echo "==> Vérification des fournisseurs de ressources Azure..."

  for ns in "${namespaces[@]}"; do
    state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null | tr -d '\r' || true)
    if [ "$state" = "Registered" ]; then
      echo "✓ $ns déjà enregistré"
      continue
    fi

    echo "==> Enregistrement de $ns (état actuel : ${state:-inconnu})..."
    echo "    Sur un abonnement neuf, cela peut prendre plusieurs minutes."
    if ! az provider register --namespace "$ns" --wait; then
      echo "❌ Impossible d'enregistrer $ns."
      echo "   Sans ce fournisseur, Azure refuse les quotas et la création de la VM."
      exit 1
    fi
    echo "✓ $ns enregistré"
  done
}

ensure_resource_providers

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

# ============================================= Sélection interactive de la région =============================================
echo "Régions autorisées par Azure :"
for i in "${!POLICY_REGIONS[@]}"; do
  region_clean="${POLICY_REGIONS[$i]}"
  [ "$os" = "Windows" ] && region_clean=$(echo "$region_clean" | tr -d '\r')
  printf "  [%2d] %s\n" "$((i+1))" "$region_clean"
done
echo ""

while true; do
  read -r -p "Choisissez une région (1-${#POLICY_REGIONS[@]}) [défaut: 1] : " region_choice
  region_choice=${region_choice:-1}
  if [[ "$region_choice" =~ ^[0-9]+$ ]] && [ "$region_choice" -ge 1 ] && [ "$region_choice" -le "${#POLICY_REGIONS[@]}" ]; then
    LOCATION="${POLICY_REGIONS[$((region_choice-1))]}"
    [ "$os" = "Windows" ] && LOCATION=$(echo "$LOCATION" | tr -d '\r')
    break
  fi
  echo "❌ Choix invalide. Saisissez un nombre entre 1 et ${#POLICY_REGIONS[@]}."
done

echo "✓ Région sélectionnée : $LOCATION"
echo ""

# ============================================= Sélection interactive de la taille VM =============================================
echo "==> Récupération des tailles VM réellement déployables pour VOTRE abonnement dans '$LOCATION'..."
echo "    (peut prendre 20-60 secondes — interroge list-skus + list-usage + list-sizes)"

# 1) Toutes les entrées de quota : famille -> (currentValue, limit)
#    On extrait en TSV puis on filtre en awk car Azure renvoie parfois `limit`
#    en string, ce qui fait crasher la comparaison JMESPath `limit > \`0\``.
USAGE_RAW=$(az vm list-usage \
  --location "$LOCATION" \
  --query "[].[name.value, currentValue, limit]" \
  --output tsv 2>/dev/null | tr -d '\r' || true)

if [ -z "$USAGE_RAW" ]; then
  echo "❌ Impossible de récupérer les quotas pour '$LOCATION'."
  exit 1
fi

# Quota régional total (Total Regional vCPUs) restant
TOTAL_CORES_REMAINING=$(echo "$USAGE_RAW" | awk -F'\t' 'tolower($1)=="cores" {print ($3+0)-($2+0); exit}')
TOTAL_CORES_REMAINING=${TOTAL_CORES_REMAINING:-0}

if [ "$TOTAL_CORES_REMAINING" -le 0 ]; then
  echo "❌ Quota régional total épuisé dans '$LOCATION' (Total Regional vCPUs = 0 restant)."
  echo "   Demandez une augmentation de quota ou changez de région."
  exit 1
fi

# 2) SKU déployables (sans restriction de type 'Location' / NotAvailableForSubscription).
#    On garde celles qui ont uniquement des restrictions 'Zone' : elles sont bloquées
#    pour des déploiements zonaux mais déployables sans --zone (ce que fait ce script).
SKU_FAMILY_RAW=$(az vm list-skus \
  --location "$LOCATION" \
  --resource-type virtualMachines \
  --query "[?length(restrictions[?type=='Location' && reasonCode=='NotAvailableForSubscription']) == \`0\`].[name, family]" \
  --output tsv 2>/dev/null | tr -d '\r' || true)

if [ -z "$SKU_FAMILY_RAW" ]; then
  echo "❌ Aucune taille VM sans restriction dans '$LOCATION'."
  exit 1
fi

# 3) Caractéristiques (vCPU/RAM) — filtre dimensionnel raisonnable
SIZES_RAW=$(az vm list-sizes \
  --location "$LOCATION" \
  --query "[?numberOfCores>=\`2\` && numberOfCores<=\`8\` && memoryInMB>=\`4096\` && memoryInMB<=\`32768\`].[name, numberOfCores, memoryInMB]" \
  --output tsv 2>/dev/null | tr -d '\r' || true)

if [ -z "$SIZES_RAW" ]; then
  echo "❌ Impossible de récupérer les caractéristiques des tailles VM."
  exit 1
fi

# 4) Pour chaque taille : vérifier absence de restriction + cores ≤ quota famille
#    + cores ≤ quota régional. C'est la condition pour que `az vm create` réussisse.
SIZES_AVAILABLE=""
while IFS=$'\t' read -r name cores memmb; do
  [ -z "$name" ] && continue

  # Quota régional total
  if [ "$cores" -gt "$TOTAL_CORES_REMAINING" ]; then continue; fi

  # Famille du SKU (et donc absence de restriction si trouvée)
  family=$(echo "$SKU_FAMILY_RAW" | awk -F'\t' -v n="$name" '$1==n {print tolower($2); exit}')
  [ -z "$family" ] && continue

  # Quota restant pour la famille
  fam_remaining=$(echo "$USAGE_RAW" | awk -F'\t' -v f="$family" 'tolower($1)==f {print ($3+0)-($2+0); exit}')
  fam_remaining=${fam_remaining:-0}
  if [ "$cores" -gt "$fam_remaining" ]; then continue; fi

  SIZES_AVAILABLE+="${name}	${cores}	${memmb}	${fam_remaining}"$'\n'
done <<< "$SIZES_RAW"

if [ -z "$SIZES_AVAILABLE" ]; then
  echo "❌ Aucune taille (2-8 vCPU, 4-32 GB) déployable dans '$LOCATION'."
  echo "   Toutes les familles ont un quota restant insuffisant pour les cores requis."
  echo "   Essayez une autre région."
  exit 1
fi

# 4) Filtre familles courantes B/D/E/F (sinon fallback sur tout)
SIZES_FILTERED=$(echo "$SIZES_AVAILABLE" | grep -E '^Standard_(B[0-9]|D[0-9]|E[0-9]|F[0-9])' | sort || true)

if [ -z "$SIZES_FILTERED" ]; then
  echo "⚠️  Aucune taille des familles B/D/E/F autorisée. Affichage de toutes les tailles autorisées."
  SIZES_FILTERED=$(echo "$SIZES_AVAILABLE" | sort)
fi

SIZES=()
while IFS=$'\t' read -r name cores memmb fam_rem; do
  [ -n "$name" ] && SIZES+=("${name}|${cores}|${memmb}|${fam_rem}")
done <<< "$SIZES_FILTERED"

if [ ${#SIZES[@]} -eq 0 ]; then
  echo "❌ Aucune taille VM compatible trouvée."
  exit 1
fi

echo ""
echo "Tailles VM déployables dans '$LOCATION' (quota régional restant : $TOTAL_CORES_REMAINING cores)"
echo "(filtre : familles B/D/E/F, 2-8 vCPU, 4-32 GB RAM, quota famille suffisant)"
printf "  %-4s %-30s %-8s %-10s %-18s\n" "#" "Nom" "vCPU" "RAM (GB)" "Quota famille"
echo "  -----------------------------------------------------------------------"
for i in "${!SIZES[@]}"; do
  IFS='|' read -r s_name s_cores s_memmb s_fam <<< "${SIZES[$i]}"
  s_mem_gb=$((s_memmb / 1024))
  printf "  [%2d] %-30s %-8s %-10s %-18s\n" "$((i+1))" "$s_name" "$s_cores" "$s_mem_gb" "${s_fam} cores"
done

echo ""
while true; do
  read -r -p "Choisissez une taille (1-${#SIZES[@]}) ou tapez un nom 'Standard_*' [défaut: 1] : " size_choice
  size_choice=${size_choice:-1}
  if [[ "$size_choice" =~ ^[0-9]+$ ]] && [ "$size_choice" -ge 1 ] && [ "$size_choice" -le "${#SIZES[@]}" ]; then
    IFS='|' read -r VM_SIZE _ _ _ <<< "${SIZES[$((size_choice-1))]}"
    break
  elif [[ "$size_choice" =~ ^Standard_ ]]; then
    custom_cores=$(az vm list-sizes --location "$LOCATION" --query "[?name=='$size_choice'].numberOfCores" -o tsv 2>/dev/null | tr -d '\r')
    if [ -z "$custom_cores" ]; then
      echo "❌ Taille '$size_choice' inexistante dans '$LOCATION'."
      continue
    fi
    custom_family=$(echo "$SKU_FAMILY_RAW" | awk -F'\t' -v n="$size_choice" '$1==n {print tolower($2); exit}')
    if [ -z "$custom_family" ]; then
      echo "❌ Taille '$size_choice' restreinte (NotAvailableForSubscription)."
      continue
    fi
    custom_remaining=$(echo "$USAGE_RAW" | awk -F'\t' -v f="$custom_family" 'tolower($1)==f {print ($3+0)-($2+0); exit}')
    custom_remaining=${custom_remaining:-0}
    if [ "$custom_cores" -gt "$custom_remaining" ]; then
      echo "❌ Quota famille insuffisant : $size_choice requiert $custom_cores cores, restant: $custom_remaining."
      continue
    fi
    if [ "$custom_cores" -gt "$TOTAL_CORES_REMAINING" ]; then
      echo "❌ Quota régional insuffisant : $size_choice requiert $custom_cores cores, restant: $TOTAL_CORES_REMAINING."
      continue
    fi
    VM_SIZE="$size_choice"
    break
  else
    echo "❌ Choix invalide."
  fi
done

echo "✓ Taille VM sélectionnée : $VM_SIZE"
echo ""

# ============================================= Sélection du SKU disque =============================================
echo "Type de disque (SKU) :"
echo "  [1] Standard_LRS     (HDD, économique)"
echo "  [2] StandardSSD_LRS  (SSD standard, équilibré)"
echo "  [3] Premium_LRS      (SSD haute performance, requiert taille avec suffixe 's')"
read -r -p "Choisissez le SKU de disque (1-3) [défaut: 1] : " disk_choice
disk_choice=${disk_choice:-1}
case "$disk_choice" in
  2) DISK_SKU="StandardSSD_LRS" ;;
  3) DISK_SKU="Premium_LRS" ;;
  *) DISK_SKU="Standard_LRS" ;;
esac

if [ "$DISK_SKU" = "Premium_LRS" ] && [[ "$VM_SIZE" != *s* ]]; then
  echo "⚠️  La taille '$VM_SIZE' ne supporte pas Premium_LRS (pas de suffixe 's')."
  echo "    Bascule automatique sur StandardSSD_LRS."
  DISK_SKU="StandardSSD_LRS"
fi

echo "✓ SKU de disque sélectionné : $DISK_SKU"
echo ""

echo "=========================================="
echo "Configuration de déploiement :"
echo "  Région      : $LOCATION"
echo "  Taille VM   : $VM_SIZE"
echo "  Stockage    : $DISK_SKU"
echo "  Abonnement  : $(az account show --query name -o tsv)"
echo "  Subscription: $SUBSCRIPTION_ID"
echo "=========================================="
echo ""
read -r -p "Appuyez sur Entrée pour confirmer et lancer le déploiement (Ctrl+C pour annuler)... " _

generate_ssh_key() {
  SSH_KEY_DIR=$(dirname "$SSH_KEY_PATH")
  mkdir -p "$SSH_KEY_DIR"

  if [ "$REGENERATE_SSH_KEY" -eq 1 ]; then
    if [[ -f "$SSH_KEY_PATH" || -f "${SSH_KEY_PATH}.pub" ]]; then
      echo "⏳ Régénération demandée : suppression des clés existantes."
      rm -f "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub"
    fi
    echo "🗝 Génération d'une nouvelle paire de clés SSH : $SSH_KEY_PATH"
    ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" -q
    echo "✓ Clé SSH régénérée."
    return
  fi

  if [[ -f "$SSH_KEY_PATH" && -f "${SSH_KEY_PATH}.pub" ]]; then
    echo "ℹ️ Clé SSH existante détectée : $SSH_KEY_PATH (conservée)"
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"
    return
  fi

  if [[ -f "$SSH_KEY_PATH" && ! -f "${SSH_KEY_PATH}.pub" ]]; then
    echo "❌ Clé privée trouvée mais clé publique absente : ${SSH_KEY_PATH}.pub"
    echo "   Utilisez --regenerate-ssh-key pour recréer une paire cohérente."
    exit 1
  fi

  echo "🗝 Génération d'une nouvelle paire de clés SSH : $SSH_KEY_PATH"
  ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" -q
  chmod 600 "$SSH_KEY_PATH"
  chmod 644 "${SSH_KEY_PATH}.pub"
  echo "✓ Clé SSH générée."
}

generate_ssh_key

if [ ! -f "$SSH_PUB_KEY_PATH" ]; then
  echo "❌ Clé publique SSH introuvable : $SSH_PUB_KEY_PATH"
  echo "   Utilisez --regenerate-ssh-key pour générer une paire valide."
  exit 1
fi

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
        -v n8n:/home/node/.n8n \
        --restart unless-stopped \
        n8nio/n8n

      echo "Installation completed successfully"

runcmd:
  - /tmp/setup-docker.sh

CLOUDEOF
)

# Écriture du cloud-init dans un fichier temporaire (compatible macOS et Windows/Git Bash)
CLOUD_INIT_FILE=$(mktemp 2>/dev/null || echo "${TMP:-${TEMP:-/tmp}}/cloud-init-$$.yaml")
echo "$CLOUD_INIT_YAML" > "$CLOUD_INIT_FILE"
trap 'rm -f "$CLOUD_INIT_FILE"' EXIT

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

# Attente de la propagation ARM : le NSG peut renvoyer "created" mais ne pas être
# immédiatement visible pour les commandes suivantes (eventual consistency)
echo "  ⏳ Attente de la propagation du NSG..."
NSG_READY=0
for i in $(seq 1 30); do
  if az network nsg show --resource-group "$RG_NAME" --name "$NSG_NAME" --output none 2>/dev/null; then
    NSG_READY=1
    break
  fi
  sleep 2
done
if [ "$NSG_READY" -eq 0 ]; then
  echo "❌ NSG '$NSG_NAME' introuvable après 60 secondes."
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

# Si la CLI est installé, y a pas de raison de vérifier l'OS
# case "$os" in
#   macOS|Windows) ;;
#   *)
#     echo "OS non supporté pour la création automatique de VM."
#     exit 1
#     ;;
# esac

echo ""
echo "==> Création VM : $VM_NAME"
if ! az vm create \
  --resource-group "$RG_NAME" \
  --name "$VM_NAME" \
  --location "$LOCATION" \
  --nics "$NIC_NAME" \
  --image "Canonical:ubuntu-24_04-lts:server:latest" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_PUB_KEY_PATH" \
  --storage-sku "$DISK_SKU" \
  --custom-data "$CLOUD_INIT_FILE" \
  -o none; then
  echo "Erreur lors de la création de la VM sur $os"
  exit 1
fi

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
echo "  SSH (port 22) : ssh -i $SSH_KEY_PATH $ADMIN_USER@$PUBLIC_IP"
echo ""
echo "  Suivi des logs : ssh -i $SSH_KEY_PATH $ADMIN_USER@$PUBLIC_IP 'sudo tail -f /var/log/cloud-init-output.log'"
echo ""
echo "🔒 Sécurité :"
echo "  ⚠ NSG ouvert à tous (*) - À restreindre en production !"
echo "  ⚠ Credentials en clair - À changer immédiatement !"
echo "  ⚠ Pas de HTTPS - À configurer avec reverse proxy + Let's Encrypt"
echo ""
