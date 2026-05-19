# PLAN-99-freeform — receipts feature (regression fixture)

Reference shape `/plan-format` is expected to produce from
`freeform-plan-input.md`. Not byte-for-byte enforced (Claude may
phrase task bodies differently); validates structural correctness
via `ingest-plan.sh`.

## Task 1: Add a receipt template module
**depends_on:** []
**touches:** [`src/receipts/template.py`]

Expose `render_receipt(order)` returning HTML.

## Task 2: Add the receipt-sender Lambda
**depends_on:** []
**touches:** [`lambdas/send_receipt/handler.py`, `tests/test_send_receipt.py`]

Uses the template from task 1.

## Task 3: Wire the sender into checkout
**depends_on:** [2]
**touches:** [`src/checkout/handler.py`]

After successful checkout, invoke the receipt-sender.

## Task 4: Add an IAM role for the Lambda
**depends_on:** []
**touches:** [`infra/iam.tf`]

Minimal trust policy for AWS Lambda service. Sensitive — flagged by
ingest auto-detector.

## Task 5: Update docs
**depends_on:** []
**touches:** [`docs/receipts.md`]

User-supplied during gap-fill (input had no explicit file path).
