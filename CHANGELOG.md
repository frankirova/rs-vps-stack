# Registro de cambios

Todos los cambios notables de este proyecto se documentan aquí.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es/1.1.0/) y el proyecto adhiere a [Semantic Versioning](https://semver.org/lang/es/).

---

## [Sin publicar]

### Agregado
- Archivo `LICENSE` con licencia MIT
- `SECURITY.md` con política de divulgación responsable
- `CONTRIBUTING.md` con guía de contribución, convención de módulos y flujo de config
- `CHANGELOG.md` (este archivo)
- Badges de licencia y plataforma en el README
- Tabla de configuración completa agrupada por bloque en el README
- Mapa de dependencias de módulos en el README
- Declaración de idempotencia en el README
- Aclaración del wiring Telegram/Fail2ban en el README
- Explicación de generación de `config.env` en el README
- Documentación del tradeoff de seguridad del módulo 08 en el README
- Entrada de troubleshooting para alertas Telegram silenciosas en el README

---

## [1.0.0] — 2025-01-01

### Agregado
- Módulo 01: hardening SSH con puerto custom y autenticación solo por llave pública
- Módulo 02: actualizaciones automáticas, hardening de kernel y unattended-upgrades
- Módulo 03b: desacoplamiento de Docker de iptables para compatibilidad con UFW
- Módulo 03: firewall UFW con exposición mínima (solo SSH y WireGuard)
- Módulo 04: Fail2ban con baneo automático y notificación Telegram
- Módulo 05: servidor WireGuard hub-and-spoke con generación automática de peers y QR codes
- Módulo 06: DNS recursivo privado con Unbound, accesible solo desde la VPN
- Módulo 07: backups cifrados con Restic, cron diario y verificación de integridad semanal
- Módulo 08: bot de Telegram interactivo para alertas y gestión de actualizaciones
- Arquitectura Zero Trust: todo el acceso a aplicaciones pasa por VPN WireGuard
- Soporte para Ubuntu 22.04 LTS
