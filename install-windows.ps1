# =============================================================================
# Script de instalacion de GLPI Agent v1.17 — WINDOWS
# Servidor: glpi-service.mundopacifico.cl (HTTPS preferido, HTTP fallback)
#
# Caracteristicas:
#  - Seleccion automatica de protocolo: 443 (HTTPS) -> 80 (HTTP)
#  - Deteccion y correccion automatica de DNS incorrecto (via archivo hosts)
#  - Desinstalacion de versiones previas conflictivas
#  - Correccion de configuraciones apuntando al servidor antiguo (iplg)
#  - Instalacion 100% silenciosa (MSI /quiet)
#  - Log completo de la instalacion para diagnostico
#  - Limpieza total del equipo si no hay conectividad con el servidor
# =============================================================================

$ErrorActionPreference = "Continue"

# --- Variables ---
$GLPI_VERSION  = "1.17"
$GLPI_HOST     = "glpi-service.mundopacifico.cl"
$GLPI_IP       = "172.16.2.55"    # IP interna conocida (fallback si el DNS falla)
$GLPI_SERVER   = ""               # se define automaticamente (https:// o http://)
$SERVIDOR_VIEJO = "iplg.mundopacifico.cl"
$BASE_URL      = "https://github.com/glpi-project/glpi-agent/releases/download/$GLPI_VERSION"
$TMP_DIR       = "$env:TEMP\glpi-agent-install"
$MSI_NAME      = "glpi-agent-$GLPI_VERSION-x64.msi"
$MSI_PATH      = Join-Path $TMP_DIR $MSI_NAME
$LOG_PATH      = Join-Path $TMP_DIR "glpi-agent-install.log"
$HOSTS_FILE    = "$env:SystemRoot\System32\drivers\etc\hosts"

# --- Funciones de log ---
function Info($msg)      { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Ok($msg)        { Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn($msg)      { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function ErrorMsg($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Separador()     { Write-Host "------------------------------------------------" -ForegroundColor Blue }

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
        Salir-ConError "Este script debe ejecutarse como Administrador."
    }
    Ok "Ejecutandose con privilegios de Administrador."
}

# =============================================================================
# HELPERS DE CONECTIVIDAD
# =============================================================================
function Puerto-Accesible($hostDestino, $puerto) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcp.ConnectAsync($hostDestino, $puerto)
        $completed = $connectTask.Wait(5000)
        if ($completed -and $tcp.Connected) {
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

# =============================================================================
# CORRECCION AUTOMATICA DE DNS (via archivo hosts)
# Caso real: equipos con doble red (cable corporativo + WiFi externo) resuelven
# el dominio con un DNS equivocado hacia una IP publica inalcanzable.
# =============================================================================
function Corregir-DnsHosts {
    Warn "El nombre $GLPI_HOST no es alcanzable, pero la IP interna $GLPI_IP si."
    Warn "Esto indica un problema de DNS (tipico en equipos con doble red)."
    Info "Fijando la resolucion correcta en el archivo hosts..."

    try {
        # Eliminar entradas previas del host para evitar duplicados
        $contenido = Get-Content $HOSTS_FILE -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch [regex]::Escape($GLPI_HOST) }
        $contenido += "$GLPI_IP  $GLPI_HOST"
        Set-Content -Path $HOSTS_FILE -Value $contenido -Force

        # Limpiar cache DNS para que tome la nueva entrada
        ipconfig /flushdns | Out-Null

        Ok "DNS corregido: $GLPI_HOST -> $GLPI_IP (via archivo hosts)."
        return $true
    } catch {
        Warn "No se pudo modificar el archivo hosts: $_"
        return $false
    }
}

# =============================================================================
# SELECCION AUTOMATICA DE PROTOCOLO Y CORRECCION DE DNS
# Orden: hostname:443 -> hostname:80 -> IP interna (corregir DNS) -> abortar
# =============================================================================
function Seleccionar-Servidor {
    Separador
    Info "Verificando conectividad hacia el servidor GLPI ($GLPI_HOST)..."

    if (Puerto-Accesible $GLPI_HOST 443) {
        $script:GLPI_SERVER = "https://$GLPI_HOST/"
        Ok "Puerto 443 accesible. Se usara HTTPS: $($script:GLPI_SERVER)"
        return $true
    }
    if (Puerto-Accesible $GLPI_HOST 80) {
        $script:GLPI_SERVER = "http://$GLPI_HOST/"
        Ok "Puerto 80 accesible. Se usara HTTP: $($script:GLPI_SERVER)"
        return $true
    }

    Warn "El nombre $GLPI_HOST no responde en 443 ni 80. Probando la IP interna $GLPI_IP..."

    if ((Puerto-Accesible $GLPI_IP 443) -or (Puerto-Accesible $GLPI_IP 80)) {
        Corregir-DnsHosts | Out-Null

        if (Puerto-Accesible $GLPI_HOST 443) {
            $script:GLPI_SERVER = "https://$GLPI_HOST/"
            Ok "Puerto 443 accesible tras correccion DNS. Se usara HTTPS: $($script:GLPI_SERVER)"
            return $true
        }
        if (Puerto-Accesible $GLPI_HOST 80) {
            $script:GLPI_SERVER = "http://$GLPI_HOST/"
            Ok "Puerto 80 accesible tras correccion DNS. Se usara HTTP: $($script:GLPI_SERVER)"
            return $true
        }
    }

    Warn "Sin conectividad hacia $GLPI_HOST (ni por nombre ni por IP interna)."
    return $false
}

function Verificar-ConectividadGlpi {
    return ((Puerto-Accesible $GLPI_HOST 443) -or (Puerto-Accesible $GLPI_HOST 80))
}

# =============================================================================
# LIMPIEZA / DESINSTALACION EN CASO DE FALLO DE CONECTIVIDAD
# =============================================================================
function Limpiar-PorPuertoBloqueado {
    Separador
    ErrorMsg "SIN CONECTIVIDAD: no es posible contactar a $GLPI_HOST ni por 443 (HTTPS) ni por 80 (HTTP)."
    Warn "Esto generalmente se debe a un firewall corporativo o reglas de red."
    Warn "Se procedera a eliminar cualquier rastro de instalacion para dejar el equipo limpio."

    # Datos de red del equipo, utiles para el ticket al area de redes
    Separador
    Info "Datos de red de este equipo (adjuntalos al solicitar la regla de firewall):"
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize | Out-String | Write-Host
    Separador

    Info "Deteniendo servicio GLPI-Agent (si existe)..."
    Stop-Service -Name "GLPI-Agent" -ErrorAction SilentlyContinue
    Set-Service -Name "GLPI-Agent" -StartupType Disabled -ErrorAction SilentlyContinue

    Info "Desinstalando GLPI Agent (si fue instalado)..."
    $productos = Get-CimInstance -ClassName Win32_Product -Filter "Name LIKE '%GLPI%Agent%'" -ErrorAction SilentlyContinue
    if ($productos) {
        $productos | ForEach-Object { $_ | Invoke-CimMethod -MethodName Uninstall -ErrorAction SilentlyContinue | Out-Null }
    }

    Info "Eliminando carpetas residuales..."
    Remove-Item -Path "C:\Program Files\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Program Files (x86)\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\ProgramData\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue

    Info "Eliminando archivos temporales de instalacion..."
    Remove-Item -Path $TMP_DIR -Recurse -Force -ErrorAction SilentlyContinue

    Separador
    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor Red
    Write-Host "   INSTALACION ABORTADA: SIN CONECTIVIDAD AL GLPI " -ForegroundColor Red
    Write-Host "  ================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Solicita a la persona encargada de redes que habilite salida"
    Write-Host "  HTTPS (443) o HTTP (80) hacia " -NoNewline
    Write-Host "$GLPI_HOST ($GLPI_IP)" -ForegroundColor Cyan -NoNewline
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
# LIMPIEZA DE INSTALACIONES PREVIAS CONFLICTIVAS
# =============================================================================
function Limpiar-InstalacionPreviaConflictiva {
    $productos = Get-CimInstance -ClassName Win32_Product -Filter "Name LIKE '%GLPI%Agent%'" -ErrorAction SilentlyContinue

    if ($productos) {
        foreach ($producto in $productos) {
            if ($producto.Version -like "*$GLPI_VERSION*") {
                Info "GLPI Agent $GLPI_VERSION ya se encuentra instalado. Se reinstalara/reconfigurara sobre el."
                continue
            }

            Warn "Instalacion previa de GLPI Agent detectada (version: $($producto.Version)), distinta a la oficial $GLPI_VERSION."
            Warn "Desinstalando para evitar conflictos..."

            Stop-Service -Name "GLPI-Agent" -ErrorAction SilentlyContinue

            try {
                $resultado = $producto | Invoke-CimMethod -MethodName Uninstall
                if ($resultado.ReturnValue -ne 0) {
                    Warn "Uninstall via WMI devolvio codigo $($resultado.ReturnValue), continuando con limpieza manual."
                }
            } catch {
                Warn "No se pudo desinstalar via WMI, continuando con limpieza manual: $_"
            }

            Remove-Item -Path "C:\Program Files\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "C:\Program Files (x86)\GLPI-Agent" -Recurse -Force -ErrorAction SilentlyContinue

            Ok "Instalacion previa eliminada."
        }
    }
}

# =============================================================================
# DESCARGA E INSTALACION VIA MSI
# =============================================================================
function Instalar-GlpiAgent {
    Limpiar-InstalacionPreviaConflictiva

    Info "Descargando instalador MSI oficial de GLPI Agent..."
    $url = "$BASE_URL/$MSI_NAME"

    $descargado = $false
    for ($intento = 1; $intento -le 3; $intento++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $MSI_PATH -UseBasicParsing
            $descargado = $true
            break
        } catch {
            Warn "Intento $intento de descarga fallo: $_"
            Start-Sleep -Seconds 3
        }
    }
    if (-not $descargado) {
        Salir-ConError "Fallo la descarga del instalador MSI tras 3 intentos (verifica acceso a github.com)."
    }
    Ok "Instalador descargado."

    Info "Instalando GLPI Agent (modo silencioso)..."
    $argumentos = @(
        "/i", "`"$MSI_PATH`"",
        "/quiet", "/norestart",
        "/log", "`"$LOG_PATH`"",
        "SERVER=`"$GLPI_SERVER`"",
        "HTTPD_TRUST=`"127.0.0.1`"",
        "RUNNOW=1"
    )

    $proceso = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentos -Wait -PassThru

    # 0 = OK, 3010 = OK pero requiere reinicio (aceptable)
    if ($proceso.ExitCode -ne 0 -and $proceso.ExitCode -ne 3010) {
        Warn "La instalacion via MSI fallo (codigo de salida: $($proceso.ExitCode)). Detalle del log (ultimas 20 lineas):"
        Separador
        if (Test-Path $LOG_PATH) {
            Get-Content $LOG_PATH -Tail 20
        } else {
            Warn "No se genero archivo de log."
        }
        Separador
        Warn "Log completo disponible en: $LOG_PATH (no se eliminara para diagnostico)"
        Salir-ConError "Fallo la instalacion via MSI. Revisa el detalle de arriba."
    }

    Ok "Instalacion via MSI completada."
}

# =============================================================================
# CONFIGURACION POST-INSTALACION
# =============================================================================
function Configurar-Agente {
    Separador
    Info "Verificando configuracion del agente..."

    # Corregir configuraciones apuntando al servidor antiguo (iplg)
    $rutasConfig = @(
        "C:\Program Files\GLPI-Agent\etc",
        "C:\ProgramData\GLPI-Agent"
    )
    foreach ($ruta in $rutasConfig) {
        if (Test-Path $ruta) {
            Get-ChildItem -Path $ruta -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $contenido = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                if ($contenido -and $contenido -match [regex]::Escape($SERVIDOR_VIEJO)) {
                    Warn "Config apuntando al servidor antiguo encontrada en $($_.FullName). Corrigiendo..."
                    $contenido = $contenido -replace "https?://$([regex]::Escape($SERVIDOR_VIEJO))[^`"' ]*", $GLPI_SERVER
                    Set-Content -Path $_.FullName -Value $contenido -Force
                    Ok "Corregida."
                }
            }
        }
    }

    # El registro de Windows tambien guarda la config del agente
    $regPath = "HKLM:\SOFTWARE\GLPI-Agent"
    if (Test-Path $regPath) {
        $serverReg = (Get-ItemProperty -Path $regPath -Name "server" -ErrorAction SilentlyContinue).server
        if ($serverReg -and $serverReg -match [regex]::Escape($SERVIDOR_VIEJO)) {
            Warn "Registro apuntando al servidor antiguo. Corrigiendo..."
            Set-ItemProperty -Path $regPath -Name "server" -Value $GLPI_SERVER
            Ok "Registro corregido."
        }
    }
}

# =============================================================================
# FLUJO PRINCIPAL
# =============================================================================
Separador
Info "Iniciando instalacion de GLPI Agent v$GLPI_VERSION..."

Verificar-Admin
New-Item -ItemType Directory -Path $TMP_DIR -Force | Out-Null

# Iniciar transcripcion completa de la ejecucion (log para diagnostico)
$transcriptPath = Join-Path $TMP_DIR "instalacion-completa.log"
Start-Transcript -Path $transcriptPath -Append -ErrorAction SilentlyContinue | Out-Null

# Conectividad a GitHub (necesaria para la descarga)
try {
    Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 | Out-Null
    Ok "Conexion a internet verificada."
} catch {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    Salir-ConError "Sin acceso a github.com (necesario para descargar el instalador). Verifica la conexion."
}

# Seleccion automatica de protocolo + correccion DNS si aplica
if (-not (Seleccionar-Servidor)) {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    Limpiar-PorPuertoBloqueado
}

Detectar-Sistema

Separador
Info "Iniciando instalacion..."
Instalar-GlpiAgent
Configurar-Agente

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
        Set-Service -Name "GLPI-Agent" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "GLPI-Agent"
        Start-Sleep -Seconds 3
        $servicio = Get-Service -Name "GLPI-Agent"
        if ($servicio.Status -eq "Running") {
            Ok "Servicio iniciado correctamente."
        } else {
            Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
            Salir-ConError "El servicio no pudo iniciarse. Revisa el Visor de Eventos."
        }
    } catch {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        Salir-ConError "No se pudo iniciar el servicio GLPI-Agent: $_"
    }
}

# =============================================================================
# FORZAR ENVIO DE INVENTARIO
# =============================================================================
Separador
Info "Forzando envio de inventario inicial al servidor..."

$inventarioOk = $false

# Metodo 1: endpoint local /now (actua sobre el agente ya corriendo)
Start-Sleep -Seconds 2
try {
    Invoke-WebRequest -Uri "http://127.0.0.1:62354/now" -UseBasicParsing -TimeoutSec 10 | Out-Null
    Ok "Inventario forzado via endpoint local (127.0.0.1:62354/now)."
    $inventarioOk = $true
} catch {
    # Metodo 2: set-forcerun + restart
    $glpiAgentExe = "C:\Program Files\GLPI-Agent\glpi-agent.bat"
    if (-not (Test-Path $glpiAgentExe)) {
        $glpiAgentExe = "C:\Program Files\GLPI-Agent\perl\bin\glpi-agent.bat"
    }
    if (Test-Path $glpiAgentExe) {
        try {
            & $glpiAgentExe --server $GLPI_SERVER --set-forcerun 2>$null
            Restart-Service -Name "GLPI-Agent" -ErrorAction SilentlyContinue
            Ok "Inventario forzado via set-forcerun (se enviara al reiniciar el servicio)."
            $inventarioOk = $true
        } catch { }
    }
}

if (-not $inventarioOk) {
    Warn "No se pudo forzar el inventario inmediato. Verificando conectividad..."
    if (-not (Verificar-ConectividadGlpi)) {
        Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
        Limpiar-PorPuertoBloqueado
    }
    Warn "El servidor esta accesible; el agente enviara el inventario en su proximo ciclo programado."
}

# =============================================================================
# RESUMEN FINAL
# =============================================================================
Separador
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Green
Write-Host "        INSTALACION COMPLETADA CON EXITO          " -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Sistema:   $OS_NAME"
Write-Host "  Servidor:  $GLPI_SERVER"
Write-Host "  Version:   $GLPI_VERSION"
Write-Host "  Servicio:  $((Get-Service -Name 'GLPI-Agent' -ErrorAction SilentlyContinue).Status)"
Write-Host ""
Write-Host "  Comandos utiles:"
Write-Host "  Get-Service GLPI-Agent                       -> Estado del servicio" -ForegroundColor Yellow
Write-Host "  Restart-Service GLPI-Agent                   -> Reiniciar el agente" -ForegroundColor Yellow
Write-Host "  irm http://127.0.0.1:62354/now               -> Forzar inventario inmediato" -ForegroundColor Yellow
Separador

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null

# Limpieza (solo en exito; en fallo los logs quedan en TMP_DIR para diagnostico)
Remove-Item -Path $TMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
Info "Archivos temporales eliminados."
