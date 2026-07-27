#Requires -Version 5.1
# Módulo compartido para scripts de integración NICE Actimize IFM — módulo Remesas
# Plataforma: Windows Server (PowerShell 5.1+)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Variables de módulo ──────────────────────────────────────────────────────
$script:LogFile = $null
$script:ScriptName = $null
$script:ActimizeEnv = $null

# ── Inicialización ───────────────────────────────────────────────────────────
function Initialize-IFMContext {
    param(
        [Parameter(Mandatory)][ValidateSet('dev','pre','pro')][string]$Environment,
        [string]$ConfigFile = 'C:\Actimize\IFM\config\environments.conf',
        [string]$LogDir     = 'C:\Actimize\IFM\logs',
        [string]$ScriptName = (Split-Path -Leaf $MyInvocation.ScriptName)
    )
    $script:ActimizeEnv = $Environment
    $script:ScriptName  = $ScriptName
    $script:ConfigFile  = $ConfigFile

    $logName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
    $script:LogFile = Join-Path $LogDir "${logName}_$(Get-Date -Format 'yyyyMMdd').log"

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

    Write-IFMLog -Level INFO -Message "=== Inicio ejecución | entorno=$Environment | PID=$PID ==="
}

# ── Logging ──────────────────────────────────────────────────────────────────
function Write-IFMLog {
    param(
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level,
        [string]$Message
    )
    $ts    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $name  = if ($script:ScriptName) { $script:ScriptName } else { 'IFM' }
    $entry = "$ts [$Level] ${name}: $Message"

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red    }
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        'OK'    { Write-Host $entry -ForegroundColor Green  }
        default { Write-Host $entry }
    }

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8
    }
}

Set-Alias -Name Log-Info  -Value { Write-IFMLog -Level INFO  @args }
Set-Alias -Name Log-Warn  -Value { Write-IFMLog -Level WARN  @args }
Set-Alias -Name Log-Error -Value { Write-IFMLog -Level ERROR @args }
Set-Alias -Name Log-OK    -Value { Write-IFMLog -Level OK    @args }

# ── Leer configuración por entorno ───────────────────────────────────────────
function Get-IFMConfig {
    param([Parameter(Mandatory)][string]$Key)

    $env        = $script:ActimizeEnv
    $configFile = $script:ConfigFile
    $inSection  = $false
    $value      = $null

    foreach ($line in [System.IO.File]::ReadLines($configFile)) {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -eq $env)
            continue
        }
        if ($inSection -and $line -match "^${Key}=(.*)$") {
            $value = $Matches[1]
            break
        }
    }

    if ($null -eq $value) {
        throw "Clave '$Key' no encontrada en sección [$env] de $configFile"
    }
    return $value
}

# ── Resolución de secretos desde Vault ───────────────────────────────────────
function Resolve-VaultSecret {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match '^\$\{VAULT:(.+)\}$') {
        $vaultPath = $Matches[1]
        try {
            $result = vault kv get -field=value "secret/$vaultPath" 2>&1
            if ($LASTEXITCODE -ne 0) { throw $result }
            return $result.Trim()
        }
        catch {
            Write-IFMLog -Level ERROR -Message "No se pudo resolver secreto Vault: $vaultPath — $_"
            throw
        }
    }
    return $Value
}

# ── Generar nombre de fichero batch ──────────────────────────────────────────
function New-BatchFilename {
    param(
        [string]$Entity   = 'BANCOES',
        [string]$Sequence = '001'
    )
    $date = Get-Date -Format 'yyyyMMdd'
    $time = Get-Date -Format 'HHmmss'
    return "REMESAS_${Entity}_${date}_${time}_${Sequence}.dat"
}

# ── Calcular hash SHA256 de un fichero ───────────────────────────────────────
function Get-FileSHA256 {
    param([Parameter(Mandatory)][string]$FilePath)
    $hash = Get-FileHash -Algorithm SHA256 -Path $FilePath
    return $hash.Hash.ToLower()
}

# ── Envío por SFTP con reintentos (usando WinSCP .NET Assembly) ──────────────
function Send-SFTPFile {
    param([Parameter(Mandatory)][string]$LocalFile)

    $remoteDir  = Get-IFMConfig 'sftp.remote_path'
    $sftpHost   = Get-IFMConfig 'sftp.host'
    $sftpPort   = [int](Get-IFMConfig 'sftp.port')
    $sftpUser   = Get-IFMConfig 'sftp.user'
    $sftpKey    = Get-IFMConfig 'sftp.key_path'

    $filename   = [System.IO.Path]::GetFileName($LocalFile)
    $ctrlFile   = [System.IO.Path]::ChangeExtension($LocalFile, '.ctrl')
    $sha256     = Get-FileSHA256 -FilePath $LocalFile
    $records    = (Select-String -Path $LocalFile -Pattern '^D\|' | Measure-Object).Count

    # Generar fichero de control
    @(
        "FILENAME=$filename",
        "SHA256=$sha256",
        "RECORDS=$records",
        "TIMESTAMP=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    ) | Set-Content -Path $ctrlFile -Encoding UTF8

    # Cargar WinSCP .NET Assembly (debe estar instalado en el servidor IFM)
    $winScpDll = 'C:\Program Files (x86)\WinSCP\WinSCPnet.dll'
    if (-not (Test-Path $winScpDll)) {
        throw "WinSCP .NET Assembly no encontrado en $winScpDll. Instalar WinSCP en el servidor IFM."
    }
    Add-Type -Path $winScpDll

    $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = $sftpHost
        PortNumber            = $sftpPort
        UserName              = $sftpUser
        SshPrivateKeyPath     = $sftpKey
        GiveUpSecurityAndAcceptAnySshHostKey = $false
    }

    $maxRetries = [int](Get-IFMConfig 'batch.retry_max')
    $delay      = [int](Get-IFMConfig 'batch.retry_delay_seconds')
    $attempt    = 0

    while ($attempt -lt $maxRetries) {
        $attempt++
        Write-IFMLog -Level INFO -Message "SFTP upload intento ${attempt}/${maxRetries}: $filename → ${sftpHost}:${remoteDir}"
        try {
            $session = New-Object WinSCP.Session
            $session.Open($sessionOptions)
            # Subir fichero de datos con nombre temporal
            $session.PutFiles($LocalFile, "${remoteDir}${filename}.tmp") | Out-Null
            # Subir fichero de control
            $session.PutFiles($ctrlFile, "${remoteDir}$([System.IO.Path]::GetFileName($ctrlFile))") | Out-Null
            # Renombrar cuando ambos están completos (operación atómica para el receptor)
            $session.MoveFile("${remoteDir}${filename}.tmp", "${remoteDir}${filename}")
            $session.Dispose()
            Write-IFMLog -Level OK -Message "SFTP upload completado: $filename"
            return $true
        }
        catch {
            try { $session.Dispose() } catch {}
            Write-IFMLog -Level WARN -Message "SFTP upload fallido (intento $attempt): $_. Reintentando en ${delay}s..."
            Start-Sleep -Seconds $delay
            $delay *= 2
        }
    }

    Write-IFMLog -Level ERROR -Message "SFTP upload fallido tras $maxRetries intentos: $filename"
    return $false
}

# ── Validar campos Travel Rule en un registro pipe-delimited ─────────────────
function Test-TravelRuleFields {
    param([Parameter(Mandatory)][string]$Record)

    $fields = $Record -split '\|'
    $valid  = $true

    $checks = @{
        'originator_name'    = $fields[8]
        'originator_account' = $fields[9]
        'originator_country' = $fields[12]
        'beneficiary_name'   = $fields[18]
        'beneficiary_account'= $fields[19]
    }

    foreach ($k in $checks.Keys) {
        if ([string]::IsNullOrWhiteSpace($checks[$k])) {
            Write-IFMLog -Level WARN -Message "Travel Rule: falta $k"
            $valid = $false
        }
    }

    return $valid
}

# ── Obtener JWT de IFM API ───────────────────────────────────────────────────
function Get-IFMToken {
    param(
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )

    $body = "client_id=${ClientId}&client_secret=${ClientSecret}&grant_type=client_credentials"
    $resp = Invoke-RestMethod `
        -Uri         "$ApiBase/auth/token" `
        -Method      POST `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body        $body `
        -TimeoutSec  10

    if (-not $resp.access_token) {
        throw "No se recibió access_token en la respuesta de autenticación IFM"
    }
    return $resp.access_token
}

# ── Notificación de error (email) ────────────────────────────────────────────
function Send-ErrorAlert {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body
    )

    try {
        $alertEmail = Get-IFMConfig 'monitoring.alert_email'
        if ($alertEmail) {
            $smtpServer = 'smtp.bancoes.local'
            $from       = 'ifm-noreply@bancoes.es'
            $envUpper   = $script:ActimizeEnv.ToUpper()
            Send-MailMessage `
                -SmtpServer $smtpServer `
                -From       $from `
                -To         $alertEmail `
                -Subject    "[IFM][$envUpper] ERROR: $Subject" `
                -Body       $Body `
                -Encoding   UTF8 `
                -ErrorAction SilentlyContinue
        }
    }
    catch { <# silencio — no queremos fallar el script por un fallo de alerta #> }

    Write-IFMLog -Level ERROR -Message "NOTIFICACIÓN: $Subject — $Body"
}

# ── Cleanup al salir ─────────────────────────────────────────────────────────
function Invoke-IFMCleanup {
    param([int]$ExitCode = 0)

    if ($ExitCode -ne 0) {
        Send-ErrorAlert `
            -Subject "Fallo en $script:ScriptName" `
            -Body    "exit_code=$ExitCode | entorno=$script:ActimizeEnv | log=$script:LogFile"
    }
    else {
        Write-IFMLog -Level INFO -Message "=== Fin ejecución correcta ==="
    }
}

# ── Exportar funciones públicas ──────────────────────────────────────────────
Export-ModuleMember -Function @(
    'Initialize-IFMContext',
    'Write-IFMLog',
    'Get-IFMConfig',
    'Resolve-VaultSecret',
    'New-BatchFilename',
    'Get-FileSHA256',
    'Send-SFTPFile',
    'Test-TravelRuleFields',
    'Get-IFMToken',
    'Send-ErrorAlert',
    'Invoke-IFMCleanup'
)
