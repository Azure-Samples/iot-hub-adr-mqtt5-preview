# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $SdkRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $DependencyDirectory,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OpenSslRoot
)
$ErrorActionPreference = 'Stop'
$SdkRoot = (Resolve-Path $SdkRoot).Path
$DependencyDirectory = (Resolve-Path $DependencyDirectory).Path
$OpenSslRoot = (Resolve-Path $OpenSslRoot).Path
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'Visual Studio C++ Build Tools and vswhere are required.' }
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio installation with x64 C++ tools found.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$ninja = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
foreach ($tool in @($vcvars, $cmake, $ninja)) {
    if (-not (Test-Path $tool)) { throw "Required build tool not found: $tool" }
}
$build = Join-Path $PSScriptRoot 'build'
$configure = "`"$cmake`" -S `"$PSScriptRoot`" -B `"$build`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM=`"$ninja`" -DMQTTV5_SDK_ROOT=`"$SdkRoot`" -DMQTTV5_DEPENDENCIES=`"$DependencyDirectory`" -DOPENSSL_ROOT_DIR=`"$OpenSslRoot`""
$command = "call `"$vcvars`" >nul && $configure && `"$cmake`" --build `"$build`" --target mqttv5-device && `"$cmake`" -E chdir `"$build`" `"$([IO.Path]::Combine([IO.Path]::GetDirectoryName($cmake), 'ctest.exe'))`" --output-on-failure"
& $env:ComSpec /d /s /c $command | Out-Host
if ($LASTEXITCODE -ne 0) { throw "C sample build/test failed (exit $LASTEXITCODE)." }
$exe = Join-Path $build 'mqttv5-device.exe'
if (-not (Test-Path $exe)) { throw 'Build did not produce mqttv5-device.exe.' }
Write-Output $exe
