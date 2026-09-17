#### Context

PR12 exposed partial Git-bundle socket writes and a file-size limit too small for workerd. The owner approved a 256 MiB limit.

#### TL;DR

*Complete Git-bundle writes and allow 256 MiB task files while retaining container isolation.*

#### Summary

- Write complete headers and bodies through the management relay and smoke client.
- Reject writes that make no progress; retain the 80 MiB bundle limit and existing timeouts.
- Cover partial writes and a real 3.5 MB management relay round trip.
- Raise the approved task file limit to 256 MiB and test the actual kernel boundary inside the container.
- Require successful curl completion for the public HTTPS smoke result.
- Record PR12's portable profile, validation results and remaining PR13 integration work.

#### Alternatives

- Larger timeouts cannot recover missing bytes; increasing the socket buffer would only hide the defect.

#### Test Plan

- [x] `make -C elixir all`
- [x] 552 Elixir tests, 0 failures, 6 skipped; format, specs, Credo and Dialyzer passed.
- [x] 31 Python runtime tests, including the multi-megabyte relay round trip.
- [x] PR12 image isolation, network, controller loss, guardian restart and verification cancellation checks.
- [x] A 144 MiB file succeeds and a file above 256 MiB is rejected inside the isolated worker.
- [x] All 36 local app verification steps and handoff-check passed in the isolated PR12 image.
