#### Context

The PR12 application bundle stalled before worker preparation because one raw socket write could send only part of the frame.

#### TL;DR

*Complete partial socket writes before reading a response; retain existing protocol and isolation limits.*

#### Summary

- Write complete headers and bodies through the management relay and smoke client.
- Reject writes that make no progress; retain the 80 MiB bundle limit and existing timeouts.
- Cover partial writes and a real 3.5 MB management relay round trip.
- Record PR12's portable profile, validation results and remaining PR13 integration work.

#### Alternatives

- Larger timeouts cannot recover missing bytes; increasing the socket buffer would only hide the defect.

#### Test Plan

- [x] `make -C elixir all`
- [x] 552 Elixir tests, 0 failures, 6 skipped; format, specs, Credo and Dialyzer passed.
- [x] 31 Python runtime tests, including the multi-megabyte relay round trip.
- [x] PR12 image isolation, network, controller loss, guardian restart and verification cancellation checks.
- [ ] Full app acceptance is blocked by the existing 128 MiB file limit; see pr12-validation.md.
