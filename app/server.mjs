import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const appDirectory = fileURLToPath(new URL(".", import.meta.url));
const publicDirectory = resolve(appDirectory, "public");

export function loadEnvironment(path = resolve(appDirectory, ".env.local")) {
  try {
    const content = readFileSync(path, "utf8");
    for (const line of content.split(/\r?\n/)) {
      const match = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
      if (match && process.env[match[1]] === undefined) {
        process.env[match[1]] = match[2];
      }
    }
  } catch (error) {
    if (error.code !== "ENOENT") {
      throw error;
    }
  }
}

export function validateMessages(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 50) {
    return false;
  }

  return (
    value.some((message) => message?.role === "user") &&
    value.every(
      (message) =>
        message &&
        (message.role === "user" || message.role === "assistant") &&
        typeof message.content === "string" &&
        message.content.trim().length > 0 &&
        message.content.length <= 4000,
    )
  );
}

export function extractAdvisorResponse(payload) {
  const content =
    typeof payload?.output === "string"
      ? payload.output
      : payload?.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("APIM returned an invalid chat response.");
  }

  const redaction = payload?.telemetry?.piiRedaction;
  const status = redaction?.status === "REDACTED" ? "REDACTED" : "ALLOWED";
  const redactedInput = Array.isArray(redaction?.messages)
    ? redaction.messages
        .filter(
          (message) =>
            message?.role === "user" && typeof message.content === "string",
        )
        .map((message) => message.content)
        .join("\n")
    : "";

  return {
    id: typeof payload.id === "string" ? payload.id : randomUUID(),
    message: content,
    model: typeof payload.model === "string" ? payload.model : "advisor-agent",
    usage: {
      promptTokens: Number(payload.usage?.prompt_tokens) || 0,
      completionTokens: Number(payload.usage?.completion_tokens) || 0,
    },
    safety: {
      status,
      redactionCount: status === "REDACTED" ? Number(redaction?.count) || 0 : 0,
      categories:
        status === "REDACTED" && Array.isArray(redaction?.categories)
          ? redaction.categories.filter((category) => typeof category === "string")
          : [],
      redactedInput: status === "REDACTED" ? redactedInput : "",
    },
  };
}

function sendJson(response, statusCode, body) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  response.end(JSON.stringify(body));
}

async function readJson(request) {
  const chunks = [];
  let bytes = 0;

  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > 16_384) {
      throw Object.assign(new Error("Request is too large."), { statusCode: 413 });
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw Object.assign(new Error("Request body must be valid JSON."), { statusCode: 400 });
  }
}

async function handleChat(request, response) {
  const correlationId = randomUUID();

  if (!process.env.APIM_GATEWAY_URL || !process.env.APIM_SUBSCRIPTION_KEY) {
    return sendJson(response, 503, {
      error: "NOT_CONFIGURED",
      message: "Run npm run configure after provisioning Azure resources.",
      correlationId,
    });
  }

  const body = await readJson(request);
  if (!validateMessages(body.messages)) {
    return sendJson(response, 400, {
      error: "INVALID_MESSAGES",
      message: "Provide 1-50 non-empty user or assistant messages, up to 4,000 characters each.",
      correlationId,
    });
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 65_000);

  try {
    const lastUserMessage = body.messages.findLast((message) => message.role === "user");
    const upstream = await fetch(
      process.env.APIM_CHAT_URL ||
        `${process.env.APIM_GATEWAY_URL.replace(/\/$/, "")}/student-support/chat`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Ocp-Apim-Subscription-Key": process.env.APIM_SUBSCRIPTION_KEY,
          "X-Correlation-Id": correlationId,
        },
        body: JSON.stringify({
          demo: true,
          scenarioId: "safe-summary",
          prompt: lastUserMessage.content,
        }),
        signal: controller.signal,
      },
    );

    if (!upstream.ok) {
      const failure = await upstream.json().catch(() => ({}));
      return sendJson(response, upstream.status < 500 ? upstream.status : 502, {
        error:
          typeof failure.code === "string" ? failure.code : "ADVISOR_UNAVAILABLE",
        message:
          typeof failure.message === "string"
            ? failure.message
            : "The advisor service could not complete this request.",
        correlationId:
          typeof failure.requestId === "string" ? failure.requestId : correlationId,
      });
    }

    const result = extractAdvisorResponse(await upstream.json());
    return sendJson(response, 200, { ...result, correlationId });
  } catch (error) {
    const timedOut = error.name === "AbortError";
    return sendJson(response, timedOut ? 504 : 502, {
      error: timedOut ? "ADVISOR_TIMEOUT" : "ADVISOR_UNAVAILABLE",
      message: timedOut
        ? "The advisor service took too long to respond."
        : "The advisor service is temporarily unavailable.",
      correlationId,
    });
  } finally {
    clearTimeout(timeout);
  }
}

function serveStatic(request, response) {
  const requestedPath = request.url === "/" ? "/index.html" : request.url;
  const filePath = resolve(publicDirectory, `.${requestedPath.split("?")[0]}`);

  if (!filePath.startsWith(`${publicDirectory}${sep}`)) {
    response.writeHead(404);
    return response.end();
  }

  try {
    const content = readFileSync(filePath);
    const contentTypes = {
      ".html": "text/html; charset=utf-8",
      ".js": "text/javascript; charset=utf-8",
      ".css": "text/css; charset=utf-8",
    };
    response.writeHead(200, {
      "Content-Type": contentTypes[extname(filePath)] || "application/octet-stream",
      "Cache-Control": filePath.endsWith(".html") ? "no-store" : "public, max-age=3600",
      "Content-Security-Policy":
        "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
    });
    response.end(content);
  } catch (error) {
    response.writeHead(error.code === "ENOENT" ? 404 : 500);
    response.end();
  }
}

export function createAppServer() {
  return createServer(async (request, response) => {
    try {
      if (request.method === "GET" && request.url === "/api/health") {
        return sendJson(response, 200, {
          status: "ok",
          apimConfigured: Boolean(
            process.env.APIM_GATEWAY_URL && process.env.APIM_SUBSCRIPTION_KEY,
          ),
          backendConfigured: process.env.APIM_BACKEND_CONFIGURED === "true",
        });
      }

      if (request.method === "POST" && request.url === "/api/chat") {
        return await handleChat(request, response);
      }

      if (request.method === "GET") {
        return serveStatic(request, response);
      }

      response.writeHead(405, { Allow: "GET, POST" });
      response.end();
    } catch (error) {
      sendJson(response, error.statusCode || 500, {
        error: "REQUEST_FAILED",
        message: error.statusCode ? error.message : "The request could not be completed.",
      });
    }
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  loadEnvironment();
  const port = Number(process.env.PORT) || 3000;
  createAppServer().listen(port, "127.0.0.1", () => {
    console.log(`Student Advisor Casework is running at http://127.0.0.1:${port}`);
  });
}
