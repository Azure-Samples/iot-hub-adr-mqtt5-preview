#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sampleRoot = Split-Path $PSScriptRoot
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("mqtt-v5-setup-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
if (Get-Variable -Name MqttV5Mock -Scope Global -ErrorAction SilentlyContinue) { throw 'Run this test in a fresh PowerShell process.' }
$global:MqttV5Mock = @{
    mode = 'success'
    calls = [Collections.Generic.List[string[]]]::new()
    authorizationAttempts = 0
    waits = 0
}
function Start-Sleep { param([int]$Seconds) $global:MqttV5Mock.waits++ }
function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $global:MqttV5Mock.calls.Add($Arguments)
    $global:LASTEXITCODE = 0
    function Arg([string]$Name) {
        $i = [Array]::IndexOf($Arguments, $Name)
        if ($i -lt 0) { throw "Missing mock argument $Name in $($Arguments -join ' ')" }
        $Arguments[$i + 1]
    }
    if ('--help' -in $Arguments) {
        if ($global:MqttV5Mock.mode -eq 'old-extension') { return 'Old extension' }
        return '--connection-profile --hub-availability --adr-cert-policy-name --validity-days --topic-templates'
    }
    $command = $Arguments -join ' '
    $base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/sample-rg/providers'
    $hubId = "$base/Microsoft.Devices/IotHubs/sample-hub"
    $hub = @{
        id = $hubId; identity = @{principalId = 'hub-principal'}
        properties = @{
            connectionProfile = 'MqttV5'; state = 'Active'; provisioningState = 'Succeeded'
            hostName = 'sample-hub.azure-devices.net'
            deviceRegistry = @{linkingProperties = @{state = 'Succeeded'}}
            mqttV5Settings = @{topicGroups = @(@{
                topicGroupId = 'fleet'; topicTemplates = @('fleet/vehicles/{deviceId}/telemetry','fleet/vehicles/{deviceId}/faults')
            })}
            routing = @{
                routes = @(
                    @{name='sample-standard'; isEnabled=$true; endpointNames=@('sample-standard'); condition="`$body.scenario = 'standard'"}
                    @{name='sample-custom'; isEnabled=$true; endpointNames=@('sample-custom'); condition="topic_matches('fleet/vehicles/+/telemetry')"}
                )
                endpoints = @{eventHubs=@(
                    @{name='sample-standard'; entityPath='sample-standard'; endpointUri='sb://sample-hub-eh.servicebus.windows.net/'; authenticationType='identity'}
                    @{name='sample-custom'; entityPath='sample-custom'; endpointUri='sb://sample-hub-eh.servicebus.windows.net/'; authenticationType='identity'}
                )}
            }
        }
    }
    if ($global:MqttV5Mock.mode -eq 'wrong-profile') { $hub.properties.connectionProfile = 'Classic' }
    if ($global:MqttV5Mock.mode -eq 'wrong-topic') { $hub.properties.mqttV5Settings.topicGroups[0].topicTemplates[0] = 'wrong/topic' }
    if ($global:MqttV5Mock.mode -eq 'wrong-route') { $hub.properties.routing.routes[1].condition = 'true' }
    if ($global:MqttV5Mock.mode -eq 'wrong-endpoint') { $hub.properties.routing.endpoints.eventHubs[1].entityPath = 'sample-standard' }
    $value = switch -Regex ($command) {
        '^version ' { @{'azure-cli'='2.73.0'}; break }
        '^account show ' { @{id='00000000-0000-0000-0000-000000000001'; tenantId='00000000-0000-0000-0000-000000000003'}; break }
        '^provider show ' { if ($global:MqttV5Mock.mode -eq 'unregistered') {'NotRegistered'} else {'Registered'}; break }
        '^group exists ' { $global:MqttV5Mock.mode -ne 'new-group'; break }
        '^group create ' { @{name='sample-rg'}; break }
        '^resource list ' {
            if ($global:MqttV5Mock.mode -eq 'collision') { return '[{"name":"sample-hub"}]' }
            return '[]'
        }
        '^resource wait ' { @{}; break }
        '^iot hub create ' {
            if ($global:MqttV5Mock.mode -eq 'cli-failure') { $global:LASTEXITCODE=7; 'Synthetic creation error' } else { @{} }
            break
        }
        '^iot hub show ' { $hub; break }
        '^iot adr ns create ' {
            @{id="$base/Microsoft.DeviceRegistry/namespaces/sample-hub-adr"; identity=@{principalId='adr-principal'}; properties=@{provisioningState='Succeeded'}}
            break
        }
        '^iot dps (create|show) ' {
            @{id="$base/Microsoft.Devices/provisioningServices/sample-hub-dps"; identity=@{principalId='dps-principal'}
                properties=@{state='Active'; idScope='sample-scope'; deviceRegistryNamespaces=@(@{linkingState='Succeeded'})}}
            break
        }
        '^iot adr ns link add ' { @{}; break }
        '^iot adr ns link hub show ' {
            @{linkingState=$(if($global:MqttV5Mock.mode -eq 'failed-link'){'Failed'}else{'Succeeded'}); provisioning=@{availability='Available'}}
            break
        }
        '^iot adr ns link dps list ' { return '[{"linkingState":"Succeeded"}]' }
        '^iot adr ns ca policy create ' { @{}; break }
        '^iot adr ns ca policy show ' {
            @{properties=@{certificate=@{validityPeriodInDays=$(if($global:MqttV5Mock.mode -eq 'wrong-policy'){90}else{1})}}}; break
        }
        '^iot adr ns ca create ' { @{}; break }
        '^iot adr ns ca show ' { @{properties=@{provisioningState='Succeeded'; issuer=@{status='Active'}}}; break }
        '^role assignment create ' { @{principalId=(Arg '--assignee-object-id'); scope=(Arg '--scope')}; break }
        '^iot dps enrollment create ' {
            $global:MqttV5Mock.authorizationAttempts++
            if ($global:MqttV5Mock.mode -eq 'rbac-delay' -and $global:MqttV5Mock.authorizationAttempts -eq 1) {
                $global:LASTEXITCODE=1; '403 Forbidden'
            } else { Arg '--enrollment-id' }
            break
        }
        '^iot dps enrollment show ' {
            @{status='enabled'; namespace='sample-hub-adr'; ca='sample-issuer'
                policy=$(if($global:MqttV5Mock.mode -eq 'wrong-enrollment'){'wrong'}else{'sample-device-policy'})}
            break
        }
        '^iot hub topic-group create ' { @{}; break }
        '^eventhubs namespace create ' { @{id="$base/Microsoft.EventHub/namespaces/sample-hub-eh"}; break }
        '^eventhubs eventhub (create|consumer-group create) ' { @{}; break }
        '^iot hub message-endpoint create eventhub ' { @{}; break }
        '^iot hub message-route create ' { @{}; break }
        default { throw "Unmocked Azure call: $command" }
    }
    ConvertTo-Json -InputObject $value -Depth 30 -Compress
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
$parameters = @{
    SubscriptionId='00000000-0000-0000-0000-000000000001'
    ResourceGroup='sample-rg'; HubName='sample-hub'; Location='centralus'
    TesterObjectId='00000000-0000-0000-0000-000000000002'
}
$count = 0
try {
    foreach ($case in @(
        @{mode='success'}, @{mode='new-group'}, @{mode='rbac-delay'},
        @{mode='collision'; error='*already exists*'},
        @{mode='wrong-profile'; error='*Hub profile*'},
        @{mode='old-extension'; error='*preview azure-iot*'},
        @{mode='unregistered'; error='*Register Microsoft.Devices*'},
        @{mode='cli-failure'; error='*Azure CLI failed*'},
        @{mode='failed-link'; error='*failed state*'},
        @{mode='wrong-policy'; error='*policy validity*'},
        @{mode='wrong-enrollment'; error='*Enrollment issuance configuration mismatch*'},
        @{mode='wrong-topic'; error='*Topic template missing*'},
        @{mode='wrong-route'; error='*Route readback mismatch*'},
        @{mode='wrong-endpoint'; error='*Endpoint readback mismatch*'}
    )) {
        $global:MqttV5Mock.mode = $case.mode
        $global:MqttV5Mock.calls.Clear()
        $global:MqttV5Mock.authorizationAttempts = 0
        $global:MqttV5Mock.waits = 0
        $output = Join-Path $temporary "$($case.mode).json"
        $threw = $false
        try { & (Join-Path $sampleRoot 'Setup-MqttV5.ps1') @parameters -OutputPath $output }
        catch {
            if (-not $case.ContainsKey('error') -or $_.Exception.Message -notlike $case.error) { throw }
            $threw = $true
        }
        if ($case.ContainsKey('error')) {
            Assert $threw "Expected rejection for $($case.mode)"
            Assert (-not (Test-Path -LiteralPath $output)) 'Failure must not produce a success manifest'
        }
        else {
            $manifest = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
            Assert ($manifest.registrationIds.dotnet -eq 'sample-dotnet' -and $manifest.registrationIds.c -eq 'sample-c') 'Both SDK enrollments'
            Assert ($manifest.createdResourceIds.Count -eq 4) 'Exact resource inventory'
            Assert (@($global:MqttV5Mock.calls | Where-Object { '--help' -notin $_ -and ($_ -join ' ') -match '^iot hub topic-group create ' }).Count -eq 1) 'One topic group only'
            Assert (@($global:MqttV5Mock.calls | Where-Object { '--help' -notin $_ -and ($_ -join ' ') -match '^iot adr ns link add ' }).Count -eq 1) 'Combined linking happens only once'
            Assert (@($global:MqttV5Mock.calls | Where-Object { ($_ -join ' ') -match '^iot hub message-route create ' }).Count -eq 2) 'Distinct routing paths'
            Assert ((Get-Content $output -Raw) -notmatch 'primaryKey|secondaryKey|connectionString|privateKey') 'No credentials in manifest'
            if ($case.mode -eq 'rbac-delay') { Assert ($global:MqttV5Mock.waits -eq 1) 'Retry only the transient authorization failure' }
            Remove-Item -LiteralPath $output
        }
        $count++
    }
    $global:MqttV5Mock.mode='success'
    $global:MqttV5Mock.calls.Clear()
    $output=Join-Path $temporary 'whatif.json'
    & (Join-Path $sampleRoot 'Setup-MqttV5.ps1') @parameters -OutputPath $output -WhatIf
    Assert ($global:MqttV5Mock.calls.Count -eq 0 -and -not (Test-Path $output)) 'WhatIf has no Azure or file side effects'
    $count++
    Write-Host "PASS: $count setup scenarios; no real Azure commands executed."
}
finally {
    Get-ChildItem -LiteralPath $temporary -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    [IO.Directory]::Delete($temporary)
    Remove-Variable -Name MqttV5Mock -Scope Global
}
