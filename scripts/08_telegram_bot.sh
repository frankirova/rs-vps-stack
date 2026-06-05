#!/usr/bin/env bash
# =============================================================================
# 08_telegram_bot.sh — Alertas + Bot interactivo de actualizaciones
#
# QUÉ HACE:
#   - Configura alertas push para eventos críticos del servidor
#   - Bot interactivo de actualizaciones:
#       /si         → instala actualizaciones pendientes
#       /no         → pospone al día siguiente
#       /reiniciar  → reinicia si hay kernel update pendiente
#       /estado     → resumen de salud del servidor
#       /backups    → estado del último backup
#       /baneados   → IPs baneadas por Fail2ban
#       /ayuda      → lista de comandos
#   - Activa notificaciones de Fail2ban
#   - Notifica en cada reinicio del servidor
#
# FIXES APLICADOS vs versión original:
#   - Servicio systemd sin directivas ProtectSystem/ProtectHome
#     (causaban error 226/NAMESPACE en algunos entornos)
#   - remote-control de Unbound deshabilitado en módulo 06
#
# PREREQUISITO:
#   Crear bot en @BotFather y configurar TG_BOT_TOKEN + TG_CHAT_ID en 00_config.sh
#
# USO:
#   sudo bash 08_telegram_bot.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 08: Telegram Bot ==="

# -----------------------------------------------------------------------------
# Instrucciones para crear el bot
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PASO PREVIO: Crear bot en Telegram (si aún no lo hiciste)     ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║                                                                  ║${NC}"
echo -e "${BLUE}║  1. Abrí Telegram → buscá @BotFather                           ║${NC}"
echo -e "${BLUE}║  2. Enviá /newbot                                                ║${NC}"
echo -e "${BLUE}║  3. Elegí nombre y username (debe terminar en 'bot')            ║${NC}"
echo -e "${BLUE}║  4. Copiá el TOKEN en 00_config.sh → TG_BOT_TOKEN              ║${NC}"
echo -e "${BLUE}║  5. Iniciá chat con tu bot → /start                             ║${NC}"
echo -e "${BLUE}║  6. Visitá: https://api.telegram.org/bot<TOKEN>/getUpdates     ║${NC}"
echo -e "${BLUE}║  7. Tu chat_id está en result[0].message.chat.id               ║${NC}"
echo -e "${BLUE}║                                                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Verificar que el token y chat_id fueron configurados
if [[ "${TG_BOT_TOKEN}" == "123456789:AAxxxxxxxxxx"* ]] || \
   [[ "${TG_CHAT_ID}" == "000000000" ]]; then
  log_error "Configurá TG_BOT_TOKEN y TG_CHAT_ID en 00_config.sh antes de continuar"
  exit 1
fi

# -----------------------------------------------------------------------------
# PASO 1 — Verificar conectividad con la API de Telegram
# -----------------------------------------------------------------------------
log_info "Verificando conexión con Telegram API..."
TG_TEST=$(curl -s --max-time 10 \
  "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe")

if echo "${TG_TEST}" | grep -q '"ok":true'; then
  BOT_NAME=$(echo "${TG_TEST}" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
  log_ok "Bot conectado: @${BOT_NAME}"
else
  log_error "No se pudo conectar. Verificá el TG_BOT_TOKEN"
  echo "Respuesta: ${TG_TEST}"
  exit 1
fi

# -----------------------------------------------------------------------------
# PASO 2 — Actualizar config.env
# -----------------------------------------------------------------------------
log_info "Actualizando archivo de configuración del sistema..."
sed -i "s|TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"${TG_BOT_TOKEN}\"|" /etc/vps-hardening/config.env
sed -i "s|TG_CHAT_ID=.*|TG_CHAT_ID=\"${TG_CHAT_ID}\"|" /etc/vps-hardening/config.env
log_ok "Credenciales actualizadas en /etc/vps-hardening/config.env"

# -----------------------------------------------------------------------------
# PASO 3 — Script principal del bot
# -----------------------------------------------------------------------------
log_info "Creando bot de actualizaciones interactivo..."

cat > /usr/local/bin/vps-telegram-bot <<'BOT_SCRIPT'
#!/usr/bin/env bash
# Bot interactivo de Telegram para gestión del VPS

set -uo pipefail

source /etc/vps-hardening/config.env

API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
STATE_FILE="/var/lib/vps-hardening/bot_state"
LOG_FILE="/var/log/vps-bot.log"
OFFSET_FILE="/var/lib/vps-hardening/tg_offset"

mkdir -p /var/lib/vps-hardening
touch "${STATE_FILE}" "${OFFSET_FILE}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"; }

send_msg() {
  local text="$1"
  curl -s -X POST "${API}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${TG_CHAT_ID}\",
      \"text\": $(echo "${text}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
      \"parse_mode\": \"HTML\"
    }" > /dev/null 2>&1
}

get_updates() {
  local offset
  offset=$(cat "${OFFSET_FILE}" 2>/dev/null || echo "0")
  curl -s --max-time 30 \
    "${API}/getUpdates?offset=${offset}&timeout=25" 2>/dev/null
}

is_authorized() {
  local from_id="$1"
  [[ "${from_id}" == "${TG_CHAT_ID}" ]]
}

cmd_estado() {
  local uptime_str load_avg mem_total mem_used disk_used wg_peers reboot_required
  uptime_str=$(uptime -p)
  load_avg=$(cut -d' ' -f1-3 /proc/loadavg)
  mem_total=$(free -m | awk '/^Mem:/{print $2}')
  mem_used=$(free -m | awk '/^Mem:/{print $3}')
  disk_used=$(df -h / | awk 'NR==2{print $5 " de " $2}')
  wg_peers=0
  if command -v wg &>/dev/null && ip link show wg0 &>/dev/null 2>&1; then
    wg_peers=$(wg show wg0 2>/dev/null | grep -c "^peer" || echo "0")
  fi
  reboot_required=""
  [[ -f /var/run/reboot-required ]] && \
    reboot_required="
⚠️ <b>Reinicio pendiente</b> (kernel actualizado)"

  send_msg "🖥 <b>Estado del servidor</b>
━━━━━━━━━━━━━━━━━━━━━
🏠 Host: <code>$(hostname)</code>
⏱ Uptime: ${uptime_str}
⚡ Carga: ${load_avg}
💾 RAM: ${mem_used}/${mem_total} MB
💿 Disco: ${disk_used}
🔒 Peers VPN activos: ${wg_peers}${reboot_required}
━━━━━━━━━━━━━━━━━━━━━
$(date '+%d/%m/%Y %H:%M:%S')"
}

cmd_ayuda() {
  send_msg "🤖 <b>Comandos disponibles</b>
━━━━━━━━━━━━━━━━━━━━━
/estado      — Salud del servidor
/backups     — Estado del último backup
/baneados    — IPs baneadas por Fail2ban
/si          — Instalar actualizaciones pendientes
/no          — Posponer actualizaciones
/reiniciar   — Reiniciar el servidor
/ayuda       — Esta ayuda"
}

cmd_backups() {
  source /etc/vps-hardening/config.env
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
  if last_snap=$(restic snapshots --latest 1 --compact 2>/dev/null | tail -1); then
    send_msg "💾 <b>Estado de backups</b>
━━━━━━━━━━━━━━━━━━━━━
✅ Último snapshot:
<code>${last_snap}</code>
━━━━━━━━━━━━━━━━━━━━━
Próximo backup: 3:00 AM"
  else
    send_msg "⚠️ No se pudo acceder al repositorio de backups."
  fi
}

cmd_baneados() {
  if command -v fail2ban-client &>/dev/null; then
    banned_list=$(fail2ban-client status sshd 2>/dev/null | \
      grep "Banned IP" | sed 's/.*Banned IP list://g' | tr ' ' '\n' | \
      grep -v '^$' | head -20)
    if [[ -z "${banned_list}" ]]; then
      send_msg "🛡 <b>IPs baneadas</b>
━━━━━━━━━━━━━━━━━━━━━
✅ Ninguna IP baneada en este momento"
    else
      send_msg "🛡 <b>IPs baneadas</b>
━━━━━━━━━━━━━━━━━━━━━
$(echo "${banned_list}" | while read -r ip; do echo "🚫 <code>${ip}</code>"; done)"
    fi
  else
    send_msg "⚠️ Fail2ban no disponible"
  fi
}

cmd_instalar_updates() {
  send_msg "⏳ <b>Instalando actualizaciones...</b>
Esto puede tardar unos minutos."
  local log_tmp
  log_tmp=$(mktemp)
  if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "${log_tmp}" 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >> "${log_tmp}" 2>&1 || true
    local reboot_msg=""
    [[ -f /var/run/reboot-required ]] && \
      reboot_msg="
⚠️ <b>Reinicio requerido</b> — Enviá /reiniciar cuando estés listo"
    send_msg "✅ <b>Actualizaciones instaladas</b>${reboot_msg}
$(date '+%d/%m/%Y %H:%M:%S')"
    echo "" > "${STATE_FILE}"
    log "Actualizaciones instaladas exitosamente"
  else
    send_msg "🔴 <b>Error instalando actualizaciones</b>
Revisá: <code>tail -50 /var/log/apt/history.log</code>"
    log "ERROR: Fallo al instalar actualizaciones"
  fi
  rm -f "${log_tmp}"
}

cmd_reiniciar() {
  if [[ -f /var/run/reboot-required ]]; then
    send_msg "🔄 <b>Reiniciando en 10 segundos...</b>
El servidor estará disponible en ~1-2 minutos."
    log "Reinicio solicitado"
    sleep 10
    reboot
  else
    send_msg "ℹ️ No hay reinicio pendiente en este momento."
  fi
}

log "Bot iniciado"

while true; do
  UPDATES=$(get_updates 2>/dev/null)
  if [[ -z "${UPDATES}" ]] || ! echo "${UPDATES}" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
    sleep 5
    continue
  fi

  echo "${UPDATES}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('result', []):
    uid = r.get('update_id', 0)
    msg = r.get('message', {})
    fid = str(msg.get('chat', {}).get('id', ''))
    txt = msg.get('text', '').strip()
    print(f'{uid}|{fid}|{txt}')
" 2>/dev/null | while IFS='|' read -r update_id from_id text; do
    echo "$((update_id + 1))" > "${OFFSET_FILE}"
    if ! is_authorized "${from_id}"; then
      log "Mensaje ignorado de: ${from_id}"
      continue
    fi
    log "Comando: ${text}"
    case "${text}" in
      /estado*)     cmd_estado ;;
      /ayuda*)      cmd_ayuda ;;
      /backups*)    cmd_backups ;;
      /baneados*)   cmd_baneados ;;
      /si*)
        PENDING=$(cat "${STATE_FILE}" 2>/dev/null)
        if [[ -z "${PENDING}" ]]; then
          send_msg "ℹ️ No hay actualizaciones pendientes. Usá /estado para ver el estado."
        else
          cmd_instalar_updates "${PENDING}"
        fi
        ;;
      /no*)
        send_msg "⏸ <b>Actualizaciones pospuestas</b>
Te recuerdo mañana a las 9:00 AM. 👍"
        log "Actualizaciones pospuestas"
        ;;
      /reiniciar*)  cmd_reiniciar ;;
      /start*)      cmd_ayuda ;;
      *)
        [[ -n "${text}" ]] && \
          send_msg "❓ Comando no reconocido: <code>${text}</code>
Enviá /ayuda para ver los comandos disponibles."
        ;;
    esac
  done
  sleep 2
done
BOT_SCRIPT

chmod +x /usr/local/bin/vps-telegram-bot

# -----------------------------------------------------------------------------
# PASO 4 — Script de detección de actualizaciones
# -----------------------------------------------------------------------------
cat > /usr/local/bin/vps-check-updates <<'CHECK_SCRIPT'
#!/usr/bin/env bash
source /etc/vps-hardening/config.env

STATE_FILE="/var/lib/vps-hardening/bot_state"
LOG_FILE="/var/log/vps-updates.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"; }

send_msg() {
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${TG_CHAT_ID}\",
      \"text\": $(echo "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
      \"parse_mode\": \"HTML\"
    }" > /dev/null 2>&1
}

apt-get update -qq 2>/dev/null
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | grep -v "^$")
COUNT=$(echo "${UPGRADABLE}" | grep -c "/" || echo "0")

[[ "${COUNT}" -eq 0 ]] && { log "Sin actualizaciones"; exit 0; }

log "${COUNT} actualizaciones disponibles"

PKG_LIST=$(echo "${UPGRADABLE}" | head -15 | awk -F'/' '{print "• " $1}')
[[ "${COUNT}" -gt 15 ]] && PKG_LIST="${PKG_LIST}
... y $((COUNT - 15)) paquetes más"

KERNEL_UPDATE=""
echo "${UPGRADABLE}" | grep -q "linux-image\|linux-headers" && \
  KERNEL_UPDATE="
⚠️ <b>Incluye actualización de kernel</b> (requiere reinicio)"

echo "${PKG_LIST}" > "${STATE_FILE}"

send_msg "🔔 <b>Actualizaciones disponibles</b> (${COUNT} paquetes)
━━━━━━━━━━━━━━━━━━━━━
${PKG_LIST}${KERNEL_UPDATE}
━━━━━━━━━━━━━━━━━━━━━
¿Instalamos ahora?
👉 /si — Instalar ahora
👉 /no — Posponer para mañana"

log "Notificación enviada. ${COUNT} pendientes."
CHECK_SCRIPT

chmod +x /usr/local/bin/vps-check-updates

# -----------------------------------------------------------------------------
# PASO 5 — Servicio systemd para el bot (sin directivas de namespace problemáticas)
# -----------------------------------------------------------------------------
log_info "Creando servicio systemd para el bot..."

cat > /etc/systemd/system/vps-telegram-bot.service <<EOF
[Unit]
Description=VPS Telegram Bot — Alertas y actualizaciones interactivas
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vps-telegram-bot
Restart=always
RestartSec=10
User=root
StandardOutput=append:/var/log/vps-bot.log
StandardError=append:/var/log/vps-bot.log

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# PASO 6 — Servicio de notificación de reinicio
# -----------------------------------------------------------------------------
cat > /etc/systemd/system/vps-boot-notify.service <<EOF
[Unit]
Description=Notificación de reinicio del servidor por Telegram
After=network-online.target vps-telegram-bot.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 15 && source /etc/vps-hardening/config.env && curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\":\"\${TG_CHAT_ID}\",\"text\":\"🟢 Servidor reiniciado\\nHost: \$(hostname)\\nFecha: \$(date +\"%d/%m/%Y %H:%M\")\",\"parse_mode\":\"HTML\"}" > /dev/null 2>&1'
User=root

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# PASO 7 — Cron de detección diaria de actualizaciones
# -----------------------------------------------------------------------------
log_info "Configurando cron de actualizaciones..."
cat >> /etc/cron.d/vps-backup <<EOF

# Verificación diaria de actualizaciones (9:00 AM)
0 9 * * * root /usr/local/bin/vps-check-updates >> /var/log/vps-updates.log 2>&1
EOF
log_ok "Cron configurado: 9:00 AM diario"

# -----------------------------------------------------------------------------
# PASO 8 — Activar notificaciones de Fail2ban
# -----------------------------------------------------------------------------
log_info "Activando notificaciones Telegram en Fail2ban..."
if ! grep -q "action = %(action_)s" /etc/fail2ban/jail.local; then
  sed -i '/\[sshd\]/a action = %(action_)s\n         telegram' \
    /etc/fail2ban/jail.local 2>/dev/null || true
fi
systemctl restart fail2ban 2>/dev/null || true
log_ok "Fail2ban notificará por Telegram"

# -----------------------------------------------------------------------------
# PASO 9 — Habilitar y arrancar servicios
# -----------------------------------------------------------------------------
log_info "Habilitando servicios..."
systemctl daemon-reload
systemctl enable vps-telegram-bot
systemctl enable vps-boot-notify
systemctl start vps-telegram-bot

sleep 3

if systemctl is-active --quiet vps-telegram-bot; then
  log_ok "Bot de Telegram activo"
else
  log_error "El bot no levantó. Verificá: journalctl -u vps-telegram-bot -n 20"
  exit 1
fi

systemctl start vps-boot-notify 2>/dev/null || true

# -----------------------------------------------------------------------------
# PASO 10 — Mensaje de bienvenida
# -----------------------------------------------------------------------------
log_info "Enviando mensaje de bienvenida..."
sleep 5

curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${TG_CHAT_ID}\",
    \"text\": \"🎉 <b>VPS Hardening Stack operativo</b>\\n━━━━━━━━━━━━━━━━━━━━━\\n✅ SSH Hardened (puerto ${SSH_PORT})\\n✅ Firewall UFW activo\\n✅ Fail2ban protegiendo SSH\\n✅ WireGuard VPN (${WG_PEERS} peers)\\n✅ Unbound DNS interno\\n✅ Backups Restic configurados\\n✅ Bot de actualizaciones activo\\n━━━━━━━━━━━━━━━━━━━━━\\nEnviá /ayuda para ver los comandos.\",
    \"parse_mode\": \"HTML\"
  }" > /dev/null 2>&1

echo ""
log_ok "=== Bot de Telegram configurado exitosamente ==="
log_info "Comandos: /si /no /reiniciar /estado /backups /baneados /ayuda"
log_info "Logs: tail -f /var/log/vps-bot.log"
log_ok "╔══════════════════════════════════════╗"
log_ok "║  🎉 STACK COMPLETO DESPLEGADO        ║"
log_ok "╚══════════════════════════════════════╝"
