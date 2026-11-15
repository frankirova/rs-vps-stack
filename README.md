# VPS Hardening Stack

[![Licencia: MIT](https://img.shields.io/badge/Licencia-MIT-blue.svg)](LICENSE)
[![Ubuntu 22.04 LTS](https://img.shields.io/badge/Ubuntu-22.04%20LTS-E95420?logo=ubuntu&logoColor=white)](https://releases.ubuntu.com/22.04/)

Stack de seguridad completo para servidores Ubuntu 22.04 LTS con Docker. Implementa una arquitectura **Zero Trust** donde ninguna aplicación es accesible desde internet — todo el acceso pasa por una VPN WireGuard.

> Diseñado para equipos pequeños (1-10 personas) que hostean aplicaciones en un VPS propio o servidor físico virtualizado.

---

## Qué hace este stack

```
ANTES:
  Internet → [sin firewall] → 20+ puertos abiertos → apps Docker expuestas
                            → SSH puerto 22 → bots de fuerza bruta atacando

DESPUÉS:
  Internet → [UFW] → solo puerto SSH custom (con llave pública)
                   → solo puerto WireGuard UDP
                   → TODO lo demás: BLOQUEADO

  VPN (10.10.0.x) → todas las apps Docker accesibles internamente
```

## Módulos incluidos

| # | Script | Función |
|---|---|---|
| 00 | `00_config.sh` | Variables globales — el único archivo que editás |
| 01 | `01_ssh_hardening.sh` | Puerto custom + solo llaves públicas + verificación segura |
| 02 | `02_system_base.sh` | Actualizaciones, kernel hardening, unattended-upgrades |
| 03b | `03b_docker_ufw_fix.sh` | Desacoplar Docker de iptables (crítico si usás Docker) |
| 03 | `03_ufw_firewall.sh` | Firewall: solo SSH y WireGuard expuestos al mundo |
| 04 | `04_fail2ban.sh` | Baneo automático de IPs con notificación Telegram |
| 05 | `05_wireguard_server.sh` | VPN hub-and-spoke con N peers, configs y QR automáticos |
| 06 | `06_unbound_dns.sh` | DNS recursivo privado, solo accesible por VPN |
| 07 | `07_backup_restic.sh` | Backups cifrados con Restic, cron diario |
| 08 | `08_telegram_bot.sh` | Bot interactivo: alertas y actualizaciones por Telegram |

---

## Mapa de dependencias

Los módulos deben ejecutarse en este orden. Cada paso depende del anterior:

1. **00 `00_config.sh`** — sourceado por todos los módulos. Debe existir y tener valores reales antes de correr cualquier script.
2. **01 `01_ssh_hardening.sh`** — primero siempre: cambia el puerto SSH. Si falla, los módulos siguientes pueden dejarte sin acceso.
3. **02 `02_system_base.sh`** — actualizaciones y hardening de kernel. Establece la base del sistema.
4. **03b `03b_docker_ufw_fix.sh`** — desacopla Docker de iptables. Debe correr **antes** de activar UFW, si usás Docker.
5. **03 `03_ufw_firewall.sh`** — activa el firewall. A partir de aquí solo SSH custom y WireGuard son accesibles.
6. **04 `04_fail2ban.sh`** — instala Fail2ban y declara la acción Telegram en `jail.local`. Las alertas quedan **inactivas** hasta que corra el módulo 08.
7. **05 `05_wireguard_server.sh`** — levanta el servidor VPN y genera configs/QR de peers.
8. **06 `06_unbound_dns.sh`** — DNS recursivo privado accesible solo desde la VPN (depende de que WireGuard esté activo).
9. **07 `07_backup_restic.sh`** — configura backups cifrados y **crea `/etc/vps-hardening/config.env`** (chmod 600). Este archivo es requerido por el módulo 08.
10. **08 `08_telegram_bot.sh`** — requiere que el módulo 07 haya generado `config.env`. Actualiza `config.env` con variables de Telegram, activa el wiring de alertas en `jail.local` y levanta el daemon del bot.

> **Nota importante sobre `config.env`:** este archivo es creado por el módulo 07, no por el módulo 08. Si corrés el módulo 08 sin haber corrido el 07 primero, fallará porque `config.env` no existe.

---

## Requisitos

- Ubuntu 22.04 LTS
- Usuario no-root con permisos sudo
- Acceso SSH al servidor
- Cuenta de Telegram (para el bot de alertas)
- Python 3 (preinstalado en Ubuntu 22.04)
- `qrencode` (para generar QR codes de peers WireGuard: `sudo apt install qrencode`)

---

## Instalación

### Paso 0 — Preparación en tu máquina local

**Generar llave SSH:**

```bash
# Linux / macOS
ssh-keygen -t ed25519 -C "mi-vps" -f ~/.ssh/mi_vps
cat ~/.ssh/mi_vps.pub

# Windows (PowerShell)
ssh-keygen -t ed25519 -C "mi-vps" -f "$env:USERPROFILE\.ssh\mi_vps"
Get-Content "$env:USERPROFILE\.ssh\mi_vps.pub"
```

**Crear el bot de Telegram:**

1. Abrí Telegram y buscá `@BotFather`
2. Enviá `/newbot` y seguí las instrucciones
3. Copiá el TOKEN que te da BotFather
4. Iniciá conversación con tu bot y enviá `/start`
5. Visitá `https://api.telegram.org/bot<TOKEN>/getUpdates`
6. Tu `chat_id` está en `result[0].message.chat.id`

### Paso 1 — Subir los scripts al servidor

```bash
scp -r vps-hardening/ usuario@IP_DEL_VPS:~/
```

### Paso 2 — Configurar variables

```bash
nano ~/vps-hardening/scripts/00_config.sh
chmod 600 ~/vps-hardening/scripts/00_config.sh
```

Variables disponibles (todas en `scripts/00_config.sh`):

### SSH

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `SSH_PORT` | `2222` | Sí | Puerto SSH nuevo |
| `SSH_USER` | `"admin"` | Sí | Tu usuario no-root |
| `SSH_PUBKEY` | `"ssh-ed25519 AAAA...tu_clave"` | Sí | Contenido de tu `~/.ssh/id_ed25519.pub` |

### WireGuard

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `WG_INTERFACE` | `"wg0"` | No | Nombre de la interfaz WireGuard |
| `WG_PORT` | `51820` | No | Puerto UDP de WireGuard |
| `WG_SERVER_IP` | `"10.10.0.1/24"` | No | IP del servidor en la red VPN |
| `WG_DNS` | `"10.10.0.1"` | No | DNS interno (Unbound) |
| `WG_PEERS` | `10` | Sí | Cantidad de peers a generar |
| `WG_PEER_NAMES` | `("admin" "worker01" ... "worker09")` | Sí | Nombres de los peers — Bash array |

> `WG_PEER_NAMES` es un array Bash. Sintaxis correcta:
> ```bash
> WG_PEER_NAMES=(
>   "admin"
>   "worker01"
>   "worker02"
> )
> ```

### Telegram

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `TG_BOT_TOKEN` | `"123456789:AAxx..."` | Sí | Token del BotFather |
| `TG_CHAT_ID` | `"000000000"` | Sí | Tu chat_id personal |
| `TG_ADMIN_IDS` | `("000000000")` | Sí | IDs autorizados a usar el bot — Bash array |

### Restic (Backups)

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `RESTIC_PASSWORD` | `"cambia_esta_password_segura_ahora"` | Sí | Password de cifrado — guardala en un gestor de contraseñas |
| `RESTIC_REPO` | `"/var/backups/restic"` | Opcional | Ruta del repositorio Restic. Cambiá a `sftp:usuario@IP:/ruta` para NAS externo |

> En `config.env` (generado por módulo 07) esta variable se llama `RESTIC_REPOSITORY`.

### Backups

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `BACKUP_PATHS` | `("/etc" "/home" "/var/log" "/root" "/usr/local/bin" "/etc/vps-hardening")` | Opcional | Paths a incluir en el backup — Bash array |
| `BACKUP_RETENTION_DAILY` | `7` | Opcional | Snapshots diarios a conservar |
| `BACKUP_RETENTION_WEEKLY` | `4` | Opcional | Snapshots semanales a conservar |
| `BACKUP_RETENTION_MONTHLY` | `3` | Opcional | Snapshots mensuales a conservar |

### Fail2ban

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `F2B_BANTIME` | `"1h"` | Opcional | Duración del baneo |
| `F2B_FINDTIME` | `"10m"` | Opcional | Ventana de tiempo para contar intentos |
| `F2B_MAXRETRY` | `5` | Opcional | Intentos fallidos antes de banear |

### Sistema

| Variable | Default | ¿Editar? | Descripción |
|----------|---------|----------|-------------|
| `TIMEZONE` | `"America/Argentina/Cordoba"` | Sí | Tu timezone (formato `Region/Ciudad`) |
| `HOSTNAME_NEW` | `"mi-vps"` | Sí | Hostname del servidor |

### Paso 3 — Red de seguridad (recomendado)

Instalá este rescate automático ANTES de tocar SSH. Si algo falla, restaura el acceso original en 5 minutos:

```bash
sudo bash -c 'cat > /usr/local/bin/ssh-rescue.sh << RESCUE
#!/bin/bash
NEW_PORT=2222
ORIGINAL_CONFIG="/etc/ssh/sshd_config.backup_original"
if [[ ! -f "\$ORIGINAL_CONFIG" ]]; then
  cp /etc/ssh/sshd_config "\$ORIGINAL_CONFIG"
fi
if ! nc -z -w5 127.0.0.1 "\$NEW_PORT" 2>/dev/null; then
  cp "\$ORIGINAL_CONFIG" /etc/ssh/sshd_config
  systemctl restart sshd
fi
RESCUE
chmod +x /usr/local/bin/ssh-rescue.sh'

sudo bash -c 'echo "*/5 * * * * root /usr/local/bin/ssh-rescue.sh" > /etc/cron.d/ssh-rescue'
```

Eliminarlo cuando el módulo 01 termine exitosamente:

```bash
sudo rm /etc/cron.d/ssh-rescue /usr/local/bin/ssh-rescue.sh
```

### Paso 4 — Usar tmux (recomendado)

Mantiene la sesión activa si se corta la conexión:

```bash
tmux new-session -s hardening
# Si se corta reconectarse con: tmux attach -t hardening
```

### Paso 5 — Despliegue en orden estricto

```bash
# SSH primero — pausa y te pide verificar el nuevo puerto antes de cerrar el anterior
sudo bash ~/vps-hardening/scripts/01_ssh_hardening.sh
```

Cuando el script pause, abrí otra terminal y verificá:

```bash
# Linux / macOS
ssh -p 2222 -i ~/.ssh/mi_vps usuario@IP_VPS

# Windows PowerShell
ssh -p 2222 -i "$env:USERPROFILE\.ssh\mi_vps" usuario@IP_VPS
```

Si entrás correctamente, escribís `confirmar` en la terminal original. Si no funciona, no hagas nada — el cron de rescate restaura el SSH original en 5 minutos.

```bash
sudo bash ~/vps-hardening/scripts/02_system_base.sh
sudo bash ~/vps-hardening/scripts/03b_docker_ufw_fix.sh  # Solo si usás Docker
sudo bash ~/vps-hardening/scripts/03_ufw_firewall.sh
sudo bash ~/vps-hardening/scripts/04_fail2ban.sh
sudo bash ~/vps-hardening/scripts/05_wireguard_server.sh
sudo bash ~/vps-hardening/scripts/06_unbound_dns.sh
sudo bash ~/vps-hardening/scripts/07_backup_restic.sh
sudo bash ~/vps-hardening/scripts/08_telegram_bot.sh
```

---

## Idempotencia

Todos los módulos están diseñados para ser **idempotentes**: podés volver a ejecutar cualquier módulo en un sistema ya configurado sin que cause efectos negativos ni duplique configuración. Los scripts verifican el estado actual antes de aplicar cambios (guards con `command -v`, `grep -q`, regeneración limpia de archivos de config). Re-correr un módulo en un servidor ya endurecido es seguro.

---

## Conectar trabajadores a la VPN

### PC (Windows / macOS / Linux)

1. Instalar WireGuard desde https://www.wireguard.com/install/
2. Bajar el archivo de configuración:

```bash
# En el servidor — copiar al home para poder bajarlo
sudo cp /etc/wireguard/peers/worker01/worker01.conf /home/tu_usuario/
sudo chown tu_usuario:tu_usuario /home/tu_usuario/worker01.conf

# Desde tu máquina local
scp -P 2222 -i ~/.ssh/mi_vps usuario@IP_VPS:~/worker01.conf ./
```

3. En WireGuard: Importar túnel desde archivo
4. Activar el túnel

### Celular (iOS / Android)

1. Instalar WireGuard desde App Store o Play Store
2. Mostrar el QR en el servidor:

```bash
qrencode -t ansiutf8 < /etc/wireguard/peers/worker01/worker01.conf
```

3. En el celular: tocar + y Escanear código QR

> Los archivos `.conf` contienen claves privadas. Distribuirlos solo por canales cifrados. Nunca por WhatsApp o email sin cifrar.

---

## Bot de Telegram

| Comando | Acción |
|---|---|
| `/estado` | CPU, RAM, disco, peers VPN activos |
| `/si` | Instalar actualizaciones pendientes |
| `/no` | Posponer actualizaciones (recuerda mañana a las 9 AM) |
| `/reiniciar` | Reiniciar servidor (solo si hay kernel update pendiente) |
| `/backups` | Estado del último snapshot Restic |
| `/baneados` | IPs actualmente baneadas por Fail2ban |
| `/ayuda` | Lista completa de comandos |

Flujo de actualizaciones:

```
[9:00 AM] Cron detecta updates disponibles
    ↓
Telegram: "Hay 3 actualizaciones: nginx, curl, openssl. /si /no"
    ↓
/si → Bot instala y reporta resultado
    ↓ (si hay kernel update)
"Reinicio requerido — /reiniciar cuando estés listo"
```

---

## Migrar backups al NAS

```bash
# Generar llave SSH del servidor
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""

# Autorizar la llave en el NAS
ssh-copy-id -i /root/.ssh/id_ed25519 usuario@IP_NAS

# Actualizar config.env
sed -i 's|RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY="sftp:usuario@IP_NAS:/ruta/backups"|' \
  /etc/vps-hardening/config.env

# Inicializar nuevo repo y probar
export RESTIC_PASSWORD_FILE=/etc/vps-hardening/restic_password
restic -r "sftp:usuario@IP_NAS:/ruta/backups" init
/usr/local/bin/vps-backup
```

---

## Operación diaria

```bash
# Ver peers VPN conectados
sudo wg show

# Ver IPs baneadas
sudo fail2ban-client status sshd

# Desbanear una IP
sudo fail2ban-client set sshd unbanip IP.BLOQUEADA

# Estado de todos los servicios
sudo systemctl status wg-quick@wg0 unbound fail2ban vps-telegram-bot

# Ver snapshots de backup
sudo restic -r /var/backups/restic \
  --password-file /etc/vps-hardening/restic_password snapshots

# Logs del bot
tail -f /var/log/vps-bot.log
```

---

## Estructura de archivos generados

```
/etc/
├── wireguard/
│   ├── wg0.conf                     Config del servidor WireGuard
│   └── peers/
│       ├── worker01/
│       │   ├── worker01.conf        Importar en cliente WireGuard
│       │   └── worker01_qr.png      Escanear desde celular
│       └── ...
├── unbound/unbound.conf             DNS recursivo
├── fail2ban/jail.local              Proteccion fuerza bruta
└── vps-hardening/
    ├── config.env                   Variables del sistema (chmod 600)
    └── restic_password              Password backups (chmod 600)

/usr/local/bin/
├── vps-backup                       Backup manual o por cron
├── vps-backup-check                 Verificacion semanal de integridad
├── vps-check-updates                Deteccion diaria de updates
└── vps-telegram-bot                 Daemon del bot de Telegram
```

---

## Troubleshooting

**El bot no responde:**
```bash
sudo systemctl status vps-telegram-bot
sudo journalctl -u vps-telegram-bot -n 30
```

**WireGuard no conecta:**
```bash
sudo wg show
sudo ufw status | grep 51820
sudo journalctl -u wg-quick@wg0 -n 20
```

**DNS no resuelve:**
```bash
sudo systemctl status unbound
dig @127.0.0.1 google.com
```

**Restaurar un archivo desde backup:**
```bash
sudo restic -r /var/backups/restic \
  --password-file /etc/vps-hardening/restic_password \
  restore latest --target /tmp/restore --include /etc/nginx
```

**Fail2ban no envía alertas Telegram:**

Diagnóstico paso a paso:

1. **¿Corrió el módulo 08?** Las alertas Telegram de Fail2ban solo se activan cuando el módulo 08 ejecuta el wiring en `jail.local`. Verificá:
   ```bash
   sudo systemctl status vps-telegram-bot
   ```
   Si el servicio no existe, el módulo 08 no corrió.

2. **¿Tiene `config.env` las variables de Telegram?**
   ```bash
   sudo grep TG_ /etc/vps-hardening/config.env
   ```
   Deben aparecer `TG_BOT_TOKEN` y `TG_CHAT_ID` con valores reales (no los placeholders del ejemplo).

3. **¿Está activo el bloque de acción Telegram en `jail.local`?**
   ```bash
   sudo grep -A5 "telegram" /etc/fail2ban/jail.local
   ```
   El bloque `action` con la llamada al script de Telegram debe estar descomentado.

4. **Resolución:** si alguno de los pasos anteriores falla, volvé a correr el módulo 08:
   ```bash
   sudo bash ~/vps-hardening/scripts/08_telegram_bot.sh
   ```
   Luego reiniciá Fail2ban:
   ```bash
   sudo systemctl restart fail2ban
   sudo fail2ban-client status sshd
   ```

---

## Notas de seguridad

- La password de Restic debe guardarse en un gestor externo (KeePassXC, Bitwarden). Si se pierde, los backups son irrecuperables.
- Los archivos `.conf` de WireGuard contienen claves privadas. Tratalos como contraseñas.
- El archivo `/etc/vps-hardening/config.env` tiene permisos 600. No lo subas a repositorios.
- El bot de Telegram solo responde al chat_id configurado. Cualquier otro usuario es ignorado.

### Generación de config.env

`/etc/vps-hardening/config.env` es **generado automáticamente por el módulo 07** (`07_backup_restic.sh`) a partir de los valores en `00_config.sh`. Tiene permisos `600` (solo lectura por root). **No lo creés ni edités a mano**: el módulo 08 lo actualiza internamente con `sed` y lo sourcea; cualquier edición manual puede romper el formato esperado. Si necesitás cambiar valores (por ejemplo, migrar el repo Restic a un NAS), editá `00_config.sh` y volvé a correr el módulo correspondiente.

### Wiring Telegram / Fail2ban

El módulo 04 (`04_fail2ban.sh`) configura Fail2ban e instala la acción de notificación Telegram en `jail.local`, pero esa acción **queda comentada/inactiva** hasta que el módulo 08 corra. Las alertas Telegram de Fail2ban son silenciosas hasta que el módulo 08 active el wiring explícitamente. Si ves que Fail2ban está baneando IPs pero no llegan alertas, revisá si el módulo 08 ya corrió.

### Tradeoff de seguridad — Módulo 08

El servicio `vps-telegram-bot` instalado por el módulo 08 **no usa las directivas de sandboxing `ProtectSystem` y `ProtectHome`** de systemd. Fueron removidas porque generan el error `226/NAMESPACE` en el entorno de ejecución. Consecuencia: el proceso tiene acceso más amplio al sistema de archivos que lo habitual para un servicio systemd hardened. Esto es un tradeoff consciente y documentado; el servicio corre como `root` con acceso al filesystem completo. Si el contexto de seguridad de tu deployment lo requiere, evaluá si esto es aceptable antes de correr el módulo 08.

---

## Compatibilidad testeada

| Componente | Version |
|---|---|
| Ubuntu | 22.04 LTS |
| WireGuard | kernel 5.15+ (incluido en Ubuntu 22.04) |
| Unbound | 1.13.1 |
| Restic | 0.16+ |
| Fail2ban | 0.11+ |
| Docker | 24+ (modulo 03b) |

---

## Licencia

MIT — Libre para usar, modificar y distribuir.


## Cómo se construyó

Desarrollado con agentes de IA bajo mi dirección. Definí el problema, los requisitos, la arquitectura y los criterios de aceptación; revisé el código, lo probé y lo uso.
