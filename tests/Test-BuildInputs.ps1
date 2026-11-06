#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$sampleRoot = Split-Path $PSScriptRoot
$runner = Join-Path $sampleRoot 'Run-Sample.ps1'
$cases = @(
    @{},
    @{ CDependencyDirectory = 'unused-dependencies' },
    @{ COpenSslRoot = 'unused-openssl' },
    @{ CDependencyDirectory = ' '; COpenSslRoot = 'unused-openssl' },
    @{ CDependencyDirectory = 'unused-dependencies'; COpenSslRoot = ' ' }
)
foreach ($case in $cases) {
    $rejected = $false
    try {
        & $runner -BuildOnly -Language c @case
    }
    catch {
        if ($_.Exception.Message -notlike 'Building C requires *') { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Incomplete C build inputs were accepted.' }
}
$build = Get-Command (Join-Path $sampleRoot 'device-c\Build.ps1')
foreach ($name in @('SdkRoot', 'DependencyDirectory', 'OpenSslRoot')) {
    $mandatory = @($build.Parameters[$name].Attributes |
        Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory })
    if ($mandatory.Count -eq 0) { throw "C build parameter must be mandatory: $name" }
}
Write-Output 'Build-input validation passed: 5 runner rejection cases and 3 mandatory C build parameters.'
