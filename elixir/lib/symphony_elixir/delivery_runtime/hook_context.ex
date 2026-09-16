defmodule SymphonyElixir.DeliveryRuntime.HookContext do
  @moduledoc "Bounded hook input, never a credential or worker authority."

  @spec build(map(), map(), map(), String.t()) :: map()
  def build(settings, status, cycle, interval) do
    %{
      "schema_version" => 1,
      "repo" => settings.repo,
      "project_number" => settings.gate.scope["project_number"],
      "cycle_id" => cycle["id"],
      "version" => status.version,
      "item_id" => cycle["task"]["item_id"],
      "issue_id" => cycle["task"]["issue_id"],
      "branch" => cycle["work"]["branch"],
      "expected_dev_sha" => cycle["work"]["base_sha"],
      "interval_id" => interval,
      "mode" => mode(cycle)
    }
  end

  @spec encode(map()) :: {:ok, String.t()} | {:error, atom()}
  def encode(context) do
    case Jason.encode(context) do
      {:ok, bytes} when byte_size(bytes) <= 16_384 -> {:ok, bytes}
      _ -> {:error, :hook_context_invalid}
    end
  end

  # This is data encoded for a fixed shell decoder, never an interpolated JSON fragment.
  @spec shell_prefix(map()) :: {:ok, String.t()} | {:error, atom()}
  def shell_prefix(context) do
    with {:ok, bytes} <- encode(context) do
      {:ok,
       "SYMPHONY_DELIVERY_CONTEXT=$(printf '%s' '" <>
         Base.encode64(bytes) <>
         "' | base64 -d)\nexport SYMPHONY_DELIVERY_CONTEXT\n"}
    end
  end

  defp mode(%{"recovery" => value}) when not is_nil(value), do: "recovery"
  defp mode(%{"budget" => %{"interval_ids" => []}}), do: "new"
  defp mode(_), do: "continue"
end
