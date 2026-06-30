# =============================================================================
# Script de instalacion de GLPI Agent v1.17 para Windows
# Servidor: http://glpi-service.mundopacifico.cl/
# =============================================================================

$ErrorActionPreference = "Stop"

# --- Variables ---
$GLPI_VERSION = "1.17"
$GLPI_SERVER  = "http://glpi-service.mundopacifico.cl/"
$GLPI_HOST    = "glpi-service.mundopacifico.cl"
$BASE_URL     = "https://github.com/glpi-project/glpi-agent/releases/download/$GLPI_VERSION"
$TMP_DIR      = "$env:TEMP\glpi-agent-install"
$MSI_NAME     = "glpi-agent-$GLPI_VERSION-x64.msi"
$MSI_PATH     = Join-Path $TMP_DIR $MSI_NAME
$LOG_PATH     = Join-Path $TMP_DIR "glpi-agent-install.log"

# --- Funciones de log ---
function Info($msg)      { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Ok($msg)        { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn($msg)      { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function ErrorMsg($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Separador()     { Write-Host "────────────────────────────────────────────" -ForegroundColor Blue }

function Salir-ConError($msg) {
    ErrorMsg $msg
    exit 1
}

# =============================================================================
# VERIFICACION: EJECUCION COMO ADMINISTRADOR
# =============================================================================
function Verificar-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Salir-ConError "Este script debe ejecutarse como Administrador. Abre PowerShell con 'Ejecutar como administrador' e intenta de nuevo."
    }
    Ok "Ejecutandose con privilegios de Administrador."
}

# =============================================================================
# VERIFICACION DE PUERTO 80 (servidor GLPI)
# =============================================================================
function Verificar-Puerto80 {
    Separador
    Info "Verificando acceso al puerto 80 del servidor GLPI..."

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcp.ConnectAsync($GLPI_HOST, 80)
        $completed = $connectTask.Wait(5000)

        if ($completed -and $tcp.Connected) {
            $tcp.Close()
            Ok "Puerto 80 accesible hacia $GLPI_HOST."
            return $true
        } else {
            $tcp.Close()
            Warn "El puerto 80 hacia $GLPI_HOST esta bloqueado o inaccesible."
            return $false
        }
    } catch {
        Warn "El puerto 80 hacia $GLPI_HOST esta bloqueado o inaccesible."
        return $false
    }
}

# =============================================================================
# LIMPIEZA / DESINSTALACION EN CASO DE FALLO POR PUERTO 80
# =============================================================================
function Limpiar-PorPuertoBloqueado {
    Separador
    ErrorMsg "PUERTO 80 BLOQUEADO: no es posible contactar a $GLPI_SERVER"
    Warn "Esto generalmente se debe a un firewall corporativo o reglas de red que bloquean el puerto 80 (HTTP)."
    Warn "Se procedera a eliminar cualquier rastro de instalacion para dejar el equipo limpio."

    Info "Deteniendo servicio GLPI-Agent (si existe)..."
    Stop-Service -Name "GLPI-Agent" -ErrorAction SilentlyContinue
    Set-Service -Name "GLPI-Agent" -StartupType Disabled -ErrorAction SilentlyContinue

    Info "Desinstalando GLPI Agent (si fue instalado)..."
    $producto = Get-WmiObject -Class Win32_Product -Filter "Name LIKE '%GLPI%Agent%'" -ErrorAction SilentlyContinue
    if ($producto) {
        $producto | ForEach-Object { $_.Uninstall() | Out-Null }
    }

    Info "Eliminando carpetas residuales..."
    Remove-Item -Path "C:\Program Files\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Program Files (x86)\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\ProgramData\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue

    Info "Eliminando archivos temporales de instalacion..."
    Remove-Item -Path $TMP_DIR -Recurse -Force -ErrorAction SilentlyContinue

    Separador
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║   INSTALACION ABORTADA: PUERTO 80 BLOQUEADO   ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Solicita a la persona encargada de redes que habilite salida"
    Write-Host "  HTTP (puerto 80) hacia " -NoNewline
    Write-Host "$GLPI_HOST" -ForegroundColor Cyan -NoNewline
    Write-Host " y vuelve a ejecutar el script."
    Separador

    exit 1
}

# =============================================================================
# DETECCION DEL SISTEMA
# =============================================================================
function Detectar-Sistema {
    Separador
    Info "Detectando sistema operativo..."

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $script:OS_NAME    = $os.Caption
    $script:OS_VERSION = $os.Version
    $script:ARCH       = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

    if ($script:ARCH -eq "x86") {
        Salir-ConError "Arquitectura de 32 bits detectada. El instalador MSI de GLPI Agent requiere Windows de 64 bits."
    }

    Ok "Sistema detectado: $OS_NAME"
    Info "Version: $OS_VERSION"
    Info "Arquitectura: $ARCH"
}

# =============================================================================
# DESCARGA E INSTALACION VIA MSI
# =============================================================================
function Instalar-GlpiAgent {
    Info "Descargando instalador MSI oficial de GLPI Agent..."
    $url = "$BASE_URL/$MSI_NAME"

    try {
        Invoke-WebRequest -Uri $url -OutFile $MSI_PATH -UseBasicParsing
    } catch {
        Salir-ConError "Fallo la descarga del instalador MSI: $_"
    }
    Ok "Instalador descargado."

    Info "Instalando GLPI Agent (modo silencioso)..."
    $argumentos = @(
        "/i", "`"$MSI_PATH`"",
        "/quiet", "/norestart",
        "/log", "`"$LOG_PATH`"",
        "SERVER=`"$GLPI_SERVER`"",
        "RUNNOW=1"
    )

    $proceso = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentos -Wait -PassThru

    if ($proceso.ExitCode -ne 0) {
        Salir-ConError "La instalacion via MSI fallo (codigo de salida: $($proceso.ExitCode)). Revisa el log: $LOG_PATH"
    }

    Ok "Instalacion via MSI completada."
}

# =============================================================================
# FLUJO PRINCIPAL
# =============================================================================
Separador
Info "Iniciando instalacion de GLPI Agent v$GLPI_VERSION..."

Verificar-Admin

New-Item -ItemType Directory -Path $TMP_DIR -Force | Out-Null

# Conectividad con servidor GLPI
Info "Verificando conectividad con el servidor GLPI..."
try {
    $resp = Invoke-WebRequest -Uri $GLPI_SERVER -UseBasicParsing -TimeoutSec 5
    Ok "Servidor GLPI accesible."
} catch {
    Warn "No se pudo verificar el servidor (puede ser normal antes del registro)."
}

# Conectividad internet
try {
    Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 | Out-Null
    Ok "Conexion a internet verificada."
} catch {
    Salir-ConError "Sin acceso a internet. Verifica la conexion."
}

# Verificacion de puerto 80 (antes de instalar, igual que en la version Linux)
if (-not (Verificar-Puerto80)) {
    Limpiar-PorPuertoBloqueado
}

Detectar-Sistema

Separador
Info "Iniciando instalacion..."
Instalar-GlpiAgent

# =============================================================================
# VERIFICACION DEL SERVICIO
# =============================================================================
Separador
Info "Verificando estado del servicio GLPI-Agent..."
Start-Sleep -Seconds 3

$servicio = Get-Service -Name "GLPI-Agent" -ErrorAction SilentlyContinue

if ($servicio -and $servicio.Status -eq "Running") {
    Ok "Servicio GLPI-Agent ACTIVO."
} else {
    Warn "Servicio no activo. Intentando iniciar..."
    try {
        Start-Service -Name "GLPI-Agent"
        Start-Sleep -Seconds 2
        $servicio = Get-Service -Name "GLPI-Agent"
        if ($servicio.Status -eq "Running") {
            Ok "Servicio iniciado correctamente."
        } else {
            Salir-ConError "El servicio no pudo iniciarse. Revisa el Visor de Eventos (Event Viewer) > Aplicaciones."
        }
    } catch {
        Salir-ConError "No se pudo iniciar el servicio GLPI-Agent: $_"
    }
}

# =============================================================================
# FORZAR ENVIO DE INVENTARIO
# =============================================================================
Separador
Info "Forzando envio de inventario inicial al servidor..."

$glpiAgentExe = "C:\Program Files\GLPI-Agent\glpi-agent.bat"
if (-not (Test-Path $glpiAgentExe)) {
    $glpiAgentExe = "C:\Program Files\GLPI-Agent\perl\bin\glpi-agent.bat"
}

if (Test-Path $glpiAgentExe) {
    try {
        & $glpiAgentExe --server $GLPI_SERVER --set-forcerun
        Restart-Service -Name "GLPI-Agent" -ErrorAction SilentlyContinue
        Ok "Inventario forzado y servicio reiniciado para ejecutarlo de inmediato."
    } catch {
        Warn "Fallo el envio del inventario. Verificando si el puerto 80 sigue accesible..."
        if (-not (Verificar-Puerto80)) {
            Limpiar-PorPuertoBloqueado
        } else {
            Warn "El puerto 80 esta accesible, pero hubo otra advertencia al enviar el inventario. Revisa el log: $LOG_PATH"
        }
    }
} else {
    Warn "No se encontro el ejecutable de glpi-agent en la ruta esperada. Verifica la instalacion manualmente."
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================
Separador
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║       INSTALACION COMPLETADA CON EXITO       ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Sistema:   $OS_NAME"
Write-Host "  Servidor:  $GLPI_SERVER"
Write-Host "  Version:   $GLPI_VERSION"
Write-Host "  Servicio:  $((Get-Service -Name 'GLPI-Agent' -ErrorAction SilentlyContinue).Status)"
Write-Host ""
Write-Host "  Comandos utiles:"
Write-Host "  Get-Service GLPI-Agent                              -> Estado del servicio" -ForegroundColor Yellow
Write-Host "  Restart-Service GLPI-Agent                          -> Reiniciar el agente" -ForegroundColor Yellow
Write-Host "  & '$glpiAgentExe' --set-forcerun                    -> Forzar inventario" -ForegroundColor Yellow
Write-Host "  Get-EventLog -LogName Application -Source GLPI*     -> Ver logs" -ForegroundColor Yellow
Separador

# Limpieza
Remove-Item -Path $TMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
Info "Archivos temporales eliminados."
