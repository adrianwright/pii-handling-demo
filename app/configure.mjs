import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const appDirectory = fileURLToPath(new URL(".", import.meta.url));
const projectDirectory = fileURLToPath(new URL("..", import.meta.url));
const azureCli = process.platform === "win32" ? "az.cmd" : "az";

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: projectDirectory,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
    ...options,
  }).trim();
}

function parseAzdValues(output) {
  return Object.fromEntries(
    output
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => {
        const separator = line.indexOf("=");
        const key = line.slice(0, separator);
        const value = line.slice(separator + 1).replace(/^"|"$/g, "");
        return [key, value];
      }),
  );
}

const values = parseAzdValues(
  run("azd", ["env", "get-values"], {
    env: {
      ...process.env,
      AZURE_DEV_USER_AGENT: "microsoft_foundry_skill",
    },
  }),
);

const required = [
  "AZURE_SUBSCRIPTION_ID",
  "AZURE_RESOURCE_GROUP",
  "APIM_SERVICE_NAME",
  "APIM_GATEWAY_URL",
];

for (const name of required) {
  if (!values[name]) {
    throw new Error(`Missing ${name}. Run azd provision before configuring the app.`);
  }
}

const resourceUrl =
  `https://management.azure.com/subscriptions/${values.AZURE_SUBSCRIPTION_ID}` +
  `/resourceGroups/${values.AZURE_RESOURCE_GROUP}` +
  `/providers/Microsoft.ApiManagement/service/${values.APIM_SERVICE_NAME}` +
  `/subscriptions/${values.APIM_ADVISOR_SUBSCRIPTION_ID || "university-pii-demo-local"}` +
  "/listSecrets?api-version=2024-05-01";

const secrets = JSON.parse(
  run(
    azureCli,
    ["rest", "--method", "post", "--url", resourceUrl, "--output", "json"],
    { shell: process.platform === "win32" },
  ),
);

if (!secrets.primaryKey) {
  throw new Error("APIM did not return a primary subscription key.");
}

writeFileSync(
  `${appDirectory}.env.local`,
  [
    `APIM_GATEWAY_URL=${values.APIM_GATEWAY_URL}`,
    `APIM_CHAT_URL=${values.APIM_CHAT_URL || `${values.APIM_GATEWAY_URL}/student-support/chat`}`,
    `APIM_SUBSCRIPTION_KEY=${secrets.primaryKey}`,
    `APIM_BACKEND_CONFIGURED=${values.APIM_BACKEND_CONFIGURED || "false"}`,
    "PORT=3000",
    "",
  ].join("\n"),
  { encoding: "utf8", mode: 0o600 },
);

console.log("Configured app/.env.local with protected APIM access.");
