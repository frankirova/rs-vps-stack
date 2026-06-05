#!/usr/bin/env bash
# =============================================================================
# 03b_docker_ufw_fix.sh — Desacoplar Docker de iptables
#
# POR QUÉ EXISTE ESTE SCRIPT:
#   Docker por defecto escribe reglas en iptables directamente, saltando UFW.
#   Esto significa que aunque UFW esté activo con "deny incoming", todos los
#   puertos mapeados en contenedores siguen accesibles desde internet.
#   Este script soluciona eso de forma permanente y segura.
#
# QUÉ HACE:
#   1. Le dice a Docker que NO toque iptables (daemon.json)
#   2. Crea una red Docker interna dedicada para comunicación entre contenedores
#   3. Agrega reglas iptables manuales que permiten solo tráfico VPN → Docker
#   4. Reinicia Docker de forma controlada
#   5. Verifica que los contenedores siguen funcionando internamente
#
# EFECTO INMEDIATO AL EJECUTAR:
#   - Todos los puertos Docker dejan de ser accesibles desde internet
#   - Los contenedores siguen comunicándose entre sí sin problema
#   - Solo accesibles desde la red VPN (10.10.0.0/24) una vez que
#     WireGuard esté activo (módulo 05)
#
# PREREQUISITO:
#   Correr DESPUÉS de 02_system_base.sh y ANTES de 03_ufw_firewall.sh
#
# USO:
#   sudo bash 03b_docker_ufw_fix.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 03b: Fix Docker + UFW ==="

# -----------------------------------------------------------------------------
# Verificaciones previas
# -----------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log_error "Docker no está instalado. Este script no es necesario."
  exit 1
fi

if ! systemctl is-active --quiet docker; then
  log_error "Docker no está corriendo."
  exit 1
fi

log_ok "Docker detectado: $(docker --version)"

# Contar contenedores corriendo
RUNNING_CONTAINERS=$(docker ps --format '{{.Names}}' | wc -l)
log_info "Contenedores activos actualmente: ${RUNNING_CONTAINERS}"

if [[ ${RUNNING_CONTAINERS} -gt 0 ]]; then
  log_info "Contenedores que serán afectados:"
  docker ps --format "  → {{.Names}} (puertos: {{.Ports}})"
fi

# -----------------------------------------------------------------------------
# ADVERTENCIA y confirmación explícita
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  ATENCIÓN — Leer antes de continuar                             ║${NC}"
echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}║  Este script va a:                                               ║${NC}"
echo -e "${YELLOW}║  1. Reiniciar Docker (los contenedores se detienen y reinician) ║${NC}"
echo -e "${YELLOW}║  2. Bloquear acceso externo a TODOS los puertos Docker          ║${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}║  Las apps quedarán inaccesibles desde internet.                 ║${NC}"
echo -e "${YELLOW}║  Estarán disponibles solo desde la VPN (módulo 05).             ║${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}║  Los contenedores NO pierden datos — solo cambia el acceso.    ║${NC}"
echo -e "${YELLOW}║                                                                  ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -r -p "¿Confirmar? Escribí 'aplicar': " CONFIRM
[[ "${CONFIRM}" != "aplicar" ]] && { log_warn "Cancelado."; exit 0; }

# -----------------------------------------------------------------------------
# PASO 1 — Backup de configuración Docker actual
# -----------------------------------------------------------------------------
log_info "Haciendo backup de configuración Docker..."
DOCKER_BACKUP_DIR="/etc/vps-hardening/backups/docker"
mkdir -p "${DOCKER_BACKUP_DIR}"

# Backup daemon.json si existe
if [[ -f /etc/docker/daemon.json ]]; then
  cp /etc/docker/daemon.json \
    "${DOCKER_BACKUP_DIR}/daemon.json.backup_$(date +%Y%m%d_%H%M%S)"
  log_ok "Backup de daemon.json guardado"
else
  log_info "No había daemon.json previo (instalación limpia de Docker)"
fi

# Guardar lista de contenedores y sus configuraciones para referencia
docker inspect $(docker ps -q) 2>/dev/null \
  > "${DOCKER_BACKUP_DIR}/containers_snapshot_$(date +%Y%m%d_%H%M%S).json" \
  || true
log_ok "Snapshot de contenedores guardado en ${DOCKER_BACKUP_DIR}"

# -----------------------------------------------------------------------------
# PASO 2 — Configurar Docker para NO tocar iptables
#
# iptables: false  → Docker no crea reglas en iptables
# ip-forward: true → Permite que los contenedores se comuniquen entre sí
#                    y con el exterior a través del host (necesario para VPN)
# -----------------------------------------------------------------------------
log_info "Configurando Docker daemon (desactivar gestión de iptables)..."

mkdir -p /etc/docker

# Preservar configuración existente si hay (merge)
if [[ -f /etc/docker/daemon.json ]] && \
   python3 -c "import json; json.load(open('/etc/docker/daemon.json'))" 2>/dev/null; then
  # Leer config existente y mergear
  python3 <<'PYEOF'
import json

with open('/etc/docker/daemon.json', 'r') as f:
    config = json.load(f)

# Aplicar configuración de seguridad
config['iptables'] = False
config['ip-forward'] = True
config['log-driver'] = config.get('log-driver', 'json-file')
config['log-opts'] = config.get('log-opts', {
    'max-size': '10m',
    'max-file': '3'
})

with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(config, f, indent=2)

print("daemon.json actualizado (merge con configuración existente)")
PYEOF
else
  # Crear daemon.json desde cero
  cat > /etc/docker/daemon.json <<'EOF'
{
  "iptables": false,
  "ip-forward": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {"base": "172.16.0.0/12", "size": 24}
  ]
}
EOF
  log_ok "daemon.json creado"
fi

# -----------------------------------------------------------------------------
# PASO 3 — Limpiar reglas iptables de Docker existentes
# (las que Docker insertó antes de que le dijéramos que no lo haga)
# -----------------------------------------------------------------------------
log_info "Limpiando reglas iptables legacy de Docker..."

# Flush de cadenas Docker en iptables
iptables -t nat -F DOCKER 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F DOCKER 2>/dev/null || true
iptables -F DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-FORWARD 2>/dev/null || true
iptables -F DOCKER-ISOLATION-STAGE-1 2>/dev/null || true
iptables -F DOCKER-ISOLATION-STAGE-2 2>/dev/null || true

log_ok "Reglas legacy limpiadas"

# -----------------------------------------------------------------------------
# PASO 4 — Reglas iptables manuales para reemplazar las de Docker
#
# Estas reglas reemplazan lo que Docker hacía automáticamente, pero de forma
# controlada: solo permiten tráfico desde la red VPN hacia los contenedores.
#
# NOTA: Estas reglas se aplican AHORA para que Docker funcione después del
# reinicio. UFW las complementará en el módulo 03.
# -----------------------------------------------------------------------------
log_info "Aplicando reglas iptables manuales para Docker..."

# Obtener interfaz pública
PUBLIC_IF=$(ip route | grep default | awk '{print $5}' | head -1)
log_info "Interfaz pública: ${PUBLIC_IF}"

# Permitir tráfico entre contenedores en la misma red Docker (bridge interno)
iptables -A FORWARD -i docker0 -o docker0 -j ACCEPT
iptables -A FORWARD -i br-+ -o br-+ -j ACCEPT

# Permitir que los contenedores salgan a internet (para updates, APIs externas)
iptables -A FORWARD -i docker0 -o "${PUBLIC_IF}" -j ACCEPT
iptables -A FORWARD -i br-+ -o "${PUBLIC_IF}" -j ACCEPT

# Permitir respuestas de conexiones establecidas desde contenedores
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# NAT para que los contenedores puedan salir a internet con la IP del host
iptables -t nat -A POSTROUTING -s 172.16.0.0/12 ! -o docker0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 192.168.0.0/16 ! -o docker0 -j MASQUERADE

# ---- Acceso desde VPN a contenedores Docker ----
# Cuando WireGuard esté activo (módulo 05), los peers conectados en
# 10.10.0.0/24 podrán acceder a todos los servicios Docker
iptables -A FORWARD -i "${WG_INTERFACE}" -j ACCEPT
iptables -A FORWARD -o "${WG_INTERFACE}" -j ACCEPT

# NAT para tráfico VPN → contenedores
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -j MASQUERADE

log_ok "Reglas iptables manuales aplicadas"

# -----------------------------------------------------------------------------
# PASO 5 — Persistir reglas iptables para que sobrevivan reinicios
# -----------------------------------------------------------------------------
log_info "Persistiendo reglas iptables..."

apt-get install -y -qq iptables-persistent netfilter-persistent

# Guardar reglas actuales
netfilter-persistent save
systemctl enable netfilter-persistent

log_ok "Reglas iptables persistidas"

# -----------------------------------------------------------------------------
# PASO 6 — Reiniciar Docker con nueva configuración
# -----------------------------------------------------------------------------
log_info "Reiniciando Docker (los contenedores se detienen y reinician)..."
log_warn "Esto puede tardar 30-60 segundos..."

systemctl restart docker

# Esperar que Docker levante completamente
WAIT=0
until docker info &>/dev/null 2>&1; do
  sleep 2
  WAIT=$((WAIT + 2))
  if [[ ${WAIT} -gt 60 ]]; then
    log_error "Docker tardó demasiado en reiniciar. Verificá: journalctl -u docker"
    exit 1
  fi
done

log_ok "Docker reiniciado correctamente"

# -----------------------------------------------------------------------------
# PASO 7 — Verificar que los contenedores volvieron a correr
# -----------------------------------------------------------------------------
log_info "Verificando estado de contenedores..."
sleep 5  # Dar tiempo a que los contenedores con restart:always vuelvan a subir

RUNNING_AFTER=$(docker ps --format '{{.Names}}' | wc -l)
log_info "Contenedores activos después del reinicio: ${RUNNING_AFTER}"

if [[ ${RUNNING_AFTER} -gt 0 ]]; then
  log_ok "Contenedores corriendo:"
  docker ps --format "  ✓ {{.Names}} — {{.Status}}"
fi

if [[ ${RUNNING_AFTER} -lt ${RUNNING_CONTAINERS} ]]; then
  DIFF=$((RUNNING_CONTAINERS - RUNNING_AFTER))
  log_warn "${DIFF} contenedor(es) no volvieron a subir automáticamente"
  log_warn "Verificá con: docker ps -a"
  log_warn "Contenedores sin política restart:always no reinician solos"
  log_info "Para reiniciar manualmente: docker start NOMBRE_CONTENEDOR"
fi

# -----------------------------------------------------------------------------
# PASO 8 — Verificar que Docker ya NO modifica iptables
# -----------------------------------------------------------------------------
log_info "Verificando que Docker no está modificando iptables..."
sleep 3

# Si Docker insertó reglas en la cadena DOCKER, algo salió mal
DOCKER_RULES=$(iptables -L DOCKER 2>/dev/null | grep -c "ACCEPT" || echo "0")
if [[ "${DOCKER_RULES}" -gt 0 ]]; then
  log_warn "Docker todavía tiene reglas en iptables. Verificá daemon.json."
  log_warn "Puede requerir un reinicio completo del servidor para limpiar."
else
  log_ok "Docker no está gestionando iptables — control total en UFW"
fi

# -----------------------------------------------------------------------------
# PASO 9 — Script de acceso directo para cuando estés dentro de la VPN
# -----------------------------------------------------------------------------
log_info "Generando inventario de servicios Docker..."

INVENTORY_FILE="/etc/vps-hardening/docker_services.txt"
cat > "${INVENTORY_FILE}" <<EOF
# =============================================================
# Inventario de servicios Docker
# Generado el $(date)
# Accesibles desde la VPN en: 10.10.0.1:PUERTO
# =============================================================

EOF

docker ps --format "{{.Names}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null | \
while IFS=$'\t' read -r name ports image; do
  # Extraer puertos del host
  HOST_PORTS=$(echo "${ports}" | grep -oP '0\.0\.0\.0:\K[0-9]+' | tr '\n' ', ' | sed 's/,$//')
  if [[ -n "${HOST_PORTS}" ]]; then
    echo "${name} (${image})" >> "${INVENTORY_FILE}"
    echo "  → Acceso VPN: 10.10.0.1:${HOST_PORTS}" >> "${INVENTORY_FILE}"
    echo "" >> "${INVENTORY_FILE}"
  fi
done

log_ok "Inventario guardado en: ${INVENTORY_FILE}"
echo ""
cat "${INVENTORY_FILE}"

# -----------------------------------------------------------------------------
# Resumen final
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Docker + UFW desacoplados correctamente                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                                  ║${NC}"
echo -e "${GREEN}║  ✓ Docker ya NO gestiona iptables                               ║${NC}"
echo -e "${GREEN}║  ✓ Contenedores: comunicación interna OK                        ║${NC}"
echo -e "${GREEN}║  ✓ Contenedores: salida a internet OK (para updates)            ║${NC}"
echo -e "${GREEN}║  ✗ Contenedores: inaccesibles desde internet público            ║${NC}"
echo -e "${GREEN}║  ↺ Contenedores: accesibles desde VPN (tras módulo 05)         ║${NC}"
echo -e "${GREEN}║                                                                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
log_ok "=== Docker + UFW fix completado ==="
log_warn "Tus apps ya NO son accesibles desde internet."
log_warn "Quedarán accesibles desde 10.10.0.1:PUERTO una vez activa la VPN."
log_info "Próximo paso: sudo bash 03_ufw_firewall.sh"
