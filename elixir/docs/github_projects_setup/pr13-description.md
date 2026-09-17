#### Context

Projects delivery rules existed, but the launcher could not bind them to isolated workers and explicit model settings.

#### TL;DR

*Connect one pilot task to the isolated runtime, with explicit model/effort pins and confirmed shutdown.*

#### Summary

- Bind clean source, workflow, helper, profile and image revisions before execution; default to inspection.
- Run task code only in the prepared container; retain ownership through CI, review, deployment and validation.
- Select model and reasoning effort locally, verify Codex acknowledgements and stop on model rerouting.
- Preserve incomplete work; collect successful cycles after retention and monitor disk space and owned images.
- Keep shutdown requests across concurrent polling; acknowledge resource stop independently from agent exit.
- Document portable setup, local acceptance and the remaining operator prerequisites for the PR14 pilot.

#### Alternatives

- Host execution and inherited Codex defaults do not provide the required isolation or explicit model selection.
- Process exit alone cannot prove container termination; age alone cannot authorize workspace removal.

#### Test Plan

- [x] `make -C elixir all`
- [x] Runtime, model protocol, lifecycle, cancellation, retention and restart regression tests.
- [x] Pinned agent-runner renderer, profile and command tests.
- [x] Real rootless Podman/SSH isolation, controller loss, export and login-container cleanup acceptance.
- [x] All 36 local app checks and verification cancellation inside the project container.
- [x] Packaged launcher, authenticated dashboard, duplicate launch rejection and confirmed shutdown.
- [ ] Hosted CI and live GitHub/Codex pilot: owner-controlled follow-up, not part of local acceptance.
