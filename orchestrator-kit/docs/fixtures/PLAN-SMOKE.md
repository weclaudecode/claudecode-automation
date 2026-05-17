# PLAN-SMOKE — exercises scheduler edge cases

Smoke-test fixture targeting `weclaudecode/claudecode-test-target`
(a minimal Python `todoapp` library). The task `touches:` paths point
at that repo's actual structure.

Scheduler scenarios covered:
- No-dep tasks: 1, 2, 4 (any can launch first)
- Dependency chain: 3 → 1 (3 must wait for 1 to merge)
- Parallel-safe pair: 1 + 2 (disjoint files, both can run concurrently)
- File collision: 2 + 3 (same file → must serialize even though their
  deps don't force it)
- Sensitive flag: 4 (touches `infra/` → `auto_merge_overrides[4] = false`)

Expected ingest behavior (validates after Phase 1.2 ships):
- state.json `tasks` object has entries for 1-4 with correct
  `depends_on`, `touches`, `status: "pending"`
- `auto_merge_overrides` is `{"4": false}`

Expected scheduler behavior (validates after Phase 4 ships, MAX_PARALLEL=2):
- Tick 1: launches 1 + 2 (both deps-met, disjoint touches)
- Task 3 cannot launch (deps-blocked on 1)
- Task 4 doesn't launch automatically (needs-robbie → manual review)
- After 1 merges: 3 becomes deps-met but blocked by collision with
  task-2 branch
- After 2 merges: 3 launches

---

## Task 1: Add format_for_display utility
**depends_on:** []
**touches:** [`src/todoapp/format.py`]

Add a new module `src/todoapp/format.py` containing one function
`format_for_display(todo: Todo) -> str` returning `"[ ] title"` or
`"[x] title"` depending on `todo.done`.

Commit: `feat: add format_for_display util`.

## Task 2: Add complete_todo function
**depends_on:** []
**touches:** [`src/todoapp/core.py`]

In `src/todoapp/core.py`, add `complete_todo(id: int) -> Todo` that
marks the matching todo as done and returns it. Raises `KeyError`
if no todo has that id.

Commit: `feat: add complete_todo`.

## Task 3: Add list_todos using format util
**depends_on:** [1]
**touches:** [`src/todoapp/core.py`]

In `src/todoapp/core.py`, add `list_todos(status: str | None = None)
-> list[str]` returning a list of `format_for_display(t)` strings for
matching todos. Imports `format_for_display` from task 1.

Commit: `feat: add list_todos`.

## Task 4: Add IAM role for future Lambda deploy
**depends_on:** []
**touches:** [`infra/iam.tf`]

Add `aws_iam_role.todoapp_lambda_writer` to `infra/iam.tf` with a
minimal trust policy for the AWS Lambda service. Sensitive-flagged by
the ingest pattern detector (touches `infra/` and contains `iam_role`).

Commit: `feat(infra): add todoapp_lambda_writer IAM role`.
