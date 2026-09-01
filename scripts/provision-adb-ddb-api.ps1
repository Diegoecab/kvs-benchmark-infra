[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CompartmentOcid,

    [string]$Profile = "LATINOAMERICA_APIKEY",
    [string]$Region = "us-dallas-1",
    [string]$DbName = "MELIKVSDDB",
    [string]$DisplayName = "meli-kvs-ddb-api-dallas",
    [string]$TableName = "meli_kvs_adb_dallas_500",
    [int]$ReadCapacityUnits = 500,
    [int]$WriteCapacityUnits = 500,
    [int]$AccessKeyLifetimeMinutes = 720,
    [string]$BenchmarkRepository = (Join-Path (Split-Path $PSScriptRoot -Parent) "..\kvs-benchmark"),
    [switch]$Apply,
    [string]$CostApproval
)

$ErrorActionPreference = "Stop"
$env:SUPPRESS_LABEL_WARNING = "True"

if ($Region -ne "us-dallas-1") {
    throw "This workflow is pinned to us-dallas-1."
}
if ($ReadCapacityUnits -ne 500 -or $WriteCapacityUnits -ne 500) {
    throw "The reviewed benchmark table capacity is exactly 500 RCU and 500 WCU."
}
if ($Apply -and $CostApproval -ne "BYOL-ADB-DDB-2.05-USD-HOUR") {
    throw "Apply requires -CostApproval BYOL-ADB-DDB-2.05-USD-HOUR."
}

function New-BenchmarkPassword {
    $alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $bytes = New-Object byte[] 20
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $suffix = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
    return "Kvs1aA$suffix"
}

function Invoke-OciJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("oci-stderr-{0}.log" -f [guid]::NewGuid().ToString("N"))
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $raw = & oci @Arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { "" }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0) {
        throw (($raw | Out-String) + $stderr)
    }
    $text = $raw | Out-String
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Get-AdbByDisplayName {
    $result = Invoke-OciJson @(
        "db", "autonomous-database", "list",
        "--compartment-id", $CompartmentOcid,
        "--profile", $Profile,
        "--region", $Region,
        "--all", "--output", "json"
    )
    return @($result.data | Where-Object { $_.'display-name' -eq $DisplayName -and $_.'lifecycle-state' -ne "TERMINATED" })
}

function Wait-AdbAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$AutonomousDatabaseId,
        [int]$TimeoutSeconds = 2400
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = Invoke-OciJson @(
            "db", "autonomous-database", "get",
            "--autonomous-database-id", $AutonomousDatabaseId,
            "--profile", $Profile,
            "--region", $Region,
            "--output", "json"
        )
        $state = $result.data.'lifecycle-state'
        if ($state -eq "AVAILABLE") { return $result.data }
        if ($state -in @("TERMINATED", "TERMINATING", "UNAVAILABLE", "INACCESSIBLE")) {
            throw "ADB entered terminal state '$state'."
        }
        Write-Output "ADB state is $state; waiting 20 seconds..."
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for ADB to become AVAILABLE."
}

$existing = @(Get-AdbByDisplayName)
if ($existing.Count -gt 1) {
    throw "More than one non-terminated ADB has display name '$DisplayName'."
}

$adminPassword = New-BenchmarkPassword
if (-not $Apply) {
    if ($existing.Count -eq 1) {
        $candidate = $existing[0]
        $matches = $candidate.'license-model' -eq "BRING_YOUR_OWN_LICENSE" -and
            $candidate.'compute-model' -eq "ECPU" -and
            [double]$candidate.'compute-count' -eq 2 -and
            [int]$candidate.'data-storage-size-in-gbs' -eq 20 -and
            -not [bool]$candidate.'is-auto-scaling-enabled'
        if (-not $matches) {
            throw "Existing ADB '$DisplayName' does not match the reviewed BYOL/2-ECPU/20-GB/no-base-autoscaling configuration."
        }
        Write-Output "Existing ADB validation passed: BYOL, 2 ECPU, 20 GB, 26ai, us-dallas-1. No resource was changed."
        exit 0
    }
    Invoke-OciJson @(
        "db", "autonomous-database", "create",
        "--compartment-id", $CompartmentOcid,
        "--profile", $Profile,
        "--region", $Region,
        "--db-name", $DbName,
        "--display-name", $DisplayName,
        "--db-workload", "OLTP",
        "--db-version", "26ai",
        "--compute-model", "ECPU",
        "--compute-count", "2",
        "--data-storage-size-in-gbs", "20",
        "--admin-password", $adminPassword,
        "--license-model", "BRING_YOUR_OWN_LICENSE",
        "--is-auto-scaling-enabled", "false",
        "--opc-dry-run", "true",
        "--output", "json"
    ) | Out-Null
    Write-Output "ADB dry-run passed: BYOL, 2 ECPU, 20 GB, 26ai, us-dallas-1. No resource was created."
    exit 0
}

if ($existing.Count -eq 1) {
    $adb = $existing[0]
    Write-Output "Reusing existing ADB '$DisplayName' in state $($adb.'lifecycle-state')."
    if ($adb.'lifecycle-state' -ne "AVAILABLE") {
        $adb = Wait-AdbAvailable -AutonomousDatabaseId $adb.id
    }
    Write-Output "Rotating the transient ADMIN password before bootstrap..."
    $updated = Invoke-OciJson @(
        "db", "autonomous-database", "update",
        "--autonomous-database-id", $adb.id,
        "--profile", $Profile,
        "--region", $Region,
        "--admin-password", $adminPassword,
        "--force",
        "--wait-for-state", "AVAILABLE",
        "--max-wait-seconds", "1200",
        "--wait-interval-seconds", "15",
        "--output", "json"
    )
    $adb = $updated.data
    $adbId = $adb.id
}
else {
    Write-Output "Creating ADB '$DisplayName' with BYOL, 2 ECPU, 20 GB, and base autoscaling disabled..."
    $created = Invoke-OciJson @(
        "db", "autonomous-database", "create",
        "--compartment-id", $CompartmentOcid,
        "--profile", $Profile,
        "--region", $Region,
        "--db-name", $DbName,
        "--display-name", $DisplayName,
        "--db-workload", "OLTP",
        "--db-version", "26ai",
        "--compute-model", "ECPU",
        "--compute-count", "2",
        "--data-storage-size-in-gbs", "20",
        "--admin-password", $adminPassword,
        "--license-model", "BRING_YOUR_OWN_LICENSE",
        "--is-auto-scaling-enabled", "false",
        "--wait-for-state", "AVAILABLE",
        "--max-wait-seconds", "2400",
        "--wait-interval-seconds", "20",
        "--output", "json"
    )
    $adb = $created.data
    $adbId = $adb.id
}
if ([string]::IsNullOrWhiteSpace($adbId)) {
    throw "ADB creation returned no OCID."
}

$tagPath = Join-Path ([System.IO.Path]::GetTempPath()) ("adb-ddb-tags-{0}.json" -f [guid]::NewGuid().ToString("N"))
try {
    $featureValue = @{ name = "DynamoDB_API"; enable = $true } | ConvertTo-Json -Compress
    $tagJson = @{ 'adb$feature' = $featureValue } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($tagPath, $tagJson, (New-Object System.Text.UTF8Encoding($false)))
    $tagUri = "file://$tagPath"
    Write-Output "Enabling Autonomous AI Database API for DynamoDB..."
    Invoke-OciJson @(
        "db", "autonomous-database", "update",
        "--autonomous-database-id", $adbId,
        "--profile", $Profile,
        "--region", $Region,
        "--freeform-tags", $tagUri,
        "--force",
        "--wait-for-state", "AVAILABLE",
        "--max-wait-seconds", "1200",
        "--wait-interval-seconds", "15",
        "--output", "json"
    ) | Out-Null
}
finally {
    Remove-Item -LiteralPath $tagPath -Force -ErrorAction SilentlyContinue
}

$endpoint = "https://dataaccess.adb.$Region.oraclecloudapps.com/adb/keyvaluestore/v1/$adbId"
$authEndpoint = "https://dataaccess.adb.$Region.oraclecloudapps.com/adb/auth/v1/databases/$adbId/accesskeys"
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("ADMIN:$adminPassword"))
$headers = @{ Authorization = "Basic $basic"; "Request-Id" = [guid]::NewGuid().ToString("N") }
$body = @{
    name = "meli-kvs-benchmark-$(Get-Date -Format yyyyMMddHHmmss)"
    description = "Temporary credential for MELI Dallas KVS benchmark"
    permissions = @(@{ actions = @("ADMIN_ANY") })
    expiration_minutes = $AccessKeyLifetimeMinutes
} | ConvertTo-Json -Depth 6

$accessKey = $null
$deadline = (Get-Date).AddMinutes(12)
do {
    try {
        $accessKey = Invoke-RestMethod -Method Post -Uri $authEndpoint -Headers $headers -ContentType "application/json" -Body $body
    }
    catch {
        if ((Get-Date) -ge $deadline) { throw }
        Write-Output "DynamoDB API is not ready yet; retrying in 20 seconds..."
        Start-Sleep -Seconds 20
    }
} until ($null -ne $accessKey)

$accessKeyId = $accessKey.access_key_id
$secretAccessKey = $accessKey.secret_access_key
if ([string]::IsNullOrWhiteSpace($accessKeyId) -or [string]::IsNullOrWhiteSpace($secretAccessKey)) {
    throw "Access-key bootstrap returned an incomplete response."
}

$secretDirectory = Join-Path (Resolve-Path $BenchmarkRepository) ".secrets\adb-dallas"
New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
$runtimePath = Join-Path $secretDirectory "adb-api.runtime.json"
$runtime = [ordered]@{
    databaseId = $adbId
    region = $Region
    endpoint = $endpoint
    accessKeyId = $accessKeyId
    secretAccessKey = $secretAccessKey
    expirationTime = if ($accessKey.expiration_time) { $accessKey.expiration_time } else { $accessKey.expiration_timestamp }
    tableNames = @($TableName)
}
[System.IO.File]::WriteAllText($runtimePath, ($runtime | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $secretDirectory /inheritance:r /grant:r "${identity}:(OI)(CI)F" /T /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to restrict ACLs on $secretDirectory" }
& icacls $runtimePath /inheritance:r /grant:r "${identity}:F" /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to restrict ACLs on $runtimePath" }

$previousAccessKey = $env:AWS_ACCESS_KEY_ID
$previousSecretKey = $env:AWS_SECRET_ACCESS_KEY
$previousRegion = $env:AWS_DEFAULT_REGION
try {
    $env:AWS_ACCESS_KEY_ID = $accessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $secretAccessKey
    $env:AWS_DEFAULT_REGION = $Region
    Write-Output "Creating DynamoDB-compatible table '$TableName' at 500 RCU / 500 WCU..."
    & aws dynamodb create-table `
        --table-name $TableName `
        --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S `
        --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE `
        --provisioned-throughput ReadCapacityUnits=$ReadCapacityUnits,WriteCapacityUnits=$WriteCapacityUnits `
        --endpoint-url $endpoint `
        --region $Region `
        --output json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "CreateTable failed." }

    & aws dynamodb wait table-exists --table-name $TableName --endpoint-url $endpoint --region $Region
    if ($LASTEXITCODE -ne 0) { throw "Table did not reach ACTIVE state." }

    $description = & aws dynamodb describe-table --table-name $TableName --endpoint-url $endpoint --region $Region --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "DescribeTable failed." }
}
finally {
    $env:AWS_ACCESS_KEY_ID = $previousAccessKey
    $env:AWS_SECRET_ACCESS_KEY = $previousSecretKey
    $env:AWS_DEFAULT_REGION = $previousRegion
}

Write-Output ("ADB_READY database={0} state={1} license={2} table={3} tableState={4} rcu={5} wcu={6} runtime={7}" -f `
    $DisplayName, $adb.'lifecycle-state', $adb.'license-model', $TableName, $description.Table.TableStatus, `
    $description.Table.ProvisionedThroughput.ReadCapacityUnits, $description.Table.ProvisionedThroughput.WriteCapacityUnits, $runtimePath)
