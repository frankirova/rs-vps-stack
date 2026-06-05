#!/usr/bin/env bash
# =============================================================================
# 02_system_base.sh — Actualizaciones base y configuración del sistema
#
# QUÉ HACE:
#   - Actualiza todos los paquetes del sistema
#   - Configura unattended-upgrades para parches de seguridad CRÍTICOS
#     (se aplican solos, silenciosamente, en horario de baja carga)
#   - Las actualizaciones de paquetes regulares las maneja el bot de Telegram
#   - Configura timezone, hostname y parámetros de kernel seguros (sysctl)
#   - Instala herramientas base necesarias para los demás módulos
#
# USO:
#   sudo bash 02_system_base.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 02: Sistema Base y Actualizaciones ==="

# -----------------------------------------------------------------------------
# PASO 1 — Timezone y hostname
# -----------------------------------------------------------------------------
log_info "Configurando timezone: ${TIMEZONE}"
timedatectl set-timezone "${TIMEZONE}"
log_ok "Timezone configurada"

log_info "Configurando hostname: ${HOSTNAME_NEW}"
hostnamectl set-hostname "${HOSTNAME_NEW}"
# Agregar al /etc/hosts si no está
if ! grep -q "${HOSTNAME_NEW}" /etc/hosts; then
  echo "127.0.1.1  ${HOSTNAME_NEW}" >> /etc/hosts
fi
log_ok "Hostname configurado"

# -----------------------------------------------------------------------------
# PASO 2 — Actualización completa del sistema
# -----------------------------------------------------------------------------
log_info "Actualizando lista de paquetes..."
apt-get update -qq

log_info "Aplicando actualizaciones del sistema (puede tardar varios minutos)..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
log_ok "Sistema actualizado"

# -----------------------------------------------------------------------------
# PASO 3 — Instalar herramientas base necesarias para todos los módulos
# -----------------------------------------------------------------------------
log_info "Instalando paquetes base..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl \
  wget \
  git \
  unzip \
  jq \
  htop \
  net-tools \
  dnsutils \
  lsof \
  tmux \
  logrotate \
  gnupg \
  ca-certificates \
  apt-transport-https \
  software-properties-common \
  cron \
  bc

log_ok "Paquetes base instalados"

# -----------------------------------------------------------------------------
# PASO 4 — Unattended Upgrades (solo parches de seguridad automáticos)
# -----------------------------------------------------------------------------
log_info "Configurando unattended-upgrades para parches de seguridad..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
// Solo aplica actualizaciones de seguridad automáticamente.
// Las actualizaciones de paquetes regulares las gestiona el bot de Telegram.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Paquetes que NUNCA se actualizan automáticamente (requieren revisión manual)
Unattended-Upgrade::Package-Blacklist {
    "nginx";
    "postgresql*";
    "mysql*";
    "docker*";
};

// Eliminar dependencias huérfanas después de actualizar
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Email en caso de error (si configurás un MTA)
// Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "on-change";

// Reinicio automático DESHABILITADO — el bot de Telegram pregunta primero
Unattended-Upgrade::Automatic-Reboot "false";

// Logging detallado
Unattended-Upgrade::Verbose "true";

// Archivo de log
Unattended-Upgrade::Debug "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable unattended-upgrades
systemctl start unattended-upgrades
log_ok "Unattended-upgrades configurado (solo parches de seguridad)"

# -----------------------------------------------------------------------------
# PASO 5 — Parámetros de kernel seguros (sysctl)
# -----------------------------------------------------------------------------
log_info "Aplicando parámetros de seguridad del kernel..."

cat > /etc/sysctl.d/99-vps-hardening.conf <<'EOF'
# =============================================================
# Parámetros de seguridad del kernel — VPS Hardening Stack
# =============================================================

# --- Protección de red ---

# Deshabilitar IP forwarding (se re-habilita específicamente para WireGuard)
net.ipv4.ip_forward = 0

# Protección contra IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignorar pings broadcast (protección DDoS básica)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# No responder a ICMP redireccionados
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# No aceptar source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Protección SYN flood (SYN cookies)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Ignorar mensajes ICMP bogus
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Logging de paquetes con source route sospechoso
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# --- Protección de memoria y procesos ---

# Deshabilitar core dumps (evita volcado de memoria con datos sensibles)
fs.suid_dumpable = 0

# Restringir acceso a dmesg (solo root)
kernel.dmesg_restrict = 1

# Restringir ptrace (debugging entre procesos)
kernel.yama.ptrace_scope = 1

# Deshabilitar magic SysRq (evita ataques físicos/consola)
kernel.sysrq = 0

# Randomizar layout de memoria (ASLR)
kernel.randomize_va_space = 2

# --- Protección IPv6 (deshabilitada si no la usás) ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl -p /etc/sysctl.d/99-vps-hardening.conf > /dev/null 2>&1
log_ok "Parámetros de kernel aplicados"

# -----------------------------------------------------------------------------
# PASO 6 — Limitar acceso a compiladores (reducir superficie de ataque)
# -----------------------------------------------------------------------------
log_info "Restringiendo acceso a compiladores..."
if command -v gcc &>/dev/null; then
  chmod o-rx "$(which gcc)" 2>/dev/null || true
fi
if command -v cc &>/dev/null; then
  chmod o-rx "$(which cc)" 2>/dev/null || true
fi
log_ok "Compiladores restringidos a root y grupo staff"

# -----------------------------------------------------------------------------
# PASO 7 — Configurar logrotate para logs del sistema
# -----------------------------------------------------------------------------
log_info "Configurando rotación de logs..."
cat > /etc/logrotate.d/vps-hardening <<'EOF'
/var/log/vps-bot.log
/var/log/vps-backup.log
/var/log/vps-updates.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
log_ok "Logrotate configurado"

log_ok "=== Sistema Base configurado exitosamente ==="
log_info "Próximo paso: sudo bash 03_ufw_firewall.sh"
