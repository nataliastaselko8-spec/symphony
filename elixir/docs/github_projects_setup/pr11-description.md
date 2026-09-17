#### Context

Developers need portable Symphony setup and a worker that cannot access host files or controller credentials.

#### TL;DR

*Add a portable, isolated worker runtime with verified stop and credential-free code transfer.*

#### Summary

- Separate local machine settings, accepted revision pins and project workflow templates.
- Run task SSH and Codex in a rootless container with scoped network and filesystem restrictions.
- Stop workers on lost heartbeat, deadline or guardian failure; preserve work for reconciliation.
- Export bounded Git bundles after verified stop through controller-owned transport callbacks.
- Keep Projects execution disabled until project hooks and production startup integration.

#### Alternatives

- Host-shell execution would expose user files; global WSL firewall rules would affect unrelated projects.
- GitHub tokens in the worker would bypass the controller publisher, so only Git bundles cross the boundary.

#### Test Plan

- [x] `make -C elixir all`
- [x] Rootless Podman/SSH smoke: filesystem boundaries, IPv4/pasta, IPv6 cgroup canary and public HTTPS.
- [x] Verify stop, preserved workspace, immutable export, lost heartbeat and guardian crash/restart.
- [x] Repeat the smoke under a separate temporary Linux account with a different UID and image store.
- [x] Validate framing, local config, pins, lock contention, stale commands and controller callbacks.
