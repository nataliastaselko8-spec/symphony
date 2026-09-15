# GitHub Projects inspection

The `github_projects` tracker reads an organization-owned GitHub Projects v2 board on
github.com. This first implementation supports inspection only. It does not start the
scheduler, create workspaces, run hooks or Codex, change Project items, or publish branches
and pull requests. The existing `github` tracker continues to read repository issues.

## Run a finite inspection

Build the executable with `mise exec -- mix build`, then supply a separate workflow:

```bash
mise exec -- ./bin/symphony --dry-run /absolute/path/to/projects.WORKFLOW.md
```

Use [the inspection example](examples/github_projects.WORKFLOW.md) as a template. Set the
organization, Project number and allowed repository to your own values. The example names
and item ID are placeholders, not a live configuration.

The controller reads an already issued GitHub App installation token from `GITHUB_TOKEN`
(or the environment variable explicitly named by `provider.token`). Request read-only
organization Projects and repository access for inspection, scoped to the intended
installation/repository. App registration and token refresh are separate setup steps;
automatic installation-token renewal is not implemented here. Keep the token outside the
workflow file and repository.

`--dry-run` does not require the unattended-execution acknowledgement. Do not combine it
with `--port` or `--logs-root`. It writes a JSON report and exits zero only after a complete
successful read. Invalid configuration, denied access, malformed responses and incomplete pagination fail
with a nonzero exit rather than a partial success. GraphQL errors also fail, except for the
narrow, inventory-confirmed missing-item case described below.
An empty eligible list is still a successful inspection if the read completed.

## Configuration

Settings belong under `tracker.provider`; `active_states`, `terminal_states` and
`required_labels` remain tracker-level settings.

| Setting | Meaning |
| --- | --- |
| `organization` | Required organization login owning the Project. |
| `project_number` | Required positive Project number within that organization. |
| `repo` | Required allowed repository in `owner/name` form. |
| `token` | Installation token or `$ENV_NAME`; default environment variable is `GITHUB_TOKEN`. |
| `item_ids` | Optional exact Project item node IDs. Omit to inspect the configured Project/repository scope. Use the selected item's real ID for a pilot. |
| `fields.status` | Status field name; default `Status`. |
| `fields.agent_allowed` | Permission field name; default `Agent allowed`. |
| `agent_allowed_value` | Allowed permission option; default `yes`. Quote it in YAML. |
| `states.ready` | Ready status; default `Ready for agent`. |
| `states.working` | Continuing-work status; default `Agent working`. |
| `states.blocked` | Human-decision status; default `Needs human decision`. |
| `states.handoff` | Handoff status; default `PR ready`. |
| `context_fields` | Optional additional field names for inspection. Missing/unsupported optional fields produce diagnostics. |

Omitting `states` uses all four defaults. When supplying that map, provide all four roles.

Set explicit active states including ready/working and explicit terminal states such as
`Done`. Blocked/handoff states must not be active or terminal. Required fields and configured
status options must be unambiguous in the discovered schema. Selection values are checked
against their discovered field and option IDs.

The endpoint is fixed to `https://api.github.com/graphql` in this version. Enterprise hosts
and arbitrary GraphQL endpoints are not supported.

## Report and read contract

The report includes discovered Project/schema information, optional-field diagnostics,
individual item decisions and eligible/excluded counts. Eligibility describes only the
board's read-time criteria. It does **not** authorize execution, prove a free repository
cycle, confirm a healthy deployment or validate operator approval.

Open issues in the allowed repository can satisfy the board criteria. Archived items,
closed issues, drafts, pull requests, inaccessible content, denied permission and items
outside an explicit ID filter are excluded with reasons. Archived items remain visible in
inspection. Configured required labels must also match.

Project item IDs identify scheduled work; the underlying issue node ID and issue number
are separate identifiers in `native_ref`. Removing and re-adding an issue produces a new
item identity, so an old `item_ids` entry does not silently authorize the replacement.
Refresh-by-ID checks Project/repository scope. A `NOT_FOUND` error pointing precisely to a
null entry in `nodes` triggers a complete Project inventory, including archived items. The
reader treats the ID as missing only if that inventory confirms its absence. Every other
GraphQL error, incomplete inventory or still-present item fails the refresh.

Normalized excluded records use explicit placeholder titles for draft, pull-request and
unavailable content. They remain nondispatchable; placeholders do not reconstruct hidden
issue content.

The reader traverses Project fields/items and the used issue label/assignee connections.
Pages contain up to 100 nodes; each connection is bounded to 100 pages. Refresh batches
contain at most 50 IDs, with at most 10,000 requested IDs per operation. Optional context
supports text, number, date, single-select and iteration fields.
Missing, repeated or cyclic pagination cursors are errors. A failed later page invalidates
the entire result. Optional context values are data, never shell commands.

## Execution remains disabled

Ordinary CLI startup, application/Mix startup and release entrypoints reject
`tracker.kind: github_projects` before starting the runtime. Reloading an existing runtime
to this kind is rejected while retaining its last valid workflow.

Do not use the generic execution `WORKFLOW.md` as the Projects inspection profile. Runtime
admission, persistent cycles, manual dev validation, scoped write tools and the operational
agent-runner profile are subsequent implementation stages.

## Verification

The synthetic tests use injected GraphQL responses and need no GitHub App or private board:

```bash
mise exec -- mix test test/symphony_elixir/github_projects_test.exs \
  test/symphony_elixir/github_projects_config_test.exs \
  test/symphony_elixir/github_projects_inspection_test.exs \
  test/symphony_elixir/github_projects_entrypoint_test.exs \
  test/symphony_elixir/cli_test.exs
```

A passing fixture suite does not prove access to a private Project. Perform the first live
inspection after the owner has created/installed the App and supplied the controller's
credentials.

API references: [Projects schema](https://docs.github.com/en/graphql/reference/projects),
[GraphQL pagination](https://docs.github.com/en/graphql/guides/using-pagination-in-the-graphql-api),
[installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
