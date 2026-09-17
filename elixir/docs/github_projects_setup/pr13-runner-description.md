#### Context

The EmotionStat profile must bind the integrated Symphony runtime while keeping execution disabled until explicit local activation.

#### TL;DR

*Pin the PR13 runtime, parameterize the pilot item and label project images for compatibility and cleanup.*

#### Summary

- Keep inspection as the default; obtain the optional single pilot item from local runtime configuration.
- Pin Symphony 4fa7735eb8357305556249e9094827d4b6bf3db7 in the profile and its CI checkout.
- Require runtime contract 2 and label images with the exact profile revision and runtime contract.
- Support installation-owned image tags without changing application hooks, resource limits or GitHub rights.
- Document local model/effort selection and the separate operator steps before a live pilot.

#### Alternatives

- A floating main branch would not prove compatibility with the tested runtime.
- A shared image tag would not establish installation ownership for automatic cleanup.

#### Test Plan

- [x] 31 Python profile tests, no failures or skips, with the pinned Symphony source.
- [x] Real Symphony renderer, Config, Liquid prompt and execution guard checks.
- [x] Build the image from five allowlisted Git blobs at the exact profile revision.
- [x] Rootless Podman/SSH runtime acceptance and all 36 local app checks, followed by cancellation/preservation.
- [ ] Publish Symphony first so this repository's hosted CI can fetch the pinned commit.
- [ ] Hosted CI, independent review and merge by the owner.
