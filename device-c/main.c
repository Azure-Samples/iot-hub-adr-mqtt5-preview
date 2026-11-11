// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <sddl.h>
#else
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#endif

#include "azure/core/az_json.h"
#include "azure/iot/az_iot.h"
#include "azure/iot/adapters/az_iot_adapter_paho.h"
#include "az_iot_certificate_provider_managed.h"
#include "az_iot_crypto_openssl.h"

#define PATH_CAPACITY 4096
#define TEST_ID_CAPACITY 129

typedef struct
{
    az_iot_connection_client connection;
    az_iot_mqttv5_telemetry_client telemetry;
    az_iot_mqttv5_custom_topic_client custom;
    az_iot_mqttv5_direct_method_client methods;
    az_iot_mqttv5_twin_client twin;
    bool connection_initialized, telemetry_initialized, custom_initialized;
    bool methods_initialized, twin_initialized;
    bool connected, hub_idle, failed, issued, published, method_done;
    bool desired_seen, report_pending, report_done;
    uint64_t method_time;
    const char* test_id;
    uint8_t twin_buffer[1024];
    uint8_t connection_workspace[AZ_IOT_CONNECTION_CLIENT_DEFAULT_WORKSPACE_SIZE];
    uint8_t mqtt_workspace[AZ_IOT_PAHO_WORKSPACE_SIZE];
    uint8_t methods_workspace[AZ_IOT_MQTTV5_DIRECT_METHOD_CLIENT_DEFAULT_WORKSPACE_SIZE];
    uint8_t twin_workspace[AZ_IOT_MQTTV5_TWIN_CLIENT_DEFAULT_WORKSPACE_SIZE];
} device;

static uint64_t now_ms(void)
{
#ifdef _WIN32
    return GetTickCount64();
#else
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000u + (uint64_t)value.tv_nsec / 1000000u;
#endif
}

static void sleep_ms(unsigned int milliseconds)
{
#ifdef _WIN32
    Sleep(milliseconds);
#else
    struct timespec value = { milliseconds / 1000u, (milliseconds % 1000u) * 1000000L };
    nanosleep(&value, NULL);
#endif
}

static bool check(device* d, az_iot_result status, const char* operation)
{
    if (status == AZ_IOT_OK) return true;
    fprintf(stderr, "%s failed: %s\n", operation, az_iot_result_to_string(status));
    d->failed = true;
    return false;
}

static bool valid_test_id(const char* value)
{
    if (value == NULL || !*value || strlen(value) >= TEST_ID_CAPACITY) return false;
    for (const char* p = value; *p; ++p)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')
            || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_' || *p == '.'))
            return false;
    return true;
}

static bool timeout_seconds(const char* value, unsigned int* seconds)
{
    if (!value || !*value || strlen(value) > 3) return false;
    unsigned int n = 0;
    for (const char* p = value; *p; ++p)
    {
        if (*p < '0' || *p > '9') return false;
        n = n * 10u + (unsigned int)(*p - '0');
    }
    if (n < 1 || n > 900) return false;
    *seconds = n;
    return true;
}

static const char* required(const char* name)
{
    const char* value = getenv(name);
    if (value == NULL || *value == '\0')
    {
        fprintf(stderr, "Missing required input: %s\n", name);
        return NULL;
    }
    return value;
}

/* The child is exclusive and has a protected DACL even if a caller supplied
 * an overly broad parent. No provider ever sees a previous run's key. */
static bool create_credentials_directory(const char* root, char* output, size_t capacity)
{
    int count = snprintf(output, capacity, "%s%cdevice-c-credentials", root,
#ifdef _WIN32
        '\\'
#else
        '/'
#endif
    );
    if (count < 0 || (size_t)count >= capacity) return false;
#ifdef _WIN32
    DWORD attributes = GetFileAttributesA(root);
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)
        || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    HANDLE token = NULL;
    DWORD size = 0;
    TOKEN_USER* user = NULL;
    LPSTR sid = NULL;
    PSECURITY_DESCRIPTOR descriptor = NULL;
    bool ok = false;
    char sddl[512];
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) goto done;
    (void)GetTokenInformation(token, TokenUser, NULL, 0, &size);
    user = (TOKEN_USER*)malloc(size);
    if (!user || !GetTokenInformation(token, TokenUser, user, size, &size)
        || !ConvertSidToStringSidA(user->User.Sid, &sid)) goto done;
    count = snprintf(sddl, sizeof(sddl), "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;%s)", sid);
    if (count < 0 || (size_t)count >= sizeof(sddl)
        || !ConvertStringSecurityDescriptorToSecurityDescriptorA(
            sddl, SDDL_REVISION_1, &descriptor, NULL)) goto done;
    SECURITY_ATTRIBUTES security = { sizeof(security), descriptor, FALSE };
    ok = CreateDirectoryA(output, &security) != 0;
done:
    if (descriptor) LocalFree(descriptor);
    if (sid) LocalFree(sid);
    free(user);
    if (token) CloseHandle(token);
    return ok;
#else
    struct stat status;
    if (lstat(root, &status) != 0 || !S_ISDIR(status.st_mode)
        || status.st_uid != geteuid() || (status.st_mode & 0077) != 0) return false;
    return mkdir(output, 0700) == 0;
#endif
}

/* The dependency's string comparison does not decode \uXXXX. Our contract is
 * ASCII, so only ASCII code points can match; no general UTF-16 conversion is
 * necessary. The JSON reader has already validated escape syntax. */
static bool token_equals_ascii(const az_json_token* token, const char* expected)
{
    const uint8_t* text = az_span_ptr(token->slice);
    int32_t length = az_span_size(token->slice);
    size_t index = 0;
    for (int32_t i = 0; i < length; ++i)
    {
        unsigned int ch = text[i];
        if (ch == '\\')
        {
            if (++i >= length) return false;
            ch = text[i];
            if (ch == 'u')
            {
                if (length - i <= 4) return false;
                ch = 0;
                for (int j = 0; j < 4; ++j)
                {
                    unsigned int digit = text[++i];
                    if (digit >= '0' && digit <= '9') digit -= '0';
                    else if (digit >= 'a' && digit <= 'f') digit = digit - 'a' + 10;
                    else if (digit >= 'A' && digit <= 'F') digit = digit - 'A' + 10;
                    else return false;
                    ch = ch * 16 + digit;
                }
            }
            else if (ch != '"' && ch != '\\' && ch != '/') return false;
        }
        if (!expected[index] || ch != (unsigned char)expected[index++]) return false;
    }
    return expected[index] == '\0';
}

/* Only a top-level string property can apply this run's desired setting.
 * Parse the entire document so malformed/trailing data cannot count. */
static bool desired_matches(const uint8_t* payload, size_t length, const char* test_id)
{
    if (!payload || length > INT32_MAX) return false;
    az_json_reader reader;
    if (az_result_failed(az_json_reader_init(
            &reader, az_span_create((uint8_t*)payload, (int32_t)length), NULL))
        || az_result_failed(az_json_reader_next_token(&reader))
        || reader.token.kind != AZ_JSON_TOKEN_BEGIN_OBJECT) return false;
    bool matched = false;
    bool found = false;
    while (az_result_succeeded(az_json_reader_next_token(&reader)))
    {
        if (reader.token.kind == AZ_JSON_TOKEN_END_OBJECT)
            return matched && az_json_reader_next_token(&reader) == AZ_ERROR_JSON_READER_DONE;
        if (reader.token.kind != AZ_JSON_TOKEN_PROPERTY_NAME) return false;
        bool target = token_equals_ascii(&reader.token, "sampleTestId");
        if (az_result_failed(az_json_reader_next_token(&reader))) return false;
        if (target)
        {
            if (found) return false;
            found = true;
            matched = reader.token.kind == AZ_JSON_TOKEN_STRING
                && token_equals_ascii(&reader.token, test_id);
        }
        if (az_result_failed(az_json_reader_skip_children(&reader))) return false;
    }
    return false;
}

static void on_state(const az_iot_connection_state_event* event, void* context)
{
    device* d = (device*)context;
    if (event->scope == AZ_IOT_CONN_SCOPE_HUB)
    {
        d->connected = event->state == AZ_IOT_CONN_STATE_CONNECTED;
        d->hub_idle = event->state == AZ_IOT_CONN_STATE_IDLE;
    }
    bool fallback = event->state == AZ_IOT_CONN_STATE_RETRY_PENDING && event->recovery
        && event->recovery->next_attempt_delay_ms == 0;
    if (event->state == AZ_IOT_CONN_STATE_FAULTED
        || (event->reason != AZ_IOT_OK
            && ((event->scope == AZ_IOT_CONN_SCOPE_HUB && event->state == AZ_IOT_CONN_STATE_IDLE)
                || (event->state == AZ_IOT_CONN_STATE_RETRY_PENDING
                    && !event->is_retriable && !fallback))))
    {
        fprintf(stderr, "%s connection failed: %s\n",
            event->scope == AZ_IOT_CONN_SCOPE_DPS ? "DPS" : "Hub",
            az_iot_result_to_string(event->reason));
        d->failed = true;
    }
}

static void on_certificate(const az_iot_issued_certificate* cert, az_iot_result status, void* context)
{
    device* d = (device*)context;
    d->issued = cert != NULL && cert->count > 0 && check(d, status, "Certificate persistence");
    if (!d->issued) d->failed = true;
}

static void on_publish(az_iot_result status, void* context)
{
    device* d = (device*)context;
    d->published = check(d, status, "Telemetry PUBACK");
}

static void on_custom_publish(const az_iot_publish_result* result, void* context)
{
    device* d = (device*)context;
    if (result == NULL || result->reason_code >= 0x80)
    {
        fprintf(stderr, "Custom telemetry PUBACK rejected.\n");
        d->failed = true;
        return;
    }
    on_publish(result->status, context);
}

static void on_echo(az_iot_direct_method_request request, const char* name,
    const uint8_t* payload, size_t length, void* context)
{
    device* d = (device*)context;
    (void)name;
    if (length > AZ_IOT_MQTTV5_DIRECT_METHOD_CLIENT_DEFAULT_MAX_RESULT_BODY_SIZE)
    {
        (void)az_iot_mqttv5_direct_method_respond(&d->methods, request, 413, NULL, 0);
        fprintf(stderr, "Echo payload exceeds the SDK response limit.\n");
        d->failed = true;
        return;
    }
    if (check(d, az_iot_mqttv5_direct_method_respond(&d->methods, request, 200, payload, length),
        "Echo response"))
    {
        d->method_done = true;
        d->method_time = now_ms();
    }
}

static void on_desired(az_iot_mqttv5_twin_desired_kind kind, uint64_t version,
    const uint8_t* payload, size_t length, void* context)
{
    device* d = (device*)context;
    (void)kind;
    (void)version;
    if (desired_matches(payload, length, d->test_id)) d->desired_seen = true;
}

static void on_report(az_iot_result status, const az_iot_mqttv5_twin_patch_result* result,
    void* context)
{
    device* d = (device*)context;
    if (!check(d, status, "Reported twin response")) return;
    if (!result || result->status != AZ_IOT_MQTTV5_TWIN_PATCH_OK)
    {
        fprintf(stderr, "Service refused the reported twin patch.\n");
        d->failed = true;
        return;
    }
    d->report_done = true;
}

static void pump(device* d)
{
    uint64_t start = now_ms();
    (void)check(d, az_iot_connection_client_do_work(&d->connection, 50), "Connection pump");
    if (d->twin_initialized)
        (void)check(d, az_iot_mqttv5_twin_client_do_work(&d->twin), "Twin pump");
    uint64_t elapsed = now_ms() - start;
    if (elapsed < 50) sleep_ms((unsigned int)(50 - elapsed));
}

static az_iot_connection_client_options connection_options(device* d, bool standard)
{
    az_iot_connection_client_options options = az_iot_connection_client_options_default();
    options.workspace = d->connection_workspace;
    options.workspace_size = sizeof(d->connection_workspace);
    options.mqtt_adapter = az_iot_paho_get_adapter();
    options.mqtt_limits = (az_iot_mqtt_limits){
        .send_buffer_size = 8u * 1024u,
        .receive_buffer_size = 132u * 1024u,
        .max_in_flight_messages = 8,
        .message_store_size = 16u * 1024u,
        .connect_strings_size = 4u * 1024u
    };
    options.mqtt_workspace = d->mqtt_workspace;
    options.mqtt_workspace_size = sizeof(d->mqtt_workspace);
    options.twin_push.push_desired = standard;
    return options;
}

static bool initialize_clients(device* d, const az_iot_connection_client_options* options, bool standard)
{
    if (!check(d, az_iot_connection_client_init(&d->connection, options), "Connection init"))
        return false;
    d->connection_initialized = true;
    if (!check(d, az_iot_connection_client_add_state_observer(&d->connection, on_state, d), "State observer")
        || !check(d, az_iot_connection_client_set_operational_cert_callback(&d->connection, on_certificate, d),
            "Certificate observer")) return false;
    if (standard)
    {
        if (!check(d, az_iot_mqttv5_telemetry_client_init(&d->telemetry, &d->connection), "Telemetry init"))
            return false;
        d->telemetry_initialized = true;
        az_iot_mqttv5_direct_method_client_options methods = az_iot_mqttv5_direct_method_client_options_default();
        methods.workspace = d->methods_workspace;
        methods.workspace_size = sizeof(d->methods_workspace);
        if (!check(d, az_iot_mqttv5_direct_method_client_init(&d->methods, &d->connection, &methods), "Methods init"))
            return false;
        d->methods_initialized = true;
        if (!check(d, az_iot_mqttv5_direct_method_client_register_method(&d->methods, "echo", 0, on_echo, d),
            "Echo registration")) return false;
        az_iot_mqttv5_twin_client_options twin = az_iot_mqttv5_twin_client_options_default();
        twin.workspace = d->twin_workspace;
        twin.workspace_size = sizeof(d->twin_workspace);
        if (!check(d, az_iot_mqttv5_twin_client_init(&d->twin, &d->connection, &twin), "Twin init"))
            return false;
        d->twin_initialized = true;
        return check(d, az_iot_mqttv5_twin_client_set_desired_handler(&d->twin, on_desired, d), "Desired handler")
            && check(d, az_iot_mqttv5_twin_client_set_encode_buffer(&d->twin, AZ_SPAN_FROM_BUFFER(d->twin_buffer)),
                "Twin encode buffer");
    }
    if (!check(d, az_iot_mqttv5_custom_topic_client_init(&d->custom, &d->connection), "Custom topic init"))
        return false;
    d->custom_initialized = true;
    return true;
}

static void deinitialize_clients(device* d)
{
    if (d->twin_initialized) az_iot_mqttv5_twin_client_deinit(&d->twin);
    if (d->methods_initialized) az_iot_mqttv5_direct_method_client_deinit(&d->methods);
    if (d->custom_initialized) az_iot_mqttv5_custom_topic_client_deinit(&d->custom);
    if (d->telemetry_initialized) az_iot_mqttv5_telemetry_client_deinit(&d->telemetry);
    if (d->connection_initialized) az_iot_connection_client_deinit(&d->connection);
}

static bool ready_line(const char* id)
{
    uint8_t buffer[2048];
    az_json_writer writer;
    if (!id || !*id || strlen(id) > INT32_MAX
        || az_result_failed(az_json_writer_init(&writer, AZ_SPAN_FROM_BUFFER(buffer), NULL))
        || az_result_failed(az_json_writer_append_begin_object(&writer))
        || az_result_failed(az_json_writer_append_property_name(&writer, AZ_SPAN_FROM_STR("deviceId")))
        || az_result_failed(az_json_writer_append_string(
            &writer, az_span_create((uint8_t*)id, (int32_t)strlen(id))))
        || az_result_failed(az_json_writer_append_end_object(&writer))) return false;
    az_span json = az_json_writer_get_bytes_used_in_destination(&writer);
    printf("MQTTV5_READY %.*s\n", (int)az_span_size(json), (const char*)az_span_ptr(json));
    fflush(stdout);
    return true;
}

static bool completion_allowed(const device* d, int exit_code)
{
    return exit_code == 0 && !d->failed && d->published && d->hub_idle;
}

static int self_test(void)
{
    const char* documents[] = {
        "{\"sampleTestId\":\"run-1\"}",
        "{\"other\":{\"sampleTestId\":\"wrong\"},\"sampleTestId\":\"run-1\"}",
        "{\"sampleTestId\":\"run\\u002d1\"}",
        "{\"nested\":{\"sampleTestId\":\"run-1\"}}",
        "{\"sampleTestId\":\"wrong\"}",
        "{\"sampleTestId\":null}",
        "{\"sampleTestId\":\"run-1\",\"sampleTestId\":\"run-1\"}",
        "{\"sampleTestId\":\"run-1\"} trailing",
        "[{\"sampleTestId\":\"run-1\"}]",
        "{\"sampleTestId\":\"run-1\""
    };
    for (size_t i = 0; i < sizeof(documents) / sizeof(documents[0]); ++i)
        if (desired_matches((const uint8_t*)documents[i], strlen(documents[i]), "run-1") != (i < 3))
        {
            fprintf(stderr, "Desired JSON test %zu failed.\n", i);
            return 1;
        }
    unsigned int seconds = 0;
    if (!valid_test_id("run-1_A.b") || valid_test_id("") || valid_test_id("quote\"")
        || !timeout_seconds("900", &seconds) || seconds != 900
        || timeout_seconds("0", &seconds) || timeout_seconds("901", &seconds)
        || timeout_seconds("-1", &seconds) || timeout_seconds("1s", &seconds))
        return 1;
    device d = { 0 };
    d.published = true;
    d.hub_idle = true;
    if (!completion_allowed(&d, 0) || completion_allowed(&d, 1)) return 1;
    d.failed = true;
    if (completion_allowed(&d, 0)) return 1;
    d.failed = false;
    d.published = false;
    if (completion_allowed(&d, 0)) return 1;
    d.published = true;
    d.hub_idle = false;
    if (completion_allowed(&d, 0)) return 1;
    for (int scenario = 0; scenario < 2; ++scenario)
    {
        device initialized = { 0 };
        az_iot_connection_client_options options = connection_options(&initialized, scenario == 0);
        options.device_id = "offline-device";
        options.dps.id_scope = "offline-scope";
        options.dps.registration_id = "offline-device";
        bool ok = initialize_clients(&initialized, &options, scenario == 0);
        deinitialize_clients(&initialized);
        if (!ok) return 1;
    }
    puts("Offline tests passed: 10 JSON cases, 8 input cases, 5 completion states, 2 SDK initialization scenarios.");
    return 0;
}

int main(int argc, char** argv)
{
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return self_test();
    if (argc == 3 && strcmp(argv[1], "--self-test-state") == 0)
    {
        char path[PATH_CAPACITY];
        if (!create_credentials_directory(argv[2], path, sizeof(path))
            || create_credentials_directory(argv[2], path, sizeof(path))) return 1;
        puts("Offline exclusive-directory test passed.");
        return 0;
    }
    if (argc != 1) { fprintf(stderr, "Usage: mqttv5-device [--self-test]\n"); return 1; }
#ifdef _WIN32
    if (_putenv_s("MQTT_C_CLIENT_TRACE", "") != 0
        || _putenv_s("MQTT_C_CLIENT_TRACE_LEVEL", "") != 0)
#else
    if (unsetenv("MQTT_C_CLIENT_TRACE") != 0 || unsetenv("MQTT_C_CLIENT_TRACE_LEVEL") != 0)
#endif
    {
        fprintf(stderr, "Cannot disable MQTT wire tracing; refusing to expose credentials.\n");
        return 1;
    }
    const char* scope = required("MQTTV5_DPS_ID_SCOPE");
    const char* registration = required("MQTTV5_REGISTRATION_ID");
    const char* key = required("MQTTV5_ENROLLMENT_KEY");
    const char* scenario = required("MQTTV5_SCENARIO");
    const char* test_id = required("MQTTV5_TEST_ID");
    const char* timeout = required("MQTTV5_TIMEOUT_SECONDS");
    const char* directory = required("MQTTV5_STATE_DIRECTORY");
    const char* ca = getenv("MQTTV5_TRUSTED_CA");
    unsigned int seconds = 0;
    if (!scope || !registration || !key || !scenario || !test_id || !timeout || !directory) return 1;
    if ((strcmp(scenario, "standard") != 0 && strcmp(scenario, "custom") != 0)
        || !valid_test_id(test_id) || !timeout_seconds(timeout, &seconds)
        || strlen(scope) + strlen(registration) > 240)
    {
        fprintf(stderr, "Invalid scenario, test ID, timeout (1..900), or DPS identifier length.\n");
        return 1;
    }
    uint64_t deadline = now_ms() + (uint64_t)seconds * 1000u;
    bool standard = strcmp(scenario, "standard") == 0;
    char credentials[PATH_CAPACITY], key_path[PATH_CAPACITY], cert_path[PATH_CAPACITY];
    if (!create_credentials_directory(directory, credentials, sizeof(credentials)))
    {
        fprintf(stderr, "Cannot create exclusive private credentials directory; use a fresh existing state directory.\n");
        return 1;
    }
#ifdef _WIN32
    const char separator = '\\';
#else
    const char separator = '/';
#endif
    int key_length = snprintf(key_path, sizeof(key_path), "%s%coperational-key.pem", credentials, separator);
    int cert_length = snprintf(cert_path, sizeof(cert_path), "%s%coperational-cert.pem", credentials, separator);
    if (key_length < 0 || (size_t)key_length >= sizeof(key_path)
        || cert_length < 0 || (size_t)cert_length >= sizeof(cert_path))
    {
        fprintf(stderr, "State directory path is too long.\n");
        return 1;
    }
    int exit_code = 1;
    device d = { 0 };
    d.test_id = test_id;
    az_iot_certificate_provider_managed provider = { 0 };
    bool provider_initialized = false;
    az_iot_certificate_provider_managed_options provider_options =
        az_iot_certificate_provider_managed_options_default();
    provider_options.operational_key_pem_path = key_path;
    provider_options.operational_cert_pem_path = cert_path;
    provider_options.key_type = AZ_IOT_MANAGED_KEY_EC_P256;
    if (!check(&d, az_iot_certificate_provider_managed_init(&provider, &provider_options),
        "Managed certificate provider")) goto cleanup;
    provider_initialized = true;
    az_iot_connection_client_options options = connection_options(&d, standard);
    options.device_id = registration;
    options.dps.id_scope = scope;
    options.dps.registration_id = registration;
    options.dps_auth.sas.primary_key_base64 = key;
    options.dps_auth.sas.is_enrollment_group_key = false;
    options.crypto = az_iot_crypto_openssl();
    static uint8_t sas_buffer[AZ_IOT_SAS_BUFFER_SIZE(1, AZ_IOT_SAS_TOKEN_SIZE(256))];
    options.sas_buffer.buffer = sas_buffer;
    options.sas_buffer.size = sizeof(sas_buffer);
    options.trusted_ca.path = ca && *ca ? ca : NULL;
    options.certificate_provider = &provider.base;
    options.dps.request_operational_certificate = true;
    AZ_IOT_CSR_PAYLOAD_STORAGE(csr_buffer);
    options.csr_payload_buffer = AZ_SPAN_FROM_BUFFER(csr_buffer);
    /* hub_auth remains X.509; SAS is only for the MQTT 3.1.1 DPS bootstrap. */
    if (!initialize_clients(&d, &options, standard))
        goto cleanup;
#define REQUIRE(call, label) do { if (!check(&d, (call), (label))) goto cleanup; } while (0)
    REQUIRE(az_iot_connection_client_open(&d.connection), "Connection open");
    while (!d.connected && !d.failed && now_ms() < deadline) pump(&d);
    if (!d.connected || !d.issued || d.failed)
    {
        fprintf(stderr, "Connection did not complete with freshly issued credentials before deadline.\n");
        goto cleanup;
    }
    if (!ready_line(az_iot_connection_client_get_device_id(&d.connection)))
    {
        fprintf(stderr, "Assigned identity could not be emitted.\n");
        goto cleanup;
    }
    char payload[512], report[256], topic[AZ_IOT_MQTTV5_CUSTOM_TOPIC_MAX_LEN + 1];
    int payload_length = snprintf(payload, sizeof(payload),
        "{\"testId\":\"%s\",\"language\":\"c\",\"scenario\":\"%s\"}", test_id, scenario);
    int report_length = snprintf(report, sizeof(report), "{\"sampleTestId\":\"%s\"}", test_id);
    if (payload_length < 0 || (size_t)payload_length >= sizeof(payload)
        || report_length < 0 || (size_t)report_length >= sizeof(report)) goto cleanup;
    if (standard)
    {
        az_iot_telemetry_property properties[] = {
            { AZ_IOT_MSG_PROP_CONTENT_TYPE, "application/json" },
            { AZ_IOT_MSG_PROP_CONTENT_ENCODING, "utf-8" }
        };
        az_iot_telemetry_message message = { 0 };
        message.payload = (const uint8_t*)payload;
        message.payload_len = (size_t)payload_length;
        message.properties = properties;
        message.properties_count = sizeof(properties) / sizeof(properties[0]);
        REQUIRE(az_iot_mqttv5_telemetry_client_send(&d.telemetry, &message, on_publish, &d),
            "Standard telemetry publish");
    }
    else
    {
        REQUIRE(az_iot_mqttv5_custom_topic_client_format_topic(&d.custom,
            "fleet/vehicles/{deviceId}/telemetry", topic, sizeof(topic), NULL), "Assigned custom topic");
        az_iot_mqttv5_custom_topic_message message = { 0 };
        message.topic = topic;
        message.payload = (const uint8_t*)payload;
        message.payload_len = (size_t)payload_length;
        message.qos = AZ_IOT_MQTT_QOS_1;
        message.content_type = "application/json";
        REQUIRE(az_iot_mqttv5_custom_topic_client_publish(&d.custom, &message, on_custom_publish, &d),
            "Custom telemetry publish");
    }
    bool publish_emitted = false;
    while (!d.failed && now_ms() < deadline)
    {
        pump(&d);
        if (d.failed) break;
        if (d.published && !publish_emitted)
        {
            printf("MQTTV5_PUBLISHED {\"testId\":\"%s\"}\n", test_id);
            fflush(stdout);
            publish_emitted = true;
        }
        if (standard && d.connected && d.desired_seen && !d.report_pending)
        {
            d.report_pending = true;
            REQUIRE(az_iot_mqttv5_twin_client_patch_reported(&d.twin,
                (const uint8_t*)report, (size_t)report_length, on_report, &d), "Reported twin patch");
        }
        /* This SDK exposes no method-response PUBACK callback. Keep pumping
         * after respond(); the service verifier is authoritative for receipt. */
        if (publish_emitted && (!standard
            || (d.method_done && d.report_done && now_ms() - d.method_time >= 1000u)))
        {
            exit_code = 0;
            break;
        }
    }
    if (exit_code != 0) fprintf(stderr, "Run failed or deadline expired before required outcomes.\n");
cleanup:
    if (d.connection_initialized)
    {
        az_iot_result closed = az_iot_connection_client_close(&d.connection);
        if (exit_code == 0)
        {
            (void)check(&d, closed, "Connection close");
            while (!d.hub_idle && !d.failed && now_ms() < deadline) pump(&d);
            if (!completion_allowed(&d, exit_code))
            {
                fprintf(stderr, "Disconnect failed or did not complete before deadline.\n");
                exit_code = 1;
            }
        }
    }
    deinitialize_clients(&d);
    if (provider_initialized) az_iot_certificate_provider_managed_deinit(&provider);
    if (completion_allowed(&d, exit_code))
    {
        puts("MQTTV5_COMPLETE");
        fflush(stdout);
    }
    else if (exit_code == 0)
    {
        fprintf(stderr, "Completion invalidated during cleanup.\n");
        exit_code = 1;
    }
    return exit_code;
}
