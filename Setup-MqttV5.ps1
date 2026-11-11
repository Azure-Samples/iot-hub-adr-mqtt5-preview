# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,90}$')][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,38}[a-z0-9]$')][string]$HubName,
    [Parameter(Mandatory)][ValidateSet('australiaeast','centralus','japaneast','uksouth','westus')][string]$Location,
    [Parameter(Mandatory)][guid]$TesterObjectId,
    [ValidateSet('User','ServicePrincipal')][string]$TesterPrincipalType = 'User',
    [ValidateRange(1,90)][int]$CertificateValidityDays = 1,
    [ValidateRange(60,3600)][int]$WaitSeconds = 1800,
    [string]$OutputPath = (Join-Path $PWD 'environment.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$adrName = "$HubName-adr"
$dpsName = "$HubName-dps"
$eventNamespace = "$HubName-eh"
$rootName = 'sample-root'
$issuerName = 'sample-issuer'
$policyName = 'sample-device-policy'
$registrationIds = @{ dotnet = 'sample-dotnet'; c = 'sample-c' }
$outputFile = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFile) { throw "Output already exists: $outputFile. Refusing to overwrite it." }
if (-not (Test-Path -LiteralPath (Split-Path $outputFile) -PathType Container)) {
    throw 'Create the output directory before running setup.'
}
if (-not $PSCmdlet.ShouldProcess(
    "$SubscriptionId/$ResourceGroup",
    "Create NEW $HubName, $adrName, $dpsName, $eventNamespace, certificate authorities, enrollments, roles and routes (billable)"
)) { return }

Get-Command az -ErrorAction Stop | Out-Null
function Invoke-Az {
    param([string[]]$Arguments, [switch]$RetryAuthorization)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $text = & az @Arguments --subscription $SubscriptionId --only-show-errors --output json 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        if ($RetryAuthorization -and ($text -join "`n") -match 'AuthorizationFailed|Unauthorized|Forbidden|\b403\b|\b401\b' -and
            [DateTimeOffset]::UtcNow -lt $deadline) {
            Write-Host 'Waiting for newly assigned data-plane permissions...'
            Start-Sleep -Seconds 10
            continue
        }
        throw "Azure CLI failed: $($Arguments[0..([Math]::Min(3, $Arguments.Count - 1))] -join ' '). Stop and inspect partial resources before retrying."
    } while ($true)
    if ($text) { ($text -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100 }
}
function Wait-For {
    param([string]$Description, [scriptblock]$Read, [scriptblock]$Ready)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $value = & $Read
        if (& $Ready $value) { return $value }
        foreach ($item in @($value)) {
            $properties = $item['properties']
            if ($item['linkingState'] -in 'Failed','Canceled' -or
                ($properties -and $properties['provisioningState'] -in 'Failed','Canceled')) {
                throw "$Description reached a failed state. Inspect the resource before retrying."
            }
        }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Timed out waiting for $Description. Inspect resources before retrying." }
        Write-Host "Waiting for $Description..."
        Start-Sleep -Seconds 10
    } while ($true)
}
function Add-Role {
    param([string]$Principal, [string]$PrincipalType, [string]$Role, [string]$Scope)
    $assignment = Invoke-Az @('role','assignment','create','--assignee-object-id',$Principal,
        '--assignee-principal-type',$PrincipalType,'--role',$Role,'--scope',$Scope)
    if ($assignment.principalId -ne $Principal -or $assignment.scope -ne $Scope) {
        throw "Role assignment readback mismatch for $Role."
    }
}

$version = Invoke-Az @('version')
if ([version]$version['azure-cli'] -lt [version]'2.73.0') { throw 'Azure CLI 2.73 or later is required.' }
$account = Invoke-Az @('account','show')
if (-not $account.tenantId) { throw 'Target subscription tenant could not be determined.' }
$requiredHelp = @(
    @{ command = @('iot','hub','create'); option = '--connection-profile' },
    @{ command = @('iot','adr','ns','link','add'); option = '--hub-availability' },
    @{ command = @('iot','dps','enrollment','create'); option = '--adr-cert-policy-name' },
    @{ command = @('iot','adr','ns','ca','policy','create'); option = '--validity-days' },
    @{ command = @('iot','hub','topic-group','create'); option = '--topic-templates' }
)
foreach ($requirement in $requiredHelp) {
    $help = & az @($requirement.command) --help 2>&1
    if ($LASTEXITCODE -ne 0 -or ($help -join "`n") -notmatch [regex]::Escape($requirement.option)) {
        throw "Install the preview azure-iot extension exposing $($requirement.option)."
    }
}
foreach ($provider in @('Microsoft.Devices','Microsoft.DeviceRegistry','Microsoft.EventHub')) {
    $state = Invoke-Az @('provider','show','--namespace',$provider,'--query','registrationState')
    if ($state -ne 'Registered') { throw "Register $provider in the target subscription before setup." }
}
$groupExists = Invoke-Az @('group','exists','--name',$ResourceGroup)
if ($groupExists) {
    $resources = @(Invoke-Az @('resource','list','--resource-group',$ResourceGroup))
    foreach ($name in @($HubName,$adrName,$dpsName,$eventNamespace)) {
        if ($resources | Where-Object { $_.name -eq $name }) {
            throw "Resource $name already exists. This sample never adopts or updates existing resources."
        }
    }
}
else {
    Invoke-Az @('group','create','--name',$ResourceGroup,'--location',$Location) | Out-Null
}

Write-Host 'Creating the hub, ADR namespace and DPS. Partial resources are retained on failure.'
Invoke-Az @('iot','hub','create','--name',$HubName,'--resource-group',$ResourceGroup,
    '--location',$Location,'--sku','S1','--unit','1','--connection-profile','MqttV5',
    '--system-assigned-mi','--disable-local-auth','true','--yes','--no-wait') | Out-Null
$hubId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Devices/IotHubs/$HubName"
Invoke-Az @('resource','wait','--ids',$hubId,'--api-version','2026-10-01-preview',
    '--created','--interval','15','--timeout',"$WaitSeconds") | Out-Null
$hub = Invoke-Az @('iot','hub','show','--name',$HubName,'--resource-group',$ResourceGroup)
if ($hub.properties.connectionProfile -ne 'MqttV5' -or $hub.properties.state -ne 'Active' -or
    $hub.properties.provisioningState -ne 'Succeeded' -or -not $hub.identity.principalId) {
    throw 'Hub profile, state or managed identity verification failed.'
}
$adr = Invoke-Az @('iot','adr','ns','create','--name',$adrName,'--resource-group',$ResourceGroup,
    '--location',$Location,'--outbound-system-assigned-mi')
$dps = Invoke-Az @('iot','dps','create','--name',$dpsName,'--resource-group',$ResourceGroup,
    '--location',$Location,'--system-assigned-mi')
if ($adr.properties.provisioningState -ne 'Succeeded' -or -not $adr.identity.principalId -or
    $dps.properties.state -ne 'Active' -or -not $dps.identity.principalId) {
    throw 'ADR/DPS creation or managed identity verification failed.'
}
Invoke-Az @('iot','adr','ns','link','add','--ns',$adrName,'--resource-group',$ResourceGroup,
    '--hub-endpoint-name','sample-hub','--hub-id',$hub.id,'--hub-system-assigned-mi',
    '--hub-availability','Available','--hub-allocation-weight','1',
    '--dps-endpoint-name','sample-dps','--dps-id',$dps.id,'--dps-system-assigned-mi') | Out-Null
$null = Wait-For 'ADR hub link' {
    Invoke-Az @('iot','adr','ns','link','hub','show','--name','sample-hub','--ns',$adrName,'-g',$ResourceGroup)
} { param($v) $v.linkingState -eq 'Succeeded' -and $v.provisioning.availability -eq 'Available' }
$null = Wait-For 'ADR DPS link' {
    Invoke-Az @('iot','adr','ns','link','dps','list','--ns',$adrName,'-g',$ResourceGroup)
} { param($v) @($v).Count -eq 1 -and @($v)[0].linkingState -eq 'Succeeded' }
$null = Wait-For 'Hub association' {
    Invoke-Az @('iot','hub','show','-n',$HubName,'-g',$ResourceGroup)
} { param($v) $v.properties.deviceRegistry.linkingProperties.state -eq 'Succeeded' }
$dps = Wait-For 'DPS association' {
    Invoke-Az @('iot','dps','show','-n',$dpsName,'-g',$ResourceGroup)
} {
    param($v)
    @($v.properties.deviceRegistryNamespaces).Count -eq 1 -and
    $v.properties.deviceRegistryNamespaces[0].linkingState -eq 'Succeeded' -and $v.properties.idScope
}

Write-Host 'Configuring managed certificate issuance and two device enrollments.'
Invoke-Az @('iot','adr','ns','ca','create','--name',$rootName,'--ca-type','Root',
    '--ns',$adrName,'-g',$ResourceGroup,'--location',$Location) | Out-Null
Invoke-Az @('iot','adr','ns','ca','create','--name',$issuerName,'--ca-type','ICA',
    '--issuer-type','Microsoft','--issuer-ca-name',$rootName,'--ns',$adrName,
    '-g',$ResourceGroup,'--location',$Location) | Out-Null
$null = Wait-For 'active issuing CA' {
    Invoke-Az @('iot','adr','ns','ca','show','--name',$issuerName,'--ns',$adrName,'-g',$ResourceGroup)
} { param($v) $v.properties.provisioningState -eq 'Succeeded' -and $v.properties.issuer.status -eq 'Active' }
Invoke-Az @('iot','adr','ns','ca','policy','create','--name',$policyName,'--ca-name',$issuerName,
    '--validity-days',"$CertificateValidityDays",'--ns',$adrName,'-g',$ResourceGroup) | Out-Null
$policy = Invoke-Az @('iot','adr','ns','ca','policy','show','--name',$policyName,
    '--ca-name',$issuerName,'--ns',$adrName,'-g',$ResourceGroup)
if ($policy.properties.certificate.validityPeriodInDays -ne $CertificateValidityDays) {
    throw 'Certificate policy validity readback did not match.'
}
Add-Role "$TesterObjectId" $TesterPrincipalType 'Device Provisioning Service Data Contributor' $dps.id
Add-Role "$TesterObjectId" $TesterPrincipalType 'IoT Hub Data Contributor' $hub.id
foreach ($registrationId in $registrationIds.Values) {
    # DPS generates the bootstrap key. Do not write it to the manifest or terminal.
    Invoke-Az @('iot','dps','enrollment','create','--dps-name',$dpsName,'-g',$ResourceGroup,
        '--enrollment-id',$registrationId,'--attestation-type','symmetricKey','--auth-type','login',
        '--provisioning-status','enabled','--adr-namespace',$adrName,
        '--adr-ca-name',$issuerName,'--adr-cert-policy-name',$policyName,
        '--query','registrationId') -RetryAuthorization | Out-Null
    $enrollment = Invoke-Az @('iot','dps','enrollment','show','--dps-name',$dpsName,'-g',$ResourceGroup,
        '--enrollment-id',$registrationId,'--auth-type','login',
        '--query','{status:provisioningStatus,namespace:namespaceName,ca:certificateAuthorityName,policy:certificatePolicyName}')
    if ($enrollment.status -ne 'enabled' -or $enrollment.namespace -ne $adrName -or
        $enrollment.ca -ne $issuerName -or $enrollment.policy -ne $policyName) {
        throw "Enrollment issuance configuration mismatch: $registrationId."
    }
}
Invoke-Az @('iot','hub','topic-group','create','-n',$HubName,'-g',$ResourceGroup,
    '--topic-group-id','fleet','--topic-templates',
    'fleet/vehicles/{deviceId}/telemetry','fleet/vehicles/{deviceId}/faults') | Out-Null

Write-Host 'Creating Event Hubs destinations and distinct standard/custom routes.'
$eh = Invoke-Az @('eventhubs','namespace','create','--name',$eventNamespace,'-g',$ResourceGroup,
    '--location',$Location,'--sku','Standard','--capacity','1','--disable-local-auth','true')
Add-Role $hub.identity.principalId 'ServicePrincipal' 'Azure Event Hubs Data Sender' $eh.id
Add-Role "$TesterObjectId" $TesterPrincipalType 'Azure Event Hubs Data Receiver' $eh.id
foreach ($scenario in @('standard','custom')) {
    $entity = "sample-$scenario"
    Invoke-Az @('eventhubs','eventhub','create','--name',$entity,'--namespace-name',$eventNamespace,
        '-g',$ResourceGroup,'--partition-count','2','--retention-time','1','--cleanup-policy','Delete') | Out-Null
    Invoke-Az @('eventhubs','eventhub','consumer-group','create','--name','sample-verifier',
        '--eventhub-name',$entity,'--namespace-name',$eventNamespace,'-g',$ResourceGroup) | Out-Null
    Invoke-Az @('iot','hub','message-endpoint','create','eventhub','-n',$HubName,'-g',$ResourceGroup,
        '--endpoint-name',$entity,'--identity','[system]',
        '--endpoint-uri',"sb://$eventNamespace.servicebus.windows.net/",'--entity-path',$entity) | Out-Null
    $condition = if ($scenario -eq 'custom') { "topic_matches('fleet/vehicles/+/telemetry')" }
        else { "`$body.scenario = 'standard'" }
    Invoke-Az @('iot','hub','message-route','create','-n',$HubName,'-g',$ResourceGroup,
        '--route-name',$entity,'--endpoint-name',$entity,'--source-type','DeviceMessages',
        '--condition',$condition,'--enabled','true') | Out-Null
}
$configured = Invoke-Az @('iot','hub','show','-n',$HubName,'-g',$ResourceGroup)
$groups = @($configured.properties.mqttV5Settings.topicGroups)
if ($groups.Count -ne 1 -or $groups[0].topicGroupId -ne 'fleet' -or
    @($groups[0].topicTemplates).Count -ne 2) { throw 'Topic-group readback mismatch.' }
foreach ($template in @('fleet/vehicles/{deviceId}/telemetry','fleet/vehicles/{deviceId}/faults')) {
    if ($template -cnotin $groups[0].topicTemplates) { throw "Topic template missing: $template." }
}
foreach ($scenario in @('standard','custom')) {
    $route = @($configured.properties.routing.routes | Where-Object { $_.name -eq "sample-$scenario" })
    $expectedCondition = if ($scenario -eq 'custom') { "topic_matches('fleet/vehicles/+/telemetry')" }
        else { "`$body.scenario = 'standard'" }
    if ($route.Count -ne 1 -or -not $route[0].isEnabled -or
        $route[0].endpointNames[0] -ne "sample-$scenario" -or $route[0].condition -cne $expectedCondition) {
        throw "Route readback mismatch: $scenario."
    }
    $endpoint = @($configured.properties.routing.endpoints.eventHubs | Where-Object { $_.name -eq "sample-$scenario" })
    if ($endpoint.Count -ne 1 -or $endpoint[0].entityPath -ne "sample-$scenario" -or
        $endpoint[0].endpointUri -ne "sb://$eventNamespace.servicebus.windows.net/" -or
        $endpoint[0].authenticationType -ne 'identity') { throw "Endpoint readback mismatch: $scenario." }
}
[ordered]@{
    schemaVersion = 1
    subscriptionId = "$SubscriptionId"
    tenantId = $account.tenantId
    resourceGroup = $ResourceGroup
    hubName = $HubName
    hubHostName = $hub.properties.hostName
    adrNamespace = $adrName
    dpsName = $dpsName
    dpsIdScope = $dps.properties.idScope
    registrationIds = $registrationIds
    eventHubsNamespace = "$eventNamespace.servicebus.windows.net"
    eventHubs = @{ standard = 'sample-standard'; custom = 'sample-custom' }
    consumerGroup = 'sample-verifier'
    testerObjectId = "$TesterObjectId"
    createdResourceIds = @($hub.id,$adr.id,$dps.id,$eh.id)
    verification = 'Configuration read back; device issuance and delivery not yet tested.'
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputFile
Write-Host "Configuration verified. Non-secret manifest: $outputFile"
Write-Host 'Run the device samples to verify issuance, connectivity and delivery. RBAC propagation can take time.'
