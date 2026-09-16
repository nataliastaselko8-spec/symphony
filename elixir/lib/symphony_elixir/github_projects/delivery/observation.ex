defmodule SymphonyElixir.GitHubProjects.Delivery.Observation do
  @moduledoc "Version-bound facts, never an execution permit or an operator decision."

  alias SymphonyElixir.DeliveryGate.State
  alias SymphonyElixir.GitHubProjects.Delivery.Policy

  @derive Jason.Encoder
  defstruct schema_version: 1,
            scope: nil,
            expected_version: nil,
            context_hash: nil,
            observed_at: nil,
            complete: false,
            facts: %{},
            reasons: [],
            retry_after_seconds: nil,
            execution_enabled: false,
            next_task_allowed: false,
            manual_validation: "pending"

  @type t :: %__MODULE__{}

  @spec context(term()) :: {:ok, map()} | {:error, :invalid_observer_context}
  def context(nil), do: {:ok, %{version: nil, mode: :inspection, state: State.new()}}

  def context(%{version: %{epoch: epoch, revision: revision}, mode: mode, state: state} = value)
      when is_binary(epoch) and byte_size(epoch) > 0 and is_integer(revision) and revision >= 0 and is_map(state) do
    if mode in [:bootstrap_required, :needs_reconciliation, :reconciled] and
         state["status"] in ~w(bootstrap_required idle occupied) and Map.has_key?(state, "cycle"), do: {:ok, Map.take(value, [:version, :mode, :state])}, else: {:error, :invalid_observer_context}
  end

  def context(_), do: {:error, :invalid_observer_context}

  @spec new(map(), map(), map(), [String.t()]) :: t()
  def new(settings, context, facts, reasons) do
    %__MODULE__{
      scope: settings.gate.scope,
      expected_version: context.version,
      context_hash: fingerprint(context),
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      facts: facts,
      complete: true,
      reasons: Enum.sort(Enum.uniq(reasons))
    }
  end

  @spec failure(map(), map(), term()) :: t()
  def failure(settings, context, reason) do
    {code, retry} = diagnostic(reason)
    %{new(settings, context, %{}, [code]) | complete: false, retry_after_seconds: retry}
  end

  @spec validate(t(), map(), map()) :: :ok | {:error, atom()}
  def validate(observation, settings, context) do
    cond do
      observation.scope != settings.gate.scope ->
        {:error, :observation_scope_changed}

      observation.expected_version != context.version or observation.context_hash != fingerprint(context) ->
        {:error, :stale_observation}

      not observation.complete ->
        {:error, :observation_incomplete}

      true ->
        :ok
    end
  end

  @doc "Pure command candidates for PR-08; no writes, budget reservation, validation or cycle release."
  @spec commands(t(), map(), map()) :: {:ok, [map()]} | {:error, atom()}
  def commands(observation, settings, context) do
    with :ok <- validate(observation, settings, context),
         true <- context.version != nil do
      {:ok, command_candidates(observation.facts, context.state["cycle"])}
    else
      false -> {:error, :observer_context_required}
      error -> error
    end
  end

  defp command_candidates(_, nil), do: []

  defp command_candidates(facts, cycle) do
    ci = facts["ci"] || %{}
    pr = facts["pr"] || %{}
    ci_command(ci) ++ merge_command(pr, cycle) ++ deployment_command(facts, cycle)
  end

  defp ci_command(%{"origin" => "reserved", "result" => result} = ci) when result in ~w(pending success failure cancelled) do
    [%{action: "observe_ci", args: Map.take(ci, ~w(reservation_id run_id run_attempt result))}]
  end

  defp ci_command(_), do: []

  defp merge_command(%{"state" => "merged", "ancestry" => "included"} = pr, cycle) do
    if cycle["work"]["merge_sha"] == nil and cycle["phase"] in ~w(awaiting_review cancelling) do
      [%{action: "merged", args: %{"pr_number" => pr["number"], "sha" => pr["merge_sha"]}}]
    else
      []
    end
  end

  defp merge_command(_, _), do: []

  defp deployment_command(%{"pr" => %{"state" => "merged", "ancestry" => "included"}} = facts, cycle) do
    deployment = facts["deployment"] || %{}

    if deployment["result"] in ~w(success failure) and deployment["sha"] == facts["dev_sha"] and
         cycle["phase"] in ~w(awaiting_deployment awaiting_validation needs_human_decision cancelling) do
      args = Map.take(deployment, ~w(sha workflow_id run_id run_attempt result environment_ready))
      [%{action: "deployment", args: args}]
    else
      []
    end
  end

  defp deployment_command(_, _), do: []

  # Reconciliation changes only the ephemeral mode, not the observed persisted state.
  defp fingerprint(value), do: value |> Map.take([:version, :state]) |> :erlang.term_to_binary([:deterministic]) |> Policy.hash()
  defp diagnostic({:github_delivery_limited, seconds}), do: {"github_delivery_limited", seconds}
  defp diagnostic({:github_delivery_http, status}), do: {"github_delivery_http_#{status}", nil}
  defp diagnostic({:github_projects_http, status, _}), do: {"github_projects_http_#{status}", nil}
  defp diagnostic(reason) when is_atom(reason), do: {Atom.to_string(reason), nil}
  defp diagnostic(_), do: {"observation_unavailable", nil}
end
