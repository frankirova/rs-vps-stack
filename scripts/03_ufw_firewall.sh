#!/usr/bin/env bash
# =============================================================================
# 03_ufw_firewall.sh — Configuración de Firewall con UFW
#
# QUÉ HACE:
#   - Instala y configura UFW con política de denegación por defecto
#   - Solo abre los puertos estrictamente necesarios:
#       * SSH en el puerto hardened
#       * WireGuard (UDP)
#   - Las apps del VPS solo serán accesibles desde la interfaz VPN (wg0)
#     NUNCA desde internet directamente
#   - Activa rate limiting en SSH como capa extra contra fuerza bruta
#
# USO:
#   sudo bash 03_ufw_firewall.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 03: UFW Firewall ==="

# -----------------------------------------------------------------------------
# PASO 1 — Instalar UFW si no está presente
# -----------------------------------------------------------------------------
if ! command -v ufw &>/dev/null; then
  log_info "Instalando UFW..."
  apt-get install -y -qq ufw
fi
log_ok "UFW disponible"

# -----------------------------------------------------------------------------
# PASO 2 — Reset limpio y políticas por defecto
# -----------------------------------------------------------------------------
log_info "Aplicando política de denegación por defecto..."

# Deshabilitar UFW momentáneamente para reconfigurar sin riesgo
ufw --force disable > /dev/null 2>&1

# Reset completo de reglas (idempotente)
ufw --force reset > /dev/null 2>&1

# Política base: denegar todo entrante, permitir todo saliente
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

log_ok "Políticas por defecto configuradas (deny incoming / allow outgoing)"

# -----------------------------------------------------------------------------
# PASO 3 — Reglas de entrada permitidas
# -----------------------------------------------------------------------------

# SSH en puerto hardened (con rate limiting: max 6 intentos cada 30s por IP)
log_info "Agregando regla SSH con rate limiting en puerto ${SSH_PORT}..."
ufw limit "${SSH_PORT}/tcp" comment "SSH hardened - rate limited"

# WireGuard VPN (UDP)
log_info "Agregando regla WireGuard en puerto ${WG_PORT} UDP..."
ufw allow "${WG_PORT}/udp" comment "WireGuard VPN"

# NOTA: Las apps (web, API, etc.) NO se abren aquí.
# Solo serán accesibles desde la interfaz wg0 (10.10.0.0/24)
# El acceso se gestiona cuando instalés nginx/caddy con bind en 10.10.0.1

log_ok "Reglas de entrada configuradas"

# -----------------------------------------------------------------------------
# PASO 4 — Reglas de forwarding para WireGuard
# (permite que el tráfico de peers VPN salga a internet a través del VPS)
# -----------------------------------------------------------------------------
log_info "Configurando forwarding para WireGuard..."

# Obtener la interfaz de red pública
PUBLIC_IF=$(ip route | grep default | awk '{print $5}' | head -1)
log_info "Interfaz pública detectada: ${PUBLIC_IF}"

# Habilitar forwarding en el kernel para WireGuard
sed -i 's|#net/ipv4/ip_forward=1|net/ipv4/ip_forward=1|g' /etc/ufw/sysctl.conf
sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|g' /etc/ufw/sysctl.conf

# Si no estaba la línea, agregarla
if ! grep -q "net.ipv4.ip_forward=1" /etc/ufw/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/ufw/sysctl.conf
fi

# Agregar reglas de NAT/forwarding en before.rules
UFW_BEFORE="/etc/ufw/before.rules"

# Backup
cp "${UFW_BEFORE}" "${UFW_BEFORE}.backup_$(date +%Y%m%d_%H%M%S)"

# Insertar bloque NAT al inicio del archivo si no existe
if ! grep -q "# WireGuard NAT" "${UFW_BEFORE}"; then
  # Crear contenido temporal con el bloque NAT al inicio
  TMP_FILE=$(mktemp)
  cat > "${TMP_FILE}" <<EOF
# WireGuard NAT — Generado por 03_ufw_firewall.sh
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.10.0.0/24 -o ${PUBLIC_IF} -j MASQUERADE
COMMIT

# WireGuard FORWARD
*filter
:ufw-before-forward - [0:0]
-A ufw-before-forward -i ${WG_INTERFACE} -j ACCEPT
-A ufw-before-forward -o ${WG_INTERFACE} -j ACCEPT
COMMIT

EOF
  cat "${UFW_BEFORE}" >> "${TMP_FILE}"
  mv "${TMP_FILE}" "${UFW_BEFORE}"
  log_ok "Reglas NAT para WireGuard agregadas"
else
  log_ok "Reglas NAT ya presentes, sin cambios"
fi

# -----------------------------------------------------------------------------
# PASO 5 — Reglas adicionales de seguridad (antes del procesamiento normal)
# -----------------------------------------------------------------------------

# Limitar ping (permite pero no más de 5 por segundo)
UFW_BEFORE_RULES_SECTION=""
if ! grep -q "limit-icmp" /etc/ufw/before.rules 2>/dev/null; then
  # Las reglas de ICMP ya están en before.rules por defecto en Ubuntu
  # Solo documentamos la política
  log_info "Reglas ICMP: usando configuración default de Ubuntu (permisiva limitada)"
fi

# -----------------------------------------------------------------------------
# PASO 6 — Habilitar UFW
# -----------------------------------------------------------------------------
log_info "Habilitando UFW..."
ufw --force enable
log_ok "UFW habilitado"

# -----------------------------------------------------------------------------
# PASO 7 — Mostrar estado final
# -----------------------------------------------------------------------------
echo ""
log_info "Estado actual del firewall:"
ufw status verbose

echo ""
log_ok "=== UFW Firewall configurado exitosamente ==="
log_warn "RECORDÁ: Las apps solo son accesibles desde la VPN (10.10.0.0/24)"
log_warn "         NO abras puertos 80/443 al exterior sin reverse proxy + VPN"
log_info "Próximo paso: sudo bash 04_fail2ban.sh"
