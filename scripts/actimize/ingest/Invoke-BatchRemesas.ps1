#Requires -Version 5.1
<#
.SYNOPSIS
    Genera el fichero batch diario de remesas para carga en NICE Actimize IFM.
.DESCRIPTION
    Extrae las transacciones de remesas del día anterior (T-1) del Core Banking (Oracle),
    genera un fichero plano delimitado por pipes, lo cifra con PGP, lo comprime y lo
    envía por SFTP al servidor de ingestión de NICE Actimize IFM.
.PARAMETER Environment
    Entorno de ejecución: dev | pre | pro
.PARAMETER TargetDate
    Fecha de extracción en formato YYYY-MM-DD. Por defecto: ayer (T-1).
.PARAMETER ConfigFile
    Ruta al fichero de configuración de entornos.
.EXAMPLE
    .\Invoke-BatchRemesas.ps1 -Environment pro
    .\Invoke-BatchRemesas.ps1 -Environment pre -TargetDate 2024-06-12
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dev','pre','pro')][string]$Environment,
    [string]$TargetDate  = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd'),
    [string]$ConfigFile  = 'C:\Actimize\IFM\config\environments.conf'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Cargar módulo común ──────────────────────────────────────────────────────
$moduleDir = Join-Path $PSScriptRoot '..\lib'
Import-Module (Join-Path $moduleDir 'Common.psm1') -Force

Initialize-IFMContext -Environment $Environment -ConfigFile $ConfigFile -ScriptName $MyInvocation.MyCommand.Name

$exitCode = 0
try {
    Write-IFMLog -Level INFO -Message "Fecha objetivo: $TargetDate"

    # ── Leer configuración ───────────────────────────────────────────────────
    $dbHost      = Get-IFMConfig 'db.host'
    $dbPort      = Get-IFMConfig 'db.port'
    $dbName      = Get-IFMConfig 'db.name'
    $dbUser      = Get-IFMConfig 'db.user'
    $dbPass      = Resolve-VaultSecret (Get-IFMConfig 'db.password')
    $maxRecords  = Get-IFMConfig 'batch.max_records_per_file'
    $outputDir   = Get-IFMConfig 'local.batch_output_dir'
    $archiveDir  = Get-IFMConfig 'local.batch_archive_dir'
    $pgpKeyPath  = Get-IFMConfig 'local.pgp_key_path'
    $entityId    = 'BANCOES'
    $batchSeq    = '001'

    # ── Directorio de salida ─────────────────────────────────────────────────
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    $filename   = New-BatchFilename -Entity $entityId -Sequence $batchSeq
    $outputFile = Join-Path $outputDir $filename

    Write-IFMLog -Level INFO -Message "Fichero destino: $outputFile"

    # ── Conexión Oracle via ODP.NET / ODBC ───────────────────────────────────
    # Requiere Oracle Data Provider for .NET instalado en el servidor IFM Windows
    $connString = "Data Source=//${dbHost}:${dbPort}/${dbName};User Id=${dbUser};Password=${dbPass};"

    Add-Type -AssemblyName System.Data
    $dllPath = 'C:\oracle\product\client\odp.net\managed\common\Oracle.ManagedDataAccess.dll'
    if (Test-Path $dllPath) {
        Add-Type -Path $dllPath
        $connType = 'Oracle.ManagedDataAccess.Client.OracleConnection'
        $cmdType  = 'Oracle.ManagedDataAccess.Client.OracleCommand'
    }
    else {
        throw "Oracle.ManagedDataAccess.dll no encontrado en $dllPath. Instalar ODP.NET en el servidor IFM."
    }

    $conn = New-Object $connType $connString
    $conn.Open()
    Write-IFMLog -Level INFO -Message "Conectado a Oracle: ${dbHost}:${dbPort}/${dbName}"

    # ── Contar registros ─────────────────────────────────────────────────────
    $countSql = @"
SELECT COUNT(*) FROM PAYMENTS.REMITTANCE_TXN
WHERE TRUNC(VALUE_DATE) = TO_DATE('$TargetDate', 'YYYY-MM-DD')
AND STATUS = 'PROCESSED'
"@
    $countCmd    = New-Object $cmdType $countSql, $conn
    $recordCount = [int]$countCmd.ExecuteScalar()
    $countCmd.Dispose()

    Write-IFMLog -Level INFO -Message "Registros a exportar: $recordCount"

    if ($recordCount -eq 0) {
        Write-IFMLog -Level WARN -Message "No hay remesas para la fecha $TargetDate. Proceso finalizado sin generar fichero."
        $conn.Close()
        exit 0
    }

    # ── Calcular total importes para trailer ─────────────────────────────────
    $sumSql = @"
SELECT TO_CHAR(NVL(SUM(EQUIV_EUR_AMOUNT),0), 'FM99999999990.00')
FROM PAYMENTS.REMITTANCE_TXN
WHERE TRUNC(VALUE_DATE) = TO_DATE('$TargetDate', 'YYYY-MM-DD')
AND STATUS = 'PROCESSED'
"@
    $sumCmd     = New-Object $cmdType $sumSql, $conn
    $totalAmount= $sumCmd.ExecuteScalar()
    $sumCmd.Dispose()

    # ── Extraer registros detalle ────────────────────────────────────────────
    $extractSql = @"
SELECT
    'D' AS rec_type,
    r.TRN_ID,
    TO_CHAR(r.VALUE_DATE, 'YYYY-MM-DD'),
    TO_CHAR(r.PROCESS_DT, 'YYYY-MM-DD"T"HH24:MI:SS'),
    TO_CHAR(r.AMOUNT, 'FM99999999990.00'),
    r.CURRENCY,
    TO_CHAR(r.EQUIV_EUR_AMOUNT, 'FM99999999990.00'),
    'EUR',
    TO_CHAR(NVL(r.FX_RATE, 1), 'FM9990.000000'),
    c.FULL_NAME,
    c.ACCOUNT_IBAN,
    r.SENDER_BIC,
    c.COUNTRY_CODE,
    c.ADDRESS,
    c.ID_TYPE,
    c.ID_NUMBER,
    c.INTERNAL_CIF,
    r.BENEFICIARY_NAME,
    r.BENEFICIARY_ACCOUNT,
    r.RECEIVER_BIC,
    r.RECEIVER_COUNTRY,
    r.RECEIVER_ADDRESS,
    NVL(r.INTERMEDIARY_BIC, ''),
    r.TXN_TYPE,
    r.PURPOSE_CODE,
    r.PAYMENT_METHOD,
    r.CHANNEL,
    REPLACE(r.REMITTANCE_INFO, '|', ' '),
    r.REGULATORY_INFO,
    r.CHARGE_TYPE,
    NVL(r.UETR, ''),
    CASE WHEN hrc.COUNTRY_CODE IS NOT NULL THEN 'Y' ELSE 'N' END AS HIGH_RISK_CTRY,
    NVL(c.PEP_FLAG, 'N'),
    NVL(r.SANCTIONS_PRE_SCREENED, 'N')
FROM
    PAYMENTS.REMITTANCE_TXN r
    JOIN PAYMENTS.CUSTOMER c ON r.SENDER_CUSTOMER_ID = c.CUSTOMER_ID
    LEFT JOIN COMPLIANCE.HIGH_RISK_COUNTRIES hrc ON r.RECEIVER_COUNTRY = hrc.COUNTRY_CODE
WHERE
    TRUNC(r.VALUE_DATE) = TO_DATE('$TargetDate', 'YYYY-MM-DD')
    AND r.STATUS = 'PROCESSED'
ORDER BY r.PROCESS_DT ASC
FETCH FIRST $maxRecords ROWS ONLY
"@

    # ── Escribir fichero ─────────────────────────────────────────────────────
    $writer     = [System.IO.StreamWriter]::new($outputFile, $false, [System.Text.Encoding]::UTF8)
    $now        = Get-Date
    $dateStamp  = $now.ToString('yyyyMMdd')
    $timeStamp  = $now.ToString('HHmmss')

    # Cabecera
    $writer.WriteLine("H|$filename|$dateStamp|$timeStamp|$recordCount|$entityId")

    # Detalle
    $extractCmd = New-Object $cmdType $extractSql, $conn
    $reader     = $extractCmd.ExecuteReader()
    $linesWritten = 0
    while ($reader.Read()) {
        $cols = @(0..($reader.FieldCount - 1) | ForEach-Object { $reader.GetValue($_) })
        $writer.WriteLine($cols -join '|')
        $linesWritten++
    }
    $reader.Close()
    $extractCmd.Dispose()
    $conn.Close()

    # Trailer
    $writer.WriteLine("T|$filename|$recordCount|$totalAmount")
    $writer.Close()

    $fileSize = (Get-Item $outputFile).Length
    Write-IFMLog -Level INFO -Message "Fichero generado: $fileSize bytes | $linesWritten registros detalle"

    # ── Validación Travel Rule (muestra primeros 100 registros) ─────────────
    Write-IFMLog -Level INFO -Message "Validando Travel Rule en muestra de registros..."
    $trErrors = 0
    Get-Content $outputFile | Select-Object -First 102 | Where-Object { $_ -match '^D\|' } | ForEach-Object {
        if (-not (Test-TravelRuleFields -Record $_)) { $trErrors++ }
    }
    if ($trErrors -gt 0) {
        Write-IFMLog -Level WARN -Message "Travel Rule: $trErrors registros con campos incompletos (muestra 100)"
    }

    # ── Cifrado PGP ──────────────────────────────────────────────────────────
    $encryptedFile = "$outputFile.gpg"
    Write-IFMLog -Level INFO -Message "Cifrando fichero con PGP..."

    # Usar Gpg4win (instalado en servidor IFM Windows)
    $gpgExe = 'C:\Program Files (x86)\GnuPG\bin\gpg.exe'
    if (-not (Test-Path $gpgExe)) { throw "GnuPG no encontrado en $gpgExe. Instalar Gpg4win en el servidor IFM." }

    & $gpgExe --batch --yes --recipient 'ifm-ingest@bancoes.es' --output $encryptedFile --encrypt $outputFile
    if ($LASTEXITCODE -ne 0) { throw "GPG falló con código $LASTEXITCODE" }

    Remove-Item $outputFile -Force
    Write-IFMLog -Level OK -Message "Fichero cifrado: $encryptedFile"

    # ── Compresión ───────────────────────────────────────────────────────────
    $compressedFile = "$encryptedFile.gz"
    Write-IFMLog -Level INFO -Message "Comprimiendo fichero..."

    # Usar System.IO.Compression (nativo en .NET / PowerShell 5+)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $srcStream  = [System.IO.File]::OpenRead($encryptedFile)
    $dstStream  = [System.IO.File]::Create($compressedFile)
    $gzipStream = New-Object System.IO.Compression.GZipStream $dstStream, ([System.IO.Compression.CompressionMode]::Compress)
    $srcStream.CopyTo($gzipStream)
    $gzipStream.Dispose(); $dstStream.Dispose(); $srcStream.Dispose()

    Remove-Item $encryptedFile -Force
    Write-IFMLog -Level OK -Message "Fichero comprimido: $compressedFile"

    # ── Envío SFTP ───────────────────────────────────────────────────────────
    $sftpHost = Get-IFMConfig 'sftp.host'
    Write-IFMLog -Level INFO -Message "Enviando fichero a IFM SFTP: $sftpHost"

    if (Send-SFTPFile -LocalFile $compressedFile) {
        Write-IFMLog -Level OK -Message "Fichero enviado correctamente a Actimize IFM"
        $monthDir = Join-Path $archiveDir (Get-Date -Format 'yyyyMM')
        if (-not (Test-Path $monthDir)) { New-Item -ItemType Directory -Path $monthDir -Force | Out-Null }
        Move-Item $compressedFile $monthDir
        Write-IFMLog -Level INFO -Message "Fichero archivado en: $monthDir"
    }
    else {
        throw "Fallo en envío SFTP. El fichero queda en: $compressedFile"
    }

    Write-IFMLog -Level OK -Message "Proceso completado: $recordCount remesas del $TargetDate enviadas a Actimize IFM"
}
catch {
    $exitCode = 1
    Write-IFMLog -Level ERROR -Message "Error no controlado: $_"
}
finally {
    Invoke-IFMCleanup -ExitCode $exitCode
}

exit $exitCode
