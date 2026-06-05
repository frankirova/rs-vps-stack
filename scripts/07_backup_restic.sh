#!/usr/bin/env bash
# =============================================================================
# 07_backup_restic.sh — Backups cifrados con Restic
#
# QUÉ HACE:
#   - Instala Restic
#   - Inicializa repositorio de backups local (cifrado)
#   - Configura backup diario vía cron con retención automática
#   - Notifica a Telegram si el backup falla
#   - Parametrizado para migrar a NAS cuando lo tengas disponible:
#     solo cambiás RESTIC_REPO en 00_config.sh
#
# USO:
#   sudo bash 07_backup_restic.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 07: Backups con Restic ==="

# -----------------------------------------------------------------------------
# PASO 1 — Instalar Restic
# -----------------------------------------------------------------------------
if ! command -v restic &>/dev/null; then
  log_info "Instalando Restic..."
  
  # Detectar arquitectura
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64)  RESTIC_ARCH="amd64" ;;
    aarch64) RESTIC_ARCH="arm64" ;;
    *)       RESTIC_ARCH="amd64" ;;
  esac
  
  # Obtener última versión
  RESTIC_VERSION=$(curl -s https://api.github.com/repos/restic/restic/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  
  if [[ -z "${RESTIC_VERSION}" ]]; then
    # Fallback a apt si no hay internet
    apt-get install -y -qq restic
  else
    RESTIC_URL="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${RESTIC_ARCH}.bz2"
    curl -sL "${RESTIC_URL}" | bunzip2 > /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
    log_ok "Restic ${RESTIC_VERSION} instalado"
  fi
else
  log_ok "Restic ya instalado ($(restic version | head -1))"
fi

# -----------------------------------------------------------------------------
# PASO 2 — Crear archivo de credenciales seguro
# El password de cifrado NUNCA se pasa como argumento (visible en ps)
# Se usa como variable de entorno o archivo de password
# -----------------------------------------------------------------------------
log_info "Configurando credenciales de Restic..."

RESTIC_CREDS_DIR="/etc/vps-hardening"
RESTIC_PASSWORD_FILE="${RESTIC_CREDS_DIR}/restic_password"

mkdir -p "${RESTIC_CREDS_DIR}"
chmod 700 "${RESTIC_CREDS_DIR}"

if [[ ! -f "${RESTIC_PASSWORD_FILE}" ]]; then
  echo "${RESTIC_PASSWORD}" > "${RESTIC_PASSWORD_FILE}"
  chmod 600 "${RESTIC_PASSWORD_FILE}"
  log_ok "Archivo de password creado: ${RESTIC_PASSWORD_FILE}"
else
  log_ok "Archivo de password ya existe"
fi

# -----------------------------------------------------------------------------
# PASO 3 — Guardar variables de entorno globales del sistema
# Este archivo es sourceado por el script de backup y el bot de Telegram
# -----------------------------------------------------------------------------
cat > /etc/vps-hardening/config.env <<EOF
# Variables de entorno del sistema VPS Hardening
# Generado el $(date) — Permisos: solo root (chmod 600)

# Telegram
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

# Restic
RESTIC_REPOSITORY="${RESTIC_REPO}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"

# SSH (para referencia)
SSH_PORT="${SSH_PORT}"
EOF
chmod 600 /etc/vps-hardening/config.env
log_ok "Archivo de configuración del sistema creado"

# -----------------------------------------------------------------------------
# PASO 4 — Inicializar repositorio Restic (idempotente)
# -----------------------------------------------------------------------------
log_info "Inicializando repositorio Restic en: ${RESTIC_REPO}"

mkdir -p "${RESTIC_REPO}"

export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}"
export RESTIC_REPOSITORY="${RESTIC_REPO}"

if ! restic snapshots &>/dev/null 2>&1; then
  restic init
  log_ok "Repositorio Restic inicializado y cifrado"
else
  log_ok "Repositorio Restic ya inicializado"
fi

unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

# -----------------------------------------------------------------------------
# PASO 5 — Script principal de backup
# -----------------------------------------------------------------------------
log_info "Creando script de backup..."

cat > /usr/local/bin/vps-backup <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
# =============================================================
# vps-backup — Script de backup con Restic
# Ejecutado diariamente por cron
# =============================================================
set -euo pipefail

source /etc/vps-hardening/config.env

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

LOG_FILE="/var/log/vps-backup.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)

log() { echo "[${TIMESTAMP}] $*" | tee -a "${LOG_FILE}"; }

# Función de notificación Telegram
notify_telegram() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${TG_CHAT_ID}\",
      \"text\": \"${message}\",
      \"parse_mode\": \"HTML\"
    }" > /dev/null 2>&1 || true
}

log "=== Iniciando backup ==="

# Directorios a respaldar (definidos en config)
BACKUP_PATHS=(
  "/etc"
  "/home"
  "/var/log"
  "/root"
  "/usr/local/bin"
  "/etc/vps-hardening"
)

# Ejecutar backup
START_TIME=$(date +%s)

if restic backup \
  --tag "auto" \
  --tag "$(date +%Y-%m)" \
  --exclude="/var/log/journal" \
  --exclude="*.tmp" \
  --exclude="*.swap" \
  --one-file-system \
  "${BACKUP_PATHS[@]}" >> "${LOG_FILE}" 2>&1; then

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  log "Backup completado en ${DURATION}s"

  # Aplicar política de retención
  log "Aplicando retención de snapshots..."
  restic forget \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 3 \
    --prune >> "${LOG_FILE}" 2>&1

  # Obtener estadísticas del repo
  STATS=$(restic snapshots --latest 1 --compact 2>/dev/null | tail -2 || echo "N/A")

  notify_telegram "✅ <b>Backup completado</b>
Servidor: <code>${HOSTNAME}</code>
Duración: ${DURATION}s
Fecha: ${TIMESTAMP}"

  log "=== Backup exitoso ==="

else
  log "ERROR: El backup falló"
  notify_telegram "🔴 <b>FALLO EN BACKUP</b>
Servidor: <code>${HOSTNAME}</code>
Fecha: ${TIMESTAMP}
⚠️ Revisá el log: /var/log/vps-backup.log"
  exit 1
fi
BACKUP_SCRIPT

chmod +x /usr/local/bin/vps-backup

# -----------------------------------------------------------------------------
# PASO 6 — Script de verificación de integridad
# -----------------------------------------------------------------------------
cat > /usr/local/bin/vps-backup-check <<'CHECK_SCRIPT'
#!/usr/bin/env bash
# Verificación semanal de integridad del repositorio Restic

source /etc/vps-hardening/config.env
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE

notify_telegram() {
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"$1\",\"parse_mode\":\"HTML\"}" \
    > /dev/null 2>&1 || true
}

echo "[$(date)] Verificando integridad del repositorio..."

if restic check --read-data-subset=10% >> /var/log/vps-backup.log 2>&1; then
  notify_telegram "🔍 <b>Integridad del backup verificada</b>
Repositorio: OK ✅
Servidor: <code>$(hostname)</code>"
else
  notify_telegram "🚨 <b>ERROR DE INTEGRIDAD EN BACKUP</b>
El repositorio puede estar corrupto.
Servidor: <code>$(hostname)</code>
Acción requerida: revisión manual urgente."
fi
CHECK_SCRIPT

chmod +x /usr/local/bin/vps-backup-check

# -----------------------------------------------------------------------------
# PASO 7 — Configurar cron
# -----------------------------------------------------------------------------
log_info "Configurando cron para backups..."

# Backup diario a las 3:00 AM (hora de menor carga)
CRON_BACKUP="0 3 * * * root /usr/local/bin/vps-backup >> /var/log/vps-backup.log 2>&1"

# Verificación de integridad cada domingo a las 4:00 AM
CRON_CHECK="0 4 * * 0 root /usr/local/bin/vps-backup-check >> /var/log/vps-backup.log 2>&1"

cat > /etc/cron.d/vps-backup <<EOF
# Backups automatizados con Restic
# Generado por 07_backup_restic.sh el $(date)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${CRON_BACKUP}
${CRON_CHECK}
EOF

chmod 644 /etc/cron.d/vps-backup
log_ok "Cron configurado: backup 3:00 AM diario / verificación domingo 4:00 AM"

# -----------------------------------------------------------------------------
# PASO 8 — Primer backup de prueba
# -----------------------------------------------------------------------------
log_info "Ejecutando primer backup de prueba..."
if /usr/local/bin/vps-backup; then
  log_ok "Primer backup completado exitosamente"
else
  log_warn "El primer backup falló — verificá la configuración"
fi

# -----------------------------------------------------------------------------
# PASO 9 — Instrucciones para migrar al NAS cuando esté disponible
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  CUANDO TENGAS EL NAS — Migración en 3 pasos                   ║${NC}"
echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}║  1. En 00_config.sh cambiá:                                    ║${NC}"
echo -e "${YELLOW}║     RESTIC_REPO=\"sftp:usuario@IP_NAS:/ruta/backups\"            ║${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}║  2. Copiá la llave SSH del VPS al NAS:                         ║${NC}"
echo -e "${YELLOW}║     ssh-copy-id -i /root/.ssh/id_ed25519 usuario@IP_NAS        ║${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}║  3. Re-inicializá el repo y hacé backup:                       ║${NC}"
echo -e "${YELLOW}║     restic -r sftp:usuario@IP_NAS:/ruta/backups init           ║${NC}"
echo -e "${YELLOW}║     /usr/local/bin/vps-backup                                  ║${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
log_ok "=== Restic configurado exitosamente ==="
log_info "Repo: ${RESTIC_REPO} | Backup: 3 AM diario | Check: Domingos 4 AM"
log_info "Próximo paso: sudo bash 08_telegram_alerts.sh"
