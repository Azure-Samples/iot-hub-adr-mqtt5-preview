#requires -Version 7.4
[CmdletBinding()]
param([string]$SdkRoot)
$ErrorActionPreference = 'Stop'
$pin = '798941ba4440c5f540084af4863c0cd40b4f9624'
if (-not $SdkRoot) {
    $SdkRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "MqttV5Samples\sdk\$pin"
}
if (-not (Test-Path -LiteralPath $SdkRoot)) {
    & git clone --no-checkout https://github.com/Azure/azure-iot-sdk.git $SdkRoot
    if ($LASTEXITCODE -ne 0) { throw 'SDK clone failed.' }
    & git -C $SdkRoot checkout --detach $pin
    if ($LASTEXITCODE -ne 0) { throw 'SDK checkout failed.' }
}
$head = & git -C $SdkRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $pin) { throw "SDK must be at commit $pin; do not modify an existing checkout automatically." }
$changes = & git -C $SdkRoot status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'SDK has tracked changes or cannot be inspected. Use a clean pinned checkout.' }
(Resolve-Path -LiteralPath $SdkRoot).Path
