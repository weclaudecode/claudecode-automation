# Freeform plan — receipts feature

A deliberately rough plan used as a regression fixture for `/plan-format`.
Mixes prose, partial structure, and missing fields by design.

Tasks (rough):

1. Add a receipt template module. Should expose `render_receipt(order)`
   returning HTML. Lives in `src/receipts/template.py`.

2. Add the receipt-sender Lambda. Uses the template from task 1.
   Files: `lambdas/send_receipt/handler.py` + tests under
   `tests/test_send_receipt.py`.

3. Wire the sender into checkout. Modifies `src/checkout/handler.py`.
   Depends on task 2 being merged.

4. Add an IAM role for the Lambda. Files in `infra/iam.tf`.
   This one should NOT auto-merge.

5. Update docs. (No specific files yet — TBD by author.)
