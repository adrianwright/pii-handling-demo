# Deployed infrastructure

The infrastructure is managed by Azure Developer CLI (`azd`) and Bicep.

## Environment

- **azd environment:** selected by the operator
- **Region:** selected by the operator
- **Resource group:** generated as `rg-${AZURE_ENV_NAME}`
- **APIM:** Basic v2 with a system-assigned managed identity
- **Language:** Text Analytics account with local authentication disabled
- **Foundry:** AI Services account and system-assigned project identity
- **Model:** `gpt-5.6-luna` version `2026-07-09`, Global Standard capacity 5
- **Base RAI policy:** `university-demo-base`
- **Search:** Basic Azure AI Search, local auth disabled, index `student-support-cases`

## Search index and seeding

The `student-support-cases` index separates safe operational fields (`case_id`,
`case_type`, `status`, `office`, `next_action`, `due_date`, `program`) from
synthetic PII fields (`student_name`, `email`, `phone`, `date_of_birth`, `ssn`,
`address`, `private_notes`). Normal casework returns only safe fields; the
PII fields exist so the output guardrail can be demonstrated. Native Foundry
Search grounding also receives synthetic contact fields appended to `content`
by the seed script; normal response minimization is enforced by agent
instructions plus the completion guardrail, not by a Search field projection.

Seed or refresh the index (Entra auth, no API keys):

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
.\search\seed.ps1
```

All records are synthetic (`is_synthetic = true`). Never point the seed script
at real data.

Run this command to retrieve current resource names and endpoints:

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
azd env get-values
```

## Identity access

The APIM managed identity has:

- `Cognitive Services User` on the Language account
- `Cognitive Services OpenAI User` on the Foundry account
- `Search Index Data Reader` on the Search service
- `Foundry User` (formerly Azure AI User) on the Foundry project, for the
  project Responses API. This role includes development/data-plane access,
  not just agent invocation.

The Foundry account and project managed identities have:

- `Search Index Data Reader` on the Search service (for the agent's retrieval tool)
- `Search Service Contributor` on the Search service (native tool schema access)

The Foundry project has a keyless `student-support-cases` Search connection.
The native tool calls Search directly; APIM is not in the retrieval path.

The developer/operator identity has `Search Service Contributor` and
`Search Index Data Contributor` on the Search service, for creating and seeding
the index.

Local authentication is disabled on the Language, Foundry, and Search accounts.
All application traffic should use Microsoft Entra managed identity.

## APIM configuration

The subscription-protected `POST /student-support/chat` API is deployed with strict schema validation, mandatory Language redaction for person/email/phone, typed placeholders, sanitized errors, and API body/header logging disabled.

The APIM backend is **enabled**, pinned to `university-student-support`
version `1`. Both deployment parameter files preserve that pin and enabled
state. Live gateway checks cover safe case retrieval, redaction, input
guardrails, schema rejection, and disabled diagnostic logging. There is no
unguarded-model fallback, and the output-probe agent is not exposed by chat.

See [APIM configuration and request contract](apim/README.md) for the endpoint, targeted deployment command, tests, and backend activation prerequisites.

## Foundry Application Insights

`monitoring.bicep`, included by the main deployment, manages the workspace-based
Application Insights resource, its Log Analytics workspace, and the Foundry
project's `AppInsights` connection. By default, `main.parameters.json` leaves
the resource-name overrides empty so names are generated for the active
environment.

The project's managed identity receives `Monitoring Reader`
(`43d0d8ad-25c7-4714-9337-8ba259a9fe05`) scoped only to Application Insights.
For an existing environment with a portal-created assignment, set
`monitoringReaderRoleAssignmentName` in a local parameter override to avoid a
duplicate-assignment conflict.

The template preserves the portal's public ingestion/query settings, 30-day
workspace retention, and 90-day Application Insights retention setting. It uses
the portal's `ApiKey` connection format, resolving the Application Insights
connection string at deployment time rather than storing or outputting it.
This telemetry connection is separate from the managed-identity application path.
To preserve existing monitoring resources, supply that environment's resource
names and existing assignment GUID in a local parameter override.

This linkage does not add SDK instrumentation or enable prompt/completion content
recording. APIM body/header logging remains disabled. Foundry telemetry may contain
sensitive tool or model content if content recording is enabled separately;
continue using synthetic data only.

## Guardrail scope

The model's base RAI policy remains unchanged. Both agent versions explicitly
use the separate `university-student-privacy` guardrail, with Prompt Shields,
input/output PII categories, and standard harm controls. Tool-returned contact
data remains available for reasoning; the normal agent minimizes it and the
completion guardrail blocks the fixed probe's attempted disclosure. See
[`agent\README.md`](../agent/README.md) for deployment, coverage, and limitations.

## Common commands

Preview changes:

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
azd provision --preview --no-prompt
```

Apply changes:

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
azd provision --no-prompt
```

The Bicep deployment is idempotent. Do not run `azd down` unless the entire demo environment and its data should be removed.
