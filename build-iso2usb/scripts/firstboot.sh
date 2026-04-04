#!/bin/bash
# NeurHomIA — firstboot v3 propre

set -euo pipefail
LOG_FILE="/var/log/neurhomia-firstboot.log"
exec > "$LOG_FILE" 2>&1
set -x

# ============================================
# VARIABLES
# ============================================
PROJECT_NAME="NeurHomIA"
PROJECT_NAME_LOWER="neurhomia"
GITHUB_REPO="cce66/NeurHomIA"
INSTALL_DIR="/opt/${PROJECT_NAME_LOWER}"

TARGET_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd || true)
[ -z "$TARGET_USER" ] && TARGET_USER="${PROJECT_NAME_LOWER}"

SELECTED_TZ=""
MQTT_PASSWORD=""

log() {
    echo "$(date '+%F %T') [INFO] $*"
}

wait_docker() {
    log "Attente Docker..."
    until systemctl is-active --quiet docker; do
        sleep 2
    done
}

install_docker() {
    if ! command -v docker >/dev/null; then
        log "Installation Docker..."
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg lsb-release

        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        systemctl enable --now docker
    fi

    wait_docker
    usermod -aG docker "$TARGET_USER" || true
}

safe_git_sync() {
    if [ -d "${INSTALL_DIR}/.git" ]; then
        log "Git pull..."
        cd "${INSTALL_DIR}"
        git pull
    else
        log "Git clone..."
        for i in {1..5}; do
            git clone "https://github.com/${GITHUB_REPO}.git" "${INSTALL_DIR}" && break
            sleep 5
        done
    fi
}

# ============================================
# UI
# ============================================
whiptail --title "$PROJECT_NAME" \
  --msgbox "Configuration initiale $PROJECT_NAME" 10 60

# ============================================
# RESEAU
# ============================================
IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1 || true)

if [ -n "$IFACE" ]; then
    if whiptail --yesno "Configurer le réseau ($IFACE) ?" 8 50; then
        if whiptail --yesno "Utiliser DHCP ?" 8 50; then
            cat > /etc/netplan/99-${PROJECT_NAME_LOWER}.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      dhcp4: true
EOF
        else
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
        netplan apply
    fi
fi

# ============================================
# TIMEZONE
# ============================================
SELECTED_TZ=$(timedatectl show --property=Timezone --value)
timedatectl set-timezone "$SELECTED_TZ"

# ============================================
# UFW SAFE
# ============================================
ufw allow OpenSSH || true
ufw allow 80 || true
ufw allow 443 || true
ufw allow 1883 || true
ufw --force enable || true

# ============================================
# MQTT PASSWORD
# ============================================
if whiptail --yesno "Configurer mot de passe MQTT ?" 8 50; then
    MQTT_PASSWORD=$(whiptail --passwordbox "Mot de passe MQTT" 8 50 3>&1 1>&2 2>&3)
fi

# ============================================
# DOCKER
# ============================================
install_docker

# ============================================
# GIT
# ============================================
safe_git_sync
cd "$INSTALL_DIR"

# ============================================
# ENV
# ============================================
cat > .env <<EOF
TZ=${SELECTED_TZ}
MQTT_PASSWORD=${MQTT_PASSWORD}
EOF
chmod 600 .env

# ============================================
# PROFILS
# ============================================
PROFILES=$(whiptail --checklist "Profils Docker :" 15 50 4 \
    "zigbee2mqtt" "Zigbee" OFF \
    "meteo" "Météo" OFF \
    "backup" "Backup" OFF \
    3>&1 1>&2 2>&3)

PROFILES_CLEAN=$(echo "$PROFILES" | tr -d '"')
echo "$PROFILES_CLEAN" > .profiles

PROFILES_ARGS=""
for p in $PROFILES_CLEAN; do
    PROFILES_ARGS="$PROFILES_ARGS --profile $p"
done

# ============================================
# MOSQUITTO CONFIG (PAS docker run)
# ============================================
if [ -n "$MQTT_PASSWORD" ]; then
    mkdir -p /opt/mosquitto/config
    mosquitto_passwd -b /opt/mosquitto/config/passwd "${PROJECT_NAME_LOWER}" "$MQTT_PASSWORD"
fi

# ============================================
# DOCKER START
# ============================================
wait_docker
docker compose pull
docker compose $PROFILES_ARGS up -d --remove-orphans

# ============================================
# SYSTEMD STACK
# ============================================
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

# ============================================
# CLI
# ============================================
cat > /usr/local/bin/${PROJECT_NAME_LOWER}-status <<EOF
#!/bin/bash
cd ${INSTALL_DIR}
docker compose ps
EOF

chmod +x /usr/local/bin/${PROJECT_NAME_LOWER}-status

# ============================================
# FIN
# ============================================
IP=$(hostname -I | awk '{print $1}')
whiptail --msgbox "Installation terminée\nIP: $IP" 10 60

exit 0
