defmodule SymphonyElixir.DeliveryGate.Snapshot do
  @moduledoc "Versioned snapshot with a bounded command journal for validation and idempotency."

  alias SymphonyElixir.DeliveryGate.State

  @max_commands 20_000

  @spec new(map()) :: map()
  def new(scope), do: %{"schema_version" => 1, "scope" => scope, "revision" => 0, "commands" => [], "state" => State.new()}

  @spec decode(term(), map()) :: {:ok, map()} | {:error, atom()}
  def decode(snapshot, scope) do
    with %{"schema_version" => 1, "scope" => ^scope, "commands" => commands} when is_list(commands) <- snapshot,
         true <- length(commands) <= @max_commands,
         {:ok, rebuilt} <- replay(commands, new(scope)),
         true <- rebuilt == snapshot do
      {:ok, rebuilt}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  @spec append(map(), String.t(), non_neg_integer(), String.t(), map(), integer()) ::
          {:ok, map(), :new | :replayed} | {:error, atom()}
  def append(snapshot, id, revision, action, args, at_ms) do
    existing = Enum.find(snapshot["commands"], &(&1["id"] == id))
    content = %{"id" => id, "expected_revision" => revision, "action" => action, "args" => args}

    cond do
      not valid_identity?(id, at_ms) -> {:error, :invalid_command_identity}
      existing != nil and Map.take(existing, Map.keys(content)) == content -> {:ok, snapshot, :replayed}
      existing != nil -> {:error, :command_id_reused}
      revision != snapshot["revision"] -> {:error, :stale_revision}
      length(snapshot["commands"]) >= @max_commands -> {:error, :journal_full}
      true -> append_new(snapshot, Map.put(content, "at_ms", at_ms))
    end
  end

  defp append_new(snapshot, command) do
    with {:ok, state} <- State.apply_command(snapshot["state"], command["action"], command["args"]) do
      updated = %{snapshot | "state" => state, "revision" => snapshot["revision"] + 1}
      {:ok, Map.put(updated, "commands", snapshot["commands"] ++ [command]), :new}
    end
  end

  defp replay([], snapshot), do: {:ok, snapshot}

  defp replay([command | rest], snapshot) when is_map(command) do
    case append(snapshot, command["id"], command["expected_revision"], command["action"], command["args"], command["at_ms"]) do
      {:ok, updated, :new} -> replay(rest, updated)
      _ -> {:error, :invalid_journal}
    end
  end

  defp replay(_, _), do: {:error, :invalid_journal}

  defp valid_identity?(id, time), do: is_binary(id) and byte_size(id) in 1..200 and is_integer(time) and time >= 0
end
