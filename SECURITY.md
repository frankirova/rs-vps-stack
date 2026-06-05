# Política de Seguridad

## Reportar una Vulnerabilidad

**No abras un issue público** si encontrás una vulnerabilidad de seguridad en este proyecto. Los issues públicos exponen el problema antes de que haya un fix disponible, poniendo en riesgo a todos los usuarios.

### Cómo reportar

Creá un **issue privado** en GitHub:

1. En este repositorio, andá a **Security → Report a vulnerability** (o usá el enlace directo: `https://github.com/<owner>/vps-hardening/security/advisories/new`)
2. Describí el problema con el mayor detalle posible:
   - Módulo o archivo afectado
   - Pasos para reproducir
   - Impacto potencial
   - Sugerencia de fix (si tenés)

### Tiempo de respuesta

| Acción | Plazo estimado |
|--------|----------------|
| Acuse de recibo | 48 horas hábiles |
| Evaluación inicial | 5 días hábiles |
| Fix o plan de mitigación | 14 días hábiles (puede extenderse según complejidad) |

Nos comprometemos a mantenerte informado del progreso en cada etapa.

### Alcance

Este proyecto es un stack de hardening para uso personal/de equipo. Las vulnerabilidades que nos interesan incluyen:

- Escalada de privilegios a través de los scripts
- Exposición de secretos (tokens, contraseñas) en logs o archivos con permisos incorrectos
- Bypass de controles de acceso configurados por los módulos
- Problemas en la generación de claves WireGuard o configuraciones de peers

### Divulgación coordinada

Una vez resuelto el problema, acordamos con el reportante la fecha de divulgación pública. Damos crédito a quien reporta (salvo que prefiera anonimato).
