#Requires -Version 7
$ErrorActionPreference = 'Stop'
[xml]$policy = Get-Content (Join-Path $PSScriptRoot 'policy.xml') -Raw
$expression = ($policy.policies.inbound.'set-variable' | Where-Object name -EQ redactionResult).value
$body = $expression.Substring(2, $expression.Length - 3)
$outputExpression = ($policy.policies.inbound.'set-variable' | Where-Object name -EQ safeResult).value
$outputBody = $outputExpression.Substring(2, $outputExpression.Length - 3)
$source = @"
using System;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
public interface IResponse {
    int StatusCode { get; }
    ResponseBody Body { get; }
}
public class ResponseBody {
    public string Json;
    public T As<T>() { return JsonConvert.DeserializeObject<T>(Json); }
}
public class TestResponse : IResponse {
    public int StatusCode { get; set; }
    public ResponseBody Body { get; set; }
}
public class PolicyContext {
    public Dictionary<string, object> Variables = new Dictionary<string, object>();
}
public static class RedactionPolicy {
    public static string Run(string inputMessages, string languageBody) {
        var context = new PolicyContext();
        context.Variables["userMessages"] = inputMessages;
        context.Variables["languageBody"] = languageBody;
        $body
    }
}
public static class OutputPolicy {
    public static string Run(int responseStatus, string responseBody) {
        var context = new PolicyContext();
        context.Variables["foundryResponse"] = new TestResponse {
            StatusCode = responseStatus, Body = new ResponseBody { Json = responseBody }
        };
        $outputBody
    }
}
"@
$references = @([Newtonsoft.Json.Linq.JObject].Assembly.Location) + @(
    Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | Select-Object -ExpandProperty FullName
)
Add-Type -TypeDefinition $source -ReferencedAssemblies $references -CompilerOptions '/nowarn:1701'

function Invoke-Redaction($Messages, $Response) {
    [RedactionPolicy]::Run(
        (ConvertTo-Json -InputObject $Messages -Depth 30 -Compress),
        (ConvertTo-Json -InputObject $Response -Depth 30 -Compress)
    ) | ConvertFrom-Json -Depth 30
}

function Assert-Rejected([string]$Name, $Messages, $Response) {
    $rejected = $false
    try { $null = Invoke-Redaction $Messages $Response }
    catch [System.Management.Automation.MethodInvocationException] { $rejected = $true }
    if (-not $rejected) { throw "FAIL: $Name was accepted" }
    Write-Output "PASS: $Name"
}

$messages = @(@{role = 'user'; content = 'Help Jordan Rivera; jordan.rivera@example.edu.'})
$good = @{
    kind = 'PiiEntityRecognitionResults'
    results = @{
        errors = @()
        documents = @(@{
            id = '0'; warnings = @(); redactedText = 'Help *************; ************************.'
            entities = @(
                @{category = 'Person'; offset = 5; length = 13; text = 'Jordan Rivera'},
                @{category = 'Email'; offset = 20; length = 25; text = 'jordan.rivera@example.edu'}
            )
        })
    }
}
$result = Invoke-Redaction $messages $good
if ($result.messages[0].content -cne 'Help [PERSON_1]; [EMAIL_1].' -or $result.count -ne 2) {
    throw 'Typed placeholders or entity count incorrect'
}
Write-Output 'PASS: typed placeholders'

function Copy-Fixture { $good | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -Depth 30 }
$bad = Copy-Fixture; $bad.results.errors = @(@{id = '0'; error = @{code = 'InvalidDocument'}})
Assert-Rejected 'document errors' $messages $bad
$bad = Copy-Fixture; $bad.results.documents = @()
Assert-Rejected 'missing documents' $messages $bad
$bad = Copy-Fixture; $bad.results.documents += $bad.results.documents[0]
Assert-Rejected 'duplicate documents' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].id = '1'
Assert-Rejected 'unexpected document ID' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].warnings = @(@{code = 'DocumentTruncated'})
Assert-Rejected 'truncated document' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].entities[1].offset = 10
Assert-Rejected 'overlapping spans' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].entities[0].length = 500
Assert-Rejected 'out-of-range span' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].entities[0].text = 'Different text'
Assert-Rejected 'mismatched entity text' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].entities[0].category = 'Unsupported'
Assert-Rejected 'unknown category' $messages $bad
$bad = Copy-Fixture; $bad.results.documents[0].Remove('entities')
Assert-Rejected 'missing entities' $messages $bad
$bad = Copy-Fixture; $bad.Remove('results')
Assert-Rejected 'missing results' $messages $bad
$malformedRejected = $false
try { $null = [RedactionPolicy]::Run('[]', '{broken') }
catch [System.Management.Automation.MethodInvocationException] { $malformedRejected = $true }
if (-not $malformedRejected) { throw 'Malformed JSON was accepted' }
Write-Output 'PASS: malformed JSON'

$unicode = [char]::ConvertFromUtf32(0x1F393) + ' Jordan Rivera'
$unicodeMessages = @(@{role = 'user'; content = $unicode})
$unicodeResponse = Copy-Fixture
$unicodeResponse.results.documents[0].entities = @(@{category = 'Person'; offset = 3; length = 13; text = 'Jordan Rivera'})
$result = Invoke-Redaction $unicodeMessages $unicodeResponse
if ($result.messages[0].content -cne ([char]::ConvertFromUtf32(0x1F393) + ' [PERSON_1]')) { throw 'UTF-16 offsets failed' }
Write-Output 'PASS: UTF-16 offsets'

$multi = @($messages[0], @{role = 'user'; content = 'Email jordan.rivera@example.edu'})
$multiResponse = Copy-Fixture
$multiResponse.results.documents = @(
    @{id = '1'; warnings = @(); redactedText = 'Email ************************'; entities = @(
        @{category = 'Email'; offset = 6; length = 25; text = 'jordan.rivera@example.edu'}
    )},
    $multiResponse.results.documents[0]
)
$result = Invoke-Redaction $multi $multiResponse
if ($result.count -ne 3 -or $result.messages[1].content -cne 'Email [EMAIL_2]') { throw 'Reordered multi-document mapping failed' }
Write-Output 'PASS: every user message mapped by ID with request-wide counters'

$emptyResponse = Copy-Fixture
$emptyResponse.results.documents[0].entities = @()
$emptyResponse.results.documents[0].redactedText = 'Summarize CASE-1042.'
$result = Invoke-Redaction @(@{role = 'user'; content = 'Summarize CASE-1042.'}) $emptyResponse
if ($result.count -ne 0 -or $result.status -ne 'ALLOWED') { throw 'No-PII result failed' }
Write-Output 'PASS: no-PII input'

if ($policy.SelectNodes('//forward-request').Count -ne 0) { throw 'Original request must never be forwarded' }
if ($policy.SelectNodes('//send-request[@mode!="new" or @ignore-error!="false"]').Count -ne 0) { throw 'Backend isolation or fail-closed invariant failed' }
if ($policy.SelectNodes('//trace|//log-to-eventhub').Count -ne 0) { throw 'Policy must not log bodies' }
Write-Output 'PASS: no implicit forwarding, fail-open calls, or body logging'

function Assert-Output([string]$Name, [int]$ResponseStatus, $ResponseBody, [string]$Code, [int]$ExpectedStatus) {
    $result = [OutputPolicy]::Run($ResponseStatus, ($ResponseBody | ConvertTo-Json -Depth 30 -Compress)) | ConvertFrom-Json
    if ($result.code -ne $Code -or $result.httpStatus -ne $ExpectedStatus) { throw "FAIL: $Name" }
    if ($ExpectedStatus -ne 200 -and $null -ne $result.output) { throw "FAIL: $Name exposed blocked output" }
    Write-Output "PASS: $Name"
}

$safeOutput = @{
    status = 'completed'
    output = @(
        @{type = 'tool_result'; content = 'PRIVATE SYNTHETIC TOOL RESULT'},
        @{type = 'message'; role = 'assistant'; status = 'completed'; content = @(
            @{type = 'output_text'; text = 'Upload the residency document by October 2.'}
        )}
    )
}
Assert-Output 'completed assistant-only output' 200 $safeOutput SAFE_RESPONSE 200
$raw = [OutputPolicy]::Run(200, ($safeOutput | ConvertTo-Json -Depth 30)) | ConvertFrom-Json
if ($raw.output -ne 'Upload the residency document by October 2.') { throw 'Tool data included in output' }
$idOutput = $safeOutput | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable -Depth 30
$idOutput.output[1].content[0].text = 'Student ID U0001042'
Assert-Output 'deterministic student-ID output block' 200 $idOutput STUDENT_ID_OUTPUT_BLOCKED 422
$attack = @{error = @{code = 'content_filter'; innererror = @{content_filter_result = @{jailbreak = @{filtered = $true}}}}}
Assert-Output 'structured jailbreak block' 400 $attack JAILBREAK_BLOCKED 422
$pii = @{error = @{code = 'content_filter'; innererror = @{content_filter_result = @{pii = @{filtered = $true}}}}}
Assert-Output 'structured input PII block' 400 $pii PII_INPUT_BLOCKED 422
$pii.status = 'incomplete'
$pii.incomplete_details = @{reason = 'content_filter'}
Assert-Output 'structured output PII block' 200 $pii PII_OUTPUT_BLOCKED 422
Assert-Output 'unknown filter type remains generic' 400 @{error = @{code = 'content_filter'; message = 'PRIVATE ERROR DETAIL'}} GUARDRAIL_BLOCKED 422
Assert-Output 'HTTP failure hides backend body' 500 $safeOutput BACKEND_FAILED 502
foreach ($deniedStatus in @(401, 403)) {
    $denied = [OutputPolicy]::Run($deniedStatus, '') | ConvertFrom-Json
    if ($denied.code -ne 'BACKEND_AUTHORIZATION_FAILED' -or $denied.httpStatus -ne 502 -or $null -ne $denied.output) {
        throw 'Empty authorization rejection was not safely normalized'
    }
}
Write-Output 'PASS: empty upstream 401/403 produces an explicit sanitized authorization error'
Assert-Output 'model quota is surfaced without backend details' 429 @{error = @{code = 'rate_limit_exceeded'; message = 'PRIVATE BACKEND DETAIL'}} BACKEND_RATE_LIMITED 429
Assert-Output 'incomplete output is never released' 200 @{status = 'incomplete'; output = $safeOutput.output} BACKEND_FAILED 502
Assert-Output 'action-required response is never released' 200 @{status = 'requires_action'; output = $safeOutput.output} BACKEND_FAILED 502
$rejected = $false
try { $null = [OutputPolicy]::Run(200, '{"status":"completed","output":[]}') }
catch [System.Management.Automation.MethodInvocationException] { $rejected = $true }
if (-not $rejected) { throw 'Empty output was accepted' }
Write-Output 'PASS: empty completed response fails closed'

$inputAnnotation = @{
    error = @{
        code = 'content_filter'
        content_filters = @(@{
            blocked = $true; source_type = 'prompt'
            content_filter_results = @{personally_identifiable_information = @{filtered = $true}}
        })
    }
}
Assert-Output 'live Foundry input PII annotations' 400 $inputAnnotation PII_INPUT_BLOCKED 422
$outputAnnotation = @{
    status = 'incomplete'; incomplete_details = @{reason = 'content_filter'}
    output = $safeOutput.output
    content_filters = @(@{
        blocked = $true; source_type = 'completion'
        content_filter_results = @{personally_identifiable_information = @{filtered = $true}}
    })
}
Assert-Output 'live Foundry output PII annotations suppress all output' 200 $outputAnnotation PII_OUTPUT_BLOCKED 422
$outputAnnotation.status = 'completed'
Assert-Output 'blocked annotation takes precedence over completed status' 200 $outputAnnotation PII_OUTPUT_BLOCKED 422
$inputAnnotation.error.content_filters[0].content_filter_results = @{jailbreak = @{filtered = $true}}
Assert-Output 'live Foundry jailbreak annotations' 400 $inputAnnotation JAILBREAK_BLOCKED 422
$inputAnnotation.error.content_filters[0].source_type = 'tool'
Assert-Output 'unknown intervention point is not mislabeled as user input' 400 $inputAnnotation GUARDRAIL_BLOCKED 422
$inputAnnotation.error.content_filters[0].blocked = $false
Assert-Output 'nonblocking annotation does not invent a category' 400 $inputAnnotation GUARDRAIL_BLOCKED 422
$outputAnnotation.status = 'incomplete'
$outputAnnotation.output = @(
    @{type = 'azure_ai_search_call_output'; content = 'PRIVATE SYNTHETIC RECORD'},
    @{type = 'message'; role = 'assistant'; status = 'completed'; content = @(
        @{type = 'output_text'; text = 'Jordan Rivera'}
    )},
    @{type = 'message'; role = 'assistant'; status = 'completed'; content = @(
        @{type = 'output_text'; text = "I'm sorry, but I cannot assist with that request."}
    )}
)
Assert-Output 'live partial PII before blocking refusal is entirely discarded' 200 $outputAnnotation PII_OUTPUT_BLOCKED 422
