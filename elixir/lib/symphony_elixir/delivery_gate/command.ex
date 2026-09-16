defmodule SymphonyElixir.DeliveryGate.Command do
  @moduledoc """
  Closed, JSON-only vocabulary for trusted controller commands.

  Operator identity and observations must be supplied by an authenticated
  controller, never by worker tool arguments. No public endpoint is provided.
  """

  @proof [sha: :sha, workflow_id: :positive, run_id: :positive, run_attempt: :positive]
  @operator [actor: :text, reason: :text]
  @task [item_id: :text, issue_id: :text, branch: :branch]
  @limits [initial_ms: :natural, fix_ms: :natural, fixes: :natural, ci_attempts: :natural, retries_per_sha: :natural]
  @recovery_limits Keyword.merge(@limits, initial_ms: :positive, ci_attempts: :positive)
  @ci_result {:enum, ["pending", "success", "failure", "cancelled", "unknown"]}
  @schemas %{
    "record_restore" => @operator,
    "bootstrap" => @proof ++ @operator ++ [criteria: :strings],
    "reserve" => @task ++ [cycle_id: :text, sha: :sha],
    "start_work" => [interval_id: :text, budget: {:enum, ["initial", "fix"]}],
    "checkpoint" => [interval_id: :text, elapsed_ms: :natural],
    "stop_work" => [interval_id: :text, elapsed_ms: :natural],
    "resolve_interval" => @operator ++ [interval_id: :text, elapsed_ms: :natural],
    "reserve_ci" => [reservation_id: :text, sha: :sha, retry: :boolean, reason: :text],
    "observe_ci" => [reservation_id: :text, run_id: :positive, run_attempt: :positive, result: @ci_result],
    "confirm_ci_not_started" => @operator ++ [reservation_id: :text],
    "external_ci" => [run_id: :positive, run_attempt: :positive, sha: :sha],
    "begin_fix" => [],
    "handoff" => [pr_number: :positive, sha: :sha],
    "merged" => [pr_number: :positive, sha: :sha],
    "deployment" => @proof ++ [result: {:enum, ["success", "failure", "unknown"]}, environment_ready: :boolean],
    "validate_dev" => @proof ++ @operator ++ [criteria: :strings, passed: :boolean],
    "block" => [reason: :text],
    "request_cancel" => @operator,
    "finish_cancel" => @proof ++ @operator ++ [criteria: :strings],
    "complete" => @proof,
    "assign_recovery" => @task ++ @operator ++ [sha: :sha] ++ @recovery_limits,
    "finish_recovery" => @proof,
    "extend_budget" => @operator ++ @limits,
    "resume" => @operator ++ [sha: :sha],
    "review_resume" => @operator ++ @limits ++ [sha: :sha, head_sha: :sha, pr_number: :positive]
  }

  @spec validate(String.t(), map()) :: :ok | {:error, atom()}
  def validate(action, args) do
    case @schemas[action] do
      nil -> {:error, :unknown_command}
      fields -> validate_fields(args, fields)
    end
  end

  @spec proof(map()) :: map()
  def proof(args), do: Map.take(args, Enum.map(@proof, fn {key, _} -> to_string(key) end))

  defp validate_fields(args, fields) when is_map(args) do
    expected = Enum.map(fields, fn {key, _} -> to_string(key) end)

    if Enum.sort(Map.keys(args)) == Enum.sort(expected) and
         Enum.all?(fields, fn {key, type} -> valid?(args[to_string(key)], type) end) do
      :ok
    else
      {:error, :invalid_command_arguments}
    end
  end

  defp validate_fields(_, _), do: {:error, :invalid_command_arguments}

  defp valid?(value, :text), do: is_binary(value) and byte_size(value) in 1..2048 and String.trim(value) != ""
  defp valid?(value, :natural), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
  defp valid?(value, :positive), do: valid?(value, :natural) and value > 0
  defp valid?(value, :boolean), do: is_boolean(value)
  defp valid?(value, :sha), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{40}$/, value)
  defp valid?(value, :strings), do: is_list(value) and length(value) in 1..50 and Enum.all?(value, &valid?(&1, :text))
  defp valid?(value, {:enum, values}), do: value in values

  defp valid?(value, :branch) do
    valid?(value, :text) and String.starts_with?(value, "agent/") and
      Regex.match?(~r/^[A-Za-z0-9_\/-]+$/, value) and not String.contains?(value, "//") and
      not String.ends_with?(value, "/")
  end
end
