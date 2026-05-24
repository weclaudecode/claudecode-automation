---
name: agentcore-bundle
description: Quick-reference patterns for AgentCore workers: Bedrock model IDs per region, SigV4 signing for streamable-http MCP Gateway calls, Memory namespace conventions, and fix recipes for defect codes D1-D9. Triggers when building or debugging AgentCore deployments (mentions of "agentcore", "AgentCore", defect codes like "fix D3" or "this is D2", "bedrock model ID region", "SigV4 mcp", "memory namespace"). Does NOT trigger on generic AWS/Bedrock questions — use aws-core:amazon-bedrock for those.
allowed-tools: Read, Bash
---

# AgentCore Quick-Reference Bundle

Complement to `aws-agents:agents-deploy` (full diagnostics) and `agentcore-deploy-runbook` (runbooks). This skill is bullets and code for fast lookup — not a tutorial.

---

## 1. Bedrock Model IDs per Region

Use inference profile IDs, not base model IDs. Region must match the profile prefix.

| Region | Inference profile prefix | Example (Sonnet 4.5) |
|---|---|---|
| US (us-east-1, us-west-2) | `us.anthropic.*` | `us.anthropic.claude-sonnet-4-5-20251001-v1:0` |
| AU (ap-southeast-2) | `au.anthropic.*` | `au.anthropic.claude-sonnet-4-5-20251001-v1:0` |
| APAC fallback | `apac.anthropic.*` | `apac.anthropic.claude-sonnet-4-5-20251001-v1:0` |

**Verify profiles enabled in your account:**
```bash
aws bedrock list-inference-profiles --region ap-southeast-2
```

**Common gotcha (D2):** YAML `model_id` copied from US examples will cause `ValidationException: invalid model identifier` in ap-southeast-2. Always use the `au.` or `apac.` prefix for that region.

---

## 2. SigV4 Signing for Streamable-HTTP MCP Gateway Calls

Every `streamablehttp_client` call against an AgentCore Gateway using `GatewayAuthorizer.using_aws_iam()` **must** be SigV4-signed. Plain headers → 403. (D3)

**`SigV4HttpxAuth` wrapper — copy-paste:**

```python
import boto3
import hashlib
import hmac
from datetime import datetime, timezone
from urllib.parse import urlparse, quote
import httpx

class SigV4HttpxAuth(httpx.Auth):
    """SigV4 auth for httpx. Service: bedrock-agentcore."""

    def __init__(self, region: str | None = None):
        session = boto3.session.Session()
        creds = session.get_credentials().get_frozen_credentials()
        self.access_key = creds.access_key
        self.secret_key = creds.secret_key
        self.token = creds.token
        self.region = region or session.region_name or "us-east-1"
        self.service = "bedrock-agentcore"

    def auth_flow(self, request: httpx.Request):
        now = datetime.now(timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = now.strftime("%Y%m%d")

        parsed = urlparse(str(request.url))
        canonical_uri = quote(parsed.path or "/", safe="/-_.~")
        canonical_qs = parsed.query or ""

        body = request.content or b""
        payload_hash = hashlib.sha256(body).hexdigest()

        headers_to_sign = {
            "content-type": request.headers.get("content-type", "application/json"),
            "host": parsed.netloc,
            "x-amz-date": amz_date,
        }
        if self.token:
            headers_to_sign["x-amz-security-token"] = self.token

        signed_headers = ";".join(sorted(headers_to_sign))
        canonical_headers = "".join(
            f"{k}:{v}\n" for k, v in sorted(headers_to_sign.items())
        )

        canonical_request = "\n".join([
            request.method,
            canonical_uri,
            canonical_qs,
            canonical_headers,
            signed_headers,
            payload_hash,
        ])

        credential_scope = f"{date_stamp}/{self.region}/{self.service}/aws4_request"
        string_to_sign = "\n".join([
            "AWS4-HMAC-SHA256",
            amz_date,
            credential_scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        ])

        def _sign(key: bytes, msg: str) -> bytes:
            return hmac.new(key, msg.encode(), hashlib.sha256).digest()

        signing_key = _sign(
            _sign(
                _sign(
                    _sign(f"AWS4{self.secret_key}".encode(), date_stamp),
                    self.region,
                ),
                self.service,
            ),
            "aws4_request",
        )
        signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

        auth_header = (
            f"AWS4-HMAC-SHA256 Credential={self.access_key}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        )
        request.headers["Authorization"] = auth_header
        request.headers["x-amz-date"] = amz_date
        if self.token:
            request.headers["x-amz-security-token"] = self.token
        yield request
```

**Usage with Strands MCPClient:**
```python
from strands.mcp.client import streamablehttp_client

auth = SigV4HttpxAuth(region="ap-southeast-2")
async with streamablehttp_client(gateway_url, auth=auth) as (read, write, _):
    ...
```

---

## 3. Memory Namespace Conventions

Strategies without `namespaces` do not extract from events → no memory accumulates. (D13)

**Namespace pattern:**
```
firm/{firmId}/accountant/{accountantId}/client/{clientId}/summary
firm/{firmId}/accountant/{accountantId}/client/{clientId}/prefs
firm/{firmId}/accountant/{accountantId}/global/prefs
```

**CDK wiring (stable construct):**
```python
from aws_cdk import aws_bedrockagentcore as agentcore

memory = agentcore.Memory(self, "AgentMemory",
    memory_duration_days=365,
    encryption_key=foundation.cmk,  # D6: must not be commented out
    strategies=[
        agentcore.MemoryStrategy.using_built_in_summarization(
            namespaces=[
                "firm/{firmId}/accountant/{accountantId}/client/{clientId}/summary"
            ]
        ),
        agentcore.MemoryStrategy.using_built_in_user_preference(
            namespaces=[
                "firm/{firmId}/accountant/{accountantId}/client/{clientId}/prefs",
                "firm/{firmId}/accountant/{accountantId}/global/prefs",
            ]
        ),
    ],
)
```

---

## 4. Defect Fix Recipes (D1–D9)

### D1: `foundation_cmk()` stub returns None
**File:** `gateway_stack.py:151,156,182-186`
**Symptom:** CDK synth or deploy fails — `environment_encryption` and log-group `encryption_key` resolve to None.
**Fix:** Delete the `foundation_cmk(self)` helper. Replace with `foundation.cmk` directly (already on the constructor arg). Two call sites: `environment_encryption=foundation.cmk` and `encryption_key=foundation.cmk`.
**Reference:** PLAN.md §0.3 D1

---

### D2: US-only model_id used in ap-southeast-2
**File:** `xero_advisor_agent.yaml:25`
**Symptom:** `ValidationException: invalid model identifier` at runtime.
**Fix:** Change `model_id` from `us.anthropic.claude-sonnet-4-5-20251001-v1:0` to `au.anthropic.claude-sonnet-4-5-20251001-v1:0` (or `apac.` fallback). Verify with `aws bedrock list-inference-profiles --region ap-southeast-2`.
**Reference:** PLAN.md §0.3 D2

---

### D3: Missing SigV4 on MCPClient → 403 on every tool call
**File:** `main.py:73-80`
**Symptom:** Every Gateway MCP call returns 403. Plain `headers=` is not accepted by IAM-authorized Gateway.
**Fix:** Add `SigV4HttpxAuth` (see Section 2 above) and pass `auth=SigV4HttpxAuth(region=REGION)` to `streamablehttp_client`.
**Reference:** PLAN.md §0.3 D3

---

### D4: API Gateway HttpApi does not support response streaming
**File:** `auth_stack.py:97-124`
**Symptom:** Streaming claims in README don't work; responses are buffered or fail.
**Fix:** Replace `HttpApi` + `HttpLambdaIntegration` with Lambda Function URL (`invoke_mode=RESPONSE_STREAM`) fronted by CloudFront (OAC for auth). Alternatively: REST API with `responseStreaming=STREAM`. Simplest MVP: drop streaming, buffer and return single JSON response.
**Reference:** PLAN.md §0.3 D4

---

### D5: Wrong boto3 client for GetWorkloadAccessToken
**File:** `index.py:32`
**Symptom:** `UnknownOperation` on first OAuth call.
**Fix:** Change `boto3.client("bedrock-agentcore-control")` to `boto3.client("bedrock-agentcore")`. `GetWorkloadAccessToken` is a data-plane operation.
**Reference:** PLAN.md §0.3 D5

---

### D6: CMK on Memory commented out
**File:** `agent_stack.py:67`
**Symptom:** Memory stored with AWS-managed key, not CMK — violates per-env encryption requirement.
**Fix:** Uncomment `encryption_key=foundation.cmk` on the Memory construct. Stable `aws_bedrockagentcore` supports this prop (see Section 3 above).
**Reference:** PLAN.md §0.3 D6

---

### D7: VPC PRIVATE_WITH_EGRESS NAT cost (RESOLVED)
**Status:** Resolved in §1.2 Path A — Runtime now uses `RuntimeNetworkConfiguration.using_public()`. No VPC, no NAT.
**Fix (if re-opened):** Switch Runtime network config to `using_public()`. Remove VPC/NAT from FoundationStack; switch tool Lambdas to `AWSLambdaBasicExecutionRole`.
**Reference:** PLAN.md §0.3 D7 (marked RESOLVED 2026-05-24)

---

### D8: `aws_bedrock_agentcore_alpha` graduated to stable
**File:** `gateway_stack.py:15`, `agent_stack.py:14` (and all four stack files)
**Symptom:** Alpha import still works today but will break on future minor; API may silently drift.
**Fix:** Replace `from aws_cdk import aws_bedrock_agentcore_alpha as agentcore` with `from aws_cdk import aws_bedrockagentcore as agentcore` in all four stacks. Keep alpha import only for `Policy*` constructs (the only remaining alpha-only constructs as of `aws-cdk-lib>=2.257`). See `cdk-agentcore` skill for full construct patterns.
**Reference:** PLAN.md §0.3 D8

---

### D9: Module-level boto3 clients
**File:** `main.py:32`, `index.py:32`
**Symptom:** Cold-start failure in Runtime container if region/credentials env vars not set at import time.
**Fix:** Move boto3 client creation inside each function (lazy init). Pattern:

```python
# Before (module-level, fragile):
identity = boto3.client("bedrock-agentcore")

# After (lazy, safe):
def get_identity_client():
    return boto3.client("bedrock-agentcore", region_name=os.environ["AWS_REGION"])
```
**Reference:** PLAN.md §0.3 D9

---

## 5. CDK Construct Quick-Reference

| Construct | Module (aws-cdk-lib >= 2.257) |
|---|---|
| Runtime, Gateway, Memory, Identity, Tools, Evaluation | `aws_cdk.aws_bedrockagentcore` (stable) |
| Policy* constructs | `aws_cdk.aws_bedrock_agentcore_alpha` (still alpha) |

Use `cdk-agentcore` skill for full construct patterns and IAM grant methods (`grant_invoke`, `grant_full_access`).

**Verify stable module available:**
```bash
python3 -c "from aws_cdk import aws_bedrockagentcore; print('ok')"
```
