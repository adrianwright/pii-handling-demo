# Foundry student-support agent

Prompt agents run in the existing `university-pii-demo` Foundry project. They
use the existing `university-demo-model` deployment and connect **directly**
to Azure AI Search, not through APIM.

| Agent | Purpose |
|---|---|
| `university-student-support` | Normal, privacy-minimizing casework |
| `university-student-support-output-probe` | Fixed synthetic CASE-1042 output-leak probe; never selected by normal chat |

Source root: `agent`. Deployment context comes from the active azd environment.
If Foundry tooling requires metadata, copy
`.foundry/agent-metadata.example.yaml` to the ignored
`.foundry/agent-metadata.yaml` and set the active environment name. Registration writes
`AGENT_STANDARD_NAME`, `AGENT_STANDARD_VERSION`, `AGENT_PROBE_NAME`, and
`AGENT_PROBE_VERSION` to that environment. Identical definitions reuse the
latest version; changed definitions create a new immutable version.

## Deploy

From the repository root, with Azure CLI and azd already signed in:

```powershell
python -m venv agent\.venv
agent\.venv\Scripts\python -m pip install -r agent\requirements.txt
.\agent\Deploy-Agent.ps1
```

The script deploys only `infra\agent.bicep`, seeds the synthetic Search index,
and registers both agents using the Python SDK with Azure CLI credentials.
It does not enable or repoint APIM. Both agents must retain the complete
`university-student-privacy` policy, attached using its full ARM resource ID.
The existing model's base policy is unchanged.

## Search and identity

The project connection `student-support-cases` uses `CognitiveSearch` / `AAD`
authentication. Local/key authentication remains disabled on Search.
Both the Foundry account and project system-assigned identities have
`Search Index Data Reader` plus `Search Service Contributor` scoped to the
Search service. The native tool needs schema access as well as document
access. No `Search Index Data Contributor` role is granted to either identity.
`Search Service Contributor` permits index/schema administration; the agent's
exposed Search tool itself provides retrieval only, not writes.

Retrieval uses `simple` keyword queries, `top_k=1`, and a mandatory
`is_synthetic eq true` filter. The added `case_reference` keyword field makes
opaque IDs searchable without changing the existing index key. The probe
additionally has the immutable filter `case_id eq 'CASE-1042'`.

Native Search grounding consumes the document `content` field. Seeding appends
the case reference and synthetic name/email/phone/SSN values to this content so both
normal minimization and an attempted output leak are meaningful. The source
records still separate operational fields from private fields.

**Important:** `top_k=1` limits one retrieval, not an entire conversation.
Exact-ID matching, refusing enumeration, and not calling Search without a
case ID are agent instructions, not record-level authorization. This direct
Search design replaces the originally proposed deterministic `get_case` API.
Do not connect real records without enforced record-level access controls.

## Guardrail coverage

Both prompt and completion controls block names, email, phone, addresses, IP
addresses, age, U.S. SSNs, U.S. driver's licenses, U.S./U.K. passports, U.S.
bank accounts, IBANs, and credit cards. Prompt Shields blocks jailbreaks.
The full policy also retains Medium harm filters and protected-material
controls because agent policy assignment overrides the model policy.

The region's filter catalog does not expose a dedicated DOB category.
`Age Protection` is **not** a guarantee of DOB detection. The residual-PII
scene demonstrates address detection. Proprietary `U` + seven-digit student
IDs are additionally blocked by the existing deterministic APIM outbound rule.
Do not claim Foundry recognizes those IDs.

## Validation and activation

```powershell
agent\.venv\Scripts\python -m unittest discover -s agent -p "test_*.py"
.\infra\apim\Test-Policy.ps1
agent\.venv\Scripts\python agent\smoke.py --repeats 3
```

Live checks use pinned versions and `store=false`, cover safe retrieval,
raw-record refusal, unknown IDs, input PII, jailbreaks, and the fixed output
probe. Assertions require actual blocking annotations at the correct
intervention point; a model refusal is not counted as a guardrail block.
Checks suppress response/tool text and print only sanitized outcomes.
Bounded 429 retries accommodate the existing capacity-5 model.

Foundry may return buffered partial text (including synthetic PII) alongside
an `incomplete` content-filter result. This is not releasable output. APIM
discards **all** messages in a blocked/incomplete response, even when an
individual message says `completed`. The checks distinguish private buffered
text from private released text; never display the raw SDK response.

Only enable normal chat after all checks pass. Use the standard agent's
verified name/version in `infra\apim\deployment.parameters.json` and mirror
the activation in `infra\main.parameters.json` so later provisioning retains
the pin. Deploy `infra\apim.bicep` with those parameters. Never configure
normal chat to use the probe.

The public parameter examples leave the backend disabled until a verified agent
version is supplied. APIM's managed identity requires project-scoped **Foundry
User** (formerly Azure AI User) for the project Responses API. This role
includes development/data-plane access and is broader than endpoint-only
Consumer; see `infra\apim\README.md` for the production least-privilege
tradeoff.

The probe is invoked through the operator-only smoke script; it is not
available as a browser scenario or a client-controlled agent selector.
No request can disable APIM redaction. A separate authenticated fixed probe
operation would be needed to show the output-probe scene in the browser.

No application tracing/exporter is enabled by these scripts. `store=false`
does not establish a tenant-wide telemetry/abuse-monitoring retention policy;
inspect Azure diagnostic and platform retention settings separately before
handling anything other than these synthetic fixtures.

References: [Native Search tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/ai-search),
[Foundry guardrails](https://learn.microsoft.com/azure/foundry/guardrails/how-to-create-guardrails).
