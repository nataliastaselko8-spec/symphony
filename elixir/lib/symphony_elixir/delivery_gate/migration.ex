defmodule SymphonyElixir.DeliveryGate.Migration do
  @moduledoc "Explicit, replayable four-to-seven-status migration of a settled pilot."
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DeliveryGate.{Pilot, Settings, Snapshot}

  @legacy ~w(ready working blocked handoff)
  @full @legacy ++ ~w(review dev_validation production_ready)
  @container_policy %{
    "type" => "workspaceWrite",
    "writableRoots" => ["/workspace", "/workspace/repo", "/workspace/repo/.git"],
    "readOnlyAccess" => %{"type" => "fullAccess"},
    "networkAccess" => false,
    "excludeTmpdirEnvVar" => false,
    "excludeSlashTmp" => false
  }

  @spec prepare(map() | nil, map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(source, before, after_config) do
    with {:ok, old, proposed, old_scope, scope} <- contracts(before, after_config),
         source = source || Snapshot.new(old_scope),
         {:ok, _} <- Pilot.inspect(source, old_scope, old.tracker.provider["item_ids"] || []),
         true <- source["schema_version"] == 1 do
      migration = %{"version" => 1, "before" => before, "after" => after_config, "source" => source}
      snapshot = source |> Map.put("schema_version", 2) |> Map.put("scope", scope) |> Map.put("migration", migration)
      revision = snapshot["revision"]

      with {:ok, migrated, :new} <- Snapshot.append(snapshot, "migration:seven-status-v1", revision, "invalidate_queue_confirmation", %{}, 0),
           {:ok, _} <- Pilot.inspect(migrated, scope, proposed.tracker.provider["item_ids"] || []) do
        {:ok, migrated}
      end
    else
      _ -> {:error, :migration_requires_compatible_settled_pilot}
    end
  end

  @spec seed(map(), map(), list()) :: {:ok, map()} | {:error, atom()}
  def seed(migration, scope, commands) do
    with %{"version" => 1, "before" => before, "after" => proposed, "source" => source} when is_map(source) <- migration,
         true <- map_size(migration) == 4 and source["schema_version"] == 1,
         {:ok, old, _, old_scope, ^scope} <- contracts(before, proposed),
         {:ok, _} <- Pilot.inspect(source, old_scope, old.tracker.provider["item_ids"] || []),
         true <- Enum.take(commands, source["revision"]) == source["commands"],
         %{"id" => "migration:seven-status-v1", "action" => "invalidate_queue_confirmation", "args" => %{}, "at_ms" => 0} <- Enum.at(commands, source["revision"]) do
      {:ok, Snapshot.new(scope) |> Map.put("schema_version", 2) |> Map.put("migration", migration)}
    else
      _ -> {:error, :invalid_migration}
    end
  end

  defp contracts(before, proposed) do
    with {:ok, old} <- Schema.parse(before),
         {:ok, target} <- Schema.parse(proposed),
         {:ok, old_gate} <- Settings.from_config(old),
         {:ok, new_gate} <- Settings.from_config(target),
         {:ok, _} <- SymphonyElixir.GitHubProjects.Settings.parse(old.tracker),
         {:ok, _} <- SymphonyElixir.GitHubProjects.Settings.parse(target.tracker),
         states when is_map(states) <- old.tracker.provider["states"],
         next when is_map(next) <- target.tracker.provider["states"],
         true <- Enum.sort(Map.keys(states)) == Enum.sort(@legacy),
         true <- Enum.sort(Map.keys(next)) == Enum.sort(@full) and Map.take(next, @legacy) == states,
         true <- compatible_codex?(old.codex, target.codex),
         normalized = %{
           old
           | tracker: %{old.tracker | provider: Map.put(old.tracker.provider, "states", next)},
             delivery: %{old.delivery | state_path: target.delivery.state_path},
             codex: target.codex
         },
         true <- normalized == target do
      {:ok, old, target, old_gate.scope, new_gate.scope}
    else
      _ -> {:error, :incompatible_migration_contract}
    end
  end

  defp compatible_codex?(old, target) do
    old == target or
      (old.read_timeout_ms == 5_000 and is_nil(old.turn_sandbox_policy) and
         target == %{old | read_timeout_ms: 60_000, turn_sandbox_policy: @container_policy})
  end
end
