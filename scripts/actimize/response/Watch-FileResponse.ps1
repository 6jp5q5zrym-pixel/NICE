#Requires -Version 5.1
<#
.SYNOPSIS
    Watcher de ficheros de respuesta IFM para testear la opcion C (Fichero).

.DESCRIPTION
    Usa FileSystemWatcher de .NET para detectar en tiempo real cuando IFM-X escribe
    un nuevo fichero .json en la carpeta de respuestas. Al detectarlo, lee el fichero,
    muestra un resumen del contenido y lo mueve a la carpeta de archivado.

    Simula lo que deberia hacer el proceso de polling del Core Banking.

    IFM escribe los ficheros con la convencion:
        RESPONSE_{batchId}_{yyyyMMdd_HHmmss_fff}.json

    Los ficheros .tmp (escritura en curso) se ignoran; IFM los renombra a .json
    cuando el volcado esta completo.

.PARAMETER WatchDir
    Carpeta donde IFM deposita los ficheros de respuesta.
    Debe coincidir con FF_bulkPaymentResponseFileOutputDir en FF_applicationConfig.ini.
    Por defecto C:\Actimize\IFM\responses.

.PARAMETER ArchiveDir
    Carpeta donde mover los ficheros ya procesados.
    Por defecto <WatchDir>\processed.

.PARAMETER MaxFiles
    Numero maximo de ficheros a procesar antes de terminar. 0 = sin limite.
    Por defecto 0.

.PARAMETER StabilizationDelayMs
    Milisegundos a esperar tras detectar el fichero antes de leerlo.
    Evita intentar leer un fichero que aun no ha sido completamente escrito.
    Por defecto 200.

.EXAMPLE
    .\Watch-FileResponse.ps1

.EXAMPLE
    .\Watch-FileResponse.ps1 `
        -WatchDir "C:\Actimize\IFM\responses" `
        -ArchiveDir "C:\Actimize\IFM\responses\processed" `
        -MaxFiles 5
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$WatchDir = 'C:\Actimize\IFM\responses',

    [Parameter()]
    [string]$ArchiveDir = '',

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxFiles = 0,

    [Parameter()]
    [ValidateRange(50, 5000)]
    [int]$StabilizationDelayMs = 200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Valor por defecto de ArchiveDir depende de WatchDir, no se puede calcular en param()
if ([string]::IsNullOrEmpty($ArchiveDir)) {
    $ArchiveDir = Join-Path $WatchDir 'processed'
}

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'ERROR'   { 'Red' }
        'WARN'    { 'Yellow' }
        'OK'      { 'Green' }
        'HIGH'    { 'Red' }
        'REVIEW'  { 'Yellow' }
        default   { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-ResponseSummary {
    param([object]$Response, [string]$FileName)

    $h = $Response.header

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGreen
    Write-Host "  Fichero    : $FileName" -ForegroundColor White
    Write-Host "  Batch ID   : $($h.batchId)" -ForegroundColor White
    Write-Host "  BP Key     : $($h.bulkTransactionKey)" -ForegroundColor White
    Write-Host "  Procesado  : $($h.processingTimestamp)  ($($h.processingTimeMs) ms)" -ForegroundColor White
    Write-Host ("  Entries    : {0} total  |  {1} validas  |  {2} invalidas" -f `
        $h.totalEntries, $h.validEntriesCount, $h.invalidEntriesCount) -ForegroundColor White
    Write-Host ("  Bulk score : {0:N1}  |  Alerta generada: {1}" -f `
        $h.bulkRiskScore, $h.isAlertGenerated) -ForegroundColor White

    if ($h.isAlertGenerated) {
        Write-Host '  [!] ALERTA GENERADA — ACCION REQUERIDA' -ForegroundColor Red
    }

    # Acciones a nivel bulk
    if ($Response.bulkActions -and $Response.bulkActions.Count -gt 0) {
        Write-Host ''
        Write-Host '  ACCIONES BULK:' -ForegroundColor Yellow
        foreach ($a in $Response.bulkActions) {
            Write-Host "    $($a.name) = $($a.value)$(if ($a.originalValue -and $a.originalValue -ne $a.value) { "  (original: $($a.originalValue))" })" -ForegroundColor Yellow
        }
    }

    # Detalle por entry
    Write-Host ''
    Write-Host '  ENTRIES:' -ForegroundColor White

    $blocked  = @()
    $reviewed = @()

    foreach ($e in $Response.entries) {
        $color = switch ($e.riskLevelCode) {
            { $_ -le 2 } { 'Red'    }
            3             { 'Yellow' }
            default       { 'Green'  }
        }

        $actionSuffix = ''
        if ($e.entryActions -and $e.entryActions.Count -gt 0) {
            $actionSuffix = '  [' + (($e.entryActions | ForEach-Object { "$($_.name)=$($_.value)" }) -join ', ') + ']'
        }

        Write-Host ("    [{0}] {1,-30} score={2,5:N1}  {3,-12} -> {4}{5}" -f `
            $e.riskLevelCode,
            $e.transactionId,
            $e.riskScore,
            $e.riskLevelLabel,
            $e.decision,
            $actionSuffix) -ForegroundColor $color

        switch ($e.decision) {
            'BLOCK'  { $blocked  += $e }
            'REVIEW' { $reviewed += $e }
        }
    }

    # Resumen de riesgo
    Write-Host ''
    if ($blocked.Count -gt 0) {
        Write-Host ("  BLOQUEADAS ({0}):" -f $blocked.Count) -ForegroundColor Red
        foreach ($e in $blocked) {
            Write-Host "    -> $($e.transactionId)  riskLevel=$($e.riskLevelCode) ($($e.riskLevelLabel))  score=$($e.riskScore)" -ForegroundColor Red
        }
    }
    if ($reviewed.Count -gt 0) {
        Write-Host ("  EN REVISION ({0}):" -f $reviewed.Count) -ForegroundColor Yellow
        foreach ($e in $reviewed) {
            Write-Host "    -> $($e.transactionId)  riskLevel=$($e.riskLevelCode) ($($e.riskLevelLabel))  score=$($e.riskScore)" -ForegroundColor Yellow
        }
    }
    if ($blocked.Count -eq 0 -and $reviewed.Count -eq 0) {
        Write-Host '  Todas las entries aprobadas sin alertas.' -ForegroundColor Green
    }

    Write-Host ('=' * 70) -ForegroundColor DarkGreen
    Write-Host ''
}

function Invoke-ProcessFile {
    param([string]$FilePath)

    $fileName = Split-Path $FilePath -Leaf
    Write-Log "Procesando fichero: $fileName"

    # Breve espera para asegurar que IFM termino el volcado
    Start-Sleep -Milliseconds $StabilizationDelayMs

    # Verificar que el fichero sigue existiendo (pudo ser movido por otro proceso)
    if (-not (Test-Path $FilePath)) {
        Write-Log "Fichero ya no existe (posiblemente procesado por otro proceso): $fileName" 'WARN'
        return $false
    }

    try {
        $rawJson  = Get-Content -Path $FilePath -Encoding UTF8 -Raw
        $response = $rawJson | ConvertFrom-Json

        Write-ResponseSummary -Response $response -FileName $fileName

        # Mover a carpeta de archivado
        $destPath = Join-Path $ArchiveDir $fileName
        # Si ya existe en archivado (reenvio), renombrar con sufijo
        if (Test-Path $destPath) {
            $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $ext       = [System.IO.Path]::GetExtension($fileName)
            $suffix    = Get-Date -Format '_yyyyMMddHHmmssfff'
            $destPath  = Join-Path $ArchiveDir ($baseName + $suffix + $ext)
        }

        Move-Item -Path $FilePath -Destination $destPath
        Write-Log "Archivado en: $destPath" 'OK'
        return $true
    }
    catch {
        Write-Log "Error procesando $fileName : $($_.Exception.Message)" 'ERROR'
        # Mover a subdirectorio de errores para no bloquear el watcher
        $errorDir = Join-Path $ArchiveDir 'errors'
        if (-not (Test-Path $errorDir)) {
            New-Item -ItemType Directory -Path $errorDir -Force | Out-Null
        }
        try {
            Move-Item -Path $FilePath -Destination (Join-Path $errorDir $fileName) -Force
            Write-Log "Fichero movido a carpeta de errores: $errorDir" 'WARN'
        }
        catch {
            Write-Log "No se pudo mover el fichero de error: $($_.Exception.Message)" 'ERROR'
        }
        return $false
    }
}

# ---------------------------------------------------------------------------
# Setup de directorios
# ---------------------------------------------------------------------------

foreach ($dir in @($WatchDir, $ArchiveDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Log "Directorio creado: $dir"
    }
}

# ---------------------------------------------------------------------------
# Procesar ficheros existentes antes de iniciar el watcher
# (por si IFM escribio ficheros mientras el watcher no estaba activo)
# ---------------------------------------------------------------------------

$existingFiles = Get-ChildItem -Path $WatchDir -Filter '*.json' -File |
                 Where-Object { $_.Name -like 'RESPONSE_*' } |
                 Sort-Object CreationTime

if ($existingFiles.Count -gt 0) {
    Write-Log "Encontrados $($existingFiles.Count) ficheros existentes. Procesando antes de iniciar watcher..."
    foreach ($f in $existingFiles) {
        $processed = Invoke-ProcessFile -FilePath $f.FullName
        if ($processed) {
            $script:filesProcessed++
        }
        if ($MaxFiles -gt 0 -and $script:filesProcessed -ge $MaxFiles) {
            Write-Log "Limite de $MaxFiles ficheros alcanzado."
            exit 0
        }
    }
}

# ---------------------------------------------------------------------------
# Iniciar FileSystemWatcher
# ---------------------------------------------------------------------------

$script:filesProcessed = 0
$script:pendingFiles   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

$watcher                     = New-Object System.IO.FileSystemWatcher
$watcher.Path                = $WatchDir
$watcher.Filter              = 'RESPONSE_*.json'
$watcher.NotifyFilter        = [System.IO.NotifyFilters]::FileName
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $false

# El evento Created se dispara cuando IFM renombra el .tmp a .json
$createdAction = {
    # $Event.SourceEventArgs.FullPath contiene la ruta del nuevo fichero
    $script:pendingFiles.Enqueue($Event.SourceEventArgs.FullPath)
}
$createdHandler = Register-ObjectEvent -InputObject $watcher -EventName Created -Action $createdAction

$watcher.EnableRaisingEvents = $true

Write-Log "=== Watch-FileResponse.ps1 iniciado ==="
Write-Log "WatchDir   : $WatchDir"
Write-Log "ArchiveDir : $ArchiveDir"
Write-Log "MaxFiles   : $(if ($MaxFiles -eq 0) { 'sin limite (Ctrl+C para parar)' } else { $MaxFiles })"
Write-Host ''
Write-Host "  Configura IFM con:" -ForegroundColor White
Write-Host "    FF_bulkPaymentResponseFileOutputDir=$WatchDir\" -ForegroundColor Green
Write-Host ''
Write-Host "  Esperando ficheros RESPONSE_*.json en $WatchDir ..." -ForegroundColor DarkGray
Write-Host "  Presiona Ctrl+C para detener." -ForegroundColor DarkGray
Write-Host ''

try {
    while ($MaxFiles -eq 0 -or $script:filesProcessed -lt $MaxFiles) {
        $filePath = $null
        if ($script:pendingFiles.TryDequeue([ref]$filePath)) {
            $processed = Invoke-ProcessFile -FilePath $filePath
            if ($processed) {
                $script:filesProcessed++
            }
        }
        else {
            Start-Sleep -Milliseconds 200
        }
    }

    Write-Log "Limite de $MaxFiles ficheros alcanzado. Terminando." 'OK'
}
finally {
    $watcher.EnableRaisingEvents = $false
    Unregister-Event -SourceIdentifier $createdHandler.Name -ErrorAction SilentlyContinue
    $watcher.Dispose()
    Write-Log "Watcher detenido. Total ficheros procesados: $($script:filesProcessed)"
}
