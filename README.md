# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

This fork also provides [read-only GitHub Projects inspection](elixir/docs/github_projects.md).
It supports [controller-owned GitHub App credentials](elixir/docs/github_app_credentials.md)
with automatic token renewal, and [delivery observations](elixir/docs/github_projects_delivery.md)
that verify PRs, development runs and deployment evidence. An internal
[delivery runtime](elixir/docs/delivery_runtime.md) connects retained ownership and budgets
to worker admission, cancellation and cleanup. Its [task publisher](elixir/docs/github_projects_publication.md)
retains publication intent, confines Git writes to the task branch and waits for verified CI.
A local [operator dashboard](elixir/docs/operator_dashboard.md) authenticates the owner and
records version-bound validation, pause, cancellation and recovery decisions in the same store.
It also records manual Queue/Scheduler readiness separately from deployment and application validation.
An isolated demo is available; Projects-based agent execution is not enabled yet.

The fork includes a [portable worker runtime](runtime/README.md): local configuration,
read-only inspection, a rootless Podman worker, scoped network controls, verified stop
and credential-free Git bundle transfer. Machine paths and WSL accounts are configured
outside the checkout. Production Projects execution still requires the later startup integration.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
