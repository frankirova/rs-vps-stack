#!/usr/bin/env bash
# =============================================================================
# 05_wireguard_server.sh — VPN WireGuard en modo hub-and-spoke
#
# QUÉ HACE:
#   - Instala WireGuard
#   - Genera claves del servidor
#   - Genera configuración de N peers (trabajadores)
#   - Cada peer obtiene un archivo .conf listo para importar en cualquier
#     cliente WireGuard (Windows, macOS, iOS, Android, Linux)
#   - Las apps del VPS solo escuchan en 10.10.0.1 (nunca en IP pública)
#
# ARQUITECTURA:
#   Internet → [VPS 10.10.0.1] ← túnel WireGuard ← [Peer 10.10.0.2 franki]
#                                                  ← [Peer 10.10.0.3 worker01]
#                                                  ← ...
#
# USO:
#   sudo bash 05_wireguard_server.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 05: WireGuard VPN Server ==="

# Directorio para guardar configs de peers
WG_PEERS_DIR="/etc/wireguard/peers"
WG_CONF="/etc/wireguard/${WG_INTERFACE}.conf"

# -----------------------------------------------------------------------------
# PASO 1 — Instalar WireGuard
# -----------------------------------------------------------------------------
if ! command -v wg &>/dev/null; then
  log_info "Instalando WireGuard..."
  apt-get install -y -qq wireguard wireguard-tools
fi
log_ok "WireGuard disponible ($(wg --version))"

# -----------------------------------------------------------------------------
# PASO 2 — Crear directorio de peers con permisos estrictos
# -----------------------------------------------------------------------------
mkdir -p "${WG_PEERS_DIR}"
chmod 700 /etc/wireguard
chmod 700 "${WG_PEERS_DIR}"
log_ok "Directorio de peers: ${WG_PEERS_DIR}"

# -----------------------------------------------------------------------------
# PASO 3 — Generar claves del servidor (idempotente)
# -----------------------------------------------------------------------------
SERVER_PRIVKEY_FILE="/etc/wireguard/server_private.key"
SERVER_PUBKEY_FILE="/etc/wireguard/server_public.key"

if [[ ! -f "${SERVER_PRIVKEY_FILE}" ]]; then
  log_info "Generando claves del servidor..."
  wg genkey | tee "${SERVER_PRIVKEY_FILE}" | wg pubkey > "${SERVER_PUBKEY_FILE}"
  chmod 600 "${SERVER_PRIVKEY_FILE}"
  chmod 644 "${SERVER_PUBKEY_FILE}"
  log_ok "Claves del servidor generadas"
else
  log_ok "Claves del servidor ya existen, reutilizando"
fi

SERVER_PRIVKEY=$(cat "${SERVER_PRIVKEY_FILE}")
SERVER_PUBKEY=$(cat "${SERVER_PUBKEY_FILE}")

# Obtener IP pública del servidor
SERVER_PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org || \
                   curl -s --max-time 10 https://ifconfig.me || \
                   hostname -I | awk '{print $1}')
log_info "IP pública del servidor detectada: ${SERVER_PUBLIC_IP}"

# -----------------------------------------------------------------------------
# PASO 4 — Generar claves y configuraciones de peers
# -----------------------------------------------------------------------------
log_info "Generando claves y configuraciones para ${WG_PEERS} peers..."

PEERS_CONFIG_BLOCK=""

for i in $(seq 1 "${WG_PEERS}"); do
  PEER_NAME="${WG_PEER_NAMES[$((i-1))]}"
  # Peers: 10.10.0.2, 10.10.0.3, ... 10.10.0.11
  PEER_IP="10.10.0.$((i+1))"
  
  PEER_DIR="${WG_PEERS_DIR}/${PEER_NAME}"
  mkdir -p "${PEER_DIR}"
  chmod 700 "${PEER_DIR}"
  
  PEER_PRIVKEY_FILE="${PEER_DIR}/private.key"
  PEER_PUBKEY_FILE="${PEER_DIR}/public.key"
  PEER_PSK_FILE="${PEER_DIR}/preshared.key"
  
  # Generar claves del peer (idempotente)
  if [[ ! -f "${PEER_PRIVKEY_FILE}" ]]; then
    wg genkey | tee "${PEER_PRIVKEY_FILE}" | wg pubkey > "${PEER_PUBKEY_FILE}"
    wg genpsk > "${PEER_PSK_FILE}"
    chmod 600 "${PEER_PRIVKEY_FILE}" "${PEER_PSK_FILE}"
    chmod 644 "${PEER_PUBKEY_FILE}"
  fi
  
  PEER_PRIVKEY=$(cat "${PEER_PRIVKEY_FILE}")
  PEER_PUBKEY=$(cat "${PEER_PUBKEY_FILE}")
  PEER_PSK=$(cat "${PEER_PSK_FILE}")
  
  # Generar archivo de configuración del cliente
  cat > "${PEER_DIR}/${PEER_NAME}.conf" <<EOF
# =============================================================
# WireGuard Client Config — ${PEER_NAME}
# Generado el $(date)
# 
# INSTRUCCIONES:
#   1. Enviá este archivo al trabajador de forma SEGURA
#      (NO por WhatsApp/email sin cifrar)
#   2. El trabajador lo importa en su cliente WireGuard:
#      - Windows/macOS: Archivo → Importar túnel
#      - iOS/Android: Escanear QR (ver más abajo)
#      - Linux: wg-quick up ./$(basename "${PEER_DIR}/${PEER_NAME}.conf")
#   3. Una vez conectado, tendrá IP interna: ${PEER_IP}
# =============================================================

[Interface]
# IP del peer dentro del túnel VPN
Address = ${PEER_IP}/24

# DNS interno del VPS (Unbound)
DNS = ${WG_DNS}

# Clave privada del peer (NO compartir con nadie más)
PrivateKey = ${PEER_PRIVKEY}

# Puerto de escucha local (0 = automático)
ListenPort = 0

# Mantener conexión activa (útil detrás de NAT/routers hogareños)
# PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Servidor VPS
PublicKey = ${SERVER_PUBKEY}

# Pre-shared key (capa adicional de seguridad post-cuántica)
PresharedKey = ${PEER_PSK}

# IP pública del servidor y puerto WireGuard
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}

# Solo el tráfico hacia la red VPN pasa por el túnel
# (10.10.0.0/24 = red interna; NO redirige todo el internet del worker)
AllowedIPs = 10.10.0.0/24

# Keepalive: envía un paquete cada 25s para mantener NAT abierto
PersistentKeepalive = 25
EOF

  chmod 600 "${PEER_DIR}/${PEER_NAME}.conf"
  
  # Generar QR code si qrencode está disponible
  if command -v qrencode &>/dev/null; then
    qrencode -t png -o "${PEER_DIR}/${PEER_NAME}_qr.png" \
      < "${PEER_DIR}/${PEER_NAME}.conf"
    log_ok "QR generado para ${PEER_NAME}: ${PEER_DIR}/${PEER_NAME}_qr.png"
  fi
  
  # Acumular bloque [Peer] para la config del servidor
  PEERS_CONFIG_BLOCK+="
# --- Peer: ${PEER_NAME} ---
[Peer]
PublicKey = ${PEER_PUBKEY}
PresharedKey = ${PEER_PSK}
AllowedIPs = ${PEER_IP}/32
# Nombre: ${PEER_NAME}
"
  
  log_ok "  Peer ${i}/${WG_PEERS}: ${PEER_NAME} → ${PEER_IP}"
done

# -----------------------------------------------------------------------------
# PASO 5 — Generar configuración del servidor WireGuard
# -----------------------------------------------------------------------------
log_info "Generando configuración del servidor..."

# Obtener interfaz pública para PostUp/PostDown
PUBLIC_IF=$(ip route | grep default | awk '{print $5}' | head -1)

cat > "${WG_CONF}" <<EOF
# =============================================================
# WireGuard Server Config — ${WG_INTERFACE}
# Generado por 05_wireguard_server.sh el $(date)
# =============================================================

[Interface]
# IP del servidor en la red VPN
Address = ${WG_SERVER_IP}

# Puerto UDP de escucha
ListenPort = ${WG_PORT}

# Clave privada del servidor
PrivateKey = ${SERVER_PRIVKEY}

# Habilitar NAT para que los peers puedan acceder a internet a través del VPS
PostUp   = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
           iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT; \
           iptables -t nat -A POSTROUTING -o ${PUBLIC_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; \
           iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT; \
           iptables -t nat -D POSTROUTING -o ${PUBLIC_IF} -j MASQUERADE

# Guardar config al parar (preserva peers agregados dinámicamente)
SaveConfig = false

${PEERS_CONFIG_BLOCK}
EOF

chmod 600 "${WG_CONF}"
log_ok "Configuración del servidor escrita en ${WG_CONF}"

# -----------------------------------------------------------------------------
# PASO 6 — Instalar qrencode para QR codes de móviles
# -----------------------------------------------------------------------------
if ! command -v qrencode &>/dev/null; then
  log_info "Instalando qrencode para generar QR de peers móviles..."
  apt-get install -y -qq qrencode
  
  # Regenerar QRs ahora que qrencode está disponible
  for i in $(seq 1 "${WG_PEERS}"); do
    PEER_NAME="${WG_PEER_NAMES[$((i-1))]}"
    PEER_DIR="${WG_PEERS_DIR}/${PEER_NAME}"
    qrencode -t png -o "${PEER_DIR}/${PEER_NAME}_qr.png" \
      < "${PEER_DIR}/${PEER_NAME}.conf"
  done
  log_ok "QR codes generados para todos los peers"
fi

# -----------------------------------------------------------------------------
# PASO 7 — Habilitar y arrancar WireGuard
# -----------------------------------------------------------------------------
log_info "Habilitando WireGuard..."
systemctl enable "wg-quick@${WG_INTERFACE}"
wg-quick up "${WG_INTERFACE}" 2>/dev/null || true

sleep 2

if ip link show "${WG_INTERFACE}" &>/dev/null; then
  log_ok "Interfaz ${WG_INTERFACE} activa"
  wg show "${WG_INTERFACE}"
else
  log_error "La interfaz ${WG_INTERFACE} no levantó. Verificá los logs:"
  journalctl -u "wg-quick@${WG_INTERFACE}" --no-pager -n 20
  exit 1
fi

# -----------------------------------------------------------------------------
# PASO 8 — Resumen de peers generados
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  WireGuard configurado — Resumen de peers                   ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
for i in $(seq 1 "${WG_PEERS}"); do
  PEER_NAME="${WG_PEER_NAMES[$((i-1))]}"
  PEER_IP="10.10.0.$((i+1))"
  printf "${GREEN}║${NC}  %-12s → %-15s  Config: peers/%s/     ${GREEN}║${NC}\n" \
    "${PEER_NAME}" "${PEER_IP}" "${PEER_NAME}"
done
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

echo ""
log_warn "DISTRIBUCIÓN DE CONFIGS: Enviá cada .conf a su trabajador por canal seguro"
log_warn "  Los archivos están en: ${WG_PEERS_DIR}/<nombre>/<nombre>.conf"
log_warn "  Para móviles: ${WG_PEERS_DIR}/<nombre>/<nombre>_qr.png"
echo ""
log_ok "=== WireGuard VPN configurado exitosamente ==="
log_info "Próximo paso: sudo bash 06_unbound_dns.sh"
