#### Context

Delivery ownership and budgets must survive controller restarts so an unfinished PR or deployment cannot release the repository for another task.

#### TL;DR

*Persist delivery cycles, execution budgets, cancellation and recovery in a controller-owned Linux store.*

#### Summary

- Add a durable cycle model with separate work/fix time, CI reservations and explicit operator budget extensions.
- Preserve ownership through review, deployment, manual validation, cancellation and approved recovery.
- Use Linux file locking, atomic replacement, checksums and conservative recovery of uncertain accounting.
- Reject stale commands and incompatible settings; keep GitHub Projects execution disabled pending runtime integration.
- Document the controller API and update the rollout plan; stabilize an existing retry timing test for WSL scheduling.

#### Alternatives

- In-memory state loses ownership and budgets on restart; a new database is unnecessary for this single-controller pilot.
- Use a small Python standard-library helper for Linux flock/fsync instead of adding a native dependency to the BEAM.

#### Test Plan

- [x] `make -C elixir all` in Ubuntu WSL2: format, specs, Credo, coverage, Python tests, build and Dialyzer.
- [x] 405 Elixir tests, 0 failures, 6 skipped; 100% measured Elixir coverage. Eight Python tests passed.
- [x] Linux restart, competing writers, stale commands, missing/corrupt state and cancellation/recovery tests.
- [x] Python crash/replace/fsync tests.
- Live worker execution and GitHub Actions mutations are outside this foundation PR.
