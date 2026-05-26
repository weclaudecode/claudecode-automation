# Security

This kit ships workers launched with `--permission-mode bypassPermissions`
(see `orchestrator-kit/.claude/scripts/launch-worker.sh`). Workers run
without per-tool prompts, and the orchestrator drives them autonomously.
Read this page before installing into any repo you care about.

## What workers can do

Workers run with no per-tool prompts and no human-in-the-loop on individual
actions. Concretely, that means a single worker can:

- Write to any file under the repo, and any path reachable from the worker's
  shell — including files outside the repo if the shell can `cd` to them.
- Run arbitrary Bash, including outbound network calls. `curl`, `wget`,
  `git`, `pip install`, `npm install`, and anything else on `$PATH` are
  fair game.
- Execute any git operation the local checkout permits: commit, push,
  branch creation, branch deletion, even force-push. The kit itself does
  not force-push, but a maliciously crafted plan could steer a worker
  into doing so.
- Call any tool the operator's `gh` token can reach — open PRs, edit
  issues, cut releases, change labels, even modify repo settings. The
  blast radius is exactly the scope of the token.
- Spawn additional `claude -p` invocations. The reviewer phase relies on
  this by design, but the same primitive is available to worker code.

## Safety layers in the kit

Four layers sit between a worker and `main`. None of them is sufficient
on its own; together they reduce, but do not eliminate, the blast radius.

- **Reviewer phase `safety_block` category** — the reviewer flags IAM,
  schema, and secrets findings as `safety_block`, which blocks auto-merge
  and surfaces the PR to the operator. See `orchestrator-kit/.claude/scripts/review-pr.sh`.
- **`auto_merge_overrides`** — at ingest time, sensitive-pattern detection
  disables auto-merge for tasks touching IAM, migrations,
  `.github/workflows/`, and similar paths. See the `SENSITIVE_PATTERNS`
  array in `orchestrator-kit/.claude/scripts/ingest-plan.sh`.
- **Iter cap (`review_iter_cap`)** — reviewer/iterator rounds are capped
  per task (`ORCH_REVIEW_MAX_ITERS`, default 5), so a runaway worker stops
  rather than looping indefinitely. On the cap the task is blocked with
  `blocked_reason: review_iter_cap`. See
  `orchestrator-kit/.claude/scripts/iterate-pr.sh`.
- **Branch protection on `main`** — operator-configured, not enforced by
  the kit itself. The auto-merge gate is only as meaningful as the branch
  protection rules behind it.

## Recommended deployment posture

Treat the kit as you would any other automation with write access to your
repo and an outbound network path.

- **Single-tenant repo** with branch protection enabled. Do not share a
  repo's `.claude/state/` directory between operators — state files are
  trusted input to the next tick.
- **Isolated VM or container** if you are concerned about supply-chain
  compromise of any dependency a worker might `pip install` or
  `npm install`. The kit does not ship containerization; that is on the
  operator.
- **`gh` token scoped to the target repo only**, never org-wide. A worker
  running under an org-wide token can affect repos it was never meant to
  touch.
- **Audit `.claude/state/decisions.md`** after every plan completes.
  Workers log Tier-2 decisions there precisely so they can be reviewed
  after the fact.

## Reporting vulnerabilities

If you find a security issue in the kit, report it privately.

- Email: `robbie@weclaudecode.com`.
- Do **not** open public GitHub issues for security reports. Public
  issues alert attackers before a fix is available.
- Acknowledgement expected within 7 days. Coordinated disclosure preferred.
