#### Context

Projects tasks need safe publication without worker write credentials or lost ownership after CI failures and restarts.

#### TL;DR

*Add task-bound tools and durable controller publication of one branch, PR and progress report.*

#### Summary

- Bind six task tools to the active worker permit; reject caller-selected authority and destinations.
- Persist publication intent and reconcile uncertain writes; retain cancellation and repository ownership.
- Verify immutable Git bundles in a fresh controller repository and publish only the assigned task branch.
- Bind PRs before CI; reuse the same PR and report, confirm native linkage and gate readiness on current CI.
- Observe manual CI reruns under Actions read, retaining attempt and repair budgets.
- Keep live Projects execution disabled pending operator UI, worker isolation and runner transport.

#### Alternatives

- Worker write tokens and arbitrary API tools would bypass controller authority and protected-ref restrictions.
- Retrying uncertain mutations or editing PR metadata for progress can duplicate effects and start extra CI runs.

#### Test Plan

- [x] `make -C elixir all`
- [x] Ubuntu WSL2: 508 Elixir tests, 0 failures, 6 skipped; 100% measured coverage.
- [x] 8 Python store tests and 9 Git publisher tests, including concurrent ref changes and untrusted hooks.
- [x] Format, specs, Credo and Dialyzer passed; PR body validated locally.
- [ ] O3c: real App writes, native issue/PR linkage and Project automation; production exporter remains PR-11.
