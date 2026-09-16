#### Context

Delivery ownership and budgets need verified GitHub facts before runtime integration. Old green runs and partial evidence must not open the queue.

#### TL;DR

*Add a read-only delivery observer with pinned evidence checks and a one-shot diagnostic command.*

#### Summary

- Observe Project ownership, PR CI, merge ancestry and development attempts independently of pilot filters.
- Verify bounded ZIP evidence against pinned sources, GitHub jobs, run identity and artifact digest.
- Keep cancellation, recovery and manual validation pending; reject observations for a changed cycle version.
- Add delivery_read credentials and restart-only policy settings without enabling Projects execution.
- Stabilize the existing continuation timer test by checking when the retry was scheduled.

#### Alternatives

- Trusting a green run or producer flag alone misses partial reruns, changed policy and stale deployments.
- Runtime writes, worker dispatch, reruns and operator actions remain separate rollout steps.

#### Test Plan

- [x] `make -C elixir all` — 445 Elixir tests, 0 failures, 6 skipped; 100% measured coverage; 8 Python tests.
- [x] Synthetic observer, hostile archive and temporary controller/store integration tests.
- [x] Read-only EmotionStat/App validation: run 35095177024/1, artifact 10446890300, digest and jobs verified.
- [x] `mix pr_body.check --file docs/github_projects_setup/pr07-description.md`
