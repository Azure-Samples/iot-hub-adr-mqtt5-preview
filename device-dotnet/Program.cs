using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Azure.Iot.Device;
using Microsoft.Azure.Iot.Device.Authentication;
using Microsoft.Azure.Iot.Device.Models;
using Microsoft.Azure.Iot.Device.Models.DirectMethods;
using Microsoft.Azure.Iot.Device.Models.Telemetry;
using Microsoft.Azure.Iot.Device.Mqtt;
using Microsoft.Azure.Iot.Device.MQTTv5.Connection;
using Microsoft.Azure.Iot.Device.MQTTv5.CustomTopics;
using Microsoft.Azure.Iot.Device.MQTTv5.DirectMethods;
using Microsoft.Azure.Iot.Device.MQTTv5.Models;
using Microsoft.Azure.Iot.Device.MQTTv5.Telemetry;
using Microsoft.Azure.Iot.Device.MQTTv5.Twin;

if (args is ["--self-test"])
{
    using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    string encoded = CreateCsr("sample-dotnet", key);
    var parsed = CertificateRequest.LoadSigningRequest(Convert.FromBase64String(encoded), HashAlgorithmName.SHA256);
    if (parsed.SubjectName.Name != "CN=sample-dotnet" || encoded.Contains("-----", StringComparison.Ordinal))
        throw new InvalidOperationException("CSR encoding self-test failed.");
    Console.WriteLine("PASS: DPS CSR is signed DER encoded as Base64, without PEM headers.");
    return;
}
string scenario = Required("MQTTV5_SCENARIO");
if (scenario is not ("standard" or "custom")) throw new ArgumentException("Scenario must be standard or custom.");
string testId = Required("MQTTV5_TEST_ID");
string registrationId = Required("MQTTV5_REGISTRATION_ID");
string idScope = Required("MQTTV5_DPS_ID_SCOPE");
int seconds = int.Parse(Required("MQTTV5_TIMEOUT_SECONDS"));
if (seconds is < 30 or > 1800) throw new ArgumentOutOfRangeException(nameof(seconds));
using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
using var operationalKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
var provisioning = new ProvisioningSettings(idScope)
{
    CertificateSigningRequest = new(operationalKey, CreateCsr(registrationId, operationalKey))
};
var authentication = new SymmetricKeyAuthenticationProvider(
    registrationId, idScope, Convert.FromBase64String(Required("MQTTV5_ENROLLMENT_KEY")),
    secondarySymmetricKey: null, issuedCertificatePrivateKey: operationalKey);
Environment.SetEnvironmentVariable("MQTTV5_ENROLLMENT_KEY", null);
using var connection = new ConnectionClient(new ConnectionClientOptions { ReceiveDesiredPropertyUpdates = true });
using var telemetry = new TelemetryClient(connection);
using var topics = new CustomTopicsClient(connection);
using var twin = new TwinClient(connection);
using var methods = new DirectMethodClient(connection);
var desired = new ConcurrentQueue<JsonObject>();
var methodHandled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
twin.DesiredPatchReceived += patch => desired.Enqueue(patch.DesiredProperties);
twin.TwinPushReceived += push =>
{
    if (push.Desired is not null) desired.Enqueue(push.Desired.Properties);
};
methods.DirectMethodProbeReceivedAsync += probe => Task.FromResult(
    probe.MethodName == "echo" ? DirectMethodProbeAck.Accepted() : DirectMethodProbeAck.Rejected(RejectedReason.MethodNotFound));
methods.DirectMethodInvokedAsync += invocation =>
{
    if (invocation.MethodName != "echo")
        return Task.FromResult(new DirectMethodResponse { Status = 404, Payload = "{}"u8.ToArray() });
    using var body = JsonDocument.Parse(invocation.Payload);
    if (body.RootElement.TryGetProperty("testId", out var value) && value.GetString() == testId)
        methodHandled.TrySetResult();
    return Task.FromResult(new DirectMethodResponse { Status = 200, Payload = invocation.Payload });
};
var context = await connection.ProvisionAndConnectAsync(provisioning, authentication, cancellationToken: timeout.Token);
if (context.IssuedClientCertificates is not { Count: > 0 })
    throw new InvalidOperationException("DPS did not issue an operational certificate.");
string deviceId = context.DeviceId;
Console.WriteLine("MQTTV5_READY " + JsonSerializer.Serialize(new { deviceId }));
byte[] payload = JsonSerializer.SerializeToUtf8Bytes(new { testId, scenario, language = "dotnet", temperature = 21.5 });
if (scenario == "standard")
{
    await telemetry.SendTelemetryAsync(new DeviceToCloudTelemetry
    {
        Payload = payload, MessageId = testId, ContentType = "application/json", ContentEncoding = "utf-8"
    }, timeout.Token);
}
else
{
    var ack = await topics.PublishAsync(new MqttPublish
    {
        Topic = $"fleet/vehicles/{deviceId}/telemetry",
        Payload = payload, ContentType = "application/json",
        PayloadFormatIndicator = MqttPayloadFormatIndicator.CharacterData,
        QualityOfServiceLevel = MqttQualityOfServiceLevel.AtLeastOnce
    }, timeout.Token);
    if ((int)ack.ReasonCode >= 0x80) throw new InvalidOperationException($"Custom publish rejected: {ack.ReasonCode}");
}
Console.WriteLine("MQTTV5_PUBLISHED " + JsonSerializer.Serialize(new { testId }));
if (scenario == "standard")
{
    bool reported = false;
    while (!reported || !methodHandled.Task.IsCompletedSuccessfully)
    {
        timeout.Token.ThrowIfCancellationRequested();
        while (desired.TryDequeue(out var patch))
        {
            if (patch["sampleTestId"]?.GetValue<string>() != testId) continue;
            var result = await twin.UpdateReportedPropertiesAsync(
                new ReportedPatchRequest { ReportedProperties = new JsonObject { ["sampleTestId"] = testId } }, timeout.Token);
            if (result.Result != Microsoft.Azure.Iot.Device.Models.Twin.Result.Ok)
                throw new InvalidOperationException($"Reported-property update failed: {result.Result}");
            reported = true;
        }
        await Task.Delay(100, timeout.Token);
    }
}
await connection.DisconnectAsync(cancellationToken: timeout.Token);
Console.WriteLine("MQTTV5_COMPLETE");

static string Required(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
    ? value : throw new InvalidOperationException($"Set {name}.");

static string CreateCsr(string registrationId, ECDsa key)
{
    var subject = new X500DistinguishedNameBuilder();
    subject.AddCommonName(registrationId);
    var request = new CertificateRequest(subject.Build(), key, HashAlgorithmName.SHA256);
    return Convert.ToBase64String(request.CreateSigningRequest());
}
