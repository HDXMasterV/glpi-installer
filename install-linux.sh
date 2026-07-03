#!/bin/bash
# =============================================================================
# Script universal de instalación de GLPI Agent v1.17 — LINUX
# Compatible con: Ubuntu, Debian, RHEL, CentOS, Rocky, Alma, Fedora, etc.
# Servidor: glpi-service.mundopacifico.cl (HTTPS preferido, HTTP fallback)
#
# Características:
#  - Selección automática de protocolo: 443 (HTTPS) → 80 (HTTP)
#  - Detección y corrección automática de DNS incorrecto (vía /etc/hosts)
#  - Purga de instalaciones previas conflictivas (paquetes de distro)
#  - Corrección de configuraciones apuntando al servidor antiguo (iplg)
#  - Manejo de locks de dpkg / unattended-upgrades sin colgarse
#  - Instalación 100% silenciosa (sin diálogos PAM ni debconf)
#  - Log completo de toda la ejecución para diagnóstico
#  - Limpieza total del equipo si no hay conectividad con el servidor
# =============================================================================

set -uo pipefail   # (sin -e: los errores se manejan explícitamente)

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variables ---
GLPI_VERSION="1.17"
GLPI_HOST="glpi-service.mundopacifico.cl"
GLPI_IP="172.16.2.55"          # IP interna conocida del servidor (fallback si el DNS falla)
GLPI_SERVER=""                 # se define automáticamente (https:// o http://)
SERVIDOR_VIEJO="iplg.mundopacifico.cl"
BASE_URL="https://github.com/glpi-project/glpi-agent/releases/download/${GLPI_VERSION}"
TMP_DIR="/tmp/glpi-agent-install"
CFG_FILE="/etc/glpi-agent/conf.d/00-install.cfg"
SCRIPT_LOG="${TMP_DIR}/instalacion-completa.log"

# --- Funciones de log ---
info()      { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()        { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()     { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
error_no_exit() { echo -e "${RED}[ERROR]${NC} $1"; }
separador() { echo -e "${BLUE}────────────────────────────────────────────${NC}"; }

# =============================================================================
# HELPERS DE CONECTIVIDAD
# =============================================================================
puerto_accesible() {
    # $1 = host o IP, $2 = puerto
    if timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        exec 3<&- 2>/dev/null || true
        return 0
    fi
    return 1
}

# =============================================================================
# CORRECCIÓN AUTOMÁTICA DE DNS (vía /etc/hosts)
# Caso real detectado: equipos con doble interfaz (cable corporativo + WiFi
# externo) resuelven el dominio con un DNS equivocado hacia una IP pública
# inalcanzable, cuando el servidor real está en la IP interna.
# =============================================================================
corregir_dns_hosts() {
    warn "El nombre ${GLPI_HOST} no es alcanzable, pero la IP interna ${GLPI_IP} sí."
    warn "Esto indica un problema de DNS (típico en equipos con doble red: cable + WiFi)."
    info "Fijando la resolución correcta en /etc/hosts..."

    # Eliminar entradas previas del host para evitar duplicados o valores viejos
    sed -i "/[[:space:]]${GLPI_HOST}[[:space:]]*$/d" /etc/hosts 2>/dev/null || true
    sed -i "/[[:space:]]${GLPI_HOST}$/d" /etc/hosts 2>/dev/null || true

    echo "${GLPI_IP}  ${GLPI_HOST}" >> /etc/hosts

    # Verificar que ahora resuelve bien
    if getent hosts "${GLPI_HOST}" | grep -q "${GLPI_IP}"; then
        ok "DNS corregido: ${GLPI_HOST} → ${GLPI_IP} (vía /etc/hosts)."
        return 0
    else
        warn "No se pudo verificar la corrección de DNS."
        return 1
    fi
}

# =============================================================================
# SELECCIÓN AUTOMÁTICA DE PROTOCOLO Y CORRECCIÓN DE DNS
# Orden de decisión:
#   1. hostname:443 → HTTPS
#   2. hostname:80  → HTTP
#   3. IP:443 o IP:80 → problema de DNS → corregir /etc/hosts → reintentar
#   4. nada responde → sin conectividad real → limpiar e informar
# =============================================================================
seleccionar_servidor() {
    separador
    info "Verificando conectividad hacia el servidor GLPI (${GLPI_HOST})..."

    # Intento 1: por nombre
    if puerto_accesible "${GLPI_HOST}" 443; then
        GLPI_SERVER="https://${GLPI_HOST}/"
        ok "Puerto 443 accesible. Se usará HTTPS: ${GLPI_SERVER}"
        return 0
    fi
    if puerto_accesible "${GLPI_HOST}" 80; then
        GLPI_SERVER="http://${GLPI_HOST}/"
        ok "Puerto 80 accesible. Se usará HTTP: ${GLPI_SERVER}"
        return 0
    fi

    warn "El nombre ${GLPI_HOST} no responde en 443 ni 80. Probando la IP interna ${GLPI_IP}..."

    # Intento 2: por IP interna (detecta problema de DNS)
    if puerto_accesible "${GLPI_IP}" 443 || puerto_accesible "${GLPI_IP}" 80; then
        corregir_dns_hosts || true

        # Reintentar por nombre tras la corrección
        if puerto_accesible "${GLPI_HOST}" 443; then
            GLPI_SERVER="https://${GLPI_HOST}/"
            ok "Puerto 443 accesible tras corrección DNS. Se usará HTTPS: ${GLPI_SERVER}"
            return 0
        fi
        if puerto_accesible "${GLPI_HOST}" 80; then
            GLPI_SERVER="http://${GLPI_HOST}/"
            ok "Puerto 80 accesible tras corrección DNS. Se usará HTTP: ${GLPI_SERVER}"
            return 0
        fi
    fi

    warn "Sin conectividad hacia ${GLPI_HOST} (ni por nombre ni por IP interna)."
    return 1
}

# Verificación reutilizable post-instalación
verificar_conectividad_glpi() {
    puerto_accesible "${GLPI_HOST}" 443 || puerto_accesible "${GLPI_HOST}" 80
}

# =============================================================================
# LIMPIEZA / DESINSTALACIÓN EN CASO DE FALLO DE CONECTIVIDAD
# =============================================================================
limpiar_por_puerto_bloqueado() {
    separador
    error_no_exit "SIN CONECTIVIDAD: no es posible contactar a ${GLPI_HOST} ni por 443 (HTTPS) ni por 80 (HTTP)."
    warn "Esto generalmente se debe a un firewall corporativo o reglas de red."
    warn "Se procederá a eliminar cualquier rastro de instalación para dejar el equipo limpio."

    # Datos de red del equipo, útiles para el ticket al área de redes
    separador
    info "Datos de red de este equipo (adjúntalos al solicitar la regla de firewall):"
    ip addr 2>/dev/null | grep "inet " | grep -v 127.0.0.1 || true
    ip route 2>/dev/null | head -3 || true
    separador

    info "Deteniendo servicio glpi-agent (si existe)..."
    systemctl stop glpi-agent 2>/dev/null || true
    systemctl disable glpi-agent 2>/dev/null || true

    info "Eliminando paquete glpi-agent (si fue instalado)..."
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge glpi-agent 2>/dev/null || true
    fi
    if command -v yum &>/dev/null; then
        yum remove -y glpi-agent 2>/dev/null || true
    fi
    if command -v dnf &>/dev/null; then
        dnf remove -y glpi-agent 2>/dev/null || true
    fi

    info "Eliminando archivos de configuración y binarios residuales..."
    rm -rf /etc/glpi-agent
    rm -rf /var/lib/glpi-agent
    rm -rf /opt/glpi-agent
    rm -f /usr/local/bin/glpi-agent

    info "Eliminando archivos temporales de instalación..."
    rm -rf "${TMP_DIR}"

    separador
    echo -e "${RED}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║  INSTALACIÓN ABORTADA: SIN CONECTIVIDAD AL GLPI  ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Solicita a la persona encargada de redes que habilite salida"
    echo -e "  HTTPS (443) o HTTP (80) hacia ${BLUE}${GLPI_HOST}${NC} (${GLPI_IP})"
    echo -e "  desde la red de este equipo, y vuelve a ejecutar el script."
    separador

    exit 1
}

# =============================================================================
# DETECCIÓN DEL SISTEMA
# =============================================================================
detectar_sistema() {
    separador
    info "Detectando sistema operativo..."

    ARCH=$(uname -m)
    OS_ID=""
    OS_VERSION=""
    OS_FAMILY=""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-unknown}"
    else
        error "No se pudo detectar el sistema operativo (/etc/os-release no encontrado)."
    fi

    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop|kali|raspbian)
            OS_FAMILY="deb" ;;
        rhel|centos|rocky|almalinux|fedora|ol|amzn)
            OS_FAMILY="rpm" ;;
        *)
            OS_FAMILY="unknown" ;;
    esac

    ok "Sistema detectado: ${OS_NAME}"
    info "Arquitectura: ${ARCH}"
    info "Familia: ${OS_FAMILY}"
}

# =============================================================================
# DETECCIÓN DE DISTROS EOL (sin repositorios activos)
# =============================================================================
es_eol() {
    EOL_UBUNTU=("14.04" "16.04" "18.04" "18.10" "19.04" "19.10" "20.10" "21.04" "21.10" "22.10" "23.04" "23.10")
    if [[ "${OS_ID}" == "ubuntu" ]]; then
        for v in "${EOL_UBUNTU[@]}"; do
            [[ "${OS_VERSION}" == "$v" ]] && return 0
        done
    fi
    if [[ "${OS_ID}" == "centos" ]] && [[ "${OS_VERSION%%.*}" -le 8 ]] 2>/dev/null; then
        return 0
    fi
    return 1
}

# =============================================================================
# ELECCIÓN DEL MÉTODO DE INSTALACIÓN
# =============================================================================
elegir_metodo() {
    separador
    info "Determinando método de instalación óptimo..."

    if [[ "${ARCH}" != "x86_64" ]]; then
        warn "Arquitectura ${ARCH} detectada. Usando AppImage no es posible; se usará el paquete correspondiente si existe."
        # El .deb oficial es 'all' (independiente de arquitectura), sirve en ARM también si hay perl
        if [[ "${OS_FAMILY}" == "deb" ]]; then
            METODO="deb"
        elif [[ "${OS_FAMILY}" == "rpm" ]]; then
            METODO="rpm"
        else
            error "Arquitectura ${ARCH} con distro desconocida: instalación no soportada automáticamente."
        fi
        ok "Método seleccionado: ${METODO}"
        return
    fi

    if es_eol; then
        warn "Distro EOL detectada (${OS_NAME}). Usando AppImage para evitar problemas de dependencias."
        METODO="appimage"
        ok "Método seleccionado: ${METODO}"
        return
    fi

    case "${OS_FAMILY}" in
        deb)
            info "Distro Debian/Ubuntu detectada. Usando paquete .deb oficial (apt-get)."
            METODO="deb"
            ;;
        rpm)
            info "Distro RPM detectada. Usando instalador Perl nativo."
            METODO="rpm"
            ;;
        *)
            warn "Familia de distro desconocida. Usando AppImage como método seguro."
            METODO="appimage"
            ;;
    esac

    ok "Método seleccionado: ${METODO}"
}

# =============================================================================
# LIMPIEZA DE INSTALACIONES PREVIAS CONFLICTIVAS
# (ej: glpi-agent 1.4 del repositorio genérico de Ubuntu)
# =============================================================================
limpiar_instalacion_previa_conflictiva() {
    local version_instalada=""

    if command -v dpkg &>/dev/null; then
        version_instalada=$(dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+glpi-agent[[:space:]]/ {print $3}')
    elif command -v rpm &>/dev/null; then
        version_instalada=$(rpm -q --qf '%{VERSION}' glpi-agent 2>/dev/null | grep -v "not installed" || true)
    fi

    if [[ -n "${version_instalada}" ]]; then
        if [[ "${version_instalada}" == *"${GLPI_VERSION}"* ]]; then
            info "GLPI Agent ${GLPI_VERSION} ya se encuentra instalado. Se reinstalará/reconfigurará sobre él."
            return 0
        fi

        warn "Instalación previa de glpi-agent detectada (versión: ${version_instalada}), distinta a la oficial ${GLPI_VERSION}."
        warn "Purgando para evitar conflictos..."

        systemctl stop glpi-agent 2>/dev/null || true

        if command -v apt-get &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y glpi-agent 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum remove -y glpi-agent 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf remove -y glpi-agent 2>/dev/null || true
        fi

        rm -rf /etc/glpi-agent /var/lib/glpi-agent

        ok "Instalación previa eliminada."
    fi
}

# =============================================================================
# LIBERACIÓN DE DPKG (unattended-upgrades y locks)
# =============================================================================
liberar_dpkg() {
    info "Liberando dpkg de actualizaciones automáticas y locks..."

    # Matar procesos que puedan tener el lock, sin esperar shutdowns graceful
    pkill -9 -f "unattended-upgr" 2>/dev/null || true

    # Detener servicios con timeout para no colgarse jamás
    timeout 5 systemctl stop unattended-upgrades 2>/dev/null || true
    timeout 5 systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    # Matar cualquier proceso restante que tenga algún lock tomado
    local lock_file pid
    for lock_file in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
        if [[ -f "${lock_file}" ]]; then
            pid=$(fuser "${lock_file}" 2>/dev/null | tr -d ' ' || true)
            if [[ -n "${pid}" ]]; then
                kill -9 ${pid} 2>/dev/null || true
            fi
        fi
    done
    sleep 2

    # Eliminar archivos de lock residuales
    rm -f /var/lib/dpkg/lock-frontend \
          /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock 2>/dev/null || true

    # Reparar posibles estados a medias de dpkg
    dpkg --configure -a 2>/dev/null || true

    ok "dpkg disponible."
}

# =============================================================================
# INSTALACIÓN VIA .DEB DIRECTO (Ubuntu/Debian)
# =============================================================================
instalar_deb() {
    local install_log="${TMP_DIR}/deb-install.log"
    local deb_file="${TMP_DIR}/glpi-agent.deb"
    local url="${BASE_URL}/glpi-agent_${GLPI_VERSION}-1_all.deb"

    # Modo 100% silencioso: ningún paquete puede lanzar diálogos (PAM, debconf, etc.)
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export UCF_FORCE_CONFFOLD=1

    liberar_dpkg
    limpiar_instalacion_previa_conflictiva

    DEBIAN_FRONTEND=noninteractive apt-get install -f -y >>"${install_log}" 2>&1 || true

    info "Descargando paquete .deb oficial de GLPI Agent..."
    curl -fL --retry 3 --retry-delay 3 --progress-bar "${url}" -o "${deb_file}" \
        || error "Falló la descarga del paquete .deb (verifica acceso a github.com)."
    ok "Paquete descargado."

    info "Instalando via apt-get (resuelve dependencias automáticamente)..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
        -o Dpkg::Options::="--force-confold" \
        -o Dpkg::Options::="--force-confmiss" \
        "${deb_file}" 2>&1 | tee -a "${install_log}"; then
        ok "Instalación via .deb completada."
    else
        warn "apt-get falló. Intentando con dpkg + reparación de dependencias..."
        DEBIAN_FRONTEND=noninteractive dpkg -i --force-confold --force-confmiss "${deb_file}" 2>&1 | tee -a "${install_log}" || true
        DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1 | tee -a "${install_log}" || true

        if dpkg -l 2>/dev/null | grep -q "^ii[[:space:]]*glpi-agent"; then
            ok "GLPI Agent instalado correctamente (via dpkg + fix de dependencias)."
        else
            warn "Detalle del error (últimas 20 líneas):"
            separador
            tail -n 20 "${install_log}" 2>/dev/null || true
            separador
            warn "Log completo: ${install_log} (no se eliminará para diagnóstico)"
            error "Falló la instalación del paquete .deb."
        fi
    fi
}

# =============================================================================
# INSTALACIÓN VIA INSTALADOR PERL (RHEL, CentOS, Rocky, Alma, Fedora)
# =============================================================================
instalar_perl_rpm() {
    if ! command -v perl &>/dev/null; then
        info "Perl no encontrado. Instalando..."
        yum install -y perl 2>/dev/null || dnf install -y perl 2>/dev/null \
            || error "No se pudo instalar Perl."
    fi

    limpiar_instalacion_previa_conflictiva

    info "Descargando instalador Perl oficial..."
    local url="${BASE_URL}/glpi-agent-${GLPI_VERSION}-linux-installer.pl"
    local dest="${TMP_DIR}/glpi-install.pl"
    local install_log="${TMP_DIR}/perl-install.log"

    curl -fL --retry 3 --retry-delay 3 --progress-bar "${url}" -o "${dest}" \
        || error "Falló la descarga del instalador Perl."
    ok "Instalador descargado."

    info "Instalando via Perl (RPM)..."
    if perl "${dest}" --install --server "${GLPI_SERVER}" 2>&1 | tee "${install_log}"; then
        ok "Instalación via Perl completada."
    else
        warn "Detalle del error (últimas 20 líneas):"
        separador
        tail -n 20 "${install_log}" 2>/dev/null || true
        separador
        warn "Log completo: ${install_log} (no se eliminará para diagnóstico)"
        error "Falló la instalación via Perl."
    fi
}

# =============================================================================
# INSTALACIÓN VIA APPIMAGE (distros EOL o desconocidas)
# =============================================================================
instalar_appimage() {
    info "Descargando AppImage (autocontenido, sin dependencias)..."
    local url="${BASE_URL}/glpi-agent-${GLPI_VERSION}-x86_64.AppImage"
    local dest="${TMP_DIR}/glpi-agent.AppImage"
    local install_log="${TMP_DIR}/appimage-install.log"

    curl -fL --retry 3 --retry-delay 3 --progress-bar "${url}" -o "${dest}" \
        || error "Falló la descarga del AppImage."

    chmod +x "${dest}"
    ok "AppImage descargado."

    info "Instalando via AppImage..."
    if "${dest}" --install --server "${GLPI_SERVER}" 2>&1 | tee "${install_log}"; then
        ok "Instalación via AppImage completada."
    else
        warn "Detalle del error (últimas 20 líneas):"
        separador
        tail -n 20 "${install_log}" 2>/dev/null || true
        separador
        error "Falló la instalación via AppImage."
    fi
}

# =============================================================================
# CONFIGURACIÓN POST-INSTALACIÓN
# =============================================================================
configurar_agente() {
    separador
    info "Aplicando configuración del agente..."

    # Red de seguridad: si falta el archivo de configuración principal
    # (caso real: dpkg no restaura conffiles borrados manualmente en el pasado),
    # crearlo con el mínimo necesario para que el agente arranque y lea conf.d
    if [[ ! -f /etc/glpi-agent/agent.cfg ]]; then
        warn "Falta /etc/glpi-agent/agent.cfg (probable instalación previa dañada). Creándolo..."
        mkdir -p /etc/glpi-agent/conf.d
        cat > /etc/glpi-agent/agent.cfg <<'EOF'
# Archivo de configuración principal de GLPI Agent
# (regenerado por el script de instalación)
# La configuración específica está en conf.d/
include "conf.d/"
EOF
        ok "agent.cfg regenerado."
    fi

    # Corregir configuraciones apuntando al servidor GLPI antiguo (iplg)
    if grep -rq "${SERVIDOR_VIEJO}" /etc/glpi-agent/ 2>/dev/null; then
        warn "Se detectó configuración apuntando al servidor antiguo (${SERVIDOR_VIEJO}). Corrigiendo..."
        grep -rl "${SERVIDOR_VIEJO}" /etc/glpi-agent/ 2>/dev/null | while read -r archivo_viejo; do
            sed -i "s|https\?://${SERVIDOR_VIEJO}[^\"' ]*|${GLPI_SERVER}|g" "${archivo_viejo}"
        done
        ok "Configuraciones antiguas corregidas."
    fi

    # Configuración principal: servidor + trust localhost (permite forzar
    # inventario desde http://localhost:62354/now sin token)
    mkdir -p "$(dirname "${CFG_FILE}")"
    cat > "${CFG_FILE}" <<EOF
server = ${GLPI_SERVER}
httpd-trust = 127.0.0.1
EOF
    ok "Servidor configurado: ${GLPI_SERVER}"
}

# =============================================================================
# VERIFICACIÓN DEL SERVICIO
# =============================================================================
verificar_servicio() {
    separador
    info "Verificando estado del servicio glpi-agent..."

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable glpi-agent 2>/dev/null || true
    systemctl restart glpi-agent 2>/dev/null || true
    sleep 3

    if systemctl is-active --quiet glpi-agent; then
        ok "Servicio glpi-agent ACTIVO."
        return 0
    fi

    warn "Servicio no activo. Intentando iniciar..."
    systemctl start glpi-agent 2>/dev/null || true
    sleep 3

    if systemctl is-active --quiet glpi-agent; then
        ok "Servicio iniciado correctamente."
        return 0
    fi

    warn "El servicio no pudo iniciarse. Últimas líneas del log del servicio:"
    separador
    journalctl -u glpi-agent -n 15 --no-pager 2>/dev/null || true
    separador
    error "El servicio glpi-agent no pudo iniciarse. Revisa el log de arriba."
}

# =============================================================================
# ENVÍO DE INVENTARIO INICIAL
# =============================================================================
enviar_inventario() {
    separador
    info "Forzando envío de inventario inicial al servidor..."

    # Método 1: endpoint local /now (actúa sobre el agente ya corriendo)
    sleep 2
    if curl -sf --max-time 10 "http://127.0.0.1:62354/now" -o /dev/null 2>/dev/null; then
        ok "Inventario forzado via endpoint local (127.0.0.1:62354/now)."
        return 0
    fi

    # Método 2: set-forcerun + restart
    if glpi-agent --server "${GLPI_SERVER}" --set-forcerun 2>/dev/null; then
        systemctl restart glpi-agent 2>/dev/null || true
        ok "Inventario forzado via set-forcerun (se enviará al reiniciar el servicio)."
        return 0
    fi

    warn "No se pudo forzar el inventario inmediato. Verificando conectividad..."
    verificar_conectividad_glpi || limpiar_por_puerto_bloqueado
    warn "El servidor está accesible; el agente enviará el inventario en su próximo ciclo programado."
}

# =============================================================================
# VERIFICACIONES PREVIAS
# =============================================================================
separador
info "Iniciando instalación de GLPI Agent v${GLPI_VERSION}..."

# Root
if [[ $EUID -ne 0 ]]; then
    error "Ejecuta el script como root: sudo $0"
fi

# Directorio temporal + log completo de ejecución
mkdir -p "${TMP_DIR}"
exec > >(tee -a "${SCRIPT_LOG}") 2>&1

# Herramientas mínimas
command -v curl &>/dev/null || error "curl no está instalado. Instálalo primero (apt install curl / yum install curl)."

# Conectividad a GitHub (necesaria para descargar el instalador)
if ! curl -sf --max-time 10 "https://github.com" -o /dev/null; then
    error "Sin acceso a github.com (necesario para descargar el instalador). Verifica la conexión a internet."
fi
ok "Conexión a internet verificada."

# =============================================================================
# FLUJO PRINCIPAL
# =============================================================================
seleccionar_servidor || limpiar_por_puerto_bloqueado

detectar_sistema
elegir_metodo

separador
info "Iniciando instalación (método: ${METODO})..."

case "${METODO}" in
    appimage) instalar_appimage ;;
    deb)      instalar_deb ;;
    rpm)      instalar_perl_rpm ;;
    *)        error "Método de instalación desconocido." ;;
esac

ok "Instalación completada."

configurar_agente
verificar_servicio
enviar_inventario

# =============================================================================
# RESUMEN FINAL
# =============================================================================
separador
echo -e "${GREEN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       INSTALACIÓN COMPLETADA CON ÉXITO       ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BLUE}Sistema:${NC}   ${OS_NAME}"
echo -e "  ${BLUE}Método:${NC}    ${METODO}"
echo -e "  ${BLUE}Servidor:${NC}  ${GLPI_SERVER}"
echo -e "  ${BLUE}Versión:${NC}   ${GLPI_VERSION}"
echo -e "  ${BLUE}Servicio:${NC}  $(systemctl is-active glpi-agent 2>/dev/null)"
echo ""
echo -e "  Comandos útiles:"
echo -e "  ${YELLOW}systemctl status glpi-agent${NC}          → Estado del servicio"
echo -e "  ${YELLOW}systemctl restart glpi-agent${NC}         → Reiniciar el agente"
echo -e "  ${YELLOW}curl http://127.0.0.1:62354/now${NC}      → Forzar inventario inmediato"
echo -e "  ${YELLOW}journalctl -u glpi-agent -f${NC}          → Logs en tiempo real"
separador

# Limpieza (solo en éxito; en fallo los logs quedan en TMP_DIR para diagnóstico)
rm -rf "${TMP_DIR}"
info "Archivos temporales eliminados."
