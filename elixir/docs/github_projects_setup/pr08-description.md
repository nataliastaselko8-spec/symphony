#### Context

The delivery gate and observer did not control scheduler dispatch, continuation or cleanup. Worker lifecycle paths needed to retain ownership and enforce cancellation and budgets.

#### TL;DR

*Bind Projects workers to the durable delivery cycle while keeping production execution disabled.*

#### Summary

- Reserve time before effects and bind a single-use activation permit to one worker process.
- Recheck hooks and turns; retain ownership through CI, review, deployment, cancellation and recovery.
- Apply version-bound observations with bounded polling, freshness deadlines and idempotent accounting.
- Stop on reload or lost authority; block replacement and cleanup when external shutdown is unconfirmed.
- Add bounded JSON hook context, internal snapshots, lifecycle tests and rollout documentation.
- Stabilize an existing retry timer test against WSL scheduling delays without changing retry behavior.

#### Alternatives

- Scheduler-only filtering cannot protect active turns, retry paths or workspace cleanup.
- Treating SSH disconnect as shutdown could overlap workers; require transport proof before replacement.
- Live rollout waits for scoped publication, operator authentication and verified SSH/Podman shutdown.

#### Test Plan

- [x] `make -C elixir all`
- [x] 473 Elixir tests, 0 failures, 6 skipped; 100% measured coverage and 8 Python store tests.
- [x] Format, specs, Credo, Dialyzer, PR body validation and `git diff --check`.
