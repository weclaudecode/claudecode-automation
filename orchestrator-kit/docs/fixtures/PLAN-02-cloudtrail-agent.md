# PLAN-02 — CloudTrail Investigation Agent (AgentCore + Lambda MCP)

End-to-end orchestrator smoke test. Builds a Strands-based agent on
AgentCore Runtime that answers CloudTrail questions via a Lambda tool
exposed through AgentCore Gateway. Scope is **code + `cdk synth`** only —
no live AWS deploys, no real bills.

## Orchestrator scenarios covered

- **Parallel-safe pair**: tasks 3 + 4 (LookupEvents tools vs Lake tool — disjoint files under `lambda/cloudtrail_tool/tools/`)
- **Parallel trio**: tasks 5 + 6 + 8 (tests vs infra vs agent code — fully disjoint)
- **Sensitive flag → needs-robbie**: task 6 (`infra/` IAM) and task 9 (`.github/workflows/`)
- **Dep chain**: 1 → 2 → 3,4 → 5,6,8 → 7 → 9
- **Plan completion**: terminal state when all tasks merge → `done`

## Architecture (see design notes for full blueprint)

- **Lambda** (`lambda/cloudtrail_tool/`): MCP-compatible handler, 6 narrow tools
  - Dispatcher reads `bedrockAgentCoreToolName` from context, strips `___` prefix
  - Auto-discovers tool modules via `pkgutil.iter_modules` (no central registry)
  - Module-scope boto3 clients (`cloudtrail`, `cloudtrail-data`)
  - Returns `{content:[{type:text,text:...}], isError:bool}` per MCP spec
  - Guardrails enforced BEFORE boto3 call: 14d lookback cap, 200 result cap, 1 GB Lake scan cap via EXPLAIN
- **CDK Python** (`infra/`): three stacks — Lambda+IAM, Gateway+Target, Runtime+Memory+Identity
- **Strands agent** (`src/cloudtrail_agent/`): system prompt + Runtime entrypoint
- **Tests** (`tests/`): pytest + moto for boto3 mocks, plus `cdk synth` validation in CI

---

## Task 1: Project bootstrap
**depends_on:** []
**touches:** [`pyproject.toml`, `.python-version`, `uv.lock`, `lambda/cloudtrail_tool/__init__.py`, `lambda/cloudtrail_tool/tools/__init__.py`, `src/cloudtrail_agent/__init__.py`, `infra/__init__.py`, `tests/__init__.py`, `tests/conftest.py`]

Lay down the project skeleton — directories, package markers, dependencies. No business logic.

Steps:
1. Add dependencies to `pyproject.toml`:
   - Runtime: `boto3>=1.35`, `aws-lambda-powertools>=3.0`, `strands-agents`, `bedrock-agentcore-sdk-python`
   - Dev: `pytest>=8`, `moto[cloudtrail]>=5`, `aws-cdk-lib>=2.150`, `constructs>=10`
2. Set `requires-python = ">=3.11"` and create `.python-version` with `3.11`.
3. Create empty package files: each `__init__.py` listed in `touches:`.
4. Create `tests/conftest.py` with one fixture: `aws_credentials` that exports dummy AWS env vars so moto initializes cleanly.
5. Run `uv lock` to generate `uv.lock`. Commit the lockfile.

Commit: `chore: bootstrap CloudTrail agent project`

## Task 2: Lambda MCP dispatcher
**depends_on:** [1]
**touches:** [`lambda/cloudtrail_tool/handler.py`, `lambda/cloudtrail_tool/_mcp.py`, `lambda/cloudtrail_tool/_guardrails.py`, `tests/test_dispatcher.py`]

The handler skeleton + tool auto-discovery + shared guardrail module. Per the `tool-lambda` skill: flat event, `___`-prefixed tool name from context, `success()`/`error()` returns. **No tool logic in this task.**

Steps:
1. `_mcp.py`: define `success(data) -> dict`, `error(message, details=None) -> dict`, `get_tool_name(context) -> str` (strips `___` prefix). All three follow the tool-lambda skill template verbatim.
2. `_guardrails.py`: constants `MAX_LOOKBACK_DAYS = 14`, `MAX_RESULTS = 200`, `MAX_LAKE_SCAN_BYTES = 1 * 1024**3`; functions `clamp_lookback_days(n) -> int`, `clamp_result_count(n) -> int`, `assert_scan_within_budget(estimated_bytes)` (raises `GuardrailExceeded` on too-large).
3. `handler.py`:
   - Module-scope: `logger = Logger()`, `tracer = Tracer()`.
   - `discover_tools()` uses `pkgutil.iter_modules(__path__)` on `tools/` package; each tool module must export `TOOLS: dict[str, callable]`. Returns merged dict.
   - `handler(event, context)`: get tool_name via `_mcp.get_tool_name`; if not in `discover_tools()`, return `error(f"Unknown tool: {tool_name}")`; otherwise call `tools_map[tool_name](event)` and return result. Catch all exceptions at the handler level and return `error(str(e), {"tool": tool_name})`.
   - Use `@logger.inject_lambda_context` and `@tracer.capture_lambda_handler` decorators.
4. `tests/test_dispatcher.py`: use `make_context(tool_name)` helper (per the tool-lambda skill); test the unknown-tool error path and that uncaught exceptions in a tool function become `error()` responses.

Run `uv run pytest tests/test_dispatcher.py -q` before committing.

Commit: `feat(lambda): MCP dispatcher + guardrail module`

## Task 3: LookupEvents-based tools
**depends_on:** [2]
**touches:** [`lambda/cloudtrail_tool/tools/lookup.py`, `lambda/cloudtrail_tool/tools/summarize.py`, `tests/test_tools_lookup.py`, `tests/test_tools_summarize.py`]

Four narrow tools wrapping `cloudtrail:LookupEvents`. All apply the guardrails from `_guardrails.py` BEFORE the boto3 call.

Steps:
1. `tools/lookup.py`:
   - Module-scope: `cloudtrail = boto3.client("cloudtrail")`.
   - Functions: `lookup_by_user(event)`, `lookup_by_resource(event)`, `lookup_by_event_name(event)`, `investigate_event(event)`.
   - Each accepts `lookback_days` (clamped to `MAX_LOOKBACK_DAYS`), `max_results` (clamped to `MAX_RESULTS`).
   - `lookup_by_user`: filter on `LookupAttributes=[{AttributeKey: 'Username', AttributeValue: event['username']}]`.
   - `lookup_by_resource`: filter on `ResourceName`.
   - `lookup_by_event_name`: filter on `EventName`.
   - `investigate_event`: filter on `EventId` (single event); return the full CloudTrail record including `CloudTrailEvent` JSON payload.
   - Each returns `success({events:[...], count:N, lookback_days:M, refused:None})` or `error(...)` if required param missing.
   - Export `TOOLS = {"lookup_by_user": lookup_by_user, ...}`.
2. `tools/summarize.py`:
   - Module-scope client same as above.
   - One function: `summarize_window(event)`. Accepts `lookback_days`, optional `group_by` ('username' | 'eventName' | 'eventSource').
   - Fetch events via `LookupEvents` (clamped), aggregate counts by the group_by field. Return top-20 by count.
   - Export `TOOLS = {"summarize_window": summarize_window}`.
3. Tests use `moto.mock_aws()` with `boto3.client("cloudtrail")` populated with synthetic events. Cover: happy path, missing param error, lookback > MAX_LOOKBACK_DAYS clamped to 14.

Run `uv run pytest tests/test_tools_lookup.py tests/test_tools_summarize.py -q`.

Commit: `feat(lambda): lookup_by_user, lookup_by_resource, lookup_by_event_name, summarize_window, investigate_event tools`

## Task 4: Lake analytical_query tool
**depends_on:** [2]
**touches:** [`lambda/cloudtrail_tool/tools/lake.py`, `tests/test_tools_lake.py`]

The Lake tool — wraps `cloudtrail-data:StartQuery` with an EXPLAIN preflight to enforce the scan budget. Runs in parallel with task 3 (different files under `tools/`).

Steps:
1. `tools/lake.py`:
   - Module-scope: `cloudtrail_data = boto3.client("cloudtrail-data")`.
   - Function `analytical_query(event)`. Required params: `event_data_store_arn`, `sql` (a CloudTrail Lake SQL string).
   - **Step A — EXPLAIN preflight**: prepend `EXPLAIN` to the user's SQL, call `StartQuery` with `QueryAlias='preflight'`; poll `DescribeQuery` until status is `FINISHED`; fetch results via `GetQueryResults`. The result includes an estimated bytes-scanned figure — extract it and call `assert_scan_within_budget(estimated_bytes)` from `_guardrails`. If `GuardrailExceeded` raised, return `error("Query would scan X bytes; max is Y bytes")`.
   - **Step B — actual query**: only if preflight passed, call `StartQuery` with the original SQL. Poll up to 30s (configurable via `event['timeout_seconds']` clamped to 60). Return results via `success({rows:[...], scanned_bytes:N, runtime_ms:M})`.
   - Export `TOOLS = {"analytical_query": analytical_query}`.
2. `tests/test_tools_lake.py`: use moto's cloudtrail-data mock (or hand-roll a botocore stub if moto coverage is missing). Cover: scan-budget exceeded returns error; happy path returns rows; missing required param returns error.

Run `uv run pytest tests/test_tools_lake.py -q`.

Commit: `feat(lambda): analytical_query tool with EXPLAIN preflight and scan budget`

## Task 5: Cross-tool integration tests
**depends_on:** [3, 4]
**touches:** [`tests/test_integration.py`]

End-to-end tests through the dispatcher — confirms `discover_tools()` finds all 6 tools and dispatches correctly. Validates the public API as a whole.

Steps:
1. Single test file. Use `make_context(tool_name)` to invoke `handler.handler(event, context)` directly.
2. Cover each tool at least once with a moto-populated CloudTrail. Verify each returns valid MCP response (`isError` is `False`, `content[0].type == "text"`, JSON-parseable text body).
3. One refusal test: `lookup_by_user` with `lookback_days=90` returns events from at-most a 14-day window (clamp evidence).

Run `uv run pytest -q` (all tests).

Commit: `test: cross-tool integration coverage via dispatcher`

## Task 6: CDK Lambda stack (sensitive — IAM)
**depends_on:** [3, 4]
**touches:** [`infra/app.py`, `infra/stacks/lambda_stack.py`]

CDK stack that builds the Lambda function and its IAM role. **Sensitive** — touches `infra/` and adds IAM permissions. Will auto-flag `needs-robbie` at ingest.

Steps:
1. `infra/app.py`: `aws_cdk.App()`, instantiate `LambdaStack(app, "CloudTrailToolStack")`. Tag everything with `Project=cloudtrail-agent`.
2. `infra/stacks/lambda_stack.py`:
   - Python Lambda asset from `lambda/cloudtrail_tool/`, handler = `handler.handler`, runtime = Python 3.11, memory = 512 MB, timeout = 60s.
   - Layer for `aws-lambda-powertools` (bundled or use Powertools' public layer ARN per region).
   - IAM role with three policy statements (least-priv):
     - `cloudtrail:LookupEvents` on `*` (no resource-level constraint exists for this action)
     - `cloudtrail-data:StartQuery`, `cloudtrail-data:GetQueryResults`, `cloudtrail-data:DescribeQuery`, `cloudtrail-data:CancelQuery` on `arn:aws:cloudtrail:*:*:eventdatastore/*`
     - Logs writes to the function's own log group
   - Export `lambda_arn` and `lambda_name` as CfnOutput for downstream stacks.
3. **Do NOT run `cdk deploy`** — only `cdk synth` to validate the stack compiles.

Verification: `cd infra && uv run cdk synth CloudTrailToolStack > /dev/null` exits 0.

Commit: `feat(infra): CDK Lambda stack with least-priv CloudTrail IAM`

## Task 7: CDK Agent stack (Gateway + Runtime + Memory + Identity)
**depends_on:** [6]
**touches:** [`infra/stacks/agent_stack.py`, `infra/app.py`]

The remaining AgentCore wiring. Depends on the Lambda stack because Gateway target needs the Lambda ARN.

Steps:
1. `infra/stacks/agent_stack.py` using `aws_cdk.aws_bedrock_agentcore_alpha` (per the `cdk-agentcore` skill patterns):
   - `Gateway`: name `cloudtrail-tools`, protocol MCP.
   - `GatewayTarget`: type Lambda, ARN from import value of `CloudTrailToolStack.lambda_arn`; tool prefix `cloudtrail`. (Resulting tool names exposed to the agent: `cloudtrail___lookup_by_user`, etc.)
   - `Memory`: type session (short-term only), TTL 1 hour.
   - `AgentRuntime`: from a `AgentRuntimeArtifact` pointing at `src/cloudtrail_agent/` (the Strands code lands in task 8 — this task creates the placeholder artifact reference; if cdk synth complains about missing dir, create an empty `src/cloudtrail_agent/main.py` in this task).
   - Cognito user pool with one group `cloudtrail-admins`. Pass user pool ARN to AgentCore Identity Inbound config.
2. Append `AgentStack(app, "CloudTrailAgentStack")` to `infra/app.py` AFTER `LambdaStack`.

Verification: `cd infra && uv run cdk synth --all > /dev/null` exits 0.

Commit: `feat(infra): CDK agent stack — Gateway, Runtime, Memory, Cognito Identity`

## Task 8: Strands agent code
**depends_on:** [3, 4]
**touches:** [`src/cloudtrail_agent/main.py`, `src/cloudtrail_agent/prompt.py`, `tests/test_agent_prompt.py`]

The Strands agent entrypoint and its system prompt. Runs in parallel with tasks 5, 6 (touches independent files).

Steps:
1. `src/cloudtrail_agent/prompt.py`:
   - Constant `SYSTEM_PROMPT`: positions the agent as a CloudTrail investigator. Lists the 6 available tools and their purposes. Instructs the agent to always cite event IDs in conclusions. Forbids the agent from making un-tooled claims about AWS state.
   - Constant `REFUSAL_GUIDANCE`: tells the agent how to respond when a tool returns a guardrail-exceeded error (suggest narrower time window, narrower filter).
2. `src/cloudtrail_agent/main.py`:
   - Import `from strands import Agent, tool` and `from bedrock_agentcore.runtime import BedrockAgentCoreApp` (per AgentCore SDK).
   - Construct `Agent(system_prompt=SYSTEM_PROMPT, tools=<list discovered via MCP target>, model='anthropic.claude-sonnet-4-6')`.
   - Wrap in `BedrockAgentCoreApp` for Runtime hosting.
   - Expose `app` at module top level so AgentCore Runtime finds it.
3. `tests/test_agent_prompt.py`: assert `SYSTEM_PROMPT` mentions each of the 6 tool names and the refusal guidance terminology.

Verification: `uv run pytest tests/test_agent_prompt.py -q`.

Commit: `feat(agent): Strands CloudTrail agent + system prompt`

## Task 9: CI workflow (sensitive — .github/workflows)
**depends_on:** [5, 6, 7, 8]
**touches:** [`.github/workflows/ci.yml`]

GitHub Actions workflow that runs `pytest` + `cdk synth --all` on every PR. **Sensitive** — `.github/workflows/` triggers the orchestrator's needs-robbie path AND the reviewer's safety_block category if it tries to widen trigger conditions or permissions.

Steps:
1. `.github/workflows/ci.yml`:
   - Triggers: `pull_request` to `main`, `push` to `main`.
   - Permissions block: `contents: read`, `pull-requests: read`. **No `write` permissions** — the workflow is verification-only.
   - Single job `test` (matches the existing branch-protection required-check name on the test target):
     - `actions/checkout@v4`
     - `astral-sh/setup-uv@v3` (no cache flag — kit's CLAUDE.md notes that requires committed uv.lock; we have one from task 1)
     - `uv sync --frozen`
     - `uv run pytest -q`
     - `uv run cdk synth --all` (cwd `infra/`)
2. Do not add deploy steps. Scope is verification only.

Verification: `cat .github/workflows/ci.yml | yq '.permissions'` shows only `read` keys; `uv run yamllint .github/workflows/ci.yml` (if yamllint installed) returns 0.

Commit: `ci: pytest + cdk synth verification workflow`
