# C MQTT v5 companion device

One executable supports `standard` and `custom`. Both use an **individual
enrollment symmetric key only for DPS bootstrap**, submit a new P-256 CSR, require
a freshly issued operational certificate, and connect to the assigned Hub with
X.509 over MQTT v5. DPS itself uses MQTT 3.1.1. An MQTT v3 Hub assignment fails;
there is no silent protocol or SAS Hub fallback.

## Build (Windows x64)

SDK release: **C `2.0.0-preview.2`**, pinned to commit
**`62f7f9580c67a8275f3c92287919ba40c01d472c`**.
Configuration verifies HEAD and rejects tracked changes in the SDK's `c` tree.
It never changes SDK source.

Prerequisites:

- Visual Studio C++ x64 tools with its CMake and Ninja components.
- The pinned `azure-iot-sdk` checkout.
- Existing dependency source directories `azure_sdk_for_c-src` (Azure SDK for C
  1.5.0) and `paho_mqtt_c-src` (Eclipse Paho C v1.3.16, commit
  `4a939ddb01eea581a32fd6f0adcfee51b91d2601`, with the pinned SDK's patches).
- An existing static x64 OpenSSL 3 installation with headers and libraries.

Use a short checkout path on Windows to avoid native object-file path limits.
From this directory, in PowerShell 7.4 or later, prepare the SDK checkout and
provide your dependency locations:

```powershell
$sdkCheckout = & ..\Initialize-Sdk.ps1
$existingDependencySources = 'C:\path\to\dependency-sources'
$staticOpenSsl = 'C:\path\to\static-openssl'
```

Prepare a **dedicated** Paho source copy before the first build. Don't modify a
dependency checkout shared with another project. The following commands require
Git and network access, and the destination must not already exist:

```powershell
$paho = Join-Path $existingDependencySources 'paho_mqtt_c-src'
git clone --branch v1.3.16 --depth 1 https://github.com/eclipse/paho.mqtt.c.git $paho
if ($LASTEXITCODE -ne 0) { throw 'Paho clone failed.' }
Get-ChildItem (Join-Path $sdkCheckout 'c\adapters\paho\patches') -Filter '*.patch' |
    Sort-Object Name | ForEach-Object {
        git -C $paho apply $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "Paho patch failed: $($_.Name)" }
    }
```

The patches supplied by the release SDK fix upstream concurrency and
failed-write cleanup defects. The build rejects unpatched or different Paho
revisions. For details, see the SDK's
[dependency guidance](https://github.com/Azure/azure-iot-sdk/blob/c/2.0.0-preview.2/c/docs/dependencies.md).
Keep the patched dependency outside this repository; don't commit its sources.

With `azure_sdk_for_c-src` also prepared in the dependency directory, build:

```powershell
$exe = .\Build.ps1 -SdkRoot $sdkCheckout `
    -DependencyDirectory $existingDependencySources -OpenSslRoot $staticOpenSsl
.\Test-Offline.ps1 -Executable $exe
```

`DependencyDirectory` must contain the two source directories named above.
All three paths are required; there are no developer-machine cache defaults.
From the repository root, the shared runner accepts the same dependencies:

```powershell
.\Run-Sample.ps1 -BuildOnly -Language c -SdkRoot $sdkCheckout `
    -CDependencyDirectory $existingDependencySources -COpenSslRoot $staticOpenSsl
```

The initializer may download the SDK. Dependency compilation is deliberately
offline: missing dependencies produce an error, not an automatic clone, install,
or SDK modification. Obtain missing prerequisites separately.
It builds dependencies and this executable beneath `device-c\build`; only source
inputs are reused from your dependency directories. Build diagnostics go to the host;
the executable's absolute path is the final and only success-stream object.
CTest runs the C parser/input and SDK initialization self-tests as part of the
build. The SDK now uses caller-owned connection, MQTT adapter, direct-method,
and twin workspaces instead of MQTT factories. The sample allocates those
workspaces for the full client lifetime and requests desired-property pushes
for the standard scenario.

Verified locally with preinstalled dependencies: Release x64, MSVC 19.51,
CMake 4.3.1, OpenSSL 3.6.5, warnings-as-errors for the companion source.
Dependency installation and clean-machine setup still require engineering validation.
The source contains POSIX platform branches, but only the Windows build and
Windows ACL behavior have been validated.

## Run contract

Set these environment variables in the child process, preferably through the
shared runner rather than shell history:

| Variable | Required value |
|---|---|
| `MQTTV5_DPS_ID_SCOPE` | DPS ID scope |
| `MQTTV5_REGISTRATION_ID` | Individual enrollment registration ID |
| `MQTTV5_ENROLLMENT_KEY` | Base64 individual enrollment symmetric key; **secret**, not a group key |
| `MQTTV5_SCENARIO` | Exactly `standard` or `custom` |
| `MQTTV5_TEST_ID` | A new unique ID for this run, 1–128 ASCII letters/digits/`.`/`_`/`-`; a GUID works |
| `MQTTV5_TIMEOUT_SECONDS` | Integer 1–900; overall provisioning and scenario budget |
| `MQTTV5_STATE_DIRECTORY` | Existing fresh per-run private directory created by the runner |
| `MQTTV5_TRUSTED_CA` | Optional PEM trust-bundle path when the platform/default OpenSSL trust is insufficient |

```powershell
# After the runner has provided the environment and private state directory:
& $exe
if ($LASTEXITCODE -ne 0) { throw 'Device sample failed.' }
```

The device exclusively creates `device-c-credentials` below the state directory.
On Windows its protected DACL grants only the current user and SYSTEM full
control, inherited by the generated key/certificate files. An existing child is
an error—even after an unsuccessful run—so credentials cannot accidentally be
reused. Existing unrelated public files such as `trusted-roots.pem` are accepted
and left untouched. The parent must create a unique state directory for each
attempt. After verification, delete both credential PEMs and the empty
`device-c-credentials` child; the parent may retain public trust and result files.
Never check the credential directory into source
control or include it in diagnostic attachments. The sample disables Paho wire
tracing and does not print SAS keys, tokens, certificates, or private keys.

After fresh issuance, connection, and handler registration:

```text
MQTTV5_READY {"deviceId":"<actual assigned Hub device ID>"}
MQTTV5_PUBLISHED {"testId":"<this run's ID>"}
```

Markers are newline-delimited and explicitly flushed. `READY` uses the SDK's
assigned-identity accessor, never an assumed registration ID.
`PUBLISHED` follows a successful QoS 1 acknowledgement, not merely queuing a send.
It proves **broker acknowledgement only, not destination receipt**.

### Standard

- Sends JSON `{"testId":"...","language":"c","scenario":"standard"}` via standard
  Hub telemetry, with JSON content type and UTF-8 content encoding.
- Registers direct method `echo`, returning the supplied payload unchanged with
  status 200. Oversized responses fail explicitly (413); the sample uses the
  SDK's default 512-byte result-body limit.
- Applies a top-level desired `sampleTestId` matching this run's ID from either
  a desired snapshot or patch. Old/mismatching values do not complete the run.
- Reports `{"sampleTestId":"..."}` and requires the service's reported-patch
  verdict to be OK, not just a successful transport exchange.
- After successful publication, echo handling, reported-patch completion, and
  disconnect, emits `MQTTV5_COMPLETE` and exits 0.

The pinned SDK exposes no application callback for direct-method response
PUBACK. The sample checks `respond()` and keeps pumping for at least one second
after responding before completion. **The service verifier must confirm the
method result and twin state independently**; `COMPLETE` is not proof that the
service received the method response.

### Custom

Sends JSON `{"testId":"...","language":"c","scenario":"custom"}` with content type
`application/json` at QoS 1 on
`fleet/vehicles/{actual assigned Hub deviceId}/telemetry`, then disconnects,
emits the bare line `MQTTV5_COMPLETE`, and exits 0 following `PUBLISHED`.
The assigned identity is resolved by
the SDK topic formatter. Hub custom-topic authorization and destination routing
must already be configured outside this sample.

All missing inputs, setup errors, publish rejections, reported-patch refusals,
and unmet deadlines return nonzero with redacted stderr diagnostics.
The runner should additionally enforce a wall-clock process timeout to cover
platform DNS/TLS/transport shutdown delays.

## Offline validation and limits

`Test-Offline.ps1` verifies standard/custom SDK initialization, JSON parsing (including escaped ASCII, unrelated
nested properties, duplicates, malformed/trailing data), required/invalid input
rejection, per-run exclusivity, protected Windows DACL principals, and no secret
output on failure, completion gating, and coexistence with a preexisting public
trust file. It uses synthetic inputs and never attempts a cloud connection.
It removes its own test directories.

No live DPS issuance, Hub connection, destination receipt, direct method, or twin
operation was tested for this companion implementation. The separate service
verifier is the authority for end-to-end outcomes.
