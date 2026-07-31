#Requires -Version 5.1
<#
.SYNOPSIS
    Simula el consumer MQ del Core Banking para la opcion A de respuesta IFM.

.DESCRIPTION
    Conecta a la cola IBM MQ configurada, lee los mensajes de respuesta que IFM-X
    deposita, deserializa el JSON y muestra un resumen por consola. Guarda un log
    de cada mensaje recibido.

    Requiere que amqmdnet.dll (IBM MQ .NET client) este instalado y accesible.
    Se instala con IBM MQ Client for Windows: https://www.ibm.com/docs/en/ibm-mq

.PARAMETER QueueManager
    Nombre del Queue Manager MQ al que conectar.

.PARAMETER Channel
    Canal MQ de tipo SVRCONN para la conexion cliente.

.PARAMETER Host
    Hostname o IP del servidor MQ.

.PARAMETER Port
    Puerto del listener MQ. Por defecto 1414.

.PARAMETER Queue
    Nombre de la cola de respuestas. Por defecto IFM.REMITTANCES.RESPONSE.

.PARAMETER LogDir
    Directorio donde guardar los logs de mensajes recibidos.
    Por defecto C:\Actimize\IFM\test.

.PARAMETER WaitIntervalMs
    Milisegundos que el GET espera por un mensaje nuevo antes de reintentar.
    Por defecto 5000 (5 segundos).

.PARAMETER MaxMessages
    Numero maximo de mensajes a leer antes de terminar. 0 = sin limite (Ctrl+C para parar).
    Por defecto 0.

.EXAMPLE
    .\Test-MQResponse.ps1 -QueueManager "QMGR_PRE" -Channel "IFM.TO.CB.SVRCONN" `
        -Host "mqserver.interno.banco.es" -Port 1414

.EXAMPLE
    .\Test-MQResponse.ps1 -QueueManager "QMGR_DEV" -Channel "SVRCONN" `
        -Host "localhost" -Port 1414 -MaxMessages 10 -LogDir "D:\logs\mq"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$QueueManager,

    [Parameter(Mandatory)]
    [string]$Channel,

    [Parameter(Mandatory)]
    [string]$Host,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port = 1414,

    [Parameter()]
    [string]$Queue = 'IFM.REMITTANCES.RESPONSE',

    [Parameter()]
    [string]$LogDir = 'C:\Actimize\IFM\test',

    [Parameter()]
    [ValidateRange(500, 60000)]
    [int]$WaitIntervalMs = 5000,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxMessages = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $(if ($Level -eq 'ERROR') { 'Red' } elseif ($Level -eq 'WARN') { 'Yellow' } else { 'Cyan' })
    return $line
}

function Get-RiskLevelLabel {
    param([int]$Code)
    switch ($Code) {
        1 { return 'Very High' }
        2 { return 'High' }
        3 { return 'Medium High' }
        4 { return 'Medium Low' }
        5 { return 'Low' }
        6 { return 'Very Low' }
        default { return "Unknown ($Code)" }
    }
}

function Write-EntrySummary {
    param([object]$Response)

    $header = $Response.header
    Write-Host ''
    Write-Host '=' * 70 -ForegroundColor Green
    Write-Host "  BATCH ID     : $($header.batchId)" -ForegroundColor White
    Write-Host "  BP Key       : $($header.bulkTransactionKey)" -ForegroundColor White
    Write-Host "  Timestamp    : $($header.processingTimestamp)" -ForegroundColor White
    Write-Host "  Total entries: $($header.totalEntries)  Validas: $($header.validEntriesCount)  Invalidas: $($header.invalidEntriesCount)" -ForegroundColor White
    Write-Host "  Bulk score   : $($header.bulkRiskScore)" -ForegroundColor White
    Write-Host "  Alerta gen.  : $($header.isAlertGenerated)" -ForegroundColor White

    if ($header.isAlertGenerated) {
        Write-Host "  [!] ALERTA GENERADA - REVISAR" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  ENTRIES:' -ForegroundColor Yellow

    $highRiskEntries = @()

    foreach ($entry in $Response.entries) {
        $color = switch ($entry.riskLevelCode) {
            { $_ -le 2 } { 'Red' }
            3             { 'Yellow' }
            default       { 'Green' }
        }
        $line = "    [{0}] TxId={1,-30} Score={2,5:N1} Level={3,-12} Decision={4}" -f `
            $entry.riskLevelCode,
            $entry.transactionId,
            $entry.riskScore,
            $entry.riskLevelLabel,
            $entry.decision

        Write-Host $line -ForegroundColor $color

        if ($entry.riskLevelCode -le 2) {
            $highRiskEntries += $entry
        }
    }

    if ($highRiskEntries.Count -gt 0) {
        Write-Host ''
        Write-Host "  ENTRIES CON RIESGO ALTO O MUY ALTO ($($highRiskEntries.Count)):" -ForegroundColor Red
        foreach ($e in $highRiskEntries) {
            Write-Host "    - $($e.transactionId) (riskLevel $($e.riskLevelCode) - $(Get-RiskLevelLabel $e.riskLevelCode))" -ForegroundColor Red
            foreach ($action in $e.entryActions) {
                Write-Host "      Accion: $($action.name) = $($action.value)" -ForegroundColor Magenta
            }
        }
    }

    Write-Host '=' * 70 -ForegroundColor Green
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Cargar libreria IBM MQ .NET
# ---------------------------------------------------------------------------

function Import-MQAssembly {
    # Rutas tipicas donde IBM MQ Client instala amqmdnet.dll en Windows
    $candidatePaths = @(
        'C:\Program Files\IBM\MQ\bin\amqmdnet.dll',
        'C:\Program Files (x86)\IBM\WebSphere MQ\bin\amqmdnet.dll',
        'C:\IBM\MQ\bin\amqmdnet.dll'
    )

    foreach ($path in $candidatePaths) {
        if (Test-Path $path) {
            Add-Type -Path $path
            Write-Log "IBM MQ .NET assembly cargado desde: $path"
            return
        }
    }

    throw @"
No se encontro amqmdnet.dll en las rutas habituales.
Instala IBM MQ Client for Windows y verifica que el .dll existe en:
  C:\Program Files\IBM\MQ\bin\amqmdnet.dll

Descarga: https://www.ibm.com/docs/en/ibm-mq (IBM MQ Client)
"@
}

# ---------------------------------------------------------------------------
# Logica principal
# ---------------------------------------------------------------------------

# Asegurar directorio de log
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$logFile = Join-Path $LogDir ("mq_responses_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

Write-Log "=== Test-MQResponse.ps1 iniciado ==="
Write-Log "QueueManager : $QueueManager"
Write-Log "Host         : ${Host}:${Port}"
Write-Log "Channel      : $Channel"
Write-Log "Queue        : $Queue"
Write-Log "LogDir       : $LogDir"
Write-Log "MaxMessages  : $(if ($MaxMessages -eq 0) { 'sin limite (Ctrl+C para parar)' } else { $MaxMessages })"

try {
    Import-MQAssembly
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}

# Propiedades de conexion MQ
$mqEnv = New-Object IBM.WMQ.MQEnvironment
$mqEnv.Hostname = $Host
$mqEnv.Port     = $Port
$mqEnv.Channel  = $Channel

$qMgr   = $null
$mqQueue = $null
$messagesRead = 0

try {
    Write-Log "Conectando a QueueManager '$QueueManager'..."
    $qMgr = New-Object IBM.WMQ.MQQueueManager($QueueManager, $mqEnv)
    Write-Log "Conexion establecida."

    # Abrir cola en modo GET (lectura)
    $openOptions = [IBM.WMQ.MQC]::MQOO_INPUT_AS_Q_DEF -bor [IBM.WMQ.MQC]::MQOO_FAIL_IF_QUIESCING
    $mqQueue = $qMgr.AccessQueue($Queue, $openOptions)
    Write-Log "Cola '$Queue' abierta. Esperando mensajes..."
    Write-Host ''

    $gmo = New-Object IBM.WMQ.MQGetMessageOptions
    # Esperar WaitIntervalMs si no hay mensajes, en lugar de fallar inmediatamente
    $gmo.Options      = [IBM.WMQ.MQC]::MQGMO_WAIT -bor [IBM.WMQ.MQC]::MQGMO_CONVERT
    $gmo.WaitInterval = $WaitIntervalMs

    while ($MaxMessages -eq 0 -or $messagesRead -lt $MaxMessages) {
        $msg = New-Object IBM.WMQ.MQMessage
        $msg.CharacterSet = 1208  # UTF-8

        try {
            $mqQueue.Get($msg, $gmo)
        }
        catch [IBM.WMQ.MQException] {
            # MQRC_NO_MSG_AVAILABLE (2033) es esperado: la cola esta vacia, reintentar
            if ($_.Exception.ReasonCode -eq 2033) {
                continue
            }
            throw
        }

        $messagesRead++
        $rawJson = $msg.ReadString($msg.MessageLength)
        $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'

        $logLine = "[$ts] MSG #$messagesRead | MsgId=$([BitConverter]::ToString($msg.MessageId).Replace('-','')) | $rawJson"
        Add-Content -Path $logFile -Value $logLine -Encoding UTF8

        Write-Log "Mensaje #$messagesRead recibido ($($rawJson.Length) chars)"

        try {
            $response = $rawJson | ConvertFrom-Json
            Write-EntrySummary -Response $response
        }
        catch {
            Write-Log "JSON invalido en mensaje #${messagesRead}: $($_.Exception.Message)" 'WARN'
            Write-Host "  Raw: $rawJson" -ForegroundColor DarkGray
        }
    }

    Write-Log "Limite de $MaxMessages mensajes alcanzado. Terminando."
}
catch {
    Write-Log "Error fatal: $($_.Exception.Message)" 'ERROR'
    if ($_.Exception -is [IBM.WMQ.MQException]) {
        Write-Log "MQ ReasonCode: $($_.Exception.ReasonCode)  CompCode: $($_.Exception.CompCode)" 'ERROR'
    }
    exit 1
}
finally {
    # Cerrar recursos en orden inverso
    if ($null -ne $mqQueue) {
        try { $mqQueue.Close() } catch { }
    }
    if ($null -ne $qMgr) {
        try { $qMgr.Disconnect() } catch { }
    }
    Write-Log "Conexion MQ cerrada. Total mensajes leidos: $messagesRead"
    Write-Log "Log guardado en: $logFile"
}
