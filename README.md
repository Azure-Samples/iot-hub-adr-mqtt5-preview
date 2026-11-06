# Azure IoT Hub MQTT v5 and ADR preview samples

Evaluation samples for Azure IoT Hub with the MQTT v5 connection profile.
These are not a production deployment framework. Azure resources incur charges.
No live deployments or end-to-end device runs have been performed for this sample
collection yet; builds and offline checks are not service-conformance evidence.

## Preview limitations

- C builds require separately prepared dependency sources and static OpenSSL.
  Their installation is not automated, and a clean-machine build is not yet validated.
- Preview CLI distribution/access must be confirmed before customer onboarding.
- Live validation must cover standard and custom scenarios in both C and .NET.
- SDK sources and third-party binaries are not vendored into this repository.

Reviewers should leave file-specific comments on the pull request. Include the
language, scenario, tool versions, and sanitized error when reporting a failure;
never attach enrollment keys, operational credentials, or private run directories.

## Experiences

1. [Set up the environment](Setup-MqttV5.ps1): create a new hub, ADR namespace,
   DPS instance, managed identities and links, managed root/intermediate CA and
   certificate policy, two symmetric-key enrollments, custom topic templates,
   Event Hubs destinations, and routes.
2. [Run standard device operations](Run-Sample.ps1): choose C or .NET; obtain an
   operational certificate through DPS, connect with X.509, send telemetry,
   answer an `echo` direct method, and acknowledge a desired-property change
   through reported properties.
3. [Run custom-topic publishing](Run-Sample.ps1): choose C or .NET; publish to
   `fleet/vehicles/{assigned-device-id}/telemetry`, then verify receipt through
   the topic-filtered route.

The shared [.NET verifier](verifier/Program.cs) checks actual destination receipt
for both device languages. For the standard scenario it also invokes the method,
updates desired properties and reads reported properties. It does not interpret
a successful publish as proof of delivery.

## Requirements

- Windows, PowerShell 7.4 or later, Git, and .NET 10 SDK.
- Azure CLI 2.73 or later and the preview `azure-iot` extension exposing
  `--connection-profile`, ADR linking, CA/policy, enrollment certificate policy,
  and topic-group commands. Select the same `AZURE_EXTENSION_DIR` for setup and
  sample runs if your preview extension uses a separate directory.
- For C, the compiler, CMake, Ninja, OpenSSL and SDK platform dependencies
  described in the [C instructions](device-c/README.md).
- Sign in with `az login`. Use an evaluation subscription and preferably a
  dedicated resource group.
- Register `Microsoft.Devices`, `Microsoft.DeviceRegistry`, and
  `Microsoft.EventHub` resource providers before setup.
- Contributor plus permission to assign roles at the applicable scopes
  (Owner includes both). Organizational policy can impose additional restrictions.
- Use the same Azure CLI principal for setup and testing. Supply its object ID
  as `TesterObjectId`; for a service principal also set
  `-TesterPrincipalType ServicePrincipal`.

### SDK version boundary

Both device implementations use the source SDK at commit
`798941ba4440c5f540084af4863c0cd40b4f9624` in
[Azure/azure-iot-sdk](https://github.com/Azure/azure-iot-sdk/tree/798941ba4440c5f540084af4863c0cd40b4f9624).
The published .NET `2.0.0-preview3` package does **not** export the symmetric-key
authentication provider used by this issuance sample. Do not substitute that
package or equate the source project's version suffix with the published binary.
The existing documentation's package-based X.509 example is a different flow.

[Initialize-Sdk.ps1](Initialize-Sdk.ps1) downloads the official SDK into a
per-user local cache and verifies the exact revision and absence of tracked
changes. Alternatively, pass `-SdkRoot` pointing to an existing clean checkout
at that revision. No SDK source modifications are needed.

Check build prerequisites without signing in or creating Azure resources:

```powershell
.\Run-Sample.ps1 -BuildOnly -Language dotnet

$cBuild = @{
    CDependencyDirectory = 'C:\path\to\dependency-sources'
    COpenSslRoot = 'C:\path\to\static-openssl'
}
.\Run-Sample.ps1 -BuildOnly -Language c @cBuild
```

Replace the C paths with prepared prerequisites described in the
[C instructions](device-c/README.md). Reuse `$cBuild` for the C commands below,
or pass `-CExecutable` with an already-built sample executable.

## 1. Set up

Run from this directory. Choose a globally unique, lowercase hub name (3-40
characters); ADR, DPS and Event Hubs namespace names are derived from it.
Setup accepts an existing resource group but refuses to adopt existing named
resources. It never converts an existing hub or removes existing configuration.

```powershell
$subscription = '<subscription-id>'
$tester = az ad signed-in-user show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the signed-in user.' }

.\Setup-MqttV5.ps1 -SubscriptionId $subscription `
    -ResourceGroup mqtt-v5-samples -HubName '<unique-hub-name>' `
    -Location centralus -TesterObjectId $tester -WhatIf

.\Setup-MqttV5.ps1 -SubscriptionId $subscription `
    -ResourceGroup mqtt-v5-samples -HubName '<unique-hub-name>' `
    -Location centralus -TesterObjectId $tester
```

`-WhatIf` describes the mutation without calling Azure or creating files.
`-CertificateValidityDays` defaults to 1 (allowed 1-90).
`-WaitSeconds` defaults to 1800 per readiness check.
`-OutputPath` defaults to `environment.json` in the current directory and must
not already exist. The output contains identifiers, not credentials.

The default deployment includes one S1 IoT Hub unit, one Standard Event Hubs
namespace with one capacity unit, two event hubs, DPS and ADR certificate
resources. Check pricing and policy before executing it.
Hub and Event Hubs service-side SAS authentication are disabled; the verifier
uses the Azure CLI identity. DPS bootstrap symmetric keys are device onboarding
credentials, not Hub SAS credentials.

### Failure and rerun behavior

Setup is **new-environment-only**, not a resumable reconciler. On failure it
stops, leaves partial resources for inspection, and does not report success.
Do not blindly rerun it: the ADR link is permanent, and combined link creation
must not be repeated after partial linking. Resolve the cause and explicitly
clean up the dedicated failed environment or use new resource names.
New role assignments can take time to propagate. Enrollment creation retries
authorization failures for a bounded period; other errors stop immediately.

## 2. Standard telemetry, direct methods and twins

```powershell
.\Run-Sample.ps1 -EnvironmentFile .\environment.json -Language dotnet -Scenario standard
.\Run-Sample.ps1 -EnvironmentFile .\environment.json -Language c -Scenario standard @cBuild
```

The runner builds the selected device and shared verifier. It starts the
destination receiver before the publisher, then:

1. Fetches the corresponding enrollment's bootstrap key into process memory.
2. Starts a fresh device instance, which generates its operational key and CSR.
3. Provisions through DPS and connects to the assigned hub with the issued
   X.509 certificate. Issuance must succeed; there is no Hub SAS fallback.
4. Verifies a direct-method response with the run's unique test ID.
5. Sets desired `sampleTestId`, then waits for the device to report the same ID.
6. Verifies the JSON telemetry's test ID, scenario and language at Event Hubs.
7. Requires successful device completion as well as all service-side checks.

## 3. Custom-topic telemetry and routing

```powershell
.\Run-Sample.ps1 -EnvironmentFile .\environment.json -Language dotnet -Scenario custom
.\Run-Sample.ps1 -EnvironmentFile .\environment.json -Language c -Scenario custom @cBuild
```

The assigned device ID, not an assumed registration ID, is used in the topic.
The custom route uses `topic_matches('fleet/vehicles/+/telemetry')` and delivers
to `sample-custom`. The standard route selects `$body.scenario = 'standard'`
and delivers to `sample-standard`. Separate destinations prevent an unrelated
all-messages route from making the custom route appear to work.

These are standalone Azure Event Hubs resources, not the unsupported built-in
Hub endpoint. The receiver has its own Data Receiver permission; Hub has Data
Sender permission.

## Results, secrets and timeouts

- `-TimeoutSeconds` defaults to 300 and accepts 30-900.
- Each run creates a private directory under
  `%LOCALAPPDATA%\MqttV5Samples\runs`, accessible to the current user and SYSTEM.
- `result.json` records PASS only after all scenario checks pass. Errors produce
  a nonzero exit; inspect the terminal error and any result file.
- Each run requests a new operational certificate. The .NET operational key
  remains in memory. Temporary C credentials are removed on exit by the runner;
  after a forced process termination, inspect the private run directory.
- For C, the Windows runner exports public roots from the operating system
  certificate stores into a temporary PEM trust bundle. Alternatively, supply
  `-TrustedCaPath` with your trusted PEM bundle. TLS verification is never disabled.
- Keys are passed through the child process environment, never command-line
  arguments or the environment manifest. Do not enable credential logging or
  copy private runtime directories into source control.
- Run scenarios sequentially. Concurrent runs sharing an enrollment can replace
  each other's Hub connections. Use separate deployments for parallel testers.
- A timeout is a failed or incomplete test, not proof that routing is unsupported.
  Check role propagation, endpoint health, TLS/network access and enrollment policy.
- This sample demonstrates initial DPS issuance, not automatic certificate renewal
  or renewal directly through Hub.

## Cleanup

Stop sample processes first. Review `createdResourceIds` in the environment
manifest. For an exclusively dedicated evaluation resource group, inspect its
contents before explicitly deleting it:

```powershell
az resource list --subscription '<subscription-id>' --resource-group mqtt-v5-samples --output table
az group delete --subscription '<subscription-id>' --name mqtt-v5-samples
```

Keep the confirmation prompt. Do not delete a shared resource group. If the
group was shared, remove only the sample resources and their scoped assignments
after review. Setup and test runners never delete Azure resources automatically.
Removing local credentials does not revoke already issued certificates.

## Offline validation

Run [tests/Test-Setup.ps1](tests/Test-Setup.ps1) for mocked orchestration checks,
then build the device/verifier and run both .NET executables with `--self-test`.
Run [tests/Test-BuildInputs.ps1](tests/Test-BuildInputs.ps1) for C build-input
validation before any SDK download or Azure operation.
The device self-test checks the signed CSR encoding; the verifier checks strict
test-ID, scenario and language correlation. The C build runs its offline CTest.
Builds and offline tests do not deploy resources or certify the service flow.
Public release, live deployment and final end-to-end validation are separate steps.
