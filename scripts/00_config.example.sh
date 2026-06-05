# ESTE ARCHIVO ES UN EJEMPLO — copiarlo a 00_config.sh y editar los valores
#!/usr/bin/env bash
# =============================================================================
# 00_config.sh — Variables globales compartidas por todos los módulos
# VPS Hardening Stack — Ubuntu 22.04 LTS
#
# INSTRUCCIONES:
#   1. Editá TODAS las variables marcadas con <-- EDITAR
#   2. Este archivo es sourceado por todos los demás módulos
#   3. Protegelo con: chmod 600 00_config.sh
# =============================================================================

# -----------------------------------------------------------------------------
# SSH
# -----------------------------------------------------------------------------
SSH_PORT=2222                             # <-- EDITAR: puerto SSH nuevo
SSH_USER="admin"                          # <-- EDITAR: tu usuario no-root
SSH_PUBKEY="ssh-ed25519 AAAA...tu_clave" # <-- EDITAR: cat ~/.ssh/id_ed25519.pub

# -----------------------------------------------------------------------------
# WIREGUARD — Red VPN interna
# -----------------------------------------------------------------------------
WG_INTERFACE="wg0"
WG_PORT=51820
WG_SERVER_IP="10.10.0.1/24"
WG_DNS="10.10.0.1"
WG_PEERS=10

# <-- EDITAR: nombres reales de los trabajadores
WG_PEER_NAMES=(
  "admin"
  "worker01"
  "worker02"
  "worker03"
  "worker04"
  "worker05"
  "worker06"
  "worker07"
  "worker08"
  "worker09"
)

# -----------------------------------------------------------------------------
# TELEGRAM — Bot de alertas y actualizaciones
# -----------------------------------------------------------------------------
TG_BOT_TOKEN="123456789:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" # <-- EDITAR
TG_CHAT_ID="000000000"                                      # <-- EDITAR
TG_ADMIN_IDS=("000000000")                                  # <-- EDITAR

# -----------------------------------------------------------------------------
# BACKUPS — Restic
# -----------------------------------------------------------------------------
RESTIC_PASSWORD="cambia_esta_password_segura_ahora" # <-- EDITAR y guardar en gestor de contraseñas
RESTIC_REPO="/var/backups/restic"                   # Repo local por defecto
# Para NAS externo descomentar y editar:
# RESTIC_REPO="sftp:usuario@IP_NAS:/ruta/backups"

BACKUP_PATHS=(
  "/etc"
  "/home"
  "/var/log"
  "/root"
  "/usr/local/bin"
  "/etc/vps-hardening"
)

BACKUP_RETENTION_DAILY=7
BACKUP_RETENTION_WEEKLY=4
BACKUP_RETENTION_MONTHLY=3

# -----------------------------------------------------------------------------
# FAIL2BAN
# -----------------------------------------------------------------------------
F2B_BANTIME="1h"
F2B_FINDTIME="10m"
F2B_MAXRETRY=5

# -----------------------------------------------------------------------------
# SISTEMA
# -----------------------------------------------------------------------------
TIMEZONE="America/Argentina/Cordoba" # <-- EDITAR: tu timezone
HOSTNAME_NEW="mi-vps"                # <-- EDITAR: hostname del servidor

# -----------------------------------------------------------------------------
# Colores para output (no editar)
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "Este script debe ejecutarse como root: sudo bash $0"
    exit 1
  fi
}

check_os() {
  if ! grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null; then
    log_warn "Este stack fue diseñado para Ubuntu 22.04. Continuás bajo tu responsabilidad."
    read -r -p "¿Continuar? [s/N]: " resp
    [[ "$resp" =~ ^[sS]$ ]] || exit 1
  fi
}
