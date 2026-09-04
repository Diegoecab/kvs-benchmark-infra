[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^vpce-[a-f0-9]+$')]
    [string]$VpcEndpointId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^arn:aws:dynamodb:[a-z0-9-]+:[0-9]{12}:table/[A-Za-z0-9_.-]+$')]
    [string]$TableArn,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Add', 'Remove')]
    [string]$Action,

    [string]$Profile = 'default',
    [string]$Region = 'us-east-1',
    [switch]$Apply,
    [string]$ChangeApproval
)

$ErrorActionPreference = 'Stop'

function Invoke-AwsJson {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $raw = & aws @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'AWS CLI command failed.' }
    return ($raw | Out-String) | ConvertFrom-Json
}

function Get-Endpoint {
    $response = Invoke-AwsJson @(
        'ec2', 'describe-vpc-endpoints',
        '--profile', $Profile,
        '--region', $Region,
        '--vpc-endpoint-ids', $VpcEndpointId,
        '--output', 'json'
    )
    $items = @($response.VpcEndpoints)
    if ($items.Count -ne 1) { throw "Expected one VPC endpoint; found $($items.Count)." }
    return $items[0]
}

$endpoint = Get-Endpoint
$expectedService = "com.amazonaws.$Region.dynamodb"
if ($endpoint.ServiceName -ne $expectedService) {
    throw "Endpoint $VpcEndpointId is for '$($endpoint.ServiceName)', not '$expectedService'."
}
if ($endpoint.VpcEndpointType -ne 'Gateway' -or $endpoint.State -ne 'available') {
    throw "Endpoint $VpcEndpointId must be an available DynamoDB Gateway endpoint."
}

$policy = $endpoint.PolicyDocument | ConvertFrom-Json
$requiredActions = @('dynamodb:DescribeTable', 'dynamodb:GetItem', 'dynamodb:PutItem')
$candidates = @($policy.Statement | Where-Object {
    $statementActions = @($_.Action)
    $_.Effect -eq 'Allow' -and ($requiredActions | Where-Object { $statementActions -notcontains $_ }).Count -eq 0
})
if ($candidates.Count -ne 1) {
    throw "Expected exactly one Allow statement containing DescribeTable/GetItem/PutItem; found $($candidates.Count)."
}

$statement = $candidates[0]
$resources = @($statement.Resource)
if ($resources -contains '*') {
    Write-Output 'NO_CHANGE endpoint policy already grants the required actions to all resources.'
    exit 0
}

if ($Action -eq 'Add') {
    $nextResources = @($resources + $TableArn | Sort-Object -Unique)
}
else {
    $nextResources = @($resources | Where-Object { $_ -ne $TableArn })
    if ($nextResources.Count -eq 0) {
        throw 'Refusing to leave the selected Allow statement without any resources.'
    }
}

if (($nextResources -join "`n") -eq (($resources | Sort-Object -Unique) -join "`n")) {
    Write-Output "NO_CHANGE action=$Action endpoint=$VpcEndpointId table=$TableArn"
    exit 0
}

$statement.Resource = $nextResources
$policyJson = $policy | ConvertTo-Json -Depth 20 -Compress
$expectedApproval = "${Action}:$TableArn"
if (-not $Apply) {
    Write-Output "PREVIEW action=$Action endpoint=$VpcEndpointId vpc=$($endpoint.VpcId) table=$TableArn"
    Write-Output "Re-run with -Apply -ChangeApproval '$expectedApproval' after review."
    Write-Output $policyJson
    exit 0
}
if ($ChangeApproval -cne $expectedApproval) {
    throw "Apply requires -ChangeApproval '$expectedApproval'."
}

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("kvs-dynamodb-vpce-policy-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllText($temporary, $policyJson, (New-Object System.Text.UTF8Encoding($false)))
    & aws ec2 modify-vpc-endpoint --profile $Profile --region $Region --vpc-endpoint-id $VpcEndpointId --policy-document "file://$temporary" --output json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'AWS rejected the endpoint policy update.' }
}
finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}

$verified = Get-Endpoint
$verifiedPolicy = $verified.PolicyDocument | ConvertFrom-Json
$verifiedResources = @($verifiedPolicy.Statement | ForEach-Object { @($_.Resource) })
$present = $verifiedResources -contains $TableArn
if (($Action -eq 'Add' -and -not $present) -or ($Action -eq 'Remove' -and $present)) {
    throw 'Endpoint policy verification did not observe the requested final state.'
}
Write-Output "APPLIED action=$Action endpoint=$VpcEndpointId table=$TableArn"
