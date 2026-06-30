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
separador() { echo -e "${BLUE}────────────────────────────────────────────${NC}"; }

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
        deb|rpm)
            info "Distro moderna con repositorios activos. Usando instalador Perl nativo."
            METODO="perl"
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
# INSTALACIÓN VIA INSTALADOR PERL (distros modernas DEB/RPM)
# =============================================================================
instalar_perl() {
    # Verificar que perl esté disponible
    if ! command -v perl &>/dev/null; then
        info "Perl no encontrado. Instalando..."
        if [[ "${OS_FAMILY}" == "deb" ]]; then
            apt-get install -y perl 2>/dev/null || error "No se pudo instalar Perl."
        elif [[ "${OS_FAMILY}" == "rpm" ]]; then
            yum install -y perl 2>/dev/null || dnf install -y perl 2>/dev/null \
                || error "No se pudo instalar Perl."
        fi
    fi

    info "Descargando instalador Perl oficial..."
    local url="${BASE_URL}/glpi-agent-${GLPI_VERSION}-linux-installer.pl"
    local dest="${TMP_DIR}/glpi-install.pl"

    curl -fL --progress-bar "${url}" -o "${dest}" \
        || error "Falló la descarga del instalador Perl."

    ok "Instalador descargado."
    info "Instalando via Perl (detecta DEB o RPM automáticamente)..."
    perl "${dest}" --install --server "${GLPI_SERVER}" --runnow \
        || error "Falló la instalación via Perl."
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
detectar_sistema
elegir_metodo

separador
info "Iniciando instalación (método: ${METODO})..."

case "${METODO}" in
    appimage) instalar_appimage ;;
    perl)     instalar_perl ;;
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
glpi-agent --server "${GLPI_SERVER}" --runnow && ok "Inventario enviado." \
    || warn "Hubo advertencias al enviar el inventario. Revisa los logs."

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
echo -e "  ${YELLOW}glpi-agent --runnow${NC}             → Forzar inventario manual"
echo -e "  ${YELLOW}journalctl -u glpi-agent -f${NC}     → Logs en tiempo real"
separador

# Limpieza
rm -rf "${TMP_DIR}"
info "Archivos temporales eliminados."
