[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AutonomousDatabaseId,

    [Parameter(Mandatory = $true)]
    [string]$TableName,

    [string]$Profile = "DEFAULT",
    [string]$Region = "us-ashburn-1",
    [int]$ReadCapacityUnits = 500,
    [int]$WriteCapacityUnits = 500,
    [ValidateRange(1, 360)]
    [int]$AccessKeyLifetimeMinutes = 360,
    [string]$BenchmarkRepository,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$env:SUPPRESS_LABEL_WARNING = "True"
if ([string]::IsNullOrWhiteSpace($BenchmarkRepository)) {
    $BenchmarkRepository = Join-Path (Split-Path $PSScriptRoot -Parent) "..\kvs-benchmark"
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
    $raw = & oci @Arguments
    if ($LASTEXITCODE -ne 0) { throw "OCI CLI command failed." }
    $text = $raw | Out-String
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

$adbResult = Invoke-OciJson @(
    "db", "autonomous-database", "get",
    "--autonomous-database-id", $AutonomousDatabaseId,
    "--profile", $Profile,
    "--region", $Region,
    "--output", "json"
)
$adb = $adbResult.data
if ($adb.'lifecycle-state' -ne "AVAILABLE") { throw "ADB must be AVAILABLE; found $($adb.'lifecycle-state')." }
if ($adb.'license-model' -ne "BRING_YOUR_OWN_LICENSE") { throw "ADB is not BYOL." }
if ($adb.'compute-model' -ne "ECPU" -or [double]$adb.'compute-count' -ne 2) { throw "ADB must use exactly 2 ECPU." }
if ([bool]$adb.'is-auto-scaling-enabled') { throw "ADB base compute autoscaling must be disabled." }

if (-not $Apply) {
    Write-Output "ADB validation passed: AVAILABLE, BYOL, 2 ECPU, base autoscaling disabled. No resource was changed."
    exit 0
}

$adminPassword = New-BenchmarkPassword
Write-Output "Rotating the transient ADMIN password for DynamoDB API bootstrap..."
Invoke-OciJson @(
    "db", "autonomous-database", "update",
    "--autonomous-database-id", $AutonomousDatabaseId,
    "--profile", $Profile,
    "--region", $Region,
    "--admin-password", $adminPassword,
    "--force",
    "--wait-for-state", "AVAILABLE",
    "--max-wait-seconds", "1200",
    "--wait-interval-seconds", "15",
    "--output", "json"
) | Out-Null

$endpoint = "https://dataaccess.adb.$Region.oraclecloudapps.com/adb/keyvaluestore/v1/$AutonomousDatabaseId"
$authEndpoint = "https://dataaccess.adb.$Region.oraclecloudapps.com/adb/auth/v1/databases/$AutonomousDatabaseId/accesskeys"
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("ADMIN:$adminPassword"))
$headers = @{ Authorization = "Basic $basic"; "Request-Id" = [guid]::NewGuid().ToString("N") }
$body = @{
    name = "meli-kvs-benchmark-$(Get-Date -Format yyyyMMddHHmmss)"
    description = "Temporary credential for MELI KVS benchmark"
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

$previousAccessKey = $env:AWS_ACCESS_KEY_ID
$previousSecretKey = $env:AWS_SECRET_ACCESS_KEY
$previousRegion = $env:AWS_DEFAULT_REGION
try {
    $env:AWS_ACCESS_KEY_ID = $accessKeyId
    $env:AWS_SECRET_ACCESS_KEY = $secretAccessKey
    $env:AWS_DEFAULT_REGION = $Region

    & aws dynamodb describe-table --table-name $TableName --endpoint-url $endpoint --region $Region --output json 2>$null | Out-Null
    $tableExists = $LASTEXITCODE -eq 0
    if ($tableExists) {
        Write-Output "Updating existing table '$TableName' to $ReadCapacityUnits RCU / $WriteCapacityUnits WCU..."
        & aws dynamodb update-table --table-name $TableName --provisioned-throughput ReadCapacityUnits=$ReadCapacityUnits,WriteCapacityUnits=$WriteCapacityUnits --endpoint-url $endpoint --region $Region --output json | Out-Null
    }
    else {
        Write-Output "Creating table '$TableName' at $ReadCapacityUnits RCU / $WriteCapacityUnits WCU..."
        & aws dynamodb create-table --table-name $TableName --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE --provisioned-throughput ReadCapacityUnits=$ReadCapacityUnits,WriteCapacityUnits=$WriteCapacityUnits --endpoint-url $endpoint --region $Region --output json | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "CreateTable/UpdateTable failed." }
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

$secretDirectory = Join-Path (Resolve-Path $BenchmarkRepository) ".secrets\adb-runtime"
New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
$runtimePath = Join-Path $secretDirectory "adb-api.runtime.json"
$runtime = [ordered]@{
    databaseId = $AutonomousDatabaseId
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

Write-Output ("ADB_READY database={0} license={1} table={2} tableState={3} rcu={4} wcu={5} runtime={6}" -f `
    $adb.'display-name', $adb.'license-model', $TableName, $description.Table.TableStatus, `
    $description.Table.ProvisionedThroughput.ReadCapacityUnits, $description.Table.ProvisionedThroughput.WriteCapacityUnits, $runtimePath)
