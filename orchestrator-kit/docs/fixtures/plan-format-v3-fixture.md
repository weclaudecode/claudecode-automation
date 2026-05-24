---
env: staging
aws:
  account: "123456789012"
  region: ap-southeast-2
  profile: deploy-role
  cdk_app_path: infrastructure
requires: [PLAN-03]
pre_flight:
  issue_title: "PLAN-99 preflight checks"
  checklist:
    - cdk bootstrap done for account 123456789012 in ap-southeast-2
    - AWS_PROFILE=deploy-role set in cron env
    - Bedrock model access confirmed
auto_recommended: false
---

# PLAN-99-v3-fixture — schema v3 test fixture

Exercises every new field introduced in schema v3: `env`, `aws`, `requires`,
`pre_flight`, `deploy_mode`, and `smoke_test`. Used by the ingest-plan.sh
regression test described in PLAN-FORMAT.md.

## Task 1: Add receipt template module
**depends_on:** []
**touches:** [`src/receipts/template.py`]

Add `render_receipt(order: Order) -> str` returning HTML.

## Task 2: Add receipt-sender Lambda
**depends_on:** [1]
**touches:** [`lambdas/send_receipt/**`, `tests/test_send_receipt.py`]
**smoke_test:** python -m pytest tests/integration/test_send_receipt.py -x

Implement the receipt-sender Lambda that calls `render_receipt`.

## Task 3: Deploy receipt-sender stack
**depends_on:** [2]
**touches:** [`infrastructure/stacks/receipt_stack.py`]
**deploy_mode:** autonomous
**auto_merge:** false
**smoke_test:** aws lambda invoke --function-name receipt-sender --payload '{}' /tmp/out.json && cat /tmp/out.json

Deploy the receipt-sender Lambda via CDK. Operator must approve the cdk diff
PR comment before the auto-merge gate passes.
