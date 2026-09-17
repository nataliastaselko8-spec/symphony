#### Context

EmotionStat needs a portable task profile that prepares its assigned branch and verifies application changes inside the isolated Symphony worker.

#### TL;DR

*Add the EmotionStat WORKFLOW, isolated hooks, verification commands and pinned project image.*

#### Summary

- Render machine settings through Symphony; keep the pilot filter empty and live execution disabled.
- Prepare and continue assigned dev-based branches without worker GitHub credentials or network Git operations.
- Preserve dirty work and conflicts; require current local verification before handoff to the controller.
- Build a scoped image with Node 24, Python, uv, jq and hooks; retain the PR11 filesystem and network boundaries.
- Pin Symphony's companion bundle-transport fix; publish that commit before running this repository's CI.
- Use the approved 256 MiB per-file limit required by workerd; keep other container limits and isolation.

#### Alternatives

- Host hooks and Docker sockets were rejected because they expose resources outside the task container.
- Docker build stays mandatory in GitHub CI and is reported as CI-only in the local verification report.

#### Test Plan

- [x] 31 Python profile tests, including real Git conflicts, restart and controller publication.
- [x] Real Symphony renderer, Config/Settings, Liquid and execution guard.
- [x] Final project-image runtime smoke, verification cancellation and workspace preservation.
- [x] All 36 local app steps passed in the container; Docker build remains CI-only.
- [x] Kernel file-limit canary: workerd size is allowed; files above 256 MiB are rejected.
- [x] Companion Symphony `make -C elixir all`: 552 Elixir tests, 0 failures, 6 skipped.
- [x] No live Project execution, GitHub writes, deployment or model turns.
