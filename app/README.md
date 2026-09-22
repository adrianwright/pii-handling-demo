# Student Advisor Casework

Dependency-free local web app for privacy-aware university advisor casework. The browser calls only the local Node server. The server keeps the APIM subscription key private and sends chat requests through the protected `student-support` APIM API. APIM uses its managed identity for downstream Azure services.

The local chat endpoint accepts 1-50 non-empty user or assistant messages, with
at least one user message and a maximum of 4,000 characters per message. The
total JSON request body is still limited to 16 KiB, so longer transcripts can
reach the size limit before 50 messages. Only the latest user message is
forwarded to APIM; the visible transcript is not model conversation memory.
Refresh the page to clear the transcript.

## Configure and run

From the repository root:

```powershell
$env:AZURE_DEV_USER_AGENT = 'microsoft_foundry_skill'
azd provision --no-prompt
Set-Location app
npm run configure
npm start
```

Open `http://127.0.0.1:3000`.

`npm run configure` uses the signed-in Azure identity to retrieve the active local-development subscription key and writes it to ignored `app/.env.local`. Never place the key in browser code or commit it.

## Validate

```powershell
Set-Location app
npm test
```
