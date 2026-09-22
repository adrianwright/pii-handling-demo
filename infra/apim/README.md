# APIM PII gateway

## Deployed state

- Environment: the operator's active `azd` environment.
- API: `university-pii-demo`.
- Operation: `POST {APIM_GATEWAY_URL}/student-support/chat`.
- API-scoped subscription: `university-pii-demo-local`; tracing disabled.
- Backend: **enabled**, pinned to `university-student-support` version `1`, with the full `university-student-privacy` guardrail and a direct managed-identity Search tool.

The project Responses call requires **Foundry User** (formerly Azure AI User),
role ID `53ca6127-db72-4b80-b1b0-d745d6d5456d`, assigned to APIM's managed
identity at the project scope. This resolved the upstream HTTP 403, and the
enabled live gateway suite passed. The temporary custom roles and diagnostic
operation were removed. The previous Consumer-only assignment did not
authorize this project API.

There is no fallback to the bare model, no general redaction bypass, and no
probe endpoint. The separate output-probe agent remains operator-only through
`agent\smoke.py`; normal chat cannot select it.

## Request contract

Send the subscription key in `Ocp-Apim-Subscription-Key` and use `Content-Type: application/json`.
Keep that key in the local application's server process, not in browser JavaScript, browser storage, source files, or screenshots. CORS is intentionally not enabled; a local backend should call APIM.

```json
{
  "demo": true,
  "scenarioId": "ingress-redaction",
  "prompt": "Help Jordan Rivera with case CASE-1042. Their email is jordan.rivera@example.edu and phone is 206-555-0142."
}
```

Alternatively, replace `prompt` with `messages`, an array of one to five `{"role":"user","content":"..."}` objects. The gateway processes **every** message. Requests cannot supply system/assistant/tool messages, agent/model selection, prior response IDs, tools, streaming flags, or extra fields.

Limits: 32,768-byte request body, 5,000 characters per text field, five messages, and 30 calls per subscription per 60 seconds. Only `demo: true` is accepted. The demo flag is an acknowledgement, not proof that input is synthetic: never submit real identities.

Supported scenarios: `safe-summary`, `ingress-redaction`, `instruction-refusal`, `jailbreak`, and `residual-pii`. A scenario ID labels intent; it does not change routing or disable any control. All query parameters, including query-string subscription keys, are rejected.

## Redaction and responses

APIM calls the existing Language account using its system-assigned managed identity:

- API version: `2024-11-01`.
- PII model version: `2023-09-01`.
- Language: `en`; offsets: `Utf16CodeUnit`; `loggingOptOut: true`.
- Selected categories: `Person`, `Email`, `PhoneNumber`.
- Placeholders: `[PERSON_1]`, `[EMAIL_1]`, `[PHONE_1]`, with category counters across the request.

The deployed service recognizes all three categories in the synthetic example. The policy checks response status, envelope, document cardinality and IDs, document errors/warnings, entity categories, offsets, lengths, and matching source text. Partial, malformed, overlapping, truncated, or failed results stop the request; no model call follows them.

For the example, `telemetry.piiRedaction.messages[0].content` is:

```text
Help [PERSON_1] with case CASE-1042. Their email is [EMAIL_1] and phone is [PHONE_1].
```

The same telemetry contains `status`, `count`, and detected `categories`. **This is narrow redaction, not anonymization.** DOB, address, SSN, and other unselected categories can remain in this text. It is returned only to the caller for the synthetic demo comparison; do not persist responses in application logs.

| HTTP | Code | Meaning |
|---|---|---|
| 400 | `INVALID_REQUEST` | Invalid shape, content type, size, mode, or query parameters |
| 401 | `SUBSCRIPTION_REQUIRED` | Missing or invalid API subscription key |
| 429 | `RATE_LIMITED` | Subscription rate exceeded |
| 429 | `BACKEND_RATE_LIMITED` | Foundry model quota exceeded; retry later |
| 503 | `PII_REDACTION_FAILED` | Required Language processing failed; Foundry was not called |
| 503 | `BACKEND_NOT_CONFIGURED` | Redaction succeeded, but the guarded agent is disabled |
| 502/503 | `BACKEND_FAILED` | Failed, incomplete, unsupported, or malformed agent response |
| 502 | `BACKEND_AUTHORIZATION_FAILED` | Foundry rejected the gateway identity; no backend body is exposed |
| 422 | `GUARDRAIL_BLOCKED` | Recognized content-filter block without a verified specific category |
| 422 | `JAILBREAK_BLOCKED`, `PII_INPUT_BLOCKED`, `PII_OUTPUT_BLOCKED` | Supported structured filter results identify the block |
| 422 | `STUDENT_ID_OUTPUT_BLOCKED` | APIM, not Foundry, blocked the synthetic `U` plus seven-digit ID format |
| 200 | `SAFE_RESPONSE` | Completed agent assistant text, after the configured agent's guardrails |

The live Foundry API returns `error.content_filters` for input blocks and
top-level `content_filters` for output blocks. The gateway uses the blocked
flag, `source_type`, and category annotations, including
`personally_identifiable_information`, to distinguish outcomes. It also retains
legacy structured mappings. Unknown shapes fail closed. A blocked or incomplete
response is discarded in full: buffered partial PII is never rendered, even if
one message inside the response has `status: completed`.

Both downstream calls use `send-request mode="new"` with managed identity. No caller headers, credentials, or query strings are copied. The original request is never forwarded, including on errors. Responses are nonstreaming with `Cache-Control: no-store`.

## Logging

The API-level Azure Monitor diagnostic overrides inherited settings: zero sampling, no always-log-errors, no client IP logging, zero request/response body bytes, and no captured headers. The policy has no trace or Event Hub logging. Schema errors are detected then immediately rejected with a generic response: APIM's default `prevent` response can otherwise echo rejected values. Validation error details stay in transient policy variables, not the public response.

Do not enable debug tracing/body logging for this API. These settings do not control an operator's separately configured Azure diagnostic exports or future Foundry/agent telemetry; review those before an end-to-end demonstration.

## Redeployment

Deploy only APIM configuration without reprovisioning the model, Search, or other resources:

```powershell
$values = azd env get-values --output json | ConvertFrom-Json
az deployment group create `
  --subscription $values.AZURE_SUBSCRIPTION_ID `
  --resource-group $values.AZURE_RESOURCE_GROUP `
  --name pii-demo-apim-config `
  --template-file .\infra\apim.bicep `
  --parameters .\infra\apim\deployment.parameters.json
```

Copy `deployment.parameters.example.json` to the ignored
`deployment.parameters.json`, then fill it with values from the active
environment. The main `azd` Bicep graph also includes this module. Subscription
keys are generated by APIM and never emitted as deployment outputs.

Before enabling the backend:

1. Deploy a versioned Foundry agent with the full input/output guardrail, privacy instructions, and authorized read-only case tool.
2. Verify guardrails, API version, Responses API support for `store: false`, and actual block payloads against that agent.
3. Set `agentName`, `agentVersion`, and `backendEnabled: true` in the APIM parameters. For full `azd` deployments, also set `agentName`, `agentVersion`, and `apimBackendEnabled` in `infra\main.parameters.json` so later provisioning preserves that intent.
4. Redeploy. Enabling the backend adds the `Foundry User` role for APIM at the project scope.
5. Rehearse each scene against the real agent and adjust only verified block mappings. Do not enable arbitrary client-selected agents or an output-probe bypass.

`Foundry User` is broader than invocation-only access: it grants development
and data-plane operations within the project. This is an explicit demo tradeoff.
For production, evaluate publishing the agent behind an application endpoint
that supports consumer-only access rather than assuming the project API is a
least-privilege production gateway contract.

## Verification

```powershell
.\infra\apim\Test-Policy.ps1
.\infra\apim\Test-Gateway.ps1
```

PowerShell 7 is required. The local suite compiles the actual C# redaction and output expressions from `policy.xml`, not a separately reimplemented algorithm. It uses PowerShell's bundled Newtonsoft.Json assembly without downloading packages. The gateway suite retrieves its key into process memory via Azure management access, sends only synthetic data, verifies redaction, live input guardrails and invalid-input handling, and checks deployed diagnostic settings. It expects the enabled backend; use `-ExpectDisabledBackend` to test an intentionally disabled deployment. Wait at least 60 seconds between repeated full runs to avoid the deliberate rate limit. Model-quota retries are bounded.

Timeout fail-closed behavior is enforced by both `send-request` policies and checked as a local policy invariant. A live Language outage has not been injected into the shared deployment.
