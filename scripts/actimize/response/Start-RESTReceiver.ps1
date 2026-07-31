#Requires -Version 5.1
<#
.SYNOPSIS
    Levanta un servidor HTTP local para testear la opcion B (REST) de respuesta IFM.

.DESCRIPTION
    Usa HttpListener de .NET (no requiere IIS ni privilegios de administrador si se
    registra el prefijo primero con netsh). Escucha en el endpoint configurado, recibe
    los POST de IFM-X, loguea el JSON y devuelve HTTP 200 con {"status":"received"}.

    Para que IFM apunte a este receiver durante las pruebas, configurar en
    FF_applicationConfig.ini:
        FF_bulkPaymentRESTEndpoint=http://localhost:<Port>/api/ifm/bulk-response

    NOTA: Si PowerShell no es administrador, ejecutar una vez:
        netsh http add urlacl url=http://+:<Port>/api/ifm/bulk-response/ user=<TU_USUARIO>

.PARAMETER Port
    Puerto donde escuchar. Por defecto 8080.

.PARAMETER LogDir
    Directorio donde guardar los logs de peticiones recibidas.
    Por defecto C:\Actimize\IFM\test\rest-logs.

.PARAMETER MaxRequests
    Numero maximo de peticiones a aceptar antes de terminar. 0 = sin limite.
    Por defecto 0.

.EXAMPLE
    .\Start-RESTReceiver.ps1

.EXAMPLE
    .\Start-RESTReceiver.ps1 -Port 9090 -LogDir "D:\logs\ifm-rest" -MaxRequests 20
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [Parameter()]
    [string]$LogDir = 'C:\Actimize\IFM\test\rest-logs',

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxRequests = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        default { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color
    return $line
}

function Get-DecisionColor {
    param([string]$Decision)
    switch ($Decision) {
        'BLOCK'   { return 'Red' }
        'REVIEW'  { return 'Yellow' }
        'APPROVE' { return 'Green' }
        default   { return 'White' }
    }
}

function Write-ResponseSummary {
    param([object]$Response, [int]$RequestNum)

    $h = $Response.header
    Write-Host ''
    Write-Host ("  Peticion #{0}" -f $RequestNum) -ForegroundColor Magenta
    Write-Host "  Batch ID   : $($h.batchId)"
    Write-Host "  BP Key     : $($h.bulkTransactionKey)"
    Write-Host "  Timestamp  : $($h.processingTimestamp)"
    Write-Host ("  Entries    : {0} total | {1} validas | {2} invalidas" -f `
        $h.totalEntries, $h.validEntriesCount, $h.invalidEntriesCount)
    Write-Host ("  Bulk score : {0:N1}  |  Alerta: {1}" -f $h.bulkRiskScore, $h.isAlertGenerated)

    if ($Response.bulkActions.Count -gt 0) {
        Write-Host "  Bulk actions:" -ForegroundColor Yellow
        foreach ($a in $Response.bulkActions) {
            Write-Host "    $($a.name) = $($a.value)" -ForegroundColor Yellow
        }
    }

    Write-Host "  Entries:" -ForegroundColor White
    foreach ($e in $Response.entries) {
        $dColor = Get-DecisionColor $e.decision
        Write-Host ("    [{0}] {1,-30} score={2,5:N1}  {3,-12} -> {4}" -f `
            $e.riskLevelCode,
            $e.transactionId,
            $e.riskScore,
            $e.riskLevelLabel,
            $e.decision) -ForegroundColor $dColor
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Inicializar HttpListener
# ---------------------------------------------------------------------------

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$logFile   = Join-Path $LogDir ("rest_receiver_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$prefix    = "http://+:${Port}/api/ifm/bulk-response/"
$listener  = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

Write-Log "=== Start-RESTReceiver.ps1 ==="
Write-Log "Endpoint : http://localhost:${Port}/api/ifm/bulk-response"
Write-Log "LogDir   : $LogDir"
Write-Log "MaxReqs  : $(if ($MaxRequests -eq 0) { 'sin limite (Ctrl+C para parar)' } else { $MaxRequests })"

try {
    $listener.Start()
}
catch {
    Write-Log "No se pudo iniciar el listener en puerto ${Port}: $($_.Exception.Message)" 'ERROR'
    Write-Log @"
Si el error es acceso denegado, ejecuta como Administrador o registra el prefijo:
  netsh http add urlacl url=http://+:${Port}/api/ifm/bulk-response/ user=$env:USERNAME
"@ 'WARN'
    exit 1
}

Write-Log "Servidor HTTP iniciado. Escuchando en $prefix" 'OK'
Write-Host ''
Write-Host "  Configura IFM con:" -ForegroundColor White
Write-Host "    FF_bulkPaymentRESTEndpoint=http://<IP_IFM>:${Port}/api/ifm/bulk-response" -ForegroundColor Green
Write-Host ''
Write-Host "  Presiona Ctrl+C para detener el servidor." -ForegroundColor DarkGray
Write-Host ''

$requestCount  = 0
$okResponse    = '{"status":"received"}'
$encoding      = [System.Text.Encoding]::UTF8

# Manejar Ctrl+C limpiamente
[Console]::TreatControlCAsInput = $false
$cancelSource  = New-Object System.Threading.CancellationTokenSource

try {
    while ($MaxRequests -eq 0 -or $requestCount -lt $MaxRequests) {

        # GetContextAsync permite interrumpir con Ctrl+C via try/catch
        $contextTask = $listener.GetContextAsync()
        try {
            # Esperar la peticion o cancelacion
            $contextTask.Wait($cancelSource.Token)
        }
        catch [System.OperationCanceledException] {
            break
        }

        $context  = $contextTask.Result
        $request  = $context.Request
        $response = $context.Response
        $requestCount++

        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'

        # Leer body
        $reader  = New-Object System.IO.StreamReader($request.InputStream, $encoding)
        $rawBody = $reader.ReadToEnd()
        $reader.Close()

        $logLine = "[$ts] #$requestCount | Method=$($request.HttpMethod) | RemoteIP=$($request.RemoteEndPoint) | BodyLen=$($rawBody.Length) | $rawBody"
        Add-Content -Path $logFile -Value $logLine -Encoding UTF8

        Write-Log "#$requestCount | $($request.HttpMethod) desde $($request.RemoteEndPoint) | $($rawBody.Length) chars"

        # Solo aceptar POST
        if ($request.HttpMethod -ne 'POST') {
            Write-Log "Metodo no permitido: $($request.HttpMethod)" 'WARN'
            $response.StatusCode = 405
            $errBytes = $encoding.GetBytes('{"error":"Method Not Allowed"}')
            $response.ContentType   = 'application/json; charset=utf-8'
            $response.ContentLength64 = $errBytes.Length
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
            $response.Close()
            continue
        }

        # Intentar deserializar y mostrar resumen
        try {
            $parsed = $rawBody | ConvertFrom-Json
            Write-ResponseSummary -Response $parsed -RequestNum $requestCount
            $response.StatusCode = 200
            $batchIdEcho = if ($parsed.header.batchId) { $parsed.header.batchId } else { '' }
            $okBody = "{`"status`":`"received`",`"batchId`":`"$batchIdEcho`"}"
        }
        catch {
            Write-Log "JSON invalido: $($_.Exception.Message)" 'WARN'
            Write-Host "  Raw body: $rawBody" -ForegroundColor DarkGray
            # Aun asi devolvemos 200 para no bloquear IFM; el error esta en log
            $response.StatusCode = 200
            $okBody = $okResponse
        }

        $responseBytes = $encoding.GetBytes($okBody)
        $response.ContentType     = 'application/json; charset=utf-8'
        $response.ContentLength64 = $responseBytes.Length
        $response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
        $response.Close()

        Write-Log "Respuesta 200 enviada a $($request.RemoteEndPoint)" 'OK'
    }

    if ($MaxRequests -gt 0) {
        Write-Log "Limite de $MaxRequests peticiones alcanzado. Terminando." 'OK'
    }
}
catch [System.Net.HttpListenerException] {
    # Se lanza al llamar Stop() desde Ctrl+C
    Write-Log "Listener detenido." 'INFO'
}
catch {
    Write-Log "Error inesperado: $($_.Exception.Message)" 'ERROR'
}
finally {
    $cancelSource.Cancel()
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Log "Servidor HTTP detenido. Total peticiones atendidas: $requestCount"
    Write-Log "Log guardado en: $logFile"
}
