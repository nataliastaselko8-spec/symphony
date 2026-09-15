---
tracker:
  kind: github_projects
  provider:
    organization: example-org
    project_number: 1
    repo: example-org/example-repo
    token: $GITHUB_TOKEN
    # Replace this synthetic ID with the selected real Project item node ID.
    # Omit item_ids for discovery of the configured Project/repository scope.
    item_ids:
      - PVTI_REPLACE_WITH_REAL_ITEM_ID
    fields:
      status: Status
      agent_allowed: Agent allowed
    agent_allowed_value: "yes"
    states:
      ready: Ready for agent
      working: Agent working
      blocked: Needs human decision
      handoff: PR ready
    context_fields:
      - Risk
      - Acceptance command
  active_states:
    - Ready for agent
    - Agent working
  terminal_states:
    - Done
  required_labels: []
---

Inspection-only profile. This prompt is never sent to an agent.
