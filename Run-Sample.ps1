#requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$EnvironmentFile,
    [Parameter(Mandatory, ParameterSetName = 'Build')][switch]$BuildOnly,
    [Parameter(Mandatory)][ValidateSet('dotnet','c')][string]$Language,
    [ValidateSet('standard','custom')][string]$Scenario = 'standard',
    [string]$SdkRoot,
    [string]$CExecutable,
    [string]$CDependencyDirectory,
    [string]$COpenSslRoot,
    [string]$TrustedCaPath,
    [ValidateRange(30,900)][int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This runner currently supports Windows. The C source can be built separately on other platforms.' }
if ($Language -eq 'dotnet' -and $SdkRoot) {
    throw '-SdkRoot applies only to C builds. The .NET sample uses the pinned NuGet package.'
}
if ($Language -eq 'c' -and -not $CExecutable -and
    ([string]::IsNullOrWhiteSpace($CDependencyDirectory) -or [string]::IsNullOrWhiteSpace($COpenSslRoot))) {
    throw 'Building C requires -CDependencyDirectory and -COpenSslRoot. See device-c/README.md, or supply an existing -CExecutable.'
}
if (-not $BuildOnly) {
    $manifestPath = (Resolve-Path -LiteralPath $EnvironmentFile).Path
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.schemaVersion -ne 1) { throw 'Unsupported environment manifest version.' }
    foreach ($key in @('subscriptionId','tenantId','resourceGroup','hubName','hubHostName','dpsName','dpsIdScope',
        'registrationIds','eventHubsNamespace','eventHubs','consumerGroup')) {
        if (-not $manifest[$key]) { throw "Manifest is missing $key." }
    }
}
if ($Language -eq 'dotnet') {
    & dotnet build (Join-Path $PSScriptRoot 'device-dotnet\Device.csproj') -c Release --nologo
    if ($LASTEXITCODE -ne 0) { throw '.NET device build failed.' }
    $deviceExecutable = (Get-Command dotnet -ErrorAction Stop).Source
    $deviceArgument = Join-Path $PSScriptRoot 'device-dotnet\bin\Release\net10.0\Device.dll'
}
else {
    if (-not $CExecutable) {
        $sdk = & (Join-Path $PSScriptRoot 'Initialize-Sdk.ps1') -SdkRoot $SdkRoot
        $CExecutable = & (Join-Path $PSScriptRoot 'device-c\Build.ps1') -SdkRoot $sdk `
            -DependencyDirectory $CDependencyDirectory -OpenSslRoot $COpenSslRoot
    }
    $deviceExecutable = (Resolve-Path -LiteralPath $CExecutable).Path
    $deviceArgument = '-'
}
& dotnet build (Join-Path $PSScriptRoot 'verifier\Verifier.csproj') -c Release --nologo
if ($LASTEXITCODE -ne 0) { throw 'Verifier build failed.' }
if ($BuildOnly) {
    Write-Host "Build passed for $Language and the shared verifier. No Azure operations performed."
    return
}

$run = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ("MqttV5Samples\runs\" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$acl = Get-Acl -LiteralPath $run
$acl.SetAccessRuleProtection($true, $false)
$user = [Security.Principal.WindowsIdentity]::GetCurrent().User
foreach ($sid in @($user, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $run -AclObject $acl
Write-Host "Private run directory: $run"
$oldKey = $env:MQTTV5_ENROLLMENT_KEY
$oldTrustedCa = $env:MQTTV5_TRUSTED_CA
try {
    if ($Language -eq 'c') {
        if ($TrustedCaPath) {
            $env:MQTTV5_TRUSTED_CA = (Resolve-Path -LiteralPath $TrustedCaPath).Path
        }
        else {
            $roots = @(Get-ChildItem -Path 'Cert:\LocalMachine\Root','Cert:\CurrentUser\Root' |
                Sort-Object Thumbprint -Unique)
            if ($roots.Count -eq 0) { throw 'No trusted roots found. Provide -TrustedCaPath with a trusted PEM bundle.' }
            $bundle = ($roots | ForEach-Object { $_.ExportCertificatePem() }) -join "`n"
            $env:MQTTV5_TRUSTED_CA = Join-Path $run 'trusted-roots.pem'
            [IO.File]::WriteAllText($env:MQTTV5_TRUSTED_CA, $bundle, [Text.Encoding]::ASCII)
        }
    }
    $key = & az iot dps enrollment show --dps-name $manifest.dpsName --resource-group $manifest.resourceGroup `
        --subscription $manifest.subscriptionId --enrollment-id $manifest.registrationIds[$Language] `
        --auth-type login --query attestation.symmetricKey.primaryKey --only-show-errors --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $key) { throw 'Cannot read the DPS bootstrap credential. Check login and data-plane permissions.' }
    $env:MQTTV5_ENROLLMENT_KEY = ($key -join '').Trim()
    $key = $null
    & dotnet (Join-Path $PSScriptRoot 'verifier\bin\Release\net10.0\Verifier.dll') `
        $manifestPath $Language $Scenario $deviceExecutable $deviceArgument $run $TimeoutSeconds
    if ($LASTEXITCODE -ne 0) { throw "Sample failed. Inspect the error above and $run\result.json; do not treat publish alone as a pass." }
}
finally {
    $env:MQTTV5_ENROLLMENT_KEY = $oldKey
    $env:MQTTV5_TRUSTED_CA = $oldTrustedCa
    # C issuance stores fresh operational credentials in this private, per-run directory.
    foreach ($relative in @('device-c-credentials\operational-key.pem',
        'device-c-credentials\operational-cert.pem','trusted-roots.pem')) {
        $path = Join-Path $run $relative
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $credentialDirectory = Join-Path $run 'device-c-credentials'
    if (Test-Path -LiteralPath $credentialDirectory) { [IO.Directory]::Delete($credentialDirectory) }
}
