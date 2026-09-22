"""Register pinned prompt agents using the existing azd environment and Entra auth."""

import json
import os
from pathlib import Path
import shutil
import subprocess

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AISearchIndexResource,
    AzureAISearchTool,
    AzureAISearchToolResource,
    PromptAgentDefinition,
    RaiConfig,
    Reasoning,
)
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import AzureCliCredential

ROOT = Path(__file__).resolve().parent
POLICY = "university-student-privacy"
STANDARD = "university-student-support"
PROBE = "university-student-support-output-probe"
PROTECTIONS = (
    "Name Protection", "Email Protection", "Phone Number Protection",
    "Address Protection", "IP Address Protection", "Age Protection",
    "U.S. Social Security Number (SSN) Protection",
    "U.S. Driver's License Number Protection",
    "U.S. or U.K. Passport Number Protection",
    "U.S. Bank Account Number Protection",
    "International Banking Account Number (IBAN) Protection",
    "Credit card Protection",
)


def cli(executable, *args):
    env = dict(os.environ, AZURE_DEV_USER_AGENT="microsoft_foundry_skill")
    command = shutil.which(executable)
    if not command:
        raise RuntimeError(f"Required executable is missing: {executable}")
    result = subprocess.run(
        [command, *args], cwd=ROOT.parent, env=env, capture_output=True, text=True,
        check=False,
    )
    if result.returncode:
        # CLI stderr may include request content or tokens. Do not persist it.
        raise RuntimeError(f"{executable} {args[0]} failed (exit {result.returncode}). Check Azure authentication and permissions.")
    return result.stdout.strip()


def environment():
    config = json.loads(cli("azd", "env", "get-values", "--output", "json"))
    for key in (
        "AZURE_AI_PROJECT_ENDPOINT", "MODEL_DEPLOYMENT_NAME",
        "AZURE_SEARCH_INDEX_NAME", "AZURE_SEARCH_ENDPOINT",
        "AZURE_SUBSCRIPTION_ID", "AZURE_RESOURCE_GROUP", "AZURE_AI_ACCOUNT_NAME",
    ):
        if not config.get(key):
            raise ValueError(f"Missing azd value: {key}")
    return config


def verify_policy(properties):
    filters = {(f["name"], f["source"]): f for f in properties["contentFilters"]}
    for name in (*PROTECTIONS, "Hate", "Sexual", "Violence", "Selfharm"):
        for source in ("Prompt", "Completion"):
            rule = filters.get((name, source), {})
            if rule.get("enabled") is not True or rule.get("blocking") is not True:
                raise ValueError(f"Guardrail must block {name} on {source}")
            if name in ("Hate", "Sexual", "Violence", "Selfharm") and rule.get("severityThreshold") not in ("Low", "Medium"):
                raise ValueError(f"Guardrail harm threshold is too permissive: {name}")
    jailbreak = filters.get(("Jailbreak", "Prompt"), {})
    if not jailbreak.get("enabled") or not jailbreak.get("blocking"):
        raise ValueError("Prompt Shields must be enabled and blocking")
    if properties.get("mode") not in ("Blocking", "Default"):
        raise ValueError("Guardrail must use synchronous blocking")


def definition(config, connection_id, policy_id, probe=False):
    return PromptAgentDefinition(
        model=config["MODEL_DEPLOYMENT_NAME"],
        instructions=(ROOT / ("probe-instructions.txt" if probe else "instructions.txt")).read_text(encoding="utf-8"),
        reasoning=Reasoning(effort="low"),
        rai_config=RaiConfig(rai_policy_name=policy_id),
        tools=[AzureAISearchTool(azure_ai_search=AzureAISearchToolResource(
            indexes=[AISearchIndexResource(
                project_connection_id=connection_id,
                index_name=config["AZURE_SEARCH_INDEX_NAME"],
                query_type="simple",
                top_k=1,
                filter="is_synthetic eq true" + (" and case_id eq 'CASE-1042'" if probe else ""),
            )],
        ))],
    )


def register(project, name, desired, description):
    try:
        versions = list(project.agents.list_versions(name, limit=1, order="desc"))
    except ResourceNotFoundError:
        versions = []
    if versions and versions[0].definition.as_dict() == desired.as_dict():
        version = versions[0]
    else:
        version = project.agents.create_version(
            agent_name=name, definition=desired, description=description,
            metadata={"data": "synthetic-only", "purpose": "pii-safety-demo"},
        )
    actual = project.agents.get_version(name, version.version)
    if actual.definition.as_dict() != desired.as_dict():
        raise RuntimeError("Persisted agent definition does not match requested configuration")
    return actual


def main():
    config = environment()
    account = (
        f"/subscriptions/{config['AZURE_SUBSCRIPTION_ID']}"
        f"/resourceGroups/{config['AZURE_RESOURCE_GROUP']}"
        f"/providers/Microsoft.CognitiveServices/accounts/{config['AZURE_AI_ACCOUNT_NAME']}"
    )
    policy = json.loads(cli(
        "az", "rest", "--method", "get", "--url",
        f"https://management.azure.com{account}/raiPolicies/{POLICY}?api-version=2025-06-01",
        "--output", "json",
    ))
    verify_policy(policy["properties"])
    with AzureCliCredential() as credential, AIProjectClient(
        endpoint=config["AZURE_AI_PROJECT_ENDPOINT"], credential=credential,
    ) as project:
        connection = project.connections.get(config["AZURE_SEARCH_INDEX_NAME"])
        if connection.target.rstrip("/") != config["AZURE_SEARCH_ENDPOINT"].rstrip("/"):
            raise ValueError("Search connection points to a different service")
        if str(connection.credentials.type).lower() not in ("aad",):
            raise ValueError("Search connection must use Entra authentication")
        for probe, name, prefix in (
            (False, STANDARD, "AGENT_STANDARD"),
            (True, PROBE, "AGENT_PROBE"),
        ):
            version = register(
                project, name, definition(config, connection.id, policy["id"], probe),
                "Synthetic output guardrail probe - not for normal chat" if probe else "Privacy-minimizing university student casework",
            )
            cli("azd", "env", "set", f"{prefix}_NAME", version.name)
            cli("azd", "env", "set", f"{prefix}_VERSION", str(version.version))
            print(f"{version.name} version {version.version}: Search connection and guardrail verified")


if __name__ == "__main__":
    main()
