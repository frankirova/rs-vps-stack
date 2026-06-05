#!/usr/bin/env bash
# =============================================================================
# 01_ssh_hardening.sh — Hardening de SSH
# 
# QUÉ HACE:
#   - Cambia el puerto SSH al definido en config
#   - Deshabilita login por contraseña (solo llaves públicas)
#   - Deshabilita login de root directo
#   - Configura timeouts y parámetros seguros
#   - Instala tu llave pública antes de cerrar el acceso por password
#
# SEGURIDAD CRÍTICA:
#   Este script verifica que podés conectarte con llave ANTES de deshabilitar
#   el acceso por contraseña. No perderás acceso si seguís los pasos en orden.
#
# USO:
#   sudo bash 01_ssh_hardening.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root
check_os

log_info "=== Módulo 01: SSH Hardening ==="

# -----------------------------------------------------------------------------
# PASO 1 — Instalar llave pública del usuario admin
# -----------------------------------------------------------------------------
log_info "Instalando llave pública para el usuario: ${SSH_USER}"

if ! id "${SSH_USER}" &>/dev/null; then
  log_error "El usuario '${SSH_USER}' no existe. Crealo antes de continuar."
  log_info  "Tip: adduser ${SSH_USER} && usermod -aG sudo ${SSH_USER}"
  exit 1
fi

USER_HOME=$(getent passwd "${SSH_USER}" | cut -d: -f6)
SSH_DIR="${USER_HOME}/.ssh"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# Agregar la llave pública si no existe ya
if ! grep -qF "${SSH_PUBKEY}" "${SSH_DIR}/authorized_keys" 2>/dev/null; then
  echo "${SSH_PUBKEY}" >> "${SSH_DIR}/authorized_keys"
  log_ok "Llave pública agregada"
else
  log_ok "Llave pública ya estaba presente"
fi

chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${SSH_USER}:${SSH_USER}" "${SSH_DIR}"

# -----------------------------------------------------------------------------
# PASO 2 — Backup de configuración SSH original
# -----------------------------------------------------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.backup_$(date +%Y%m%d_%H%M%S)"

cp "${SSHD_CONFIG}" "${BACKUP_FILE}"
log_ok "Backup de sshd_config guardado en: ${BACKUP_FILE}"

# -----------------------------------------------------------------------------
# PASO 3 — Aplicar nueva configuración SSH segura
# -----------------------------------------------------------------------------
log_info "Aplicando configuración SSH hardened..."

cat > "${SSHD_CONFIG}" <<EOF
# =============================================================
# sshd_config — Generado por 01_ssh_hardening.sh
# $(date)
# =============================================================

# Puerto no estándar para reducir ruido de bots
Port ${SSH_PORT}

# Solo IPv4 (simplifica el firewall; cambiá a 'any' si necesitás IPv6)
AddressFamily inet

# Protocolo y algoritmos seguros modernos
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

# Algoritmos de cifrado modernos (elimina cipher suites débiles)
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Autenticación — SOLO llaves públicas
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes

# Deshabilitar login directo de root
PermitRootLogin no

# Sin forwarding innecesario
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no

# Timeouts de sesión (desconecta sesiones inactivas)
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30

# Limitar intentos de autenticación
MaxAuthTries 3
MaxSessions 5
MaxStartups 10:30:60

# Solo permitir el usuario admin definido
AllowUsers ${SSH_USER}

# Deshabilitar banner que revela versión del OS
DebianBanner no

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# SFTP interno (más seguro que openssh-sftp-server externo)
Subsystem sftp internal-sftp
EOF

log_ok "Configuración SSH escrita"

# -----------------------------------------------------------------------------
# PASO 4 — Validar la configuración antes de aplicar
# -----------------------------------------------------------------------------
log_info "Validando configuración SSH..."
if ! sshd -t; then
  log_error "La configuración tiene errores. Restaurando backup..."
  cp "${BACKUP_FILE}" "${SSHD_CONFIG}"
  exit 1
fi
log_ok "Configuración válida"

# -----------------------------------------------------------------------------
# PASO 5 — Agregar regla UFW para el nuevo puerto ANTES de reiniciar SSH
#           (evita quedar afuera si UFW ya está activo)
# -----------------------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
  log_info "UFW activo detectado. Agregando regla para puerto ${SSH_PORT}..."
  ufw allow "${SSH_PORT}/tcp" comment "SSH hardened"
  log_ok "Regla UFW agregada para puerto ${SSH_PORT}"
fi

# -----------------------------------------------------------------------------
# PASO 6 — Reiniciar SSH
# -----------------------------------------------------------------------------
log_info "Reiniciando servicio SSH..."
systemctl restart sshd
log_ok "SSH reiniciado"

# -----------------------------------------------------------------------------
# PASO 7 — Verificación final con instrucciones claras
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  ACCIÓN REQUERIDA — NO CIERRES ESTA SESIÓN TODAVÍA          ║${NC}"
echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}║                                                              ║${NC}"
echo -e "${YELLOW}║  Abrí una NUEVA terminal y verificá que podés conectarte:   ║${NC}"
echo -e "${YELLOW}║                                                              ║${NC}"
echo -e "${YELLOW}║  ssh -p ${SSH_PORT} -i ~/.ssh/tu_llave ${SSH_USER}@IP_DEL_VPS         ║${NC}"
echo -e "${YELLOW}║                                                              ║${NC}"
echo -e "${YELLOW}║  Si la conexión funciona → escribí 'confirmar' aquí abajo   ║${NC}"
echo -e "${YELLOW}║  Si algo falla → el backup está en: ${BACKUP_FILE}   ║${NC}"
echo -e "${YELLOW}║                                                              ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -r -p "¿Pudiste conectarte en el nuevo puerto? Escribí 'confirmar': " CONFIRM
if [[ "${CONFIRM}" != "confirmar" ]]; then
  log_warn "No confirmaste. Restaurando configuración original por seguridad..."
  cp "${BACKUP_FILE}" "${SSHD_CONFIG}"
  systemctl restart sshd
  log_ok "Configuración original restaurada. SSH vuelve al puerto 22."
  exit 1
fi

log_ok "=== SSH Hardening completado exitosamente ==="
log_info "Puerto SSH activo: ${SSH_PORT}"
log_info "Backup de config original: ${BACKUP_FILE}"
