defmodule SymphonyElixir.GitHubProjects.Delivery.QueueConfirmation do
  @moduledoc "Manual Queue testimony supplements verified immutable evidence; it never replaces deployment verification."
  alias SymphonyElixir.DeliveryGate.Command

  @blocker "resume_queue_before_dev_validation"
  @criteria ~w(queue_active scheduler_configured)
  @fields ~w(sha workflow_id run_id run_attempt artifact_id digest policy_hashes)
  @data_fields @fields ++ ~w(criteria queue_resource scheduler_resource confirmed_at_ms source)
  @ttl 30 * 60_000

  @spec criteria() :: [String.t()]
  def criteria, do: @criteria

  @spec candidate?(map() | nil) :: boolean()
  def candidate?(nil), do: false

  def candidate?(observation) do
    deployment = observation.facts["deployment"] || %{}

    Map.get(observation, :complete, false) and inherited_deployment?(deployment) and
      deployment["sha"] == observation.facts["dev_sha"] and valid_binding?(proof_binding(observation))
  end

  defp inherited_deployment?(%{
         "result" => "success",
         "complete" => true,
         "source" => "deployment_evidence",
         "blockers" => [@blocker],
         "scheduler" => "configured",
         "queue" => %{"state" => "paused", "reason" => "inherited_pause"}
       }),
       do: true

  defp inherited_deployment?(_), do: false

  @spec proof_binding(map()) :: map()
  def proof_binding(observation) do
    observation.facts["deployment"] |> Map.take(@fields) |> Map.put("policy_hashes", observation.facts["policy_hashes"])
  end

  @spec valid_data?(map()) :: boolean()
  def valid_data?(data) do
    Enum.sort(Map.keys(data)) == Enum.sort(@data_fields) and valid_binding?(data) and
      data["criteria"] == @criteria and data["source"] == "operator_manual" and
      text?(data["queue_resource"]) and text?(data["scheduler_resource"]) and
      is_integer(data["confirmed_at_ms"]) and data["confirmed_at_ms"] > 0
  end

  @spec apply(map() | nil, map(), integer()) :: map() | nil
  def apply(nil, _, _), do: nil

  def apply(observation, state, now) do
    evidence = state["queue_confirmation"]
    candidate = candidate?(observation)
    usable = candidate and is_map(evidence) and Map.take(evidence, @fields) == proof_binding(observation) and current?(evidence, now)
    facts = observation.facts |> Map.delete("manual_queue_confirmation") |> Map.put("queue_confirmation_invalidated", is_map(evidence) and not usable)

    if candidate do
      deployment = Map.put(facts["deployment"], "environment_ready", usable)
      reasons = Enum.reject(observation.reasons, &(&1 == @blocker))
      facts = Map.put(facts, "deployment", deployment)
      facts = if usable, do: Map.put(facts, "manual_queue_confirmation", evidence), else: facts
      %{observation | facts: facts, reasons: Enum.sort(if(usable, do: reasons, else: [@blocker | reasons]))}
    else
      %{observation | facts: facts}
    end
  end

  defp current?(evidence, now) do
    elapsed = now - evidence["confirmed_at_ms"]
    elapsed >= 0 and (evidence["validated"] == true or elapsed < @ttl)
  end

  defp valid_binding?(data) do
    proof = Command.proof(data) |> Map.merge(%{"actor" => "controller", "reason" => "Queue proof", "criteria" => @criteria})
    hashes = data["policy_hashes"]

    Command.validate("bootstrap", proof) == :ok and is_integer(data["artifact_id"]) and data["artifact_id"] > 0 and
      is_binary(data["digest"]) and Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, data["digest"]) and
      is_map(hashes) and map_size(hashes) > 0 and Enum.all?(hashes, fn {key, value} -> text?(key) and hash?(value) end)
  end

  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp text?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.trim(value) != ""
end
