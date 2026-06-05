#!/usr/bin/env bash
# =============================================================================
# 06_unbound_dns.sh — DNS recursivo interno con Unbound
#
# QUÉ HACE:
#   - Instala y configura Unbound como resolver DNS recursivo
#   - Solo escucha en la interfaz VPN (10.10.0.1), no en internet
#   - Los peers WireGuard lo usan automáticamente
#   - Resolución directa a root servers (sin depender de Google/Cloudflare)
#   - DNSSEC habilitado
#   - Cache local para respuestas más rápidas
#
# FIXES APLICADOS vs versión original:
#   - Removida directiva "do-recursion" (no válida en Unbound 1.13)
#   - Remote-control deshabilitado (evita error SSL en entornos sin certs)
#   - Permisos correctos en /var/log/unbound.log y /etc/unbound/root.key
#   - so-rcvbuf ajustado a valor alcanzable sin root extra
#   - Reglas UFW agregadas para puerto 53 en loopback y wg0
#
# USO:
#   sudo bash 06_unbound_dns.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 06: Unbound DNS ==="

# -----------------------------------------------------------------------------
# PASO 1 — Instalar Unbound
# -----------------------------------------------------------------------------
if ! command -v unbound &>/dev/null; then
  log_info "Instalando Unbound..."
  apt-get install -y -qq unbound unbound-anchor dns-root-data
fi
log_ok "Unbound disponible"

# -----------------------------------------------------------------------------
# PASO 2 — Deshabilitar stub de systemd-resolved (conflicto en puerto 53)
# -----------------------------------------------------------------------------
log_info "Deshabilitando stub DNS de systemd-resolved..."

mkdir -p /etc/systemd/resolved.conf.d/
cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=1.1.1.1
EOF

systemctl restart systemd-resolved
log_ok "systemd-resolved stub deshabilitado"

if [[ -L /etc/resolv.conf ]]; then
  rm /etc/resolv.conf
fi
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chmod 444 /etc/resolv.conf
log_ok "/etc/resolv.conf apunta a 127.0.0.1"

# -----------------------------------------------------------------------------
# PASO 3 — Actualizar root hints
# -----------------------------------------------------------------------------
log_info "Actualizando root hints..."
curl -s --max-time 30 \
  "https://www.internic.net/domain/named.cache" \
  -o /etc/unbound/root.hints 2>/dev/null || \
  cp /usr/share/dns/root.hints /etc/unbound/root.hints 2>/dev/null || \
  log_warn "Usando root hints del paquete"
log_ok "Root hints listos"

# -----------------------------------------------------------------------------
# PASO 4 — Permisos correctos (fix crítico)
# -----------------------------------------------------------------------------
log_info "Configurando permisos..."
touch /var/log/unbound.log
chown unbound:unbound /var/log/unbound.log
chown -R unbound:unbound /etc/unbound/
chmod 755 /etc/unbound/
log_ok "Permisos configurados"

# -----------------------------------------------------------------------------
# PASO 5 — Inicializar ancla DNSSEC
# -----------------------------------------------------------------------------
log_info "Inicializando DNSSEC..."
unbound-anchor -a /etc/unbound/root.key 2>/dev/null || true
chmod 644 /etc/unbound/root.key
chown unbound:unbound /etc/unbound/root.key
log_ok "Ancla DNSSEC lista"

# -----------------------------------------------------------------------------
# PASO 6 — Aumentar buffer de red
# -----------------------------------------------------------------------------
sysctl -w net.core.rmem_max=1048576 > /dev/null 2>&1 || true

# Persistir en sysctl
if ! grep -q "net.core.rmem_max" /etc/sysctl.d/99-vps-hardening.conf 2>/dev/null; then
  echo "net.core.rmem_max=1048576" >> /etc/sysctl.d/99-vps-hardening.conf
fi

# -----------------------------------------------------------------------------
# PASO 7 — Configuración principal de Unbound
# -----------------------------------------------------------------------------
log_info "Escribiendo configuración de Unbound..."

cat > /etc/unbound/unbound.conf <<EOF
# =============================================================
# unbound.conf — Generado por 06_unbound_dns.sh
# $(date)
# =============================================================

server:
    # ---- Interfaz de escucha ----
    interface: 127.0.0.1
    interface: 10.10.0.1
    port: 53

    # Solo acepta consultas desde loopback y red VPN
    access-control: 0.0.0.0/0 refuse
    access-control: 127.0.0.0/8 allow
    access-control: 10.10.0.0/24 allow

    # ---- Protocolo ----
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    # ---- DNSSEC ----
    auto-trust-anchor-file: "/etc/unbound/root.key"
    val-log-level: 1

    # ---- Cache ----
    cache-min-ttl: 300
    cache-max-ttl: 86400
    cache-max-negative-ttl: 30
    msg-cache-size: 50m
    rrset-cache-size: 100m
    num-threads: 2
    so-rcvbuf: 425984

    # ---- Privacidad ----
    qname-minimisation: yes

    # Protección rebinding — no responde con IPs privadas
    private-address: 192.168.0.0/16
    private-address: 172.16.0.0/12
    private-address: 10.0.0.0/8
    private-address: 169.254.0.0/16

    prefetch: yes
    prefetch-key: yes
    edns-buffer-size: 1232

    # ---- Root hints ----
    root-hints: "/etc/unbound/root.hints"

    # ---- Logging ----
    verbosity: 1
    log-queries: no
    log-replies: no
    logfile: "/var/log/unbound.log"
    log-time-ascii: yes

    # ---- Hardening ----
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-algo-downgrade: yes
    harden-large-queries: yes
    hide-identity: yes
    hide-version: yes
    use-caps-for-id: yes
    do-not-query-localhost: no

    # ---- Zona local VPN ----
    local-zone: "vpn.internal." static
    local-data: "vps.vpn.internal. IN A 10.10.0.1"
    local-zone: "0.10.10.in-addr.arpa." static
    local-data-ptr: "10.10.0.1 vps.vpn.internal"

# ---- Remote control DESHABILITADO (evita error SSL) ----
remote-control:
    control-enable: no
EOF

log_ok "Configuración de Unbound escrita"

# -----------------------------------------------------------------------------
# PASO 8 — Validar configuración
# -----------------------------------------------------------------------------
log_info "Validando configuración..."
if ! unbound-checkconf /etc/unbound/unbound.conf; then
  log_error "Error en la configuración de Unbound"
  exit 1
fi
log_ok "Configuración válida"

# -----------------------------------------------------------------------------
# PASO 9 — Reglas UFW para DNS
# -----------------------------------------------------------------------------
log_info "Agregando reglas UFW para DNS..."
ufw allow in on lo to any port 53 comment "DNS Unbound loopback" 2>/dev/null || true
ufw allow in on "${WG_INTERFACE}" to any port 53 comment "DNS Unbound VPN" 2>/dev/null || true
log_ok "Reglas UFW DNS agregadas"

# -----------------------------------------------------------------------------
# PASO 10 — Configurar logrotate
# -----------------------------------------------------------------------------
cat > /etc/logrotate.d/unbound <<'EOF'
/var/log/unbound.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl kill -s HUP unbound 2>/dev/null || true
    endscript
}
EOF

# -----------------------------------------------------------------------------
# PASO 11 — Habilitar y arrancar Unbound
# -----------------------------------------------------------------------------
log_info "Habilitando Unbound..."
systemctl enable unbound
systemctl restart unbound

sleep 3

if systemctl is-active --quiet unbound; then
  log_ok "Unbound activo y corriendo"
else
  log_error "Unbound no levantó. Logs:"
  journalctl -u unbound --no-pager -n 20
  exit 1
fi

# -----------------------------------------------------------------------------
# PASO 12 — Test de resolución
# -----------------------------------------------------------------------------
log_info "Probando resolución DNS..."
sleep 2
RESULT=$(dig @127.0.0.1 google.com +short +time=5 2>/dev/null | head -1)
if echo "${RESULT}" | grep -qE "^[0-9]+\.[0-9]+"; then
  log_ok "Resolución DNS funcionando: ${RESULT}"
else
  log_warn "DNS aún no responde. Probá manualmente: dig @127.0.0.1 google.com"
fi

echo ""
log_ok "=== Unbound DNS configurado exitosamente ==="
log_info "Escucha en: 127.0.0.1:53 y 10.10.0.1:53"
log_info "Acepta consultas desde: loopback + red VPN (10.10.0.0/24)"
log_info "Próximo paso: sudo bash 07_backup_restic.sh"
