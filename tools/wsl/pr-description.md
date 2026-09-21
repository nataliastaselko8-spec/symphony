#### Context

Manual WSL setup depends on one computer and leaves terminals open. New developers need a clean, repeatable installation.

#### TL;DR

*Add a two-distro WSL installer, verified release bundles and background lifecycle commands.*

#### Summary

- Create dedicated controller and worker environments without adopting existing Ubuntu installations.
- Generate configuration and keys; guide GitHub App setup, Codex login and model selection.
- Verify bundle hashes, image labels and isolation; retain checkpoints and diagnostics on failure.
- Supervise background processes and require confirmed shutdown; preserve unfinished work.
- Fix nested maintenance locks and reject unknown service ownership.

#### Alternatives

- Reusing existing Ubuntu hides dependencies and changes developer environments.
- Rebuilding the task image on every computer cannot preserve an already accepted image ID.

#### Test Plan

- [x] 60 Python runtime tests, including subprocess shutdown after supervisor stdin closes.
- [x] 32 Python operator, bootstrap and portable bundle tests with real files, locks and Git repositories.
- [x] Windows PowerShell 5.1: operator, native transport, installer resume and background manager fixtures.
- [ ] Fresh WSL installation, real credentials, terminal-close and Windows suspend/resume acceptance.
- [ ] Product pilot remains a separate operator-controlled step.
