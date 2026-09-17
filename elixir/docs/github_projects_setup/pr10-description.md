#### Context

The retained delivery cycle needs authenticated owner decisions before work can resume or dev can be accepted.

#### TL;DR

*Add a local operator dashboard with durable, version-bound decisions and an isolated demonstration.*

#### Summary

- Authenticate one local operator; protect HTTP, LiveView, sessions and forms.
- Persist pause, problem, cancellation, validation, recovery and additive budget decisions through Gate.
- Recheck fresh deployment and PR evidence; reject stale forms and replay decisions without duplicate grants.
- Apply validation and eligible completion atomically; preserve ownership and uncertain work.
- Add a Russian dashboard, setup command, fixture demo and operational documentation.
- Keep Projects execution disabled and inherited Queue pause blocked until its evidence source is selected.

#### Alternatives

- Reuse the existing Runtime/Gate instead of introducing another state writer or a generic command endpoint.
- Keep extended repair unavailable until external stop verification exists; do not reset state or bypass blockers.

#### Test Plan

- [x] `make -C elixir all` stages: 540 Elixir tests, 0 failures, 6 skipped; 100% measured coverage; Dialyzer 0 errors.
- [x] 17 Python store/publisher tests; auth, stale forms, concurrent pause and worker stop tests.
- [x] Desktop demo: login, manual validation, competing forms and logout; narrow-screen layout check.
- [x] `mix pr_body.check --file docs/github_projects_setup/pr10-description.md` and `git diff --check`.
