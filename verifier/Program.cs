using System.Diagnostics;
using System.Text.Json;
using Azure.Identity;
using Azure.Messaging.EventHubs.Consumer;
using Microsoft.Azure.Devices;

if (args is ["--self-test"])
{
    using var good = JsonDocument.Parse("""{"testId":"run-1","scenario":"custom","language":"c"}""");
    if (!Matches(good.RootElement, "run-1", "custom", "c") ||
        Matches(good.RootElement, "other", "custom", "c") ||
        Matches(good.RootElement, "run-1", "standard", "c") ||
        Matches(good.RootElement, "run-1", "custom", "dotnet"))
        throw new InvalidOperationException("Receipt correlation self-test failed.");
    Console.WriteLine("PASS: receipt requires matching testId, scenario and language.");
    return;
}
if (args.Length != 7) throw new ArgumentException("Expected manifest, language, scenario, device executable, device argument, state directory, timeout seconds.");
using var manifestDocument = JsonDocument.Parse(await File.ReadAllTextAsync(args[0]));
JsonElement manifest = manifestDocument.RootElement;
string language = args[1], scenario = args[2], stateDirectory = args[5];
if (language is not ("dotnet" or "c") || scenario is not ("standard" or "custom"))
    throw new ArgumentException("Invalid language or scenario.");
int seconds = int.Parse(args[6]);
if (seconds is < 30 or > 900) throw new ArgumentOutOfRangeException(nameof(seconds));
string testId = Guid.NewGuid().ToString("N");
using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
var token = timeout.Token;
using var receiverStop = CancellationTokenSource.CreateLinkedTokenSource(token);
var credential = new AzureCliCredential(new AzureCliCredentialOptions
{
    TenantId = manifest.GetProperty("tenantId").GetString()
});
await using var receiver = new EventHubConsumerClient(
    manifest.GetProperty("consumerGroup").GetString(),
    manifest.GetProperty("eventHubsNamespace").GetString(),
    manifest.GetProperty("eventHubs").GetProperty(scenario).GetString(), credential);
var result = new Dictionary<string, object>
{
    ["testId"] = testId, ["scenario"] = scenario, ["language"] = language,
    ["status"] = "FAIL", ["issuedCertificateAndConnected"] = false,
    ["publishAcknowledged"] = false, ["destinationReceived"] = false
};
using var device = new Process();
bool deviceStarted = false;
Task? deviceOutput = null;
Task? deviceError = null;
Task? receipt = null;
Task[] readers = [];
try
{
    // Establish the cursor before launching the publisher; never start at the latest event afterward.
    DateTimeOffset receiveFrom = DateTimeOffset.UtcNow.AddSeconds(-5);
    string[] partitions = await receiver.GetPartitionIdsAsync(token);
    var delivered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    async Task ReadPartition(string partition)
    {
        try
        {
            await foreach (var item in receiver.ReadEventsFromPartitionAsync(
                partition, EventPosition.FromEnqueuedTime(receiveFrom),
                new ReadEventOptions { MaximumWaitTime = TimeSpan.FromSeconds(1) }, receiverStop.Token))
            {
                if (item.Data is null) continue;
                using var body = JsonDocument.Parse(item.Data.EventBody);
                if (Matches(body.RootElement, testId, scenario, language)) { delivered.TrySetResult(); return; }
            }
        }
        catch (OperationCanceledException) when (receiverStop.IsCancellationRequested) { }
    }
    readers = partitions.Select(ReadPartition).ToArray();
    receipt = ObserveReceipt();
    async Task ObserveReceipt()
    {
        while (!delivered.Task.IsCompleted)
        {
            foreach (var reader in readers)
                if (reader.IsFaulted) await reader;
            await Task.Delay(100, token);
        }
        await delivered.Task;
        receiverStop.Cancel();
        await Task.WhenAll(readers);
    }
    var ready = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
    bool published = false, completed = false;
    device.StartInfo = new ProcessStartInfo(args[3]) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
    if (args[4] != "-") device.StartInfo.ArgumentList.Add(args[4]);
    var environment = device.StartInfo.Environment;
    environment["MQTTV5_DPS_ID_SCOPE"] = manifest.GetProperty("dpsIdScope").GetString();
    environment["MQTTV5_REGISTRATION_ID"] = manifest.GetProperty("registrationIds").GetProperty(language).GetString();
    environment["MQTTV5_TEST_ID"] = testId;
    environment["MQTTV5_SCENARIO"] = scenario;
    environment["MQTTV5_TIMEOUT_SECONDS"] = seconds.ToString();
    environment["MQTTV5_STATE_DIRECTORY"] = stateDirectory;
    if (string.IsNullOrWhiteSpace(environment["MQTTV5_ENROLLMENT_KEY"]))
        throw new InvalidOperationException("Missing bootstrap key in the process environment.");
    if (!device.Start()) throw new InvalidOperationException("Could not start device.");
    deviceStarted = true;
    Environment.SetEnvironmentVariable("MQTTV5_ENROLLMENT_KEY", null);
    environment.Remove("MQTTV5_ENROLLMENT_KEY");
    deviceError = DrainErrors();
    async Task DrainErrors()
    {
        while (await device.StandardError.ReadLineAsync(token) is { } line)
            Console.Error.WriteLine(line);
    }
    deviceOutput = ReadDevice();
    async Task ReadDevice()
    {
        while (await device.StandardOutput.ReadLineAsync(token) is { } line)
        {
            if (line.StartsWith("MQTTV5_READY ", StringComparison.Ordinal))
            {
                using var message = JsonDocument.Parse(line["MQTTV5_READY ".Length..]);
                ready.TrySetResult(message.RootElement.GetProperty("deviceId").GetString()
                    ?? throw new InvalidOperationException("Device ID missing."));
            }
            else if (line.StartsWith("MQTTV5_PUBLISHED ", StringComparison.Ordinal))
            {
                using var message = JsonDocument.Parse(line["MQTTV5_PUBLISHED ".Length..]);
                published = message.RootElement.GetProperty("testId").GetString() == testId;
            }
            else if (line == "MQTTV5_COMPLETE") completed = true;
            Console.WriteLine(line);
        }
        if (!ready.Task.IsCompleted) ready.TrySetException(new InvalidOperationException("Device exited before connecting."));
    }
    Task first = await Task.WhenAny(ready.Task, deviceOutput).WaitAsync(token);
    if (first == deviceOutput) await deviceOutput;
    string deviceId = await ready.Task.WaitAsync(token);
    result["issuedCertificateAndConnected"] = true;
    result["deviceId"] = deviceId;
    if (scenario == "standard")
    {
        using var service = ServiceClient.Create(manifest.GetProperty("hubHostName").GetString(), credential);
        using var registry = RegistryManager.Create(manifest.GetProperty("hubHostName").GetString(), credential);
        var method = new CloudToDeviceMethod("echo", TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));
        method.SetPayloadJson(JsonSerializer.Serialize(new { testId }));
        var response = await service.InvokeDeviceMethodAsync(deviceId, method, token);
        using var responseJson = JsonDocument.Parse(response.GetPayloadAsJson());
        if (response.Status != 200 || responseJson.RootElement.GetProperty("testId").GetString() != testId)
            throw new InvalidOperationException("Direct-method response did not match.");
        result["directMethodRoundTrip"] = true;
        var before = await registry.GetTwinAsync(deviceId, token);
        string patch = JsonSerializer.Serialize(new { properties = new { desired = new { sampleTestId = testId } } });
        await registry.UpdateTwinAsync(deviceId, patch, before.ETag, token);
        while (true)
        {
            var actual = await registry.GetTwinAsync(deviceId, token);
            if (actual.Properties.Reported.Contains("sampleTestId") && (string)actual.Properties.Reported["sampleTestId"] == testId)
                break;
            await Task.Delay(1000, token);
        }
        result["desiredToReportedRoundTrip"] = true;
    }
    await receipt.WaitAsync(token);
    result["destinationReceived"] = true;
    await device.WaitForExitAsync(token);
    await deviceOutput;
    await deviceError;
    if (device.ExitCode != 0 || !published || !completed)
        throw new InvalidOperationException($"Device did not complete successfully (exit {device.ExitCode}).");
    result["publishAcknowledged"] = true;
    result["status"] = "PASS";
}
finally
{
    timeout.Cancel();
    receiverStop.Cancel();
    if (deviceStarted && !device.HasExited) { device.Kill(entireProcessTree: true); await device.WaitForExitAsync(); }
    await File.WriteAllTextAsync(Path.Combine(stateDirectory, "result.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
    Console.WriteLine(JsonSerializer.Serialize(result));
    await Task.WhenAll(readers);
    await FinishReader(deviceOutput, token);
    await FinishReader(deviceError, token);
    await FinishReader(receipt, token);
}

static async Task FinishReader(Task? reader, CancellationToken cancellationToken)
{
    if (reader is null) return;
    try { await reader; }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
}

static bool Matches(JsonElement body, string id, string scenario, string language) =>
    body.ValueKind == JsonValueKind.Object &&
    body.TryGetProperty("testId", out var test) && test.ValueKind == JsonValueKind.String && test.GetString() == id &&
    body.TryGetProperty("scenario", out var kind) && kind.ValueKind == JsonValueKind.String && kind.GetString() == scenario &&
    body.TryGetProperty("language", out var sdk) && sdk.ValueKind == JsonValueKind.String && sdk.GetString() == language;
