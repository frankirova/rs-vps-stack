#!/usr/bin/env bash
# =============================================================================
# 04_fail2ban.sh — Protección contra fuerza bruta con Fail2ban
#
# QUÉ HACE:
#   - Instala y configura Fail2ban
#   - Monitorea intentos fallidos en SSH
#   - Banea IPs automáticamente según umbrales configurados
#   - Envía alerta a Telegram cuando banea una IP (requiere módulo 08)
#   - Lista blanca para tu IP (no banearte a vos mismo)
#
# USO:
#   sudo bash 04_fail2ban.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 04: Fail2ban ==="

# -----------------------------------------------------------------------------
# PASO 1 — Instalar Fail2ban
# -----------------------------------------------------------------------------
if ! command -v fail2ban-server &>/dev/null; then
  log_info "Instalando Fail2ban..."
  apt-get install -y -qq fail2ban
fi
log_ok "Fail2ban disponible"

# -----------------------------------------------------------------------------
# PASO 2 — Configuración principal (jail.local sobreescribe jail.conf)
# NUNCA editar jail.conf directamente, se pisa en updates
# -----------------------------------------------------------------------------
log_info "Configurando jail.local..."

cat > /etc/fail2ban/jail.local <<EOF
# =============================================================
# jail.local — Configuración Fail2ban para VPS Hardening Stack
# Generado por 04_fail2ban.sh el $(date)
# =============================================================

[DEFAULT]
# Tiempo de baneo (1h = 3600s)
bantime  = ${F2B_BANTIME}

# Ventana de tiempo para contar intentos fallidos
findtime = ${F2B_FINDTIME}

# Máximo de intentos antes de banear
maxretry = ${F2B_MAXRETRY}

# Backend para leer logs (systemd es más eficiente en Ubuntu 22.04)
backend = systemd

# IPs que NUNCA se banean (tu IP fija si tenés, o la de tu ISP)
# 127.0.0.1/8 siempre está en whitelist
ignoreip = 127.0.0.1/8 ::1 10.10.0.0/24

# Acción por defecto: banear en UFW
banaction = ufw
banaction_allports = ufw

# Alerta por Telegram cuando se banea una IP (ver action_telegram.conf)
# Se activa en el módulo 08 cuando el bot esté configurado
# action = %(action_)s
#          telegram

# Encoding de los logs
encoding = utf-8

# =============================================================
# JAIL: SSH
# =============================================================
[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(syslog_backend)s
maxretry = ${F2B_MAXRETRY}
bantime  = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}

# =============================================================
# JAIL: SSH fuerza bruta agresiva (baneo más largo para reincidentes)
# =============================================================
[sshd-ddos]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(syslog_backend)s
maxretry = 2
bantime  = 24h
findtime = 1h
EOF

log_ok "jail.local configurado"

# -----------------------------------------------------------------------------
# PASO 3 — Acción personalizada para UFW (más confiable que iptables en Ubuntu)
# -----------------------------------------------------------------------------
log_info "Configurando acción UFW para Fail2ban..."

cat > /etc/fail2ban/action.d/ufw.conf <<'EOF'
# Acción Fail2ban usando UFW — más integrado con Ubuntu que iptables directo
[Definition]
actionstart =
actionstop  =
actioncheck =

actionban   = ufw insert 1 deny from <ip> to any comment "fail2ban-<name>"
actionunban = ufw delete deny from <ip> to any

[Init]
name = default
EOF

log_ok "Acción UFW configurada"

# -----------------------------------------------------------------------------
# PASO 4 — Filtro personalizado para detección más precisa de SSH
# -----------------------------------------------------------------------------
log_info "Verificando filtro SSH..."
# El filtro sshd ya viene con fail2ban, solo verificamos que existe
if [[ -f /etc/fail2ban/filter.d/sshd.conf ]]; then
  log_ok "Filtro sshd existente (builtin)"
else
  log_warn "Filtro sshd no encontrado, puede haber un problema en la instalación"
fi

# -----------------------------------------------------------------------------
# PASO 5 — Script de notificación Telegram (stub, se completa en módulo 08)
# -----------------------------------------------------------------------------
log_info "Preparando stub de notificación Telegram..."

mkdir -p /usr/local/lib/vps-hardening

cat > /usr/local/lib/vps-hardening/telegram_notify.sh <<'TELEGRAM_SCRIPT'
#!/usr/bin/env bash
# Stub de notificación Telegram — se completa en módulo 08
# Este archivo es llamado por Fail2ban y otros módulos

CONFIG_FILE="/etc/vps-hardening/config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  # Config aún no disponible, loguear solamente
  echo "[$(date)] NOTIFY: $*" >> /var/log/vps-bot.log
  exit 0
fi

source "${CONFIG_FILE}"

send_telegram() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${TG_CHAT_ID}\",
      \"text\": \"${message}\",
      \"parse_mode\": \"HTML\"
    }" > /dev/null 2>&1
}

send_telegram "$@"
TELEGRAM_SCRIPT

chmod +x /usr/local/lib/vps-hardening/telegram_notify.sh

# -----------------------------------------------------------------------------
# PASO 6 — Acción Telegram para Fail2ban (se activa cuando el bot esté listo)
# -----------------------------------------------------------------------------
cat > /etc/fail2ban/action.d/telegram.conf <<'EOF'
# Acción Fail2ban → Telegram
# Se activa en jail.local después de configurar el bot (módulo 08)
[Definition]
actionstart = /usr/local/lib/vps-hardening/telegram_notify.sh \
              "🛡 <b>Fail2ban iniciado</b>%0AJail: <code><name></code>%0AVPS: $(hostname)"

actionstop  = /usr/local/lib/vps-hardening/telegram_notify.sh \
              "⚠️ <b>Fail2ban detenido</b>%0AJail: <code><name></code>"

actionban   = /usr/local/lib/vps-hardening/telegram_notify.sh \
              "🚨 <b>IP Baneada</b>%0A%0AIP: <code><ip></code>%0AServicio: <name>%0AIntentos: <failures>%0ADuración: $(echo <bantime> | sed 's/s/s/' | sed 's/m/ min/' | sed 's/h/ hora(s)/')%0AVPS: $(hostname)"

actionunban = /usr/local/lib/vps-hardening/telegram_notify.sh \
              "✅ <b>IP Desbaneada</b>%0AIP: <code><ip></code>%0AServicio: <name>"
EOF

log_ok "Acción Telegram preparada (se activa en módulo 08)"

# -----------------------------------------------------------------------------
# PASO 7 — Habilitar y arrancar Fail2ban
# -----------------------------------------------------------------------------
log_info "Habilitando Fail2ban..."
systemctl enable fail2ban
systemctl restart fail2ban

# Esperar que levante
sleep 3

if systemctl is-active --quiet fail2ban; then
  log_ok "Fail2ban activo y corriendo"
else
  log_error "Fail2ban no levantó correctamente"
  journalctl -u fail2ban --no-pager -n 20
  exit 1
fi

# -----------------------------------------------------------------------------
# PASO 8 — Mostrar estado
# -----------------------------------------------------------------------------
echo ""
log_info "Estado de jails activos:"
fail2ban-client status

echo ""
log_info "Comandos útiles de Fail2ban:"
echo "  Ver IPs baneadas:        fail2ban-client status sshd"
echo "  Desbanear una IP:        fail2ban-client set sshd unbanip IP"
echo "  Ver logs:                tail -f /var/log/fail2ban.log"
echo ""
log_ok "=== Fail2ban configurado exitosamente ==="
log_info "Umbrales: ${F2B_MAXRETRY} intentos en ${F2B_FINDTIME} → ban por ${F2B_BANTIME}"
log_info "Próximo paso: sudo bash 05_wireguard_server.sh"
