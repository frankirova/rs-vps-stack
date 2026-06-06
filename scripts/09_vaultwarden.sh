#!/usr/bin/env bash
# =============================================================================
# 09_vaultwarden.sh — Gestor de contraseñas Vaultwarden (solo VPN)
#
# QUÉ HACE:
#   - Instala Caddy como servicio de host via apt (proxy HTTPS en 10.10.0.1:443)
#   - Levanta Vaultwarden como contenedor Docker (bind 127.0.0.1:VW_PORT)
#   - Genera y hashea el admin token con argon2 (nunca se guarda en texto plano)
#   - Configura TLS interno (CA local de Caddy) — no se expone al internet público
#   - Exporta el certificado raíz de la CA para distribución a dispositivos
#   - Agrega el drop-in systemd para que Caddy arranque después de WireGuard
#   - El acceso es EXCLUSIVO a través de la VPN (wg0, 10.10.0.0/24)
#
# PREREQUISITOS:
#   - Módulo 03b ejecutado (Docker instalado con iptables:false)
#   - Módulo 05 ejecutado (WireGuard activo en wg0)
#   - Módulo 07 ejecutado (/etc/vps-hardening/config.env existe)
#   - VW_PORT, VW_DATA_DIR, VW_DOMAIN configurados en 00_config.sh
#
# NOTA: Requiere Vaultwarden >= 1.30 para soporte de tokens argon2 hasheados.
#
# USO:
#   sudo bash 09_vaultwarden.sh
# =============================================================================

set -euo pipefail
source "$(dirname "$0")/00_config.sh"

check_root

log_info "=== Módulo 09: Vaultwarden (gestor de contraseñas VPN-only) ==="

# =============================================================================
# PASO 0 — Verificaciones previas
# =============================================================================
log_info "Verificando requisitos previos..."

# Docker disponible y activo
if ! command -v docker &>/dev/null; then
  log_error "Docker no está instalado. Ejecutá primero 03b_docker_ufw_fix.sh"
  exit 1
fi

if ! systemctl is-active --quiet docker; then
  log_error "El servicio Docker no está activo. Inicialo con: systemctl start docker"
  exit 1
fi

# config.env debe existir (módulo 07 debe haber corrido)
if [[ ! -f /etc/vps-hardening/config.env ]]; then
  log_error "No existe /etc/vps-hardening/config.env. Ejecutá primero 07_backup_restic.sh"
  exit 1
fi

# VW_PORT debe estar definido
if [[ -z "${VW_PORT:-}" ]]; then
  log_error "VW_PORT no está definido en 00_config.sh"
  exit 1
fi

# Verificar conflicto de puertos
# Toleramos que nuestros propios procesos (caddy, vaultwarden) ya estén corriendo
PORT_443_CONFLICT=$(ss -ltnp 2>/dev/null | grep ":443 " | grep -v "caddy" || true)
PORT_VW_CONFLICT=$(ss -ltnp 2>/dev/null | grep ":${VW_PORT} " | grep -v "docker" || true)

if [[ -n "${PORT_443_CONFLICT}" ]]; then
  log_error "El puerto 443 está siendo usado por otro proceso (no Caddy):"
  echo "${PORT_443_CONFLICT}"
  exit 1
fi

if [[ -n "${PORT_VW_CONFLICT}" ]]; then
  log_error "El puerto ${VW_PORT} está siendo usado por otro proceso (no Docker/Vaultwarden):"
  echo "${PORT_VW_CONFLICT}"
  exit 1
fi

log_ok "Requisitos verificados"

# =============================================================================
# PASO 1 — Instalar Caddy via apt (idempotente)
# =============================================================================
log_info "Verificando instalación de Caddy..."

if ! command -v caddy &>/dev/null; then
  log_info "Instalando Caddy desde repositorio oficial..."

  # Dependencias
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl

  # Agregar clave GPG del repositorio de Caddy (idempotente)
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    log_ok "Clave GPG de Caddy importada"
  else
    log_ok "Clave GPG de Caddy ya existe"
  fi

  # Agregar repositorio (idempotente)
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    log_ok "Repositorio de Caddy agregado"
  else
    log_ok "Repositorio de Caddy ya configurado"
  fi

  apt-get update -qq
  apt-get install -y -qq caddy
  systemctl enable caddy
  log_ok "Caddy instalado"
else
  log_ok "Caddy ya instalado ($(caddy version 2>/dev/null | head -1))"
fi

# =============================================================================
# PASO 2 — Generar y hashear el admin token (idempotente)
# =============================================================================
log_info "Configurando admin token de Vaultwarden..."

# Leer token actual de config.env (puede estar vacío o ya hasheado)
EXISTING_TOKEN=$(grep "^VW_ADMIN_TOKEN=" /etc/vps-hardening/config.env 2>/dev/null \
  | sed "s/^VW_ADMIN_TOKEN=//" | tr -d '"'"'" || true)

if [[ "${EXISTING_TOKEN}" == '$argon2'* ]]; then
  log_ok "Admin token ya hasheado en config.env — no se regenera"
  VW_ADMIN_TOKEN_HASH="${EXISTING_TOKEN}"
  VW_PLAINTEXT_TOKEN=""
else
  log_info "Generando nuevo admin token..."

  # Generar token aleatorio en texto plano
  VW_PLAINTEXT_TOKEN=$(openssl rand -base64 48)

  # Hashear con caddy (argon2id — Vaultwarden >= 1.30 acepta este formato)
  VW_ADMIN_TOKEN_HASH=$(caddy hash-password --algorithm argon2 --plaintext "${VW_PLAINTEXT_TOKEN}" 2>/dev/null)

  if [[ -z "${VW_ADMIN_TOKEN_HASH}" ]]; then
    log_error "No se pudo generar el hash argon2 del token. Verificá la versión de Caddy."
    exit 1
  fi

  log_warn "GUARDÁ ESTE TOKEN — solo se muestra una vez y no se puede recuperar:"
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ADMIN TOKEN (texto plano — COPIAR AHORA):                      ║${NC}"
  echo -e "${RED}║                                                                  ║${NC}"
  printf  "${RED}║  %-64s║${NC}\n" "${VW_PLAINTEXT_TOKEN}"
  echo -e "${RED}║                                                                  ║${NC}"
  echo -e "${RED}║  Este token NO se guardará en ningún archivo del sistema.       ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

# =============================================================================
# PASO 3 — Crear directorio de datos (idempotente)
# =============================================================================
log_info "Preparando directorio de datos: ${VW_DATA_DIR}"

mkdir -p "${VW_DATA_DIR}"
chmod 700 "$(dirname "${VW_DATA_DIR}")"
chmod 700 "${VW_DATA_DIR}"
log_ok "Directorio ${VW_DATA_DIR} listo"

# =============================================================================
# PASO 4 — Levantar contenedor Vaultwarden (idempotente)
# =============================================================================
log_info "Configurando contenedor Vaultwarden..."

# Remover contenedor anterior si existe (datos persisten en bind mount)
if docker inspect vaultwarden &>/dev/null 2>&1; then
  log_info "Removiendo contenedor vaultwarden existente..."
  docker rm -f vaultwarden 2>/dev/null || true
fi

log_info "Descargando imagen vaultwarden/server:latest..."
docker pull vaultwarden/server:latest

log_info "Iniciando contenedor Vaultwarden..."
docker run -d \
  --name vaultwarden \
  --restart unless-stopped \
  -p "127.0.0.1:${VW_PORT}:80" \
  -v "${VW_DATA_DIR}:/data" \
  -e "ADMIN_TOKEN=${VW_ADMIN_TOKEN_HASH}" \
  -e "DOMAIN=https://${VW_DOMAIN}" \
  -e "SIGNUPS_ALLOWED=false" \
  -e "ROCKET_PORT=80" \
  vaultwarden/server:latest

log_ok "Contenedor Vaultwarden iniciado (bind: 127.0.0.1:${VW_PORT})"

# =============================================================================
# PASO 5 — Escribir Caddyfile
# =============================================================================
log_info "Configurando Caddyfile..."

cat > /etc/caddy/Caddyfile <<EOF
{
    # CA local — sin ACME público
}

https://${VW_DOMAIN}:443 {
    bind 10.10.0.1
    tls internal
    reverse_proxy 127.0.0.1:${VW_PORT}
}
EOF
chmod 600 /etc/caddy/Caddyfile

log_ok "Caddyfile escrito en /etc/caddy/Caddyfile"

# =============================================================================
# PASO 6 — Validar y recargar Caddy
# =============================================================================
log_info "Validando configuración de Caddy..."

if ! caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
  log_error "Caddyfile inválido. Revisá /etc/caddy/Caddyfile"
  exit 1
fi

log_info "Recargando Caddy..."
systemctl enable caddy
systemctl reload caddy 2>/dev/null || systemctl restart caddy

if systemctl is-active --quiet caddy; then
  log_ok "Caddy activo y escuchando en 10.10.0.1:443"
else
  log_error "Caddy no arrancó correctamente. Revisá: journalctl -u caddy -n 50"
  exit 1
fi

# =============================================================================
# PASO 7 — Exportar certificado CA de Caddy
# =============================================================================
log_info "Exportando certificado raíz de la CA local de Caddy..."

CADDY_CA_SRC="/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt"
CADDY_CA_DST="/etc/vps-hardening/vaultwarden-ca.crt"

# Esperar a que Caddy genere la CA (puede tardar unos segundos en el primer arranque)
WAIT=0
while [[ ! -f "${CADDY_CA_SRC}" ]] && [[ ${WAIT} -lt 15 ]]; do
  log_info "Esperando que Caddy genere la CA local... (${WAIT}s)"
  sleep 2
  WAIT=$((WAIT + 2))
done

if [[ -f "${CADDY_CA_SRC}" ]]; then
  cp "${CADDY_CA_SRC}" "${CADDY_CA_DST}"
  chmod 644 "${CADDY_CA_DST}"
  log_ok "Certificado CA exportado a: ${CADDY_CA_DST}"
else
  log_warn "Caddy aún no generó la CA. Exportá manualmente:"
  log_warn "  cp ${CADDY_CA_SRC} ${CADDY_CA_DST}"
fi

# =============================================================================
# PASO 8 — Persistir variables VW en config.env (idempotente)
# =============================================================================
log_info "Actualizando /etc/vps-hardening/config.env..."

# Función helper: agrega o actualiza una variable en config.env
# Para el token argon2 (contiene $ y caracteres especiales) usamos
# grep-delete-append en lugar de sed para evitar problemas de escapado.
update_config_env() {
  local key="$1"
  local value="$2"
  local file="/etc/vps-hardening/config.env"

  # Eliminar línea existente (si hay)
  grep -v "^${key}=" "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"

  # Agregar la nueva línea al final
  echo "${key}=\"${value}\"" >> "${file}"
}

update_config_env "VW_PORT"     "${VW_PORT}"
update_config_env "VW_DATA_DIR" "${VW_DATA_DIR}"
update_config_env "VW_DOMAIN"   "${VW_DOMAIN}"
update_config_env "VW_ADMIN_TOKEN" "${VW_ADMIN_TOKEN_HASH}"

chmod 600 /etc/vps-hardening/config.env
log_ok "Variables VW persistidas en config.env"

# =============================================================================
# PASO 9 — Drop-in systemd: Caddy arranca después de wg0
# =============================================================================
log_info "Configurando dependencia systemd: caddy → wg-quick@wg0..."

mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/wg0-order.conf <<'DROPIN'
[Unit]
After=wg-quick@wg0.service
Wants=wg-quick@wg0.service
DROPIN
chmod 600 /etc/systemd/system/caddy.service.d/wg0-order.conf

systemctl daemon-reload
log_ok "Drop-in creado: caddy arranca después de wg-quick@wg0.service"

# =============================================================================
# PASO 10 — Recordatorio de backup y resumen final
# =============================================================================
log_warn "Re-ejecutá 07_backup_restic.sh para regenerar /usr/local/bin/vps-backup con la ruta de Vaultwarden"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  VAULTWARDEN CONFIGURADO EXITOSAMENTE                               ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  Acceso HTTPS (solo desde VPN):                                     ║${NC}"
printf  "${GREEN}║    https://%-57s║${NC}\n" "${VW_DOMAIN}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  Panel de administración:                                            ║${NC}"
printf  "${GREEN}║    https://%s/admin%-43s║${NC}\n" "${VW_DOMAIN}" ""
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  Certificado CA para instalar en dispositivos:                       ║${NC}"
echo -e "${GREEN}║    /etc/vps-hardening/vaultwarden-ca.crt                            ║${NC}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  Datos persistentes:                                                 ║${NC}"
printf  "${GREEN}║    %-66s║${NC}\n" "${VW_DATA_DIR}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  SIGNUPS_ALLOWED=false — invitá usuarios desde el panel /admin      ║${NC}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  PRÓXIMOS PASOS:                                                     ║${NC}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  1. En cada dispositivo, instalá el certificado CA:                 ║${NC}"
echo -e "${GREEN}║     /etc/vps-hardening/vaultwarden-ca.crt                           ║${NC}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  2. En el cliente Bitwarden/Vaultwarden, configurá:                 ║${NC}"
printf  "${GREEN}║     Server URL → https://%-45s║${NC}\n" "${VW_DOMAIN}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}║  3. Re-ejecutá 07_backup_restic.sh para incluir                     ║${NC}"
echo -e "${GREEN}║     Vaultwarden en los backups de Restic                            ║${NC}"
echo -e "${GREEN}║                                                                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -n "${VW_PLAINTEXT_TOKEN:-}" ]]; then
  echo -e "${RED}╔══════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  RECORDATORIO URGENTE: ADMIN TOKEN (texto plano)                    ║${NC}"
  echo -e "${RED}║                                                                      ║${NC}"
  printf  "${RED}║  %-68s║${NC}\n" "${VW_PLAINTEXT_TOKEN}"
  echo -e "${RED}║                                                                      ║${NC}"
  echo -e "${RED}║  Este token NO está guardado en ningún archivo.                     ║${NC}"
  echo -e "${RED}║  Si lo perdés, tendrás que regenerarlo ejecutando este módulo       ║${NC}"
  echo -e "${RED}║  de nuevo (lo cual reinicia el contenedor).                         ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

log_ok "=== Módulo 09 completado ==="
log_info "Contenedor: docker inspect vaultwarden"
log_info "Logs Caddy: journalctl -u caddy -f"
log_info "Logs VW:    docker logs -f vaultwarden"
