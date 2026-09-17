defmodule SymphonyElixir.Operator.Control do
  @moduledoc "Authenticated operator boundary. Slow read-only observations run outside the lifecycle GenServer."
  alias SymphonyElixir.DeliveryRuntime
  alias SymphonyElixir.Operator.{Auth, Decision, Policy, View}

  @spec prepare(GenServer.server(), String.t(), GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(auth, session, runtime, action) do
    with {:ok, _} <- Auth.check(auth, session, true),
         true <- action in Decision.actions(),
         {:ok, context} <- DeliveryRuntime.operator_context(runtime) do
      form = %{action: action, runtime: runtime, version: context.gate.version, scope: context.settings.gate.scope, stamp: Policy.stamp(context.observation)}
      with {:ok, saved} <- Auth.prepare(auth, session, form), do: {:ok, Map.merge(Map.take(saved, [:id, :action, :version]), View.form(context))}
    else
      false -> {:error, :unknown_operator_action}
      error -> error
    end
  end

  @spec execute(GenServer.server(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def execute(auth, session, id, payload) do
    with {:ok, _} <- Auth.check(auth, session, true),
         {:ok, form} <- Auth.form(auth, session, id),
         {:ok, context} <- DeliveryRuntime.operator_context(form.runtime),
         {:ok, observation} <- observe(auth, session, form, context) do
      DeliveryRuntime.operator_apply(form.runtime, auth, session, id, payload, observation, context.started_at)
    end
  end

  defp observe(auth, session, form, context) do
    if Decision.restrictive?(form.action) or context.gate.version != form.version do
      {:ok, nil}
    else
      with :ok <- Auth.allow_read(auth, session), do: context.observe.(context.config, context.options)
    end
  end
end
