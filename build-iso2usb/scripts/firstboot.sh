#!/bin/bash
# ============================================================
# NeurHomIA — Script de configuration au premier démarrage
# ------------------------------------------------------------
# Objectif :
#   - Configurer le système (réseau, sécurité)
#   - Installer Docker
#   - Déployer la stack via docker-compose
#
# Ce script est conçu pour être :
#   - Idempotent (relançable sans casse)
#   - Robuste (gestion erreurs + logs)
#   - Adapté à un ISO autoinstall
# ============================================================

set -euo pipefail   # Stop si erreur / variable non définie / pipe cassé

# Redirection des logs vers un fichier persistant
LOG_FILE="/var/log/neurhomia-firstboot.log"
exec > "$LOG_FILE" 2>&1
set -x  # Active le mode debug (trace toutes les commandes)

# ============================================================
# VARIABLES GLOBALES
# ============================================================

PROJECT_NAME="NeurHomIA"
PROJECT_NAME_LOWER="neurhomia"
GITHUB_REPO="cce66/NeurHomIA"

# Répertoire d'installation principal
INSTALL_DIR="/opt/${PROJECT_NAME_LOWER}"

# Détection automatique du premier utilisateur non système
TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd || true)
[ -z "$TARGET_USER" ] && TARGET_USER="${PROJECT_NAME_LOWER}"

# Variables dynamiques
SELECTED_TZ=""
MQTT_PASSWORD=""

# ============================================================
# FONCTIONS UTILITAIRES
# ============================================================

# Log structuré avec timestamp
log() {
    echo "$(date '+%F %T') [INFO] $*"
}

# Attendre que Docker soit prêt
wait_docker() {
    log "Attente du service Docker..."
    until systemctl is-active --quiet docker; do
        sleep 2
    done
}

# Installer Docker si absent
install_docker() {
    if ! command -v docker >/dev/null; then
        log "Docker non détecté → installation..."

        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg lsb-release

        # Ajout du dépôt officiel Docker
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq

        # Installation Docker + Compose v2
        apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin

        # Activation du service Docker
        systemctl enable --now docker
    fi

    # Attendre que Docker soit opérationnel
    wait_docker

    # Donner accès Docker à l'utilisateur principal
    usermod -aG docker "$TARGET_USER" || true
}

# Cloner ou mettre à jour le dépôt (idempotent)
safe_git_sync() {
    if [ -d "${INSTALL_DIR}/.git" ]; then
        log "Mise à jour du dépôt existant..."
        cd "${INSTALL_DIR}"
        git pull
    else
        log "Clonage du dépôt Git..."
        for i in {1..5}; do
            git clone "https://github.com/${GITHUB_REPO}.git" "${INSTALL_DIR}" && break
            log "Échec clone, tentative $i/5..."
            sleep 5
        done
    fi
}

# ============================================================
# INTERFACE UTILISATEUR
# ============================================================

whiptail --title "$PROJECT_NAME" \
  --msgbox "Configuration initiale $PROJECT_NAME" 10 60

# ============================================================
# CONFIGURATION RÉSEAU
# ============================================================

# Détection automatique de l'interface par défaut
IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1 || true)

if [ -n "$IFACE" ]; then
    if whiptail --yesno "Configurer le réseau ($IFACE) ?" 8 50; then

        # DHCP ou IP statique
        if whiptail --yesno "Utiliser DHCP ?" 8 50; then

            # Configuration DHCP
            cat > /etc/netplan/99-${PROJECT_NAME_LOWER}.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: true
EOF
        else
            # Configuration statique
            IP=$(whiptail --inputbox "IP/CIDR" 8 50 3>&1 1>&2 2>&3)
            GW=$(whiptail --inputbox "Gateway" 8 50 3>&1 1>&2 2>&3)

            cat > /etc/netplan/99-${PROJECT_NAME_LOWER}.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      addresses: [$IP]
      routes:
        - to: default
          via: $GW
EOF
        fi

        # Application configuration réseau
        netplan apply
    fi
fi

# ============================================================
# FUSEAU HORAIRE
# ============================================================

SELECTED_TZ=$(timedatectl show --property=Timezone --value)
timedatectl set-timezone "$SELECTED_TZ"

# ============================================================
# SÉCURITÉ DE BASE (UFW)
# ============================================================

# IMPORTANT : ouvrir ports AVANT activation
ufw allow OpenSSH || true
ufw allow 80 || true
ufw allow 443 || true
ufw allow 1883 || true

# Activation du firewall
ufw --force enable || true

# ============================================================
# CONFIGURATION MQTT
# ============================================================

# Option de sécurisation du broker MQTT
if whiptail --yesno "Configurer mot de passe MQTT ?" 8 50; then
    MQTT_PASSWORD=$(whiptail --passwordbox "Mot de passe MQTT" 8 50 3>&1 1>&2 2>&3)
fi

# ============================================================
# INSTALLATION DOCKER
# ============================================================

install_docker

# ============================================================
# SYNCHRONISATION DU CODE
# ============================================================

safe_git_sync
cd "$INSTALL_DIR"

# ============================================================
# CONFIGURATION ENVIRONNEMENT
# ============================================================

cat > .env <<EOF
TZ=${SELECTED_TZ}
MQTT_PASSWORD=${MQTT_PASSWORD}
EOF

chmod 600 .env

# ============================================================
# SÉLECTION DES PROFILS DOCKER
# ============================================================

PROFILES=$(whiptail --checklist "Profils Docker :" 15 50 4 \
    "zigbee2mqtt" "Zigbee" OFF \
    "meteo" "Météo" OFF \
    "backup" "Backup" OFF \
    3>&1 1>&2 2>&3)

PROFILES_CLEAN=$(echo "$PROFILES" | tr -d '"')
echo "$PROFILES_CLEAN" > .profiles

# Construction des arguments Docker Compose
PROFILES_ARGS=""
for p in $PROFILES_CLEAN; do
    PROFILES_ARGS="$PROFILES_ARGS --profile $p"
done

# ============================================================
# CONFIGURATION MOSQUITTO (préparation uniquement)
# ============================================================

if [ -n "$MQTT_PASSWORD" ]; then
    mkdir -p /opt/mosquitto/config
    mosquitto_passwd -b /opt/mosquitto/config/passwd "${PROJECT_NAME_LOWER}" "$MQTT_PASSWORD"
fi

# ============================================================
# DÉPLOIEMENT DES CONTENEURS
# ============================================================

wait_docker

# Récupération images + lancement stack
docker compose pull
docker compose $PROFILES_ARGS up -d --remove-orphans

# ============================================================
# SERVICE SYSTEMD (AUTO-RESTART)
# ============================================================

cat > /etc/systemd/system/${PROJECT_NAME_LOWER}.service <<EOF
[Unit]
Description=${PROJECT_NAME} Stack
Requires=docker.service
After=docker.service

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable ${PROJECT_NAME_LOWER}

# ============================================================
# OUTILS CLI
# ============================================================

cat > /usr/local/bin/${PROJECT_NAME_LOWER}-status <<EOF
#!/bin/bash
cd ${INSTALL_DIR}
docker compose ps
EOF

chmod +x /usr/local/bin/${PROJECT_NAME_LOWER}-status

# ============================================================
# FIN
# ============================================================

IP=$(hostname -I | awk '{print $1}')

whiptail --msgbox "Installation terminée\nIP: $IP" 10 60

exit 0
