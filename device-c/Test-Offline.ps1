# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

[CmdletBinding()]
param([string] $Executable = (Join-Path $PSScriptRoot 'build\mqttv5-device.exe'))
$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path $Executable).Path

function Invoke-OfflineProcess {
    param([string[]] $Arguments = @(), [hashtable] $Variables = @{})
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in @($start.Environment.Keys)) {
        if ($name.StartsWith('MQTTV5_', [StringComparison]::OrdinalIgnoreCase)) {
            $start.Environment.Remove($name) | Out-Null
        }
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($name in $Variables.Keys) { $start.Environment[$name] = $Variables[$name] }
    $process = [Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) {
        $process.Kill($true)
        throw 'Offline test unexpectedly blocked.'
    }
    $result = @{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
    }
    $process.Dispose()
    return $result
}

$result = Invoke-OfflineProcess -Arguments @('--self-test')
if ($result.ExitCode -ne 0) { throw "Parser tests failed: $($result.Stderr)" }
$result = Invoke-OfflineProcess
if ($result.ExitCode -eq 0 -or $result.Stderr -notmatch 'Missing required input' -or $result.Stdout) {
    throw 'Missing-input failure contract failed.'
}
$state = Join-Path $PSScriptRoot ("build\offline-state-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $state | Out-Null
try {
    $trustFile = Join-Path $state 'trusted-roots.pem'
    $publicPlaceholder = 'Offline public trust-file coexistence fixture; not a certificate.'
    Set-Content -LiteralPath $trustFile -Value $publicPlaceholder -NoNewline
    $result = Invoke-OfflineProcess -Arguments @('--self-test-state', $state)
    if ($result.ExitCode -ne 0) { throw 'Exclusive-state creation test failed.' }
    if ((Get-Content -LiteralPath $trustFile -Raw) -ne $publicPlaceholder) {
        throw 'Preexisting public trust file was modified.'
    }
    $private = Join-Path $state 'device-c-credentials'
    $acl = Get-Acl $private
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed = @($sid, 'S-1-5-18')
    if (-not $acl.AreAccessRulesProtected) { throw 'Credential directory inherited a broad DACL.' }
    foreach ($rule in $acl.Access) {
        if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
            throw 'Unexpected principal can access the credential directory.'
        }
    }
    $fakeKey = 'OFFLINE_SENTINEL_KEY_NOT_A_REAL_SECRET'
    $variables = @{
        MQTTV5_DPS_ID_SCOPE = 'offline'
        MQTTV5_REGISTRATION_ID = 'offline'
        MQTTV5_ENROLLMENT_KEY = $fakeKey
        MQTTV5_SCENARIO = 'standard'
        MQTTV5_TEST_ID = 'offline-run'
        MQTTV5_TIMEOUT_SECONDS = '30'
        MQTTV5_STATE_DIRECTORY = $state
    }
    foreach ($scenario in @('standard', 'custom')) {
        $variables.MQTTV5_SCENARIO = $scenario
        $result = Invoke-OfflineProcess -Variables $variables
        if ($result.ExitCode -eq 0 -or $result.Stderr -notmatch 'exclusive private credentials' -or
            $result.Stdout -or $result.Stderr.Contains($fakeKey)) {
            throw 'Reused-state rejection or secret-redaction contract failed.'
        }
    }
    foreach ($case in @(
        @{ Name = 'MQTTV5_SCENARIO'; Value = 'invalid' },
        @{ Name = 'MQTTV5_TEST_ID'; Value = 'bad"json' },
        @{ Name = 'MQTTV5_TIMEOUT_SECONDS'; Value = '0' },
        @{ Name = 'MQTTV5_TIMEOUT_SECONDS'; Value = '901' }
    )) {
        $copy = $variables.Clone()
        $copy[$case.Name] = $case.Value
        $result = Invoke-OfflineProcess -Variables $copy
        if ($result.ExitCode -eq 0 -or $result.Stderr -notmatch 'Invalid scenario' -or
            $result.Stdout -or $result.Stderr.Contains($fakeKey)) {
            throw "Input validation failed: $($case.Name)"
        }
    }
    Write-Output 'Offline validation passed: 9 subprocess cases; protected DACL and unchanged preexisting public trust-file checks.'
}
finally {
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            if (Test-Path -LiteralPath $state) {
                Remove-Item -LiteralPath $state -Recurse -Force
            }
            break
        }
        catch {
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}
