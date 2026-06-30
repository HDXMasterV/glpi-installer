#!/bin/bash
# =============================================================================
# Script universal de instalación de GLPI Agent v1.17
# Compatible con: Ubuntu, Debian, RHEL, CentOS, Rocky, Alma, Fedora, etc.
# Servidor: http://glpi-service.mundopacifico.cl/
# =============================================================================

set -euo pipefail

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Variables ---
GLPI_VERSION="1.17"
GLPI_SERVER="http://glpi-service.mundopacifico.cl/"
BASE_URL="https://github.com/glpi-project/glpi-agent/releases/download/${GLPI_VERSION}"
TMP_DIR="/tmp/glpi-agent-install"
CFG_FILE="/etc/glpi-agent/conf.d/00-install.cfg"

# --- Funciones de log ---
info()      { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()        { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()      { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()     { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
error_no_exit() { echo -e "${RED}[ERROR]${NC} $1"; }
separador() { echo -e "${BLUE}────────────────────────────────────────────${NC}"; }

# =============================================================================
# VERIFICACIÓN DE PUERTO 80 (servidor GLPI)
# =============================================================================
verificar_puerto_80() {
    separador
    info "Verificando acceso al puerto 80 del servidor GLPI..."

    local host="glpi-service.mundopacifico.cl"

    # Probamos conexión directa al puerto 80 usando /dev/tcp (bash puro, sin dependencias)
    if timeout 5 bash -c "exec 3<>/dev/tcp/${host}/80" 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        exec 3<&- 2>/dev/null || true
        ok "Puerto 80 accesible hacia ${host}."
        return 0
    else
        warn "El puerto 80 hacia ${host} está bloqueado o inaccesible."
        return 1
    fi
}

# =============================================================================
# LIMPIEZA / DESINSTALACIÓN EN CASO DE FALLO POR PUERTO 80
# =============================================================================
limpiar_por_puerto_bloqueado() {
    separador
    error_no_exit "PUERTO 80 BLOQUEADO: no es posible contactar a ${GLPI_SERVER}"
    warn "Esto generalmente se debe a un firewall corporativo o reglas de red que bloquean el puerto 80 (HTTP)."
    warn "Se procederá a eliminar cualquier rastro de instalación para dejar el equipo limpio."

    info "Deteniendo servicio glpi-agent (si existe)..."
    systemctl stop glpi-agent 2>/dev/null || true
    systemctl disable glpi-agent 2>/dev/null || true

    info "Eliminando paquete glpi-agent (si fue instalado)..."
    if command -v apt-get &>/dev/null; then
        apt-get remove -y --purge glpi-agent 2>/dev/null || true
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
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║   INSTALACIÓN ABORTADA: PUERTO 80 BLOQUEADO   ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Solicita a la persona encargada de redes que habilite salida"
    echo -e "  HTTP (puerto 80) hacia ${BLUE}glpi-service.mundopacifico.cl${NC} y vuelve a ejecutar el script."
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

    # Determinar familia
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
    # Ubuntu EOL conocidas
    EOL_UBUNTU=("14.04" "16.04" "18.10" "19.04" "19.10" "20.10" "21.04" "21.10" "22.10" "23.04" "23.10")
    if [[ "${OS_ID}" == "ubuntu" ]]; then
        for v in "${EOL_UBUNTU[@]}"; do
            if [[ "${OS_VERSION}" == "$v" ]]; then
                return 0
            fi
        done
    fi

    # CentOS 8 y anteriores también son EOL
    if [[ "${OS_ID}" == "centos" && "${OS_VERSION}" -le 8 ]] 2>/dev/null; then
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
        warn "Arquitectura ${ARCH} detectada. Solo el instalador Perl es compatible."
        METODO="perl"
        return
    fi

    if es_eol; then
        warn "Distro EOL detectada (${OS_NAME}). Usando AppImage para evitar problemas de dependencias."
        METODO="appimage"
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
# INSTALACIÓN VIA APPIMAGE
# =============================================================================
instalar_appimage() {
    info "Descargando AppImage (autocontenido, sin dependencias)..."
    local url="${BASE_URL}/glpi-agent-${GLPI_VERSION}-x86_64.AppImage"
    local dest="${TMP_DIR}/glpi-agent.AppImage"

    curl -fL --progress-bar "${url}" -o "${dest}" \
        || error "Falló la descarga del AppImage."

    chmod +x "${dest}"
    ok "AppImage descargado."

    info "Instalando via AppImage..."
    "${dest}" --install --server "${GLPI_SERVER}" --runnow \
        || error "Falló la instalación via AppImage."
}

# =============================================================================
# LIMPIEZA DE INSTALACIONES PREVIAS CONFLICTIVAS
# =============================================================================
# Algunos equipos tienen glpi-agent instalado desde el repositorio genérico
# de la distro (ej. Ubuntu universe, versión 1.4 u otra antigua), lo que
# choca con el instalador oficial 1.17 y hace fallar la instalación con un
# mensaje genérico "Failed to install glpi-agent".
limpiar_instalacion_previa_conflictiva() {
    local version_instalada=""

    if [[ "${OS_FAMILY}" == "deb" ]] && command -v dpkg &>/dev/null; then
        version_instalada=$(dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+glpi-agent[[:space:]]/ {print $3}')
    elif [[ "${OS_FAMILY}" == "rpm" ]] && command -v rpm &>/dev/null; then
        version_instalada=$(rpm -q --qf '%{VERSION}' glpi-agent 2>/dev/null || true)
    fi

    if [[ -n "${version_instalada}" ]]; then
        warn "Se detectó una instalación previa de glpi-agent (versión: ${version_instalada}), distinta a la oficial ${GLPI_VERSION}."
        warn "Esto suele venir del repositorio estándar de la distro y choca con el instalador oficial. Purgando..."

        systemctl stop glpi-agent 2>/dev/null || true

        if [[ "${OS_FAMILY}" == "deb" ]]; then
            apt-get remove --purge -y glpi-agent 2>/dev/null || true
            apt-get autoremove -y 2>/dev/null || true
        elif [[ "${OS_FAMILY}" == "rpm" ]]; then
            yum remove -y glpi-agent 2>/dev/null || dnf remove -y glpi-agent 2>/dev/null || true
        fi

        rm -rf /etc/glpi-agent /var/lib/glpi-agent

        ok "Instalación previa eliminada. Continuando con la instalación oficial ${GLPI_VERSION}."
    fi
}

# =============================================================================
# INSTALACIÓN VIA .DEB DIRECTO (Ubuntu/Debian)
# Más confiable que el instalador Perl: apt-get resuelve dependencias
# automáticamente y no tiene conflictos con paquetes previos del sistema.
# =============================================================================
instalar_deb() {
    local install_log="${TMP_DIR}/deb-install.log"
    local deb_file="${TMP_DIR}/glpi-agent.deb"
    local url="${BASE_URL}/glpi-agent_${GLPI_VERSION}-1_all.deb"

    # Forzar modo completamente silencioso: ningún paquete puede lanzar
    # diálogos interactivos (como el de PAM), sin importar lo que pida.
    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export UCF_FORCE_CONFFOLD=1  # conservar archivos locales si hay conflicto

    # Detener unattended-upgrades ANTES de cualquier operación dpkg.
    info "Deteniendo actualizaciones automáticas para liberar dpkg..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    # Matar directamente cualquier proceso que tenga el lock tomado
    for lock_file in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
        if [[ -f "${lock_file}" ]]; then
            local pid
            pid=$(fuser "${lock_file}" 2>/dev/null || true)
            if [[ -n "${pid}" ]]; then
                warn "Proceso ${pid} tiene el lock ${lock_file}. Terminando..."
                kill -9 "${pid}" 2>/dev/null || true
                sleep 2
            fi
        fi
    done

    # Eliminar los archivos de lock directamente
    rm -f /var/lib/dpkg/lock-frontend \
          /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock \
          /var/cache/debconf/config.dat-old 2>/dev/null || true

    ok "dpkg disponible."

    # Limpiar cualquier instalación previa conflictiva
    limpiar_instalacion_previa_conflictiva

    # Reparar posibles estados rotos de dpkg antes de instalar
    info "Verificando estado de dpkg..."
    dpkg --configure -a 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>/dev/null || true

    info "Descargando paquete .deb oficial de GLPI Agent..."
    curl -fL --progress-bar "${url}" -o "${deb_file}" \
        || error "Falló la descarga del paquete .deb."
    ok "Paquete descargado."

    info "Instalando via apt-get (resuelve dependencias automáticamente)..."
    # Preconfigurar debconf para evitar cualquier diálogo interactivo
    # (como el de PAM preguntando si sobreescribir archivos locales)
    echo 'libpam-runtime libpam-runtime/override boolean false' | debconf-set-selections 2>/dev/null || true
    echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections 2>/dev/null || true

    if DEBIAN_FRONTEND=noninteractive apt-get install -y "${deb_file}" 2>&1 | tee "${install_log}"; then
        ok "Instalación via .deb completada."
    else
        echo ""
        warn "Instalación via apt-get falló. Intentando con dpkg + fix de dependencias..."
        separador
        DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true dpkg -i "${deb_file}" 2>&1 | tee -a "${install_log}" || true
        DEBIAN_FRONTEND=noninteractive apt-get install -f -y 2>&1 | tee -a "${install_log}" || true
        separador

        # Verificar si quedó instalado a pesar del error
        if dpkg -l 2>/dev/null | grep -q "^ii[[:space:]]*glpi-agent"; then
            ok "GLPI Agent instalado correctamente (via dpkg + fix de dependencias)."
        else
            warn "Detalle del error (últimas 20 líneas):"
            separador
            tail -n 20 "${install_log}" || true
            separador
            warn "Log completo disponible en: ${install_log} (no se eliminará para diagnóstico)"
            error "Falló la instalación del paquete .deb. Revisa el detalle de arriba."
        fi
    fi

    # Aplicar configuración del servidor GLPI
    info "Aplicando configuración del servidor GLPI..."
    mkdir -p /etc/glpi-agent/conf.d
    cat > /etc/glpi-agent/conf.d/00-install.cfg <<EOF
server = ${GLPI_SERVER}
EOF
    ok "Configuración aplicada."
}

# =============================================================================
# INSTALACIÓN VIA INSTALADOR PERL (solo para RPM: RHEL, CentOS, Rocky, etc.)
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

    curl -fL --progress-bar "${url}" -o "${dest}" \
        || error "Falló la descarga del instalador Perl."

    ok "Instalador descargado."
    info "Instalando via Perl (RPM)..."

    local install_log="${TMP_DIR}/perl-install.log"

    if perl "${dest}" --install --server "${GLPI_SERVER}" --runnow 2>&1 | tee "${install_log}"; then
        ok "Instalación via Perl completada."
    else
        warn "La instalación via Perl falló. Detalle del error (últimas 20 líneas):"
        separador
        tail -n 20 "${install_log}" || true
        separador
        warn "Log completo disponible en: ${install_log} (no se eliminará para diagnóstico)"
        error "Falló la instalación via Perl. Revisa el detalle de arriba."
    fi
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

# Crear directorio temporal
mkdir -p "${TMP_DIR}"

# Conectividad con servidor GLPI
info "Verificando conectividad con el servidor GLPI..."
if curl -sf --max-time 5 "${GLPI_SERVER}" -o /dev/null; then
    ok "Servidor GLPI accesible."
else
    warn "No se pudo verificar el servidor (puede ser normal antes del registro)."
fi

# Conectividad internet
if ! curl -sf --max-time 10 "https://github.com" -o /dev/null; then
    error "Sin acceso a internet. Verifica la conexión."
fi
ok "Conexión a internet verificada."

# =============================================================================
# FLUJO PRINCIPAL
# =============================================================================
verificar_puerto_80 || limpiar_por_puerto_bloqueado

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

# =============================================================================
# VERIFICACIÓN DEL SERVICIO
# =============================================================================
separador
info "Verificando estado del servicio glpi-agent..."
sleep 3

if systemctl is-active --quiet glpi-agent; then
    ok "Servicio glpi-agent ACTIVO."
else
    warn "Servicio no activo. Intentando iniciar..."
    systemctl start glpi-agent || error "No se pudo iniciar el servicio. Revisa: journalctl -u glpi-agent -n 50"
    sleep 2
    systemctl is-active --quiet glpi-agent \
        && ok "Servicio iniciado correctamente." \
        || error "El servicio no pudo iniciarse."
fi

# Verificar configuración
info "Verificando configuración del servidor en ${CFG_FILE}..."
if [[ -f "${CFG_FILE}" ]] && grep -q "glpi-service.mundopacifico.cl" "${CFG_FILE}"; then
    ok "Servidor configurado correctamente."
else
    warn "No se encontró el servidor en la configuración. Verifica ${CFG_FILE}"
fi

# Enviar inventario
separador
info "Enviando inventario inicial al servidor..."
if glpi-agent --server "${GLPI_SERVER}" --set-forcerun; then
    systemctl restart glpi-agent 2>/dev/null || true
    ok "Inventario forzado y servicio reiniciado para ejecutarlo de inmediato."
else
    warn "Falló el envío del inventario. Verificando si el puerto 80 sigue accesible..."
    verificar_puerto_80 || limpiar_por_puerto_bloqueado
    warn "El puerto 80 está accesible, pero hubo otra advertencia al enviar el inventario. Revisa los logs."
fi

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
echo -e "  ${BLUE}Servicio:${NC}  $(systemctl is-active glpi-agent)"
echo ""
echo -e "  Comandos útiles:"
echo -e "  ${YELLOW}systemctl status glpi-agent${NC}     → Estado del servicio"
echo -e "  ${YELLOW}systemctl restart glpi-agent${NC}    → Reiniciar el agente"
echo -e "  ${YELLOW}glpi-agent --set-forcerun${NC}       → Forzar inventario en próximo arranque"
echo -e "  ${YELLOW}journalctl -u glpi-agent -f${NC}     → Logs en tiempo real"
separador

# Limpieza
rm -rf "${TMP_DIR}"
info "Archivos temporales eliminados."
