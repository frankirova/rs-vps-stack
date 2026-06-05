# Guía de contribución

Gracias por querer mejorar este proyecto. Leé esta guía antes de abrir un PR para que todo quede prolijo.

---

## Convención de numeración de módulos

Los scripts siguen el formato `NN_descripcion.sh`, donde `NN` es un prefijo de dos dígitos con cero a la izquierda que define el orden de ejecución.

```
00_config.sh          — variables globales (no es un módulo ejecutable)
01_ssh_hardening.sh   — siempre primero
02_system_base.sh
03b_docker_ufw_fix.sh — excepción: letra para variante de un paso
03_ufw_firewall.sh
04_fail2ban.sh
05_wireguard_server.sh
06_unbound_dns.sh
07_backup_restic.sh
08_telegram_bot.sh
```

**Reglas:**
- El número **codifica el orden de ejecución real** — no es decorativo.
- Los números **no se reusan** aunque se elimine un módulo.
- Si agregás un módulo entre dos existentes, usá un sufijo de letra (como `03b`).
- Mantené el nombre corto y descriptivo; solo minúsculas, guiones bajos, sin espacios.

---

## Cómo agregar un módulo nuevo

1. Elegí el número correcto según el orden en que debe ejecutarse respecto a los módulos existentes.
2. Creá el archivo en `scripts/NN_mi_modulo.sh`.
3. Empezá el script con el header estándar:

```bash
#!/usr/bin/env bash
# =============================================================================
# NN_mi_modulo.sh — Descripción breve
# VPS Hardening Stack — Ubuntu 22.04 LTS
# =============================================================================
source "$(dirname "$0")/00_config.sh"
check_root
check_os
```

4. Documentá el módulo en el README: tabla de "Módulos incluidos" y "Mapa de dependencias".
5. Si el módulo genera archivos nuevos en `/etc/vps-hardening/` o instala servicios, documentá también la sección "Estructura de archivos generados".

---

## Flujo de configuración

El proyecto tiene tres archivos de configuración con roles distintos:

| Archivo | Estado | Rol |
|---------|--------|-----|
| `scripts/00_config.example.sh` | Commiteado en git | Plantilla con valores de ejemplo — no editarlo directamente |
| `scripts/00_config.sh` | **Gitignoreado** | Tu configuración real — copiá el ejemplo y editá este |
| `/etc/vps-hardening/config.env` | Generado automáticamente | Creado por el módulo 07 a partir de `00_config.sh` |

### Pasos para configurar

```bash
# 1. Copiar el ejemplo
cp scripts/00_config.example.sh scripts/00_config.sh

# 2. Editar con tus valores reales
nano scripts/00_config.sh

# 3. Proteger el archivo
chmod 600 scripts/00_config.sh
```

**Importante:**
- `config.env` es generado por el módulo `07_backup_restic.sh` durante su ejecución. Se ubica en `/etc/vps-hardening/config.env` con permisos `600`.
- **No crear ni editar `config.env` a mano.** El módulo 08 lo actualiza con `sed` y lo sourcea; editarlo manualmente puede romper el formato esperado.
- El módulo 08 depende de que el módulo 07 haya corrido primero y generado `config.env`.

---

## Testing manual

Este proyecto no tiene suite de tests automatizados. La verificación es manual:

### Antes de hacer PR

1. **Sintaxis Bash:**
   ```bash
   bash -n scripts/NN_mi_modulo.sh
   ```

2. **En una VM limpia con Ubuntu 22.04:** corrés el módulo nuevo y verificás:
   - Sin errores en stdout/stderr
   - El servicio instalado queda activo: `sudo systemctl status nombre-servicio`
   - Los archivos generados tienen los permisos esperados: `ls -la /ruta/archivo`
   - Los puertos esperados están abiertos: `sudo ufw status`

3. **Idempotencia:** corrés el módulo dos veces seguidas. La segunda ejecución no debe fallar ni duplicar configuración.

4. **Logs:** revisás que `log_ok`, `log_info`, `log_warn` y `log_error` se usen correctamente y el output sea legible.

### Outputs esperados por módulo

| Módulo | Cómo verificar que funcionó |
|--------|-----------------------------|
| 01 SSH | `ssh -p $SSH_PORT $SSH_USER@IP` desde otra terminal |
| 02 Base | `unattended-upgrades --dry-run` sin errores |
| 03b Docker | `sudo iptables -L DOCKER-USER` muestra reglas UFW |
| 03 UFW | `sudo ufw status verbose` — solo SSH y WG expuestos |
| 04 Fail2ban | `sudo fail2ban-client status sshd` activo |
| 05 WireGuard | `sudo wg show` muestra el servidor activo |
| 06 Unbound | `dig @10.10.0.1 google.com` resuelve desde la VPN |
| 07 Restic | `sudo restic -r $RESTIC_REPO snapshots` lista el primer snapshot |
| 08 Telegram | Bot responde a `/estado` en Telegram |

---

## Estilo Bash

- Usá `#!/usr/bin/env bash` (no `/bin/bash`).
- Preferí `[[ ... ]]` sobre `[ ... ]` para condicionales.
- Variables locales en funciones: `local nombre_var`.
- Strings con espacios siempre entre comillas dobles: `"$variable"`.
- Para paths, preferí absolutas o relativas desde `$(dirname "$0")`.
- Usá las funciones `log_info`, `log_ok`, `log_warn`, `log_error` definidas en `00_config.sh` — no uses `echo` directo para mensajes al usuario.
- Guardá idempotencia: chequeá si algo ya está configurado antes de aplicarlo (ej: `command -v herramienta &>/dev/null` antes de instalar, `grep -q patron archivo` antes de agregar una línea).
